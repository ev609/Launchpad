import AppKit

/// Простое авто-обновление через публичные GitHub Releases (без токена).
/// Проверяет последний релиз, качает .zip по HTTPS, заменяет бандл и
/// перезапускается. Для приватного репо потребовался бы токен — поэтому репо
/// публичный (открытый код, MIT).
enum Updater {
    /// owner/repo на GitHub.
    static let repo = "ev609/Launchpad"

    struct Update {
        let version: String
        let downloadURL: URL
        let notes: String
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Проверка

    /// Запрашивает последний релиз. Возвращает Update, если он новее текущего.
    static func checkForUpdate(completion: @escaping (Update?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(nil); return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let release = try? JSONDecoder().decode(GHRelease.self, from: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let asset = release.assets.first { $0.name.hasSuffix(".zip") }
            DispatchQueue.main.async {
                if let asset, isNewer(latest, than: currentVersion),
                   let dl = URL(string: asset.browser_download_url) {
                    completion(Update(version: latest, downloadURL: dl, notes: release.body ?? ""))
                } else {
                    completion(nil)
                }
            }
        }.resume()
    }

    /// Сравнение версий вида 1.2.3 (по числовым компонентам).
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

    // MARK: - Установка

    /// Качает zip, заменяет текущий бандл и перезапускается.
    static func downloadAndInstall(_ update: Update,
                                   progress: @escaping (String) -> Void) {
        progress("Загрузка…")
        URLSession.shared.downloadTask(with: update.downloadURL) { tempURL, _, error in
            guard let tempURL, error == nil else {
                DispatchQueue.main.async { progress("Ошибка загрузки") }
                return
            }
            // Сохраняем zip с расширением (downloadTask даёт файл без него).
            let zip = FileManager.default.temporaryDirectory
                .appendingPathComponent("Launchpad-update.zip")
            try? FileManager.default.removeItem(at: zip)
            do {
                try FileManager.default.moveItem(at: tempURL, to: zip)
            } catch {
                DispatchQueue.main.async { progress("Ошибка сохранения") }
                return
            }
            DispatchQueue.main.async { installFromZip(zip) }
        }.resume()
    }

    /// Распаковывает, заменяет бандл и перезапускает приложение через
    /// отсоединённый шелл-скрипт (переживает выход текущего процесса).
    private static func installFromZip(_ zip: URL) {
        let dest = Bundle.main.bundlePath                    // /Applications/Launchpad.app
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Launchpad-update-\(ProcessInfo.processInfo.processIdentifier)")

        let script = """
        #!/bin/bash
        set -e
        sleep 1
        rm -rf "\(extractDir.path)"
        mkdir -p "\(extractDir.path)"
        /usr/bin/ditto -x -k "\(zip.path)" "\(extractDir.path)"
        NEWAPP="$(/usr/bin/find "\(extractDir.path)" -maxdepth 2 -name 'Launchpad.app' -type d | head -1)"
        [ -n "$NEWAPP" ] || exit 1
        /bin/rm -rf "\(dest)"
        /bin/cp -R "$NEWAPP" "\(dest)"
        /usr/bin/xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null || true
        /bin/rm -rf "\(extractDir.path)" "\(zip.path)"
        /usr/bin/open "\(dest)"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchpad-update.sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]
        try? task.run()

        // Выходим — скрипт заменит бандл и заново откроет приложение.
        NSApp.terminate(nil)
    }
}

// MARK: - GitHub API модели

private struct GHRelease: Decodable {
    let tag_name: String
    let body: String?
    let assets: [GHAsset]
}

private struct GHAsset: Decodable {
    let name: String
    let browser_download_url: String
}
