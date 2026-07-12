import AppKit

/// Кэш иконок приложений (иконки тяжёлые — держим их в памяти).
/// Используется только из главного потока (SwiftUI).
///
/// ⚠️ Кэш инвалидируется по дате изменения бандла. Без этого сменившаяся иконка
/// приложения не появлялась НИКОГДА в пределах запуска: путь тот же → отдавалась
/// старая картинка из памяти, и помогал только перезапуск Launchpad. Ровно так и
/// вышло 12.07.2026 — иконки ярлыков поменяли, а Launchpad показывал прежние.
final class IconCache {
    static let shared = IconCache()

    private struct Entry {
        let image: NSImage
        let modified: Date?
    }

    private var cache: [String: Entry] = [:]

    /// Дата изменения бандла. У .app при смене иконки обновляется mtime самого
    /// каталога (кастомная иконка пишется в атрибуты файла), поэтому этого хватает.
    private func modifiedAt(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func icon(for path: String) -> NSImage {
        let modified = modifiedAt(path)
        if let hit = cache[path], hit.modified == modified {
            return hit.image
        }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 128, height: 128)
        cache[path] = Entry(image: img, modified: modified)
        return img
    }
}

/// Запуск приложений.
enum AppLauncher {
    static func launch(_ app: AppEntry) {
        let url = URL(fileURLWithPath: app.path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }
}

/// Сохранение и загрузка раскладки в Application Support.
final class LayoutStore {
    static let shared = LayoutStore()
    let fileURL: URL

    init() {
        // Изоляция для тестов: если задан LAUNCHPAD_SUPPORT_DIR — храним там,
        // чтобы тестовые прогоны не трогали реальную раскладку пользователя.
        let base: URL
        if let custom = ProcessInfo.processInfo.environment["LAUNCHPAD_SUPPORT_DIR"], !custom.isEmpty {
            base = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Launchpad", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("layout.json")
    }

    func load() -> Layout? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let layout = try? JSONDecoder().decode(Layout.self, from: data) {
            return layout
        }
        // Файл есть, но не декодируется — сохраняем копию, чтобы не потерять молча.
        try? data.write(to: fileURL.appendingPathExtension("corrupt"), options: .atomic)
        return nil
    }

    func save(_ layout: Layout) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(layout) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
