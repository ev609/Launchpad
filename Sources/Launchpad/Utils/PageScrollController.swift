import AppKit
import Combine

/// Часто меняющееся состояние жеста отделено от общей модели раскладки.
/// Поэтому десятки scroll-событий за кадр не уведомляют поиск, настройки,
/// историю и другие подписанные на LaunchpadModel представления.
@MainActor
final class PageScrollPosition: ObservableObject {
    @Published var value: CGFloat = 0
}

@MainActor
final class PageScrollState: ObservableObject {
    /// Позиция вынесена во вложенный объект: её высокочастотные уведомления
    /// получает только ViewModifier пейджера, а не весь LaunchpadRootView.
    let position = PageScrollPosition()
    @Published private(set) var isInteracting = false
    @Published private(set) var useLightweightBackground = false

    func beginInteraction() {
        guard !isInteracting else { return }
        isInteracting = true
    }

    func endInteraction() {
        position.value = 0
        isInteracting = false
        useLightweightBackground = false
    }

    func setOffset(_ value: CGFloat) {
        position.value = value
    }

    @discardableResult
    func enableLightweightBackground() -> Bool {
        guard !useLightweightBackground else { return false }
        useLightweightBackground = true
        return true
    }
}

/// Один жест — одно перелистывание. Направление фиксируется до конца жеста,
/// инерция и завершающие пакеты не запускают новые переходы.
struct PageScrollController {
    struct Result: Equatable {
        var direction = 0
        var consumed = false
        var offset: CGFloat?
        var finished = false
    }
    private enum Axis { case horizontal, vertical }
    private var axis: Axis?
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var handled = false
    private var lastEventTime: TimeInterval?
    private var lastFlipTime = -Double.infinity
    private var velocityX: CGFloat = 0

    mutating func reset() { self = Self() }

    mutating func handle(dx: CGFloat, dy: CGFloat, precise: Bool,
                         phase: NSEvent.Phase, momentum: NSEvent.Phase,
                         time: TimeInterval) -> Result {
        if !momentum.isEmpty {
            return Result(consumed: axis == .horizontal)
        }
        let phased = !phase.isEmpty
        let beginsGesture = phase.contains(.began) || phase.contains(.mayBegin)
            || (!phased && (lastEventTime == nil || time - lastEventTime! > 0.18))
        if beginsGesture {
            axis = nil
            x = 0
            y = 0
            handled = false
            velocityX = 0
        }
        let previousEventTime = beginsGesture ? nil : lastEventTime
        lastEventTime = time
        if phase.contains(.cancelled) || phase.contains(.ended) {
            // Сохраняем axis для следующих инерционных пакетов.
            handled = true
            guard axis == .horizontal else { return Result() }
            let direction: Int
            // Проекция на 120 мс отличает быстрый короткий взмах от медленного
            // небольшого движения с тем же пройденным расстоянием.
            let projectedX = x + velocityX * 0.12
            if phase.contains(.cancelled) || abs(projectedX) < 20 {
                direction = 0
            } else {
                direction = projectedX < 0 ? 1 : -1
            }
            return Result(direction: direction, consumed: true,
                          offset: x, finished: true)
        }

        if !precise {
            let delta = abs(dx) > abs(dy) ? dx : dy
            guard delta != 0 else { return Result() }
            guard time - lastFlipTime >= 0.20 else { return Result(consumed: true) }
            lastFlipTime = time
            return Result(direction: delta < 0 ? 1 : -1, consumed: true)
        }
        x += dx
        y += dy
        if let previousEventTime {
            let elapsed = time - previousEventTime
            if elapsed > 0, elapsed < 0.1, dx != 0 {
                let instantaneous = dx / elapsed
                velocityX = velocityX * 0.35 + instantaneous * 0.65
            }
        }
        if axis == nil, max(abs(x), abs(y)) >= 8 {
            if abs(x) > abs(y) * 1.2 { axis = .horizontal }
            else if abs(y) > abs(x) * 1.2 { axis = .vertical }
        }
        guard axis == .horizontal else { return Result() }
        if phased {
            // На трекпаде экран следует за пальцами; решение о переходе
            // принимается только при ended/cancelled.
            return Result(consumed: true, offset: x)
        }
        // У устройств без фаз нет отдельного ended, сохраняем дискретное поведение.
        guard !handled, abs(x) >= 20 else { return Result(consumed: true) }
        handled = true
        guard time - lastFlipTime >= 0.20 else { return Result(consumed: true) }
        lastFlipTime = time
        return Result(direction: x < 0 ? 1 : -1, consumed: true)
    }
}
