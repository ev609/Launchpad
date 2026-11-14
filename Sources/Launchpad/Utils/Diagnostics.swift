import Foundation

/// Диагностические утилиты для проверки логики без запуска GUI.
enum Diagnostics {
    static func dumpImport() {
        let apps = AppScanner.scan()
        print("Найдено приложений: \(apps.count)")
        print("Примеры: \(apps.prefix(5).map { $0.name }.joined(separator: ", "))")

        guard let db = LaunchpadImporter.defaultDatabaseURL() else {
            print("БД старого Launchpad не найдена.")
            return
        }
        print("БД: \(db.path)")

        guard let layout = LaunchpadImporter.importLayout(dbURL: db, installed: apps) else {
            print("Импорт не удался.")
            return
        }
        print("Импортировано страниц: \(layout.pages.count)")
        for (i, page) in layout.pages.enumerated() {
            let folders = page.items.filter { if case .folder = $0 { return true }; return false }
            print("  Страница \(i + 1): элементов \(page.items.count), папок \(folders.count)")
            for item in page.items {
                if case .folder(let f) = item {
                    print("     📁 \(f.name): \(f.apps.map { $0.name }.joined(separator: ", "))")
                }
            }
        }
    }

    @MainActor
    static func report(model: LaunchpadModel) -> String {
        let metrics = PerformanceMetrics.shared
        let cache = IconCache.shared.diagnosticSnapshot()
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        let appCount = model.pages.flatMap(\.items).flatMap(\.containedApps).count
        return [
            "Launchpad diagnostics",
            "Version: \(Updater.currentVersion)",
            "Build: \(Updater.currentBuild)",
            "Build date: \(Updater.buildDateText)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Grid: \(model.columns)x\(model.rows)",
            "Pages: \(model.pages.count)",
            "Applications in layout: \(appCount)",
            "Last show: \(PerformanceMetrics.durationText(metrics.lastShowDuration))",
            "Last swipe: \(PerformanceMetrics.durationText(metrics.lastSwipeDuration))",
            "Last scan: \(PerformanceMetrics.durationText(metrics.lastScanDuration))",
            "Last swipe main-thread stalls: \(metrics.lastSwipeStalls)",
            "Adaptive mode activations: \(metrics.adaptiveActivationCount)",
            "Icon RAM cache: \(cache.residentCount) (≈\(bytes.string(fromByteCount: Int64(cache.estimatedResidentBytes))))",
            "Icon disk cache: \(cache.diskCount) (\(bytes.string(fromByteCount: Int64(cache.diskBytes))))",
        ].joined(separator: "\n")
    }
}
