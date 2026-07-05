import SwiftUI
import Combine

/// Центральная модель Launchpad: страницы, поиск, перетаскивание, папки.
@MainActor
final class LaunchpadModel: ObservableObject {

    @Published var pages: [Page] = []
    @Published var searchText: String = ""
    @Published var currentPage: Int = 0
    /// Открытая папка (по id) — показывается оверлеем.
    @Published var openFolderID: String?

    private(set) var allApps: [AppEntry] = []

    // Конфигурация сетки (из пользовательских настроек).
    var columns: Int { AppSettings.shared.columns }
    var rows: Int { AppSettings.shared.rows }
    var itemsPerPage: Int { columns * rows }

    /// Пересобирает страницы под новый размер сетки.
    func applyGridChange() {
        pages = normalize(pages)
        clampCurrentPage()
        save()
    }

    // Перелистывание страниц во время перетаскивания.
    private var edgeHoverWork: DispatchWorkItem?

    // MARK: - Загрузка

    func load() {
        allApps = AppScanner.scan()
        if let saved = LayoutStore.shared.load() {
            pages = reconcile(saved)
        } else if let imported = tryImport() {
            pages = imported
        } else {
            pages = normalize([Page(items: allApps.map { .app($0) })])
        }
        clampCurrentPage()
        save()
    }

    /// Пытается импортировать раскладку старого Launchpad.
    private func tryImport() -> [Page]? {
        guard let db = LaunchpadImporter.defaultDatabaseURL(),
              let layout = LaunchpadImporter.importLayout(dbURL: db, installed: allApps)
        else { return nil }
        return reconcile(layout)
    }

    /// Явный импорт по запросу пользователя (перезаписывает текущую раскладку).
    @discardableResult
    func importFromSystemLaunchpad() -> Bool {
        guard let db = LaunchpadImporter.defaultDatabaseURL(),
              let layout = LaunchpadImporter.importLayout(dbURL: db, installed: allApps)
        else { return false }
        pages = reconcile(layout)
        clampCurrentPage()
        save()
        return true
    }

    /// Сбрасывает раскладку в алфавитную по умолчанию.
    func resetLayout() {
        LayoutStore.shared.reset()
        pages = normalize([Page(items: allApps.map { .app($0) })])
        currentPage = 0
        save()
    }

    // MARK: - Реконсиляция с реально установленными приложениями

