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
        var seenPaths = Set<String>()
        var unavailable: [String] = []
        for base in paths {
            // Симлинк на тот же бандл (Xcode.app → Xcode-16.app) — не вторая копия.
            for path in appPaths(in: base, depth: 1, unavailable: &unavailable)
            where seenPaths.insert((path as NSString).resolvingSymlinksInPath).inserted {
                guard let entry = autoreleasepool(invoking: { makeEntry(path: path) }) else {
                    unavailable.append(path)
                    continue
                }
                guard let primary = found[entry.id] else {
                    found[entry.id] = entry
                    continue
                }
                // Вторая копия с тем же bundleID (бета, копия в ~/Applications):
                // раньше она молча пропадала. Основной остаётся первая по порядку
                // каталогов (/Applications раньше прочих) — её id не меняется.
                let copy = secondaryCopy(entry, primaryName: primary.name)
                if found[copy.id] == nil { found[copy.id] = copy }
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
                        bundleID: bundleID,
                        category: bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String)
    }

    /// Вторая копия получает собственный id, а при совпадении имени —
    /// имя папки в скобках, чтобы копии различались в сетке и поиске.
    static func secondaryCopy(_ entry: AppEntry, primaryName: String) -> AppEntry {
        var name = entry.name
        if name.localizedCaseInsensitiveCompare(primaryName) == .orderedSame {
            let folder = FileManager.default.displayName(
                atPath: (entry.path as NSString).deletingLastPathComponent)
            name += " (\(folder))"
        }
        return AppEntry(name: name, path: entry.path, bundleID: entry.bundleID,
                        category: entry.category,
                        id: (entry.bundleID ?? entry.path) + "@" + entry.path)
    }

    private static func displayName(path: String, bundle: Bundle) -> String {
        if let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String { return name }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String { return name }
        // Локализованное имя из Finder (учитывает .localized папки).
        let finderName = FileManager.default.displayName(atPath: path)
        if !finderName.isEmpty { return strippingAppExtension(finderName) }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String { return name }
        return strippingAppExtension((path as NSString).lastPathComponent)
    }

    /// Убирает только расширение в конце: «Foo.app Helper» не должен терять «.app».
    static func strippingAppExtension(_ name: String) -> String {
        name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
