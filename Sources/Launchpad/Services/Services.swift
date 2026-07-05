import AppKit

/// Кэш иконок приложений (иконки тяжёлые — держим их в памяти).
/// Используется только из главного потока (SwiftUI).
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage {
        if let img = cache[path] { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 128, height: 128)
        cache[path] = img
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
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Launchpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("layout.json")
    }

    func load() -> Layout? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Layout.self, from: data)
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