    /// Убирает удалённые приложения и добавляет новые в конец.
    private func reconcile(_ layout: Layout) -> [Page] {
        let byID = Dictionary(allApps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var result: [Page] = []

        for page in layout.pages {
            var items: [LaunchpadItem] = []
            for item in page.items {
                switch item {
                case .app(let a):
                    if let fresh = byID[a.id] {
                        seen.insert(fresh.id)
                        items.append(.app(fresh))
                    }
                case .folder(var f):
                    f.apps = f.apps.compactMap { byID[$0.id] }
                    f.apps.forEach { seen.insert($0.id) }
                    if f.apps.count == 1 {
                        items.append(.app(f.apps[0]))
                    } else if !f.apps.isEmpty {
                        items.append(.folder(f))
                    }
                }
            }
            result.append(Page(id: page.id, items: items))
        }

        let newApps = allApps.filter { !seen.contains($0.id) }
        if !newApps.isEmpty {
            result.append(Page(items: newApps.map { .app($0) }))
        }
        return normalize(result)
    }

    /// Приводит страницы к вместимости сетки, переливая лишнее на следующие страницы.
    private func normalize(_ input: [Page]) -> [Page] {
        var out: [Page] = []
        var overflow: [LaunchpadItem] = []
        for page in input {
            var items = overflow + page.items
            overflow = []
            if items.count > itemsPerPage {
                overflow = Array(items[itemsPerPage...])
                items = Array(items[0..<itemsPerPage])
            }
            if !items.isEmpty || out.isEmpty {
                out.append(Page(id: page.id, items: items))
            }
        }
        while !overflow.isEmpty {
            let slice = Array(overflow.prefix(itemsPerPage))
            overflow.removeFirst(slice.count)
            out.append(Page(items: slice))
        }
        // Убираем пустые страницы (кроме единственной).
        out = out.filter { !$0.items.isEmpty }
        return out.isEmpty ? [Page(items: [])] : out
    }

    func save() {
        LayoutStore.shared.save(Layout(pages: pages))
    }

    private func clampCurrentPage() {
        currentPage = max(0, min(currentPage, pages.count - 1))
    }

    // MARK: - Поиск

    /// Результаты поиска (плоский список приложений).
    var searchResults: [AppEntry] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return allApps
            .filter { $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Локация элементов

    /// Возвращает (индекс страницы, индекс в странице) для элемента по id.
    private func locate(_ itemID: String) -> (page: Int, index: Int)? {
        for (p, page) in pages.enumerated() {
            if let i = page.items.firstIndex(where: { $0.id == itemID }) {
                return (p, i)
            }
        }
        return nil
    }

    // MARK: - Перетаскивание

    /// Перемещает элемент на позицию перед `targetID` (или в конец страницы, если target == nil).
    func move(_ sourceID: String, before targetID: String?, onPage targetPage: Int) {
        guard let from = locate(sourceID) else { return }
        let item = pages[from.page].items.remove(at: from.index)

        guard targetPage < pages.count else {
            pages[from.page].items.insert(item, at: from.index) // откат
            return
        }

        if let targetID, let toIndex = pages[targetPage].items.firstIndex(where: { $0.id == targetID }) {
            pages[targetPage].items.insert(item, at: toIndex)
        } else {
            pages[targetPage].items.append(item)
        }
        pages = normalize(pages)
        clampCurrentPage()
        save()
    }

    /// Объединяет два приложения в папку либо добавляет приложение в существующую папку.
    /// Возвращает true, если объединение произошло.
    @discardableResult
    func combine(_ sourceID: String, into targetID: String) -> Bool {
        guard sourceID != targetID,
              let from = locate(sourceID),
              let to = locate(targetID) else { return false }

        let source = pages[from.page].items[from.index]
        let target = pages[to.page].items[to.index]

        switch target {
        case .folder(var folder):
            // Добавляем приложения источника в папку.
            let apps = source.containedApps
            folder.apps.append(contentsOf: apps.filter { app in
                !folder.apps.contains(where: { $0.id == app.id })
            })
            pages[to.page].items[to.index] = .folder(folder)
            removeItem(sourceID)

        case .app(let targetApp):
            guard case .app(let sourceApp) = source else {
                // Нельзя вложить папку в приложение — игнорируем.
                return false
            }
            let folder = Folder(name: suggestedFolderName(for: [targetApp, sourceApp]),
                                apps: [targetApp, sourceApp])
            pages[to.page].items[to.index] = .folder(folder)
            removeItem(sourceID)
        }

        pages = normalize(pages)
        clampCurrentPage()
        save()
        return true
    }

    private func removeItem(_ itemID: String) {
        guard let loc = locate(itemID) else { return }
        pages[loc.page].items.remove(at: loc.index)
    }

    /// Удаляет приложение из папки; если в папке осталось одно приложение — раскрывает её.
    func removeFromFolder(_ appID: String, folderID: String) {
        guard let loc = locate("folder:" + folderID),
              case .folder(var folder) = pages[loc.page].items[loc.index] else { return }
        folder.apps.removeAll { $0.id == appID }
        if folder.apps.count <= 1 {
            if let only = folder.apps.first {
                pages[loc.page].items[loc.index] = .app(only)
            } else {
                pages[loc.page].items.remove(at: loc.index)
            }
            openFolderID = nil
        } else {
            pages[loc.page].items[loc.index] = .folder(folder)
        }
        pages = normalize(pages)
        save()
    }

    /// Извлекает приложение из папки и кладёт его на страницу рядом с папкой.
    func extractApp(_ appID: String, fromFolder folderID: String) {
        guard let loc = locate("folder:" + folderID),
              case .folder(var folder) = pages[loc.page].items[loc.index],
              let app = folder.apps.first(where: { $0.id == appID }) else { return }

        folder.apps.removeAll { $0.id == appID }

        if folder.apps.count <= 1 {
            // Папка вырождается: заменяем её оставшимся приложением (или убираем).
            if let only = folder.apps.first {
                pages[loc.page].items[loc.index] = .app(only)
            } else {
                pages[loc.page].items.remove(at: loc.index)
            }
        } else {
            pages[loc.page].items[loc.index] = .folder(folder)
        }

        // Вставляем извлечённое приложение сразу после папки.
        let insertAt = min(loc.index + 1, pages[loc.page].items.count)
        pages[loc.page].items.insert(.app(app), at: insertAt)

        openFolderID = nil
        pages = normalize(pages)
        clampCurrentPage()
        save()
    }

    /// Меняет порядок приложений внутри папки.
    func moveInFolder(_ folderID: String, appID: String, toIndex index: Int) {
        guard let loc = locate("folder:" + folderID),
              case .folder(var folder) = pages[loc.page].items[loc.index],
              let from = folder.apps.firstIndex(where: { $0.id == appID }) else { return }
        let app = folder.apps.remove(at: from)
        let dest = max(0, min(index, folder.apps.count))
        folder.apps.insert(app, at: dest)
        pages[loc.page].items[loc.index] = .folder(folder)
        save()
    }

    func renameFolder(_ folderID: String, to name: String) {
        guard let loc = locate("folder:" + folderID),
              case .folder(var folder) = pages[loc.page].items[loc.index] else { return }
        folder.name = name.isEmpty ? folder.name : name
        pages[loc.page].items[loc.index] = .folder(folder)
        save()
    }

    func folder(withID folderID: String) -> Folder? {
        for page in pages {
            for item in page.items {
                if case .folder(let f) = item, f.id == folderID { return f }
            }
        }
        return nil
    }

    /// Предлагает имя папки по категории приложений (упрощённо — по первому приложению).
    private func suggestedFolderName(for apps: [AppEntry]) -> String {
        "Папка"
    }

    // MARK: - Навигация

    func goToPage(_ index: Int) {
        currentPage = max(0, min(index, pages.count - 1))
    }

    func nextPage() { goToPage(currentPage + 1) }
    func prevPage() { goToPage(currentPage - 1) }

    // MARK: - Перенос между страницами

    /// Переносит элемент в конец указанной страницы. Если индекс за пределами —
    /// создаёт новую страницу.
    func moveItem(_ sourceID: String, toPage index: Int) {
        guard index >= 0, let from = locate(sourceID) else { return }
        let item = pages[from.page].items.remove(at: from.index)
        var target = index
        if target >= pages.count {
            pages.append(Page(items: []))
            target = pages.count - 1
        }
        pages[target].items.append(item)
        pages = normalize(pages)
        clampCurrentPage()
        save()
    }

    /// Номер страницы, на которой находится элемент.
    func pageIndex(of itemID: String) -> Int? {
        locate(itemID)?.page
    }

    /// Элемент по идентификатору.
    func item(withID id: String) -> LaunchpadItem? {
        for page in pages {
            if let found = page.items.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// Переносит элемент на страницу `p` в позицию `index` (жестовое перетаскивание).
    /// `index` задаётся в пространстве «страница без перетаскиваемого элемента»
    /// (others-space), поэтому после удаления элемента вставляем прямо по нему.
    func placeItem(_ sourceID: String, onPage p: Int, at index: Int) {
        guard let from = locate(sourceID), p >= 0, p < pages.count else { return }
        let item = pages[from.page].items.remove(at: from.index)
        let idx = max(0, min(index, pages[p].items.count))
        pages[p].items.insert(item, at: idx)
        pages = normalize(pages)
        clampCurrentPage()
        save()
    }

    /// Листает страницы во время перетаскивания к краю экрана.
    /// У правого края последней страницы создаёт новую пустую страницу.
    func flipDuringDrag(_ direction: Int) {
        if direction > 0 {
            // Новую страницу создаём, только если последняя не пуста.
            if currentPage >= pages.count - 1, !(pages.last?.items.isEmpty ?? true) {
                pages.append(Page(items: []))
            }
            nextPage()
        } else {
            prevPage()
        }
    }

    func beginEdgeHover(_ direction: Int) {
        guard edgeHoverWork == nil else { return }
        scheduleEdgeFlip(direction)
    }

    private func scheduleEdgeFlip(_ direction: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.edgeHoverWork = nil
            self.flipDuringDrag(direction)
            self.scheduleEdgeFlip(direction) // продолжаем листать, пока курсор у края
        }
        edgeHoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func cancelEdgeHover() {
        edgeHoverWork?.cancel()
        edgeHoverWork = nil
    }

    /// Убирает пустые страницы (например, оставшиеся после перетаскивания).
    func pruneEmptyPages() {
        cancelEdgeHover()
        let before = pages.count
        pages = pages.filter { !$0.items.isEmpty }
        if pages.isEmpty { pages = [Page(items: [])] }
        if pages.count != before {
            clampCurrentPage()
            save()
        }
    }
}
