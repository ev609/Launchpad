import AppKit

/// Обычные удаления выполняются через NSWorkspace. При отказе в правах
/// обращаемся непосредственно к Finder, который умеет запрашивать авторизацию.
enum AppTrashService {
    @MainActor
    static func trash(
        _ url: URL,
        recycle: (URL) async throws -> Void = { url in
            let moved = try await NSWorkspace.shared.recycle([url])
            guard moved[url] != nil else { throw CocoaError(.fileWriteUnknown) }
        },
        finderTrash: (URL) async throws -> Void = { url in
            _ = try await trashUsingFinder(url)
        }
    ) async throws {
        do {
            try await recycle(url)
        } catch {
            guard isPermissionError(error) else { throw error }
            try await finderTrash(url)
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(error.code) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    // Путь передаётся отдельным аргументом, а не подставляется в код скрипта.
    static func finderArguments(for url: URL) -> [String] {
        ["-e", """
        on run argv
            set appFile to POSIX file (item 1 of argv) as alias
            with timeout of 600 seconds
                tell application "Finder"
                    activate
                    set trashedItem to delete appFile
                end tell
            end timeout
            return POSIX path of (trashedItem as alias)
        end run
        """, "--", url.path]
    }

    static func finderError(_ message: String) -> Error {
        if message.contains("(-128)") { return CocoaError(.userCancelled) }
        if message.contains("(-1743)") {
            return NSError(domain: "Launchpad.FinderTrash", code: -1743, userInfo: [
                NSLocalizedDescriptionKey: L("Разрешите Launchpad управлять Finder в «Системные настройки → Конфиденциальность и безопасность → Автоматизация», затем повторите удаление.")
            ])
        }
        return NSError(domain: "Launchpad.FinderTrash", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)
        ])
    }

    static func trashUsingFinder(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = finderArguments(for: url)
                    let output = Pipe(), errors = Pipe()
                    process.standardOutput = output
                    process.standardError = errors
                    try process.run()
                    process.waitUntilExit()
                    let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    guard process.terminationStatus == 0 else { throw finderError(message) }
                    // osascript добавляет один перевод строки к возвращённому пути.
                    let path = result.hasSuffix("\n") ? String(result.dropLast()) : result
                    guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: url.path) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    continuation.resume(returning: URL(fileURLWithPath: path))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
