import Foundation
import Carbon.HIToolbox

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

    private enum Keys {
        static let columns = "grid.columns"
        static let rows = "grid.rows"
        static let hotkey = "hotkey.preset"
        static let autoUpdate = "update.auto"
    }

    @Published var columns: Int {
        didSet { persist(max(4, min(columns, 10)), forKey: Keys.columns) }
    }
    @Published var rows: Int {
        didSet { persist(max(3, min(rows, 8)), forKey: Keys.rows) }
    }
    @Published var hotkey: HotkeyPreset {
        didSet { UserDefaults.standard.set(hotkey.rawValue, forKey: Keys.hotkey) }
    }
    /// Автоматически скачивать и ставить обновления (по умолчанию включено).
    @Published var autoUpdate: Bool {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: Keys.autoUpdate) }
    }

    private init() {
        let d = UserDefaults.standard
        let c = d.integer(forKey: Keys.columns)
        let r = d.integer(forKey: Keys.rows)
        columns = c == 0 ? 7 : max(4, min(c, 10))
        rows = r == 0 ? 5 : max(3, min(r, 8))
        hotkey = HotkeyPreset(rawValue: d.string(forKey: Keys.hotkey) ?? "") ?? .f4
        // Нет сохранённого значения → по умолчанию true.
        autoUpdate = d.object(forKey: Keys.autoUpdate) == nil ? true : d.bool(forKey: Keys.autoUpdate)
    }

    private func persist(_ value: Int, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
