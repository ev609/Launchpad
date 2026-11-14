import AppKit
import CryptoKit

/// Автообновление через GitHub Releases.
///
/// Архив каждого релиза подписан Ed25519. Публичный ключ закреплён в Info.plist,
/// поэтому ZIP проверяется до распаковки и запуска какого-либо нового кода.
enum Updater {
    static let repo = "ev609/Launchpad"
    static let archiveName = "Launchpad.zip"
    static let signatureName = "Launchpad.zip.sig"
    private static let maximumArchiveSize = 100 * 1024 * 1024

    struct Update {
        let version: String
        let downloadURL: URL
        let signatureURL: URL
        let notes: String
    }

    /// Ход установки: промежуточные шаги и итоговая ошибка различаются типом,
    /// а не префиксом строки.
    enum InstallStatus: Equatable {
        case progress(String)
        case failed(String)

        var text: String {
            switch self {
            case .progress(let text): return text
            case .failed(let message): return "Ошибка: \(message)"
            }
        }
    }

    private enum UpdateError: LocalizedError {
        case badLocation(String)
        case invalidResponse
        case archiveTooLarge
        case invalidSignature
        case extractionFailed
        case invalidBundle
        case wrongVersion
        case invalidCodeSignature

        var errorDescription: String? {
            switch self {
            case .badLocation(let message): return message
            case .invalidResponse: return "некорректный ответ сервера"
            case .archiveTooLarge: return "архив обновления слишком большой"
            case .invalidSignature: return "подпись обновления не прошла проверку"
            case .extractionFailed: return "не удалось распаковать обновление"
            case .invalidBundle: return "в архиве нет корректного Launchpad.app"
            case .wrongVersion: return "версия в архиве не совпадает с релизом"
            case .invalidCodeSignature: return "подпись приложения повреждена"
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static var buildDate: Date? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "LaunchpadBuildDate") as? String else {
            return nil
        }
        return ISO8601DateFormatter().date(from: value)
    }

    static var buildDateText: String {
        guard let buildDate else { return "дата неизвестна" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: buildDate)
    }

    /// Видимая версия включает автоматически меняющуюся дату сборки, но updater
    /// продолжает сравнивать только совместимую маркетинговую версию x.y.z.
    static var displayVersion: String {
        formattedDisplayVersion(version: currentVersion, build: currentBuild,
                                dateText: buildDateText)
    }

    static func formattedDisplayVersion(version: String, build: String,
                                        dateText: String) -> String {
        "\(version) · build \(build) · \(dateText)"
    }

    // MARK: - Проверка релиза

