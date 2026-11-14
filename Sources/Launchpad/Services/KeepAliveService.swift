import Foundation

/// Держит приложение всегда запущенным через LaunchAgent (`launchd`).
///
/// Поведение агента:
///  - `RunAtLoad`  — старт при входе в систему / после перезагрузки;
///  - `KeepAlive = {SuccessfulExit: false}` — перезапуск при крахе или
///    принудительном завершении, но НЕ при осознанном «Выйти».
///
/// Нюанс: `launchctl bootout` убивает процесс задания. Если текущий процесс
/// запущен самим агентом, выгружать задание нельзя — иначе выключение галочки
/// в настройках «роняет» приложение. В этом случае удаляется только plist:
/// задание доживает до выхода из системы и больше не загружается.
enum KeepAliveService {
    static let label = "com.openlaunchpad.keepalive"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var serviceTarget: String { "gui/\(getuid())/\(label)" }

    /// Текущий процесс запущен этим LaunchAgent'ом.
    static var isManagedProcess: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    /// Задание загружено в launchd текущей сессии (независимо от plist).
    static var isLoaded: Bool {
        launchctl(["print", serviceTarget]) == 0
    }

    /// Включён ли авто-перезапуск (установлен ли агент).
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path) && isLoaded
    }

    /// Путь к исполняемому файлу, записанный в plist агента.
    static var configuredProgramPath: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return nil }
        return arguments.first
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? install() : uninstall()
    }

    /// После переноса приложения plist указывает на несуществующий путь,
    /// и launchd молча перестаёт его запускать. Переписываем путь, если старой
    /// копии больше нет, а текущая лежит там, откуда можно автозапускаться.
    static func repairProgramPathIfNeeded() {
        guard !isManagedProcess,
              let configured = configuredProgramPath,
              let current = Bundle.main.executablePath,
              configured != current,
              !FileManager.default.fileExists(atPath: configured),
              InstallLocation.autostartProblem == nil else { return }
        NSLog("KeepAliveService: путь в агенте устарел (\(configured)), переписываю на \(current)")
        install()
    }

    // MARK: - Установка / удаление

    @discardableResult
    private static func install() -> Bool {
        if let problem = InstallLocation.autostartProblem {
            NSLog("KeepAliveService: авто-перезапуск недоступен — \(problem.message)")
            return false
        }
        guard let exec = Bundle.main.executablePath else { return false }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exec],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]

        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else { return false }
        do {
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return false
        }

        // Мы и есть процесс загруженного задания (plist удаляли в этой сессии):
        // перезагрузка убила бы нас, а конфигурация задания та же.
        if isManagedProcess && isLoaded { return true }

        // Перезагружаем job в текущей сессии. RunAtLoad сразу запустит новый
        // экземпляр — он заберёт управление у текущего (см. AppDelegate, handover).
        bootout()
        guard launchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) == 0 else {
            try? FileManager.default.removeItem(at: plistURL)
            NSLog("KeepAliveService: launchctl bootstrap завершился с ошибкой")
            return false
        }
        return true
    }

    private static func uninstall() -> Bool {
        if !isManagedProcess { bootout() }
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: plistURL)
            return true
        } catch {
            NSLog("KeepAliveService: не удалось удалить агент — \(error.localizedDescription)")
            return false
        }
    }

    private static func bootout() {
        launchctl(["bootout", serviceTarget])
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
