import Foundation

/// Держит приложение всегда запущенным через LaunchAgent (`launchd`).
///
/// Поведение агента:
///  - `RunAtLoad`  — старт при входе в систему / после перезагрузки;
///  - `KeepAlive = {SuccessfulExit: false}` — перезапуск при крахе или
///    принудительном завершении, но НЕ при осознанном «Выйти».
enum KeepAliveService {
    static let label = "com.openlaunchpad.keepalive"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Включён ли авто-перезапуск (установлен ли агент).
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? install() : uninstall()
    }

    // MARK: - Установка / удаление

    private static func install() -> Bool {
        guard let exec = Bundle.main.executablePath ?? CommandLine.arguments.first else {
            return false
        }
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

        // Перезагружаем job в текущей сессии.
        bootout()
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        return true
    }

    private static func uninstall() -> Bool {
        bootout()
        try? FileManager.default.removeItem(at: plistURL)
        return true
    }

    private static func bootout() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
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
