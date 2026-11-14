import AppKit

/// Сканирует систему в поисках установленных приложений `.app`.
enum AppScanner {

    /// Каталоги, где обычно лежат приложения.
    static var searchPaths: [String] {
        let standard = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
            NSHomeDirectory() + "/Applications",
        ]
        return AppDirectoryWatcher.minimalRoots(
            standard + AppSettings.shared.customAppDirectories)
    }

    struct ScanResult: Sendable {
        var apps: [AppEntry]
        var unavailablePaths: [String] = []
    }

    static func scan() -> [AppEntry] { scanResult().apps }

    /// Обходит также вложенные каталоги. Ошибки чтения возвращаются отдельно:
    /// временно недоступный каталог не означает удаление его приложений.
    static func scanResult(paths: [String] = searchPaths) -> ScanResult {
        var found: [String: AppEntry] = [:]
        var unavailable: [String] = []
        for base in paths {
            for path in appPaths(in: base, depth: 1, unavailable: &unavailable) {
                if let entry = autoreleasepool(invoking: { makeEntry(path: path) }) {
                    if found[entry.id] == nil { found[entry.id] = entry }
                } else {
                    unavailable.append(path)
                }
            }
        }
        return ScanResult(apps: found.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }, unavailablePaths: unavailable)
    }

    private static func appPaths(in base: String, depth: Int, unavailable: inout [String]) -> [String] {
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: base).sorted()
        } catch {
            unavailable.append(base)
            return []
        }
        var result: [String] = []
        for name in entries where !name.hasPrefix(".") {
            let path = base + "/" + name
            if name.lowercased().hasSuffix(".app") {
                result.append(path)
            } else if depth > 0 {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    result.append(contentsOf: appPaths(in: path, depth: depth - 1, unavailable: &unavailable))
                }
            }
        }
        return result
    }

    private static func makeEntry(path: String) -> AppEntry? {
        guard let bundle = Bundle(path: path) else { return nil }
        // Пропускаем приложения без исполняемого файла / служебные.
        guard bundle.executableURL != nil else { return nil }
        let bundleID = bundle.bundleIdentifier
        return AppEntry(name: displayName(path: path, bundle: bundle),
                        path: path,
                        bundleID: bundleID)
    }

    private static func displayName(path: String, bundle: Bundle) -> String {
        if let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String { return name }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String { return name }
        // Локализованное имя из Finder (учитывает .localized папки).
        let finderName = FileManager.default.displayName(atPath: path)
        if !finderName.isEmpty { return finderName.replacingOccurrences(of: ".app", with: "") }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String { return name }
        return (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }
}
