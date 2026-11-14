import Foundation
import Combine
import os.signpost

/// Точки измерения для Instruments → Points of Interest. В обычной работе
/// накладные расходы минимальны, а длительности открытия, свайпа и сканирования
/// видны без специальной диагностической сборки.
enum PerformanceTrace {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.openlaunchpad.app",
        category: .pointsOfInterest)

    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}

/// Последние измерения, доступные пользователю прямо в настройках.
@MainActor
final class PerformanceMetrics: ObservableObject {
    static let shared = PerformanceMetrics()

    @Published private(set) var lastShowDuration: TimeInterval?
    @Published private(set) var lastSwipeDuration: TimeInterval?
    @Published private(set) var lastScanDuration: TimeInterval?
    @Published private(set) var lastSwipeStalls = 0
    @Published private(set) var adaptiveActivationCount = 0

    private init() {}

    func recordShow(_ duration: TimeInterval) { lastShowDuration = duration }

    func recordSwipe(_ duration: TimeInterval, stalls: Int) {
        lastSwipeDuration = duration
        lastSwipeStalls = stalls
    }

    func recordScan(_ duration: TimeInterval) { lastScanDuration = duration }
    func recordAdaptiveActivation() { adaptiveActivationCount += 1 }

    static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration else { return L("ещё нет данных") }
        return String(format: L("%.1f мс"), duration * 1_000)
    }
}
