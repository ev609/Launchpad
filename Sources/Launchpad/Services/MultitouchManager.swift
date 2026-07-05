import Foundation

// MARK: - Структуры приватного MultitouchSupport.framework
// Раскладка полей должна точно совпадать с C-структурой Finger (sizeof == 96),
// иначе индексация массива касаний будет неверной.

struct MTPoint { var x: Float = 0; var y: Float = 0 }
struct MTReadout { var pos = MTPoint(); var vel = MTPoint() }

struct MTTouch {
    var frame: Int32 = 0
    var timestamp: Double = 0
    var identifier: Int32 = 0
    var state: Int32 = 0
    var unknown1: Int32 = 0
    var unknown2: Int32 = 0
    var normalized = MTReadout()
    var size: Float = 0
    var unknown3: Int32 = 0
    var angle: Float = 0
    var majorAxis: Float = 0
    var minorAxis: Float = 0
    var absolute = MTReadout()
    var unknown4: Int32 = 0
    var unknown5: Int32 = 0
    var density: Float = 0
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
// В сигнатуре @convention(c) используем сырые указатели (struct-указатель там непредставим).
private typealias MTContactCallback =
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
private typealias MTDeviceFn = @convention(c) (MTDeviceRef, Int32) -> Void

/// C-callback не может захватывать контекст — обращается к синглтону.
private func multitouchCallback(_ device: UnsafeMutableRawPointer?,
                                _ touches: UnsafeMutableRawPointer?,
                                _ count: Int32,
                                _ timestamp: Double,
                                _ frame: Int32) -> Int32 {
    let typed = touches?.assumingMemoryBound(to: MTTouch.self)
    MultitouchManager.shared?.handle(touches: typed, count: Int(count))
    return 0
}

/// Читает касания трекпада и распознаёт щипок «внутрь» несколькими пальцами
/// (жест открытия старого Launchpad).
final class MultitouchManager {
    static var shared: MultitouchManager?

    /// Вызывается на главном потоке при щипке внутрь (сведение пальцев).
    var onPinchIn: (() -> Void)?
    /// Вызывается на главном потоке при щипке наружу (разведение пальцев).
    var onPinchOut: (() -> Void)?

    private var devices: [MTDeviceRef] = []
    private var handle: UnsafeMutableRawPointer?

    /// Число найденных трекпад-устройств (для диагностики).
    var deviceCount: Int { devices.count }
    /// Максимум одновременных касаний, замеченных с момента старта (для диагностики).
    private(set) var maxTouchesSeen: Int = 0

    // Состояние распознавания (доступ только из callback-потока).
    private var minRadius: Float?
    private var maxRadius: Float?
    private var startCentroid: (x: Float, y: Float)?
    private var lastFire: Double = 0

    /// Диагностика: печать кадров касаний (для калибровки порогов).
    var logging = false

    init() {
        MultitouchManager.shared = self
    }

    /// Загружает фреймворк и запускает все трекпад-устройства.
    func start() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let h = dlopen(path, RTLD_NOW) else { return }
        handle = h

        guard let createSym = dlsym(h, "MTDeviceCreateList"),
              let registerSym = dlsym(h, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(h, "MTDeviceStart") else { return }

        let createList = unsafeBitCast(createSym, to: MTDeviceCreateListFn.self)
        let register = unsafeBitCast(registerSym, to: MTRegisterFn.self)
        let deviceStart = unsafeBitCast(startSym, to: MTDeviceFn.self)

        guard let list = createList()?.takeRetainedValue() else { return }
        let n = CFArrayGetCount(list)
        for i in 0..<n {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, multitouchCallback)
            deviceStart(device, 0)
            devices.append(device)
        }
    }

    /// Обрабатывает кадр касаний. Щипок отличается от свайпа смены пространств
    /// по СООТНОШЕНИЮ: у щипка радиус разброса меняется сильно, а центр стоит;
    /// у свайпа наоборот — центр едет, радиус почти постоянен.
    func handle(touches: UnsafeMutablePointer<MTTouch>?, count: Int) {
        if count > maxTouchesSeen { maxTouchesSeen = count }
        // Жест открытия — 3–5 пальцев. Свайпы отсекаются по соотношению ниже.
        guard let touches, count >= 3, count <= 5 else {
            resetGesture()
            return
        }
        let buf = UnsafeBufferPointer(start: touches, count: count)

        // Центр масс касаний.
        var cx: Float = 0, cy: Float = 0
        for t in buf { cx += t.normalized.pos.x; cy += t.normalized.pos.y }
        cx /= Float(count); cy /= Float(count)

        // Средний радиус разброса пальцев.
        var radius: Float = 0
        for t in buf {
            let dx = t.normalized.pos.x - cx
            let dy = t.normalized.pos.y - cy
            radius += (dx * dx + dy * dy).squareRoot()
        }
        radius /= Float(count)

        if logging {
            print(String(format: "fingers=%d centroid=(%.3f,%.3f) radius=%.3f", count, cx, cy, radius))
        }

        // Начало жеста — запоминаем точку старта.
        guard let start = startCentroid, minRadius != nil, maxRadius != nil else {
            startCentroid = (cx, cy)
            minRadius = radius
            maxRadius = radius
            return
        }
        minRadius = min(minRadius!, radius)
        maxRadius = max(maxRadius!, radius)

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFire > 1.0 else { return }

        // Смещение центра от старта жеста и изменение радиуса.
        let centroidDisp = ((cx - start.x) * (cx - start.x) + (cy - start.y) * (cy - start.y)).squareRoot()
        let shrink = maxRadius! - radius   // сведение (открыть)
        let grow = radius - minRadius!     // разведение (закрыть)

        // Щипок: изменение радиуса доминирует над смещением центра (иначе это свайп).
        if shrink > 0.06, shrink > centroidDisp * 1.2, radius < 0.24 {
            lastFire = now
            resetGesture()
            DispatchQueue.main.async { [weak self] in self?.onPinchIn?() }
        } else if grow > 0.06, grow > centroidDisp * 1.2 {
            lastFire = now
            resetGesture()
            DispatchQueue.main.async { [weak self] in self?.onPinchOut?() }
        }
    }

    private func resetGesture() {
        startCentroid = nil
        minRadius = nil
        maxRadius = nil
    }
}
