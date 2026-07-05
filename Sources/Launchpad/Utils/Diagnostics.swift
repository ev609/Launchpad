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
}
