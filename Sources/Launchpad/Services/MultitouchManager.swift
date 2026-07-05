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

    /// Вызывается на главном потоке при распознавании щипка внутрь.
    var onPinchIn: (() -> Void)?

    private var devices: [MTDeviceRef] = []
    private var handle: UnsafeMutableRawPointer?

    /// Число найденных трекпад-устройств (для диагностики).
    var deviceCount: Int { devices.count }
    /// Максимум одновременных касаний, замеченных с момента старта (для диагностики).
    private(set) var maxTouchesSeen: Int = 0

    // Состояние распознавания (доступ только из callback-потока).
    private var baselineRadius: Float?
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

    /// Обрабатывает кадр касаний. Ищет сведение 3–5 пальцев к центру.
    func handle(touches: UnsafeMutablePointer<MTTouch>?, count: Int) {
        if count > maxTouchesSeen { maxTouchesSeen = count }
        guard let touches, count >= 3, count <= 5 else {
            baselineRadius = nil
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

        guard let baseline = baselineRadius else {
            baselineRadius = radius
            return
        }

        // Пальцы заметно сошлись к центру → щипок внутрь.
        if baseline - radius > 0.08 && radius < 0.22 {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastFire > 1.0 {
                lastFire = now
                DispatchQueue.main.async { [weak self] in self?.onPinchIn?() }
            }
            baselineRadius = nil
        } else {
            // База — максимальный разброс за жест.
            baselineRadius = max(baseline, radius)
        }
    }
}
