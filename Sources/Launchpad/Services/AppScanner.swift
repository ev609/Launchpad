import AppKit

/// Сканирует систему в поисках установленных приложений `.app`.
enum AppScanner {

    /// Каталоги, где обычно лежат приложения.
    static var searchPaths: [String] {
        [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
            NSHomeDirectory() + "/Applications",
        ]
    }

    /// Возвращает уникальный список приложений, отсортированный по имени.
    static func scan() -> [AppEntry] {
        var found: [String: AppEntry] = [:]
        for base in searchPaths {
            for path in appPaths(in: base, depth: 1) {
                if let entry = makeEntry(path: path) {
                    // Приоритет у первого найденного (пользовательские > системные по порядку путей).
                    if found[entry.id] == nil { found[entry.id] = entry }
                }
            }
        }
        return found.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Ищет `.app` в каталоге, спускаясь максимум на `depth` уровней в обычные папки.
    private static func appPaths(in base: String, depth: Int) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        var result: [String] = []
        for name in entries {
            let path = base + "/" + name
            if name.hasSuffix(".app") {
                result.append(path)
            } else if depth > 0 {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                   !name.hasPrefix(".") {
                    result.append(contentsOf: appPaths(in: path, depth: depth - 1))
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
