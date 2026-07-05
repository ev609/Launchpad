import Foundation

/// Приложение, найденное в системе.
struct AppEntry: Identifiable, Codable, Hashable {
    /// Стабильный идентификатор: bundleID, если есть, иначе путь.
    var id: String
    var name: String
    /// Абсолютный путь к бандлу `.app`.
    var path: String
    var bundleID: String?

    init(name: String, path: String, bundleID: String?) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
        self.id = bundleID ?? path
    }
}

/// Папка на странице Launchpad.
struct Folder: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var apps: [AppEntry]

    init(id: String = UUID().uuidString, name: String, apps: [AppEntry]) {
        self.id = id
        self.name = name
        self.apps = apps
    }
}

/// Элемент сетки — приложение или папка.
enum LaunchpadItem: Identifiable, Codable, Hashable {
    case app(AppEntry)
    case folder(Folder)

    var id: String {
        switch self {
        case .app(let a):    return "app:" + a.id
        case .folder(let f): return "folder:" + f.id
        }
    }

    /// Все приложения, вложенные в элемент (само приложение или содержимое папки).
    var containedApps: [AppEntry] {
        switch self {
        case .app(let a):    return [a]
        case .folder(let f): return f.apps
        }
    }

    var displayName: String {
        switch self {
        case .app(let a):    return a.name
        case .folder(let f): return f.name
        }
    }
}

/// Одна страница Launchpad.
struct Page: Identifiable, Codable, Hashable {
    var id: String
    var items: [LaunchpadItem]

    init(id: String = UUID().uuidString, items: [LaunchpadItem]) {
        self.id = id
        self.items = items
    }
}

/// Полная раскладка (все страницы). Сохраняется на диск.
struct Layout: Codable {
    var pages: [Page]

    static let empty = Layout(pages: [])
}
