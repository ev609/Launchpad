import Foundation
import SQLite3

/// Импортирует раскладку из БД старого системного Launchpad
/// (`~/Library/Application Support/Dock/<UUID>.db`).
///
/// Структура БД:
///   items(rowid, type, parent_id, ordering)
///     type 1 — корень, 2 — папка, 3 — страница, 4 — приложение, 6/7 — виджеты
///   apps(item_id, bundleid) — bundleID приложения
///   groups(item_id, title)  — название папки
enum LaunchpadImporter {

    private struct RawItem {
        var rowid: Int
        var type: Int
        var parent: Int
        var ordering: Int
    }

    /// Находит БД Launchpad автоматически.
    static func defaultDatabaseURL() -> URL? {
        let dock = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dock", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dock, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        // Имя файла БД Launchpad — UUID (36 символов) + расширение .db.
        let candidates = files.filter {
            $0.pathExtension == "db" &&
            $0.deletingPathExtension().lastPathComponent.count == 36
        }
        return candidates.max { fileSize($0) < fileSize($1) }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Читает раскладку из БД и сопоставляет приложения с установленными по bundleID.
    /// Приложения, которых больше нет в системе, пропускаются.
    static func importLayout(dbURL: URL, installed: [AppEntry]) -> Layout? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // Индекс установленных приложений по bundleID (в нижнем регистре).
        var byBundle: [String: AppEntry] = [:]
        for app in installed {
            if let b = app.bundleID?.lowercased() { byBundle[b] = app }
        }

        // Читаем дерево элементов.
        var children: [Int: [RawItem]] = [:]
        query(db, "SELECT rowid, type, parent_id, ordering FROM items") { stmt in
            let it = RawItem(rowid: Int(sqlite3_column_int(stmt, 0)),
                             type: Int(sqlite3_column_int(stmt, 1)),
                             parent: Int(sqlite3_column_int(stmt, 2)),
                             ordering: Int(sqlite3_column_int(stmt, 3)))
            children[it.parent, default: []].append(it)
        }
        guard !children.isEmpty else { return nil }
        for key in children.keys {
            children[key]!.sort { $0.ordering < $1.ordering }
        }

        // rowid → bundleID
        var bundleByRow: [Int: String] = [:]
        query(db, "SELECT item_id, bundleid FROM apps") { stmt in
            let row = Int(sqlite3_column_int(stmt, 0))
            if let c = sqlite3_column_text(stmt, 1) {
                bundleByRow[row] = String(cString: c)
            }
        }
        // rowid → название папки
        var groupTitle: [Int: String] = [:]
        query(db, "SELECT item_id, title FROM groups") { stmt in
            let row = Int(sqlite3_column_int(stmt, 0))
            if let c = sqlite3_column_text(stmt, 1) {
                groupTitle[row] = String(cString: c)
            }
        }

        // Рекурсивно собирает установленные приложения под узлом.
        func appsUnder(_ rowid: Int) -> [AppEntry] {
            var result: [AppEntry] = []
            var seen = Set<String>()
            func walk(_ id: Int) {
                for child in children[id] ?? [] {
                    if child.type == 4 {
                        if let b = bundleByRow[child.rowid]?.lowercased(),
                           let app = byBundle[b], !seen.contains(app.id) {
                            seen.insert(app.id)
                            result.append(app)
                        }
                    } else {
                        walk(child.rowid)
                    }
                }
            }
            walk(rowid)
            return result
        }

        // Корней type==1 может быть несколько (приложения и виджеты Dashboard).
        // Берём тот, под которым больше всего приложений.
        let allItems = children.values.flatMap { $0 }
        let roots = allItems.filter { $0.type == 1 }
        guard let appsRoot = roots.max(by: { appsUnder($0.rowid).count < appsUnder($1.rowid).count })
        else { return nil }

        var pages: [Page] = []
        for pageNode in children[appsRoot.rowid] ?? [] where pageNode.type == 3 {
            var pageItems: [LaunchpadItem] = []
            for node in children[pageNode.rowid] ?? [] {
                switch node.type {
                case 4:
                    if let b = bundleByRow[node.rowid]?.lowercased(), let app = byBundle[b] {
                        pageItems.append(.app(app))
                    }
                case 2:
                    let apps = appsUnder(node.rowid)
                    guard !apps.isEmpty else { continue }
                    if apps.count == 1 {
                        pageItems.append(.app(apps[0]))
                    } else {
                        let title = groupTitle[node.rowid] ?? "Папка"
                        pageItems.append(.folder(Folder(name: title, apps: apps)))
                    }
                default:
                    continue
                }
            }
            if !pageItems.isEmpty { pages.append(Page(items: pageItems)) }
        }

        return pages.isEmpty ? nil : Layout(pages: pages)
    }

    // MARK: - Вспомогательное

    private static func query(_ db: OpaquePointer?, _ sql: String, _ row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
}
