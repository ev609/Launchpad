import Foundation
import Carbon.HIToolbox

struct LaunchpadNavigationState: Equatable {
    var pageID: String? = nil
    var itemID: String? = nil
    var folderID: String? = nil
    var folderAppID: String? = nil
}

/// Пресеты горячей клавиши открытия Launchpad.
enum HotkeyPreset: String, CaseIterable, Identifiable {
    case f4
    case optCmdSpace
    case ctrlSpace
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .f4:          return "F4"
        case .optCmdSpace: return "⌥⌘Space"
        case .ctrlSpace:   return "⌃Space"
        case .none:        return "Без горячей клавиши"
        }
    }

    /// Код клавиши (nil — хоткей отключён).
    var keyCode: UInt32? {
        switch self {
        case .f4:          return UInt32(kVK_F4)
        case .optCmdSpace: return UInt32(kVK_Space)
        case .ctrlSpace:   return UInt32(kVK_Space)
        case .none:        return nil
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .f4:          return 0
        case .optCmdSpace: return UInt32(optionKey | cmdKey)
        case .ctrlSpace:   return UInt32(controlKey)
        case .none:        return 0
        }
    }
}

/// Пользовательские настройки (размер сетки, горячая клавиша). Хранятся в UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    private enum Keys {
        static let columns = "grid.columns"
        static let rows = "grid.rows"
        static let hotkey = "hotkey.preset"
        static let autoUpdate = "update.auto"
        static let pinchGesture = "gesture.pinch"
        static let hiddenAppIDs = "apps.hiddenIDs"
        static let customAppDirectories = "apps.customDirectories"
        static let lastPageID = "navigation.pageID"
        static let lastItemID = "navigation.itemID"
        static let lastFolderID = "navigation.folderID"
        static let lastFolderAppID = "navigation.folderAppID"
    }

    @Published var columns: Int {
        didSet { persist(max(4, min(columns, 10)), forKey: Keys.columns) }
    }
    @Published var rows: Int {
        didSet { persist(max(3, min(rows, 8)), forKey: Keys.rows) }
    }
    @Published var hotkey: HotkeyPreset {
        didSet { defaults.set(hotkey.rawValue, forKey: Keys.hotkey) }
    }
    /// Автоматически скачивать и ставить обновления (по умолчанию включено).
    @Published var autoUpdate: Bool {
        didSet { defaults.set(autoUpdate, forKey: Keys.autoUpdate) }
    }
    /// Открывать и закрывать Launchpad щипком трекпада (по умолчанию включено).
    @Published var pinchGesture: Bool {
        didSet { defaults.set(pinchGesture, forKey: Keys.pinchGesture) }
    }
    @Published private(set) var hiddenAppIDs: Set<String> {
        didSet { defaults.set(hiddenAppIDs.sorted(), forKey: Keys.hiddenAppIDs) }
    }
    @Published private(set) var customAppDirectories: [String] {
        didSet { defaults.set(customAppDirectories, forKey: Keys.customAppDirectories) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        let c = d.integer(forKey: Keys.columns)
        let r = d.integer(forKey: Keys.rows)
        columns = c == 0 ? 7 : max(4, min(c, 10))
        rows = r == 0 ? 5 : max(3, min(r, 8))
        hotkey = HotkeyPreset(rawValue: d.string(forKey: Keys.hotkey) ?? "") ?? .f4
        // Нет сохранённого значения → по умолчанию true.
        autoUpdate = d.object(forKey: Keys.autoUpdate) == nil ? true : d.bool(forKey: Keys.autoUpdate)
        pinchGesture = d.object(forKey: Keys.pinchGesture) == nil ? true : d.bool(forKey: Keys.pinchGesture)
        hiddenAppIDs = Set(d.stringArray(forKey: Keys.hiddenAppIDs) ?? [])
        customAppDirectories = Self.normalizedDirectories(
            d.stringArray(forKey: Keys.customAppDirectories) ?? [])
    }

    private func persist(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func setAppHidden(_ id: String, hidden: Bool) {
        if hidden { hiddenAppIDs.insert(id) } else { hiddenAppIDs.remove(id) }
    }

    @discardableResult
    func addCustomDirectory(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard !customAppDirectories.contains(normalized) else { return false }
        customAppDirectories = Self.normalizedDirectories(customAppDirectories + [normalized])
        return true
    }

    func removeCustomDirectory(_ path: String) {
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        customAppDirectories.removeAll { $0 == normalized }
    }

    var navigationState: LaunchpadNavigationState {
        LaunchpadNavigationState(
            pageID: defaults.string(forKey: Keys.lastPageID),
            itemID: defaults.string(forKey: Keys.lastItemID),
            folderID: defaults.string(forKey: Keys.lastFolderID),
            folderAppID: defaults.string(forKey: Keys.lastFolderAppID)
        )
    }

    func saveNavigationState(_ state: LaunchpadNavigationState) {
        persistOptional(state.pageID, forKey: Keys.lastPageID)
        persistOptional(state.itemID, forKey: Keys.lastItemID)
        persistOptional(state.folderID, forKey: Keys.lastFolderID)
        persistOptional(state.folderAppID, forKey: Keys.lastFolderAppID)
    }

    private func persistOptional(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private static func normalizedDirectories(_ paths: [String]) -> [String] {
        Array(Set(paths.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        })).sorted()
    }
}