    static func checkForUpdate(completion: @escaping (Result<Update?, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(.failure(UpdateError.invalidResponse))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Launchpad/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Update?, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data {
                result = Result { try parseRelease(data, currentVersion: currentVersion) }
            } else {
                result = .failure(UpdateError.invalidResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    static func parseRelease(_ data: Data, currentVersion: String) throws -> Update? {
        let release = try JSONDecoder().decode(GHRelease.self, from: data)
        let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        guard isNewer(latest, than: currentVersion) else { return nil }
        guard let archive = release.assets.first(where: { $0.name == archiveName }),
              let signature = release.assets.first(where: { $0.name == signatureName }),
              let downloadURL = URL(string: archive.browser_download_url), downloadURL.scheme == "https",
              let signatureURL = URL(string: signature.browser_download_url), signatureURL.scheme == "https" else {
            throw UpdateError.invalidResponse
        }
        return Update(version: latest, downloadURL: downloadURL, signatureURL: signatureURL, notes: release.body ?? "")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }

    // MARK: - Загрузка и проверка

    static func downloadAndInstall(_ update: Update,
                                   progress: @escaping (InstallStatus) -> Void) {
        // Заменить приложение на образе диска, в карантине или в чужой папке нельзя:
        // скрипт установки упал бы уже после завершения текущего экземпляра.
        if let problem = InstallLocation.updateProblem {
            fail(UpdateError.badLocation(problem.message), progress: progress)
            return
        }
        progress(.progress("Загрузка…"))
        var request = URLRequest(url: update.downloadURL)
        request.timeoutInterval = 120

        URLSession.shared.downloadTask(with: request) { temporaryURL, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.expectedContentLength <= Int64(maximumArchiveSize) || http.expectedContentLength < 0,
                  let temporaryURL else {
                fail(error ?? UpdateError.invalidResponse, progress: progress)
                return
            }

            let archiveURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Launchpad-update-\(UUID().uuidString).zip")
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)
                let size = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= maximumArchiveSize else { throw UpdateError.archiveTooLarge }
            } catch {
                try? FileManager.default.removeItem(at: archiveURL)
                fail(error, progress: progress)
                return
            }

            downloadSignature(for: update) { result in
                switch result {
                case .failure(let error):
                    try? FileManager.default.removeItem(at: archiveURL)
                    fail(error, progress: progress)
                case .success(let signature):
                    DispatchQueue.global(qos: .userInitiated).async {
                        verifyAndPrepare(archiveURL: archiveURL,
                                         signature: signature,
                                         update: update,
                                         progress: progress)
                    }
                }
            }
        }.resume()
    }

    private static func downloadSignature(
        for update: Update,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        var request = URLRequest(url: update.signatureURL)
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data, data.count == 64 else {
                completion(.failure(error ?? UpdateError.invalidResponse))
                return
            }
            completion(.success(data))
        }.resume()
    }

    private static func verifyAndPrepare(archiveURL: URL,
                                         signature: Data,
                                         update: Update,
                                         progress: @escaping (InstallStatus) -> Void) {
        var extractionDirectory: URL?
        do {
            DispatchQueue.main.async { progress(.progress("Проверка подписи…")) }
            let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
            let publicKeys = publicKeys(from: Bundle.main.object(
                forInfoDictionaryKey: "LaunchpadUpdatePublicKey"))
            guard publicKeys.contains(where: {
                isValidSignature(archive: archive, signature: signature, publicKeyBase64: $0)
            }) else {
                throw UpdateError.invalidSignature
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Launchpad-update-\(UUID().uuidString)", isDirectory: true)
            extractionDirectory = directory
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            do {
                try run("/usr/bin/ditto", ["-x", "-k", archiveURL.path, directory.path])
            } catch {
                throw UpdateError.extractionFailed
            }

            let newApp = directory.appendingPathComponent("Launchpad.app", isDirectory: true)
            guard let bundle = Bundle(url: newApp),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  bundle.executableURL != nil else {
                throw UpdateError.invalidBundle
            }
            guard bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    == update.version else {
                throw UpdateError.wrongVersion
            }
            do {
                try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
            } catch {
                throw UpdateError.invalidCodeSignature
            }

            DispatchQueue.main.async {
                launchInstaller(newApp: newApp,
                                extractionDirectory: directory,
                                archiveURL: archiveURL,
                                progress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            if let extractionDirectory {
                try? FileManager.default.removeItem(at: extractionDirectory)
            }
            fail(error, progress: progress)
        }
    }

    /// Ключи из Info.plist: строка с одним ключом или несколькими через запятую
    /// либо массив строк. Несколько ключей нужны для ротации: релиз, подписанный
    /// новым ключом, примут версии, где новый ключ уже добавлен рядом со старым.
    static func publicKeys(from value: Any?) -> [String] {
        let raw: [String]
        if let string = value as? String {
            raw = string.components(separatedBy: CharacterSet(charactersIn: ",; \n\t"))
        } else if let array = value as? [String] {
            raw = array
        } else {
            raw = []
        }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Доступно тестам: проверяет Ed25519 без обращения к Bundle или сети.
    static func isValidSignature(archive: Data,
                                 signature: Data,
                                 publicKeyBase64: String) -> Bool {
        guard let rawKey = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
            return false
        }
        return key.isValidSignature(signature, for: archive)
    }

    // MARK: - Атомарная установка с откатом

    private static func launchInstaller(newApp: URL,
                                        extractionDirectory: URL,
                                        archiveURL: URL,
                                        progress: @escaping (InstallStatus) -> Void) {
        let destination = URL(fileURLWithPath: Bundle.main.bundlePath)
        // Если включён авто-перезапуск, новую версию запускает launchd
        // (`kickstart`), чтобы она снова была под его защитой. Через `open`
        // приложение стартовало бы вне задания, и сбой больше не перезапускался бы.
        let launchdTarget = KeepAliveService.isLoaded ? KeepAliveService.serviceTarget : ""
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchpad-update-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        set -euo pipefail
        DEST="$1"
        NEWAPP="$2"
        WORKDIR="$3"
        ARCHIVE="$4"
        OLDPID="$5"
        LAUNCHD_TARGET="${6:-}"
        STAGED="${DEST}.update"
        BACKUP="${DEST}.previous"

        relaunch() {
            if [[ -n "$LAUNCHD_TARGET" ]] && /bin/launchctl kickstart "$LAUNCHD_TARGET"; then
                return 0
            fi
            /usr/bin/open "$DEST"
        }

        relaunch_on_error() {
            STATUS=$?
            if [[ $STATUS -ne 0 ]]; then
                if [[ ! -d "$DEST" && -d "$BACKUP" ]]; then
                    /bin/mv "$BACKUP" "$DEST" || true
                fi
                [[ ! -d "$DEST" ]] || relaunch
            fi
            exit $STATUS
        }
        trap relaunch_on_error EXIT

        # Ждём завершения текущего экземпляра (не дольше 20 с): заменять бандл
        # работающей программы и запускать копию раньше времени нельзя.
        for _ in $(seq 1 100); do
            /bin/kill -0 "$OLDPID" 2>/dev/null || break
            sleep 0.2
        done
        /bin/rm -rf "$STAGED"
        /usr/bin/ditto "$NEWAPP" "$STAGED"
        /usr/bin/codesign --verify --deep --strict "$STAGED"
        /bin/rm -rf "$BACKUP"
        /bin/mv "$DEST" "$BACKUP"
        if /bin/mv "$STAGED" "$DEST"; then
            /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
            relaunch
            /bin/rm -rf "$BACKUP" "$WORKDIR" "$ARCHIVE"
            /bin/rm -f "$0"
            trap - EXIT
        else
            /bin/mv "$BACKUP" "$DEST"
            exit 1
        fi
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [scriptURL.path,
                              destination.path,
                              newApp.path,
                              extractionDirectory.path,
                              archiveURL.path,
                              String(ProcessInfo.processInfo.processIdentifier),
                              launchdTarget]
            try task.run()
            progress(.progress("Установка…"))
            NSApp.terminate(nil)
        } catch {
            fail(error, progress: progress)
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidResponse }
    }

    private static func fail(_ error: Error, progress: @escaping (InstallStatus) -> Void) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        DispatchQueue.main.async { progress(.failed(message)) }
    }
}

private struct GHRelease: Decodable {
    let tag_name: String
    let body: String?
    let assets: [GHAsset]
}

private struct GHAsset: Decodable {
    let name: String
    let browser_download_url: String
}
