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
    private var prevCentroid: (x: Float, y: Float)?
    private var lastFire: Double = 0

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

    /// Обрабатывает кадр касаний. Щипок — это сведение/разведение 4–5 пальцев
    /// БЕЗ движения центра. Свайп смены рабочих столов отсекается по движению центроида.
    func handle(touches: UnsafeMutablePointer<MTTouch>?, count: Int) {
        if count > maxTouchesSeen { maxTouchesSeen = count }
        // Открытие Launchpad — жест «большой + 3 пальца» (4–5 касаний).
        // 3-пальцевый свайп смены пространств сюда не попадает.
        guard let touches, count >= 4, count <= 5 else {
            minRadius = nil
            maxRadius = nil
            prevCentroid = nil
            return
        }
        let buf = UnsafeBufferPointer(start: touches, count: count)

        // Центр масс касаний.
        var cx: Float = 0, cy: Float = 0
        for t in buf { cx += t.normalized.pos.x; cy += t.normalized.pos.y }
        cx /= Float(count); cy /= Float(count)

        // Если центр заметно поехал — это свайп (перелистывание пространств),
        // а не щипок. Сбрасываем накопление.
        if let pc = prevCentroid {
            let move = ((cx - pc.x) * (cx - pc.x) + (cy - pc.y) * (cy - pc.y)).squareRoot()
            prevCentroid = (cx, cy)
            if move > 0.012 {
                minRadius = nil
                maxRadius = nil
                return
            }
        } else {
            prevCentroid = (cx, cy)
        }

        // Средний радиус разброса пальцев.
        var radius: Float = 0
        for t in buf {
            let dx = t.normalized.pos.x - cx
            let dy = t.normalized.pos.y - cy
            radius += (dx * dx + dy * dy).squareRoot()
        }
        radius /= Float(count)

        // Обновляем экстремумы за текущий жест.
        minRadius = min(minRadius ?? radius, radius)
        maxRadius = max(maxRadius ?? radius, radius)
        guard let lo = minRadius, let hi = maxRadius else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFire > 1.0 else { return }

        // Сведение к центру → щипок внутрь (открыть).
        if hi - radius > 0.10 && radius < 0.20 {
            lastFire = now
            minRadius = nil; maxRadius = nil
            DispatchQueue.main.async { [weak self] in self?.onPinchIn?() }
        }
        // Разведение от центра → щипок наружу (закрыть).
        else if radius - lo > 0.10 {
            lastFire = now
            minRadius = nil; maxRadius = nil
            DispatchQueue.main.async { [weak self] in self?.onPinchOut?() }
        }
    }
}
