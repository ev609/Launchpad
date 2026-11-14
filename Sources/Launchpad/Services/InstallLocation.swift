import Foundation

/// Где лежит запущенное приложение и можно ли отсюда автозапускаться и обновляться.
enum InstallLocation {
    enum Problem: Equatable {
        /// Запуск не из `.app` (например, `.build/debug/Launchpad`).
        case notAppBundle
        /// macOS запустила копию из карантина (App Translocation) по случайному пути.
        case translocated
        /// Том только для чтения — обычно смонтированный DMG.
        case readOnlyVolume
        /// Нет прав на запись в каталог с приложением — заменить его при обновлении нельзя.
        case parentNotWritable

        var message: String {
            switch self {
            case .notAppBundle:
                return L("Launchpad запущен не из приложения .app (сборка для разработки).")
            case .translocated, .readOnlyVolume:
                return L("Launchpad запущен с образа диска или из карантина. Перетащите его в папку «Программы» и запустите оттуда.")
            case .parentNotWritable:
                return L("Нет прав на запись в папку с Launchpad, поэтому обновление не установить. Переместите приложение в «Программы» под своей учётной записью.")
            }
        }
    }

    static func problem(bundlePath: String = Bundle.main.bundlePath,
                        fileManager: FileManager = .default) -> Problem? {
        let path = (bundlePath as NSString).standardizingPath
        guard path.hasSuffix(".app") else { return .notAppBundle }
        if path.contains("/AppTranslocation/") { return .translocated }
        let url = URL(fileURLWithPath: path)
        if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return .readOnlyVolume
        }
        guard fileManager.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            return .parentNotWritable
        }
        return nil
    }

    /// Препятствие для установки обновления: заменить бандл можно только целиком.
    static var updateProblem: Problem? { problem() }

    /// Препятствие для автозапуска. Запрет записи в каталог автозапуску не мешает.
    static var autostartProblem: Problem? {
        let problem = problem()
        return problem == .parentNotWritable ? nil : problem
    }
}
