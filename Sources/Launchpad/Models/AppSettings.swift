import AppKit
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
    /// Сочетание, записанное пользователем (`AppSettings.customHotkey`).
    case custom
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .f4:          return "F4"
        case .optCmdSpace: return "⌥⌘Space"
        case .ctrlSpace:   return "⌃Space"
        case .custom:      return "Своё сочетание"
        case .none:        return "Без горячей клавиши"
        }
    }

    /// Код клавиши (nil — хоткей отключён или задан пользователем).
    var keyCode: UInt32? {
        switch self {
        case .f4:          return UInt32(kVK_F4)
        case .optCmdSpace: return UInt32(kVK_Space)
        case .ctrlSpace:   return UInt32(kVK_Space)
        case .custom, .none: return nil
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .f4:          return 0
        case .optCmdSpace: return UInt32(optionKey | cmdKey)
        case .ctrlSpace:   return UInt32(controlKey)
        case .custom, .none: return 0
        }
    }
}

/// Записанное пользователем сочетание: Carbon-код клавиши и модификаторы.
struct CustomHotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Имя клавиши на момент записи (с учётом раскладки).
    var keyName: String

    var title: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyName
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// Сочетание из нажатия в окне записи. nil — нажатие не годится:
    /// обычной клавише без ⌘/⌥/⌃ нужен модификатор, иначе она перехватит набор текста.
    static func make(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags,
                     characters: String?) -> CustomHotkey? {
        let code = Int(keyCode)
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        let isFunctionKey = functionKeys[code] != nil
        let hasRealModifier = carbon & UInt32(cmdKey | optionKey | controlKey) != 0
        guard isFunctionKey || hasRealModifier else { return nil }

        let name = functionKeys[code] ?? namedKeys[code]
            ?? characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let name, !name.isEmpty else { return nil }
        return CustomHotkey(keyCode: UInt32(code), modifiers: carbon, keyName: name)
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
        static let customHotkey = "hotkey.custom"
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
    @Published var customHotkey: CustomHotkey? {
        didSet {
            if let customHotkey, let data = try? JSONEncoder().encode(customHotkey) {
                defaults.set(data, forKey: Keys.customHotkey)
            } else {
                defaults.removeObject(forKey: Keys.customHotkey)
            }
        }
    }

    /// Сочетание для регистрации: пресет или записанное. nil — отключено.
    var effectiveHotkey: (keyCode: UInt32, modifiers: UInt32, title: String)? {
        if hotkey == .custom {
            guard let customHotkey else { return nil }
            return (customHotkey.keyCode, customHotkey.modifiers, customHotkey.title)
        }
        guard let code = hotkey.keyCode else { return nil }
        return (code, hotkey.modifiers, hotkey.title)
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
        let storedCustom = d.data(forKey: Keys.customHotkey)
            .flatMap { try? JSONDecoder().decode(CustomHotkey.self, from: $0) }
        let preset = HotkeyPreset(rawValue: d.string(forKey: Keys.hotkey) ?? "") ?? .f4
        // Записанное сочетание потерялось — возвращаем F4, а не тихо отключаем.
        hotkey = preset == .custom && storedCustom == nil ? .f4 : preset
        customHotkey = storedCustom
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
