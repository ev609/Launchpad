import SwiftUI
import Combine

/// Чистая часть раскладки, вынесенная отдельно для детерминированных тестов.
enum LayoutNormalizer {
    static func normalize(_ input: [Page], itemsPerPage: Int) -> [Page] {
        precondition(itemsPerPage > 0)
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
        out = out.filter { !$0.items.isEmpty }
        return out.isEmpty ? [Page(id: input.first?.id ?? UUID().uuidString, items: [])] : out
    }
}

/// Центральная модель Launchpad: страницы, поиск, перетаскивание, папки.
@MainActor
final class LaunchpadModel: ObservableObject {

    @Published var pages: [Page] = []
    @Published var searchText: String = "" {
        didSet { updateSearchResults() }
    }
    @Published private(set) var searchResults: [AppEntry] = []
    @Published var selectedSearchID: String?
    /// Текущий элемент сетки при навигации с клавиатуры.
    @Published var selectedGridItemID: String?
    /// Текущее приложение внутри открытой папки.
    @Published var selectedFolderAppID: String?
    /// Поверх сетки показана встроенная памятка по управлению.
    @Published var showsKeyboardHelp = false
    @Published private(set) var isScanning = false
    @Published var statusMessage: String?
    @Published var operationError: String?
    @Published var hotkeyError: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoTitle = L("Отменить")
    @Published private(set) var redoTitle = L("Повторить")
    var layoutInteractionActive = false {
        didSet {
            if !layoutInteractionActive, let result = pendingScan {
                pendingScan = nil
                applyScan(result)
            }
        }
    }
    @Published var currentPage: Int = 0
    /// Интерактивный свайп уже довёл страницы до финальных позиций, поэтому
    /// следующую смену индекса надо применить без второй полной анимации.
    var suppressNextPageAnimation = false
    /// Открытая папка (по id) — показывается оверлеем.
    @Published var openFolderID: String? {
        didSet {
            folderNameEditing = false
            guard let openFolderID, let folder = folder(withID: openFolderID) else {
                selectedFolderAppID = nil
                return
            }
            if !folder.apps.contains(where: { $0.id == selectedFolderAppID }) {
                selectedFolderAppID = folder.apps.first?.id
            }
        }
    }
    /// Имя папки сейчас редактируется в TextField — глобальные стрелки не перехватываем.
    var folderNameEditing = false
    /// Фактическое число колонок открытой папки для клавиатурной навигации.
    var folderKeyboardColumns = 5
    /// Приложение, для которого запрошено удаление (показывается подтверждение).
    @Published var pendingDelete: AppEntry?
    private var deletingAppIDs: Set<String> = []
    /// Зажата ли клавиша ⌥ — показывать крестики удаления (как в оригинале).
    @Published var optionHeld: Bool = false
    /// Режим редактирования (после долгого нажатия): иконки покачиваются, видны крестики.
    @Published var editing: Bool = false

    /// Показывать ли крестики удаления.
    var showDeleteBadges: Bool { editing || optionHeld }

    private(set) var allApps: [AppEntry] = []
    @Published private(set) var hiddenApps: [AppEntry] = []
    private var knownApps: [AppEntry] = []
    private let layoutStore: LayoutStore
    private let scanApps: () -> [AppEntry]
    private let settings: AppSettings
    private let trashApp: (URL) async throws -> Void
    private var pendingScan: AppScanner.ScanResult?
    private var hasLoadedLayout = false
    private struct Snapshot {
        let pages: [Page]
        let currentPage: Int
        let name: String
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(layoutStore: LayoutStore = .shared,
         settings: AppSettings = .shared,
         scanApps: @escaping () -> [AppEntry] = AppScanner.scan,
         trashApp: @escaping (URL) async throws -> Void = { url in
             try await AppTrashService.trash(url)
         }) {
        self.layoutStore = layoutStore
        self.settings = settings
        self.scanApps = scanApps
        self.trashApp = trashApp
    }

    // Конфигурация сетки (из пользовательских настроек).
    var columns: Int { settings.columns }
    var rows: Int { settings.rows }
    var itemsPerPage: Int { columns * rows }

    /// Пересобирает страницы под новый размер сетки.
    func applyGridChange() {
        let normalized = normalize(pages)
        guard normalized != pages else { return }
        pages = normalized
        clearHistory()
        clampCurrentPage()
        save()
    }

    // Перелистывание страниц во время перетаскивания.
    private var edgeHoverWork: DispatchWorkItem?

    // MARK: - Загрузка

    func load() {
        knownApps = scanApps()
        applyVisibilityFilter()
        hasLoadedLayout = true
        updateSearchResults()
        if let saved = layoutStore.load() {
            pages = reconcile(saved)
        } else if let imported = tryImport() {
            pages = imported
        } else {
            pages = normalize([Page(items: allApps.map { .app($0) })])
        }
        clampCurrentPage()
        restoreNavigationState()
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
        let before = snapshot(L("Импорт раскладки"))
        defer { recordChange(before) }
        guard let db = LaunchpadImporter.defaultDatabaseURL() else {
            statusMessage = L("База старого Launchpad не найдена в ~/Library/Application Support/Dock/.")
            return false
        }
        guard let layout = LaunchpadImporter.importLayout(dbURL: db, installed: allApps) else {
            statusMessage = L("База старого Launchpad найдена, но прочитать из неё раскладку не удалось.")
            return false
        }
        // backupLayout сам сообщает причину отказа.
        guard backupLayout() else { return false }
        pages = reconcile(layout)
        clampCurrentPage()
        save()
        statusMessage = L("Раскладка старого Launchpad импортирована.")
        return true
    }

    /// Сбрасывает раскладку в алфавитную по умолчанию.
    func resetLayout() {
        let before = snapshot(L("Сброс раскладки"))
        defer { recordChange(before) }
        statusMessage = nil
        guard backupLayout() else { return }
        pages = normalize([Page(items: allApps.map { .app($0) })])
        currentPage = 0
        save()
    }

    // MARK: - Переносимая раскладка

    func exportLayout(to url: URL) throws {
        flushPendingSave()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Layout(pages: normalize(pages))).write(to: url, options: .atomic)
    }

    @discardableResult
    func importLayout(from url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 10 * 1024 * 1024 else {
                throw NSError(domain: "Launchpad.LayoutImport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: L("файл раскладки больше 10 МБ")])
            }
            let layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: url))
            let before = snapshot(L("Импорт из файла"))
            guard backupLayout() else { return false }
            pages = reconcile(layout)
            currentPage = 0
            save()
            recordChange(before)
            statusMessage = L("Раскладка импортирована из файла.")
            return true
        } catch {
            statusMessage = L("Не удалось импортировать раскладку: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: - Скрытые приложения

    func hideApp(_ app: AppEntry) {
        settings.setAppHidden(app.id, hidden: true)
        if !knownApps.contains(where: { $0.id == app.id }) { knownApps.append(app) }
        removeAppEverywhere(app.id)
        applyVisibilityFilter()
        pages = normalize(pages)
        clearHistory()
        clampCurrentPage()
        save()
        statusMessage = L("«%@» скрыто. Вернуть приложение можно в настройках.", app.name)
    }

    func unhideApp(_ app: AppEntry) {
        settings.setAppHidden(app.id, hidden: false)
        if !knownApps.contains(where: { $0.id == app.id }) { knownApps.append(app) }
        applyVisibilityFilter()
        pages = reconcile(Layout(pages: pages))
        clearHistory()
        save()
        statusMessage = L("«%@» снова отображается.", app.name)
    }

    private func applyVisibilityFilter() {
        hiddenApps = knownApps.filter { settings.hiddenAppIDs.contains($0.id) }
        allApps = knownApps.filter { !settings.hiddenAppIDs.contains($0.id) }
        let sorter: (AppEntry, AppEntry) -> Bool = {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        hiddenApps.sort(by: sorter)
        allApps.sort(by: sorter)
        updateSearchResults()
    }

    // MARK: - Реконсиляция с реально установленными приложениями

    /// Убирает удалённые приложения и добавляет новые в конец: сначала в свободные
    /// слоты последней страницы, лишнее `normalize` переносит на новые страницы.
    private func reconcile(_ layout: Layout) -> [Page] {
        let byID = Dictionary(allApps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var result: [Page] = []

        for page in layout.pages {
            var items: [LaunchpadItem] = []
            for item in page.items {
                switch item {
                case .app(let a):
                    if let fresh = byID[a.id], seen.insert(fresh.id).inserted {
                        items.append(.app(fresh))
                    }
                case .folder(var f):
                    f.apps = f.apps.compactMap { app in
                        guard let fresh = byID[app.id], seen.insert(fresh.id).inserted else { return nil }
                        return fresh
                    }
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
            if result.isEmpty {
                result.append(Page(items: []))
            }
            result[result.count - 1].items.append(contentsOf: newApps.map { .app($0) })
        }
        return normalize(result)
    }

    /// Приводит страницы к вместимости сетки, переливая лишнее на следующие страницы.
    private func normalize(_ input: [Page]) -> [Page] {
        LayoutNormalizer.normalize(input, itemsPerPage: itemsPerPage)
    }

    func save() {
        clampCurrentPage()
        if let openFolderID, folder(withID: openFolderID) == nil {
            self.openFolderID = nil
        }
        layoutStore.save(Layout(pages: pages))
    }

    func flushPendingSave() {
        layoutStore.flush()
    }

    private func clampCurrentPage() {
        currentPage = max(0, min(currentPage, pages.count - 1))
        if let selectedGridItemID,
           !pages[currentPage].items.contains(where: { $0.id == selectedGridItemID }) {
            self.selectedGridItemID = nil
        }
    }

    // MARK: - Поиск

    private func updateSearchResults() {
        searchResults = AppSearch.results(for: searchText, in: allApps)
        selectedSearchID = searchResults.first?.id
        if isSearching { selectedGridItemID = nil }
    }

    var selectedSearchApp: AppEntry? {
        searchResults.first { $0.id == selectedSearchID } ?? searchResults.first
    }

    func selectSearchResult(offset: Int) {
        guard !searchResults.isEmpty else { return }
        let index = searchResults.firstIndex { $0.id == selectedSearchID } ?? 0
        selectedSearchID = searchResults[max(0, min(index + offset, searchResults.count - 1))].id
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        let before = snapshot(L("Перемещение"))
        defer { recordChange(before) }
        guard sourceID != targetID, pages.indices.contains(targetPage),
              let from = locate(sourceID) else { return }
        let item = pages[from.page].items.remove(at: from.index)

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
        let before = snapshot(L("Создание или изменение папки"))
        defer { recordChange(before) }
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
            let folder = Folder(name: Self.suggestedFolderName(for: [targetApp, sourceApp]),
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
        let before = snapshot(L("Изменение папки"))
        defer { recordChange(before) }
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
        let before = snapshot(L("Извлечение из папки"))
        defer { recordChange(before) }
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
        let before = snapshot(L("Перемещение в папке"))
        defer { recordChange(before) }
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
        let before = snapshot(L("Переименование папки"))
        defer { recordChange(before) }
        guard let loc = locate("folder:" + folderID),
              case .folder(var folder) = pages[loc.page].items[loc.index] else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folder.name = trimmed
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
    /// Имя новой папки по категории приложений, как в оригинальном Launchpad:
    /// общая категория, иначе категория приложения, на которое перетащили.
    nonisolated static func suggestedFolderName(for apps: [AppEntry]) -> String {
        let categories = apps.compactMap(\.category)
        let common = Set(categories).count == 1 && categories.count == apps.count ? categories.first : nil
        guard let category = common ?? apps.first?.category else { return L("Папка") }
        return folderName(forCategory: category) ?? L("Папка")
    }

    nonisolated static func folderName(forCategory category: String) -> String? {
        let key = category.lowercased().replacingOccurrences(of: "public.app-category.", with: "")
        if key == "games" || key.hasSuffix("-games") { return L("Игры") }
        let names: [String: String] = [
            "business": L("Бизнес"),
            "developer-tools": L("Разработка"),
            "education": L("Образование"),
            "entertainment": L("Развлечения"),
            "finance": L("Финансы"),
            "graphics-design": L("Графика и дизайн"),
            "healthcare-fitness": L("Здоровье"),
            "lifestyle": L("Образ жизни"),
            "medical": L("Медицина"),
            "music": L("Музыка"),
            "news": L("Новости"),
            "photography": L("Фото"),
            "productivity": L("Продуктивность"),
            "reference": L("Справочники"),
            "social-networking": L("Общение"),
            "sports": L("Спорт"),
            "travel": L("Путешествия"),
            "utilities": L("Утилиты"),
            "video": L("Видео"),
            "weather": L("Погода"),
        ]
        return names[key]
    }

    // MARK: - Навигация

    func goToPage(_ index: Int) {
        let target = max(0, min(index, pages.count - 1))
        if target != currentPage { selectedGridItemID = nil }
        currentPage = target
    }

    func nextPage() { goToPage(currentPage + 1) }
    func prevPage() { goToPage(currentPage - 1) }

    var selectedGridItem: LaunchpadItem? {
        guard pages.indices.contains(currentPage), let selectedGridItemID else { return nil }
        return pages[currentPage].items.first { $0.id == selectedGridItemID }
    }

    var selectedFolderApp: AppEntry? {
        guard let openFolderID, let selectedFolderAppID else { return nil }
        return folder(withID: openFolderID)?.apps.first { $0.id == selectedFolderAppID }
    }

    /// Выбор соседнего элемента сетки. Горизонтальная навигация переходит между
    /// страницами, вертикальная остаётся в пределах текущей страницы.
    func moveGridSelection(horizontal: Int = 0, vertical: Int = 0) {
        guard pages.indices.contains(currentPage), !pages[currentPage].items.isEmpty else {
            selectedGridItemID = nil
            return
        }
        let items = pages[currentPage].items
        guard let selectedGridItemID,
              let index = items.firstIndex(where: { $0.id == selectedGridItemID }) else {
            self.selectedGridItemID = (horizontal < 0 || vertical < 0) ? items.last?.id : items.first?.id
            return
        }

        if horizontal != 0 {
            let target = index + horizontal
            if target < 0, currentPage > 0 {
                currentPage -= 1
                self.selectedGridItemID = pages[currentPage].items.last?.id
            } else if target >= items.count, currentPage + 1 < pages.count {
                currentPage += 1
                self.selectedGridItemID = pages[currentPage].items.first?.id
            } else {
                self.selectedGridItemID = items[max(0, min(target, items.count - 1))].id
            }
            return
        }

        if vertical != 0 {
            let target = max(0, min(index + vertical * columns, items.count - 1))
            self.selectedGridItemID = items[target].id
        }
    }

    func selectGridBoundary(first: Bool) {
        guard pages.indices.contains(currentPage) else { return }
        selectedGridItemID = first ? pages[currentPage].items.first?.id : pages[currentPage].items.last?.id
    }

    func openFolder(_ folderID: String) {
        openFolderID = folderID
    }

    func closeFolder() {
        openFolderID = nil
    }

    // MARK: - Восстановление позиции

    func saveNavigationState() {
        let pageID = pages.indices.contains(currentPage) ? pages[currentPage].id : nil
        let itemID = selectedGridItem.flatMap { $0.id }
        let folderID = openFolderID.flatMap { folder(withID: $0) == nil ? nil : $0 }
        let folderAppID = selectedFolderApp?.id
        settings.saveNavigationState(LaunchpadNavigationState(
            pageID: pageID,
            itemID: itemID,
            folderID: folderID,
            folderAppID: folderAppID
        ))
    }

    func restoreNavigationState() {
        let state = settings.navigationState
        if let pageID = state.pageID, let page = pages.firstIndex(where: { $0.id == pageID }) {
            currentPage = page
        } else if let itemID = state.itemID, let location = locate(itemID) {
            currentPage = location.page
        } else if let folderID = state.folderID, let location = locate("folder:" + folderID) {
            currentPage = location.page
        }
        clampCurrentPage()

        if let itemID = state.itemID,
           pages[currentPage].items.contains(where: { $0.id == itemID }) {
            selectedGridItemID = itemID
        } else {
            selectedGridItemID = nil
        }

        if let folderID = state.folderID, let location = locate("folder:" + folderID) {
            currentPage = location.page
            selectedGridItemID = "folder:" + folderID
            openFolder(folderID)
            if let folderAppID = state.folderAppID,
               folder(withID: folderID)?.apps.contains(where: { $0.id == folderAppID }) == true {
                selectedFolderAppID = folderAppID
            }
        } else {
            closeFolder()
        }
    }

    /// Выбор приложения в открытой папке. Число колонок совпадает с максимумом
    /// визуальной сетки папки; на узких окнах оно передаётся представлением.
    func moveFolderSelection(horizontal: Int = 0, vertical: Int = 0, columns: Int = 5) {
        guard let openFolderID, let folder = folder(withID: openFolderID), !folder.apps.isEmpty else {
            selectedFolderAppID = nil
            return
        }
        guard let selectedFolderAppID,
              let index = folder.apps.firstIndex(where: { $0.id == selectedFolderAppID }) else {
            self.selectedFolderAppID = (horizontal < 0 || vertical < 0)
                ? folder.apps.last?.id : folder.apps.first?.id
            return
        }
        let offset = horizontal != 0 ? horizontal : vertical * max(1, columns)
        let target = max(0, min(index + offset, folder.apps.count - 1))
        self.selectedFolderAppID = folder.apps[target].id
    }

    /// Переставляет выбранный элемент, сохраняя фокус на нём. На границе
    /// заполненных страниц меняет его местами с крайним элементом соседней.
    @discardableResult
    func moveSelectedGridItem(horizontal: Int = 0, vertical: Int = 0) -> Bool {
        guard let selectedGridItemID, let from = locate(selectedGridItemID),
              from.page == currentPage else { return false }
        let before = snapshot(L("Перемещение с клавиатуры"))
        let offset = horizontal != 0 ? horizontal : vertical * columns
        let targetIndex = from.index + offset

        if pages[from.page].items.indices.contains(targetIndex) {
            pages[from.page].items.swapAt(from.index, targetIndex)
        } else if horizontal < 0, from.index == 0, from.page > 0 {
            let destination = from.page - 1
            if pages[destination].items.count >= itemsPerPage,
               let last = pages[destination].items.indices.last {
                let displaced = pages[destination].items[last]
                pages[destination].items[last] = pages[from.page].items[from.index]
                pages[from.page].items[from.index] = displaced
            } else {
                let item = pages[from.page].items.remove(at: from.index)
                pages[destination].items.append(item)
                if pages[from.page].items.isEmpty { pages.remove(at: from.page) }
            }
            currentPage = destination
        } else if horizontal > 0, from.index == pages[from.page].items.count - 1 {
            if from.page + 1 < pages.count {
                let destination = from.page + 1
                if pages[destination].items.count >= itemsPerPage {
                    let displaced = pages[destination].items[0]
                    pages[destination].items[0] = pages[from.page].items[from.index]
                    pages[from.page].items[from.index] = displaced
                    currentPage = destination
                } else {
                    let item = pages[from.page].items.remove(at: from.index)
                    pages[destination].items.insert(item, at: 0)
                    if pages[from.page].items.isEmpty {
                        pages.remove(at: from.page)
                        currentPage = from.page
                    } else {
                        currentPage = destination
                    }
                }
            } else if pages[from.page].items.count > 1 {
                let item = pages[from.page].items.remove(at: from.index)
                pages.append(Page(items: [item]))
                currentPage = pages.count - 1
            } else {
                return false
            }
        } else {
            return false
        }

        save()
        recordChange(before)
        return true
    }

    /// Объединяет выбранный элемент с соседом — доступная клавиатурная
    /// альтернатива перетаскиванию одного приложения на другое.
    @discardableResult
    func combineSelectedGridItem(withNeighbor offset: Int) -> Bool {
        guard let selectedGridItemID, let from = locate(selectedGridItemID),
              pages[from.page].items.indices.contains(from.index + offset) else { return false }
        let sourceApps = pages[from.page].items[from.index].containedApps.map(\.id)
        let targetID = pages[from.page].items[from.index + offset].id
        guard combine(selectedGridItemID, into: targetID) else { return false }
        self.selectedGridItemID = pages.flatMap(\.items).first { item in
            if case .folder(let folder) = item {
                return sourceApps.allSatisfy { id in folder.apps.contains(where: { $0.id == id }) }
            }
            return false
        }?.id
        return true
    }

    /// Переставляет выбранное приложение внутри открытой папки.
    @discardableResult
    func moveSelectedFolderApp(horizontal: Int = 0, vertical: Int = 0, columns: Int = 5) -> Bool {
        guard let openFolderID, let folder = folder(withID: openFolderID),
              let selectedFolderAppID,
              let from = folder.apps.firstIndex(where: { $0.id == selectedFolderAppID }) else { return false }
        let offset = horizontal != 0 ? horizontal : vertical * max(1, columns)
        let target = max(0, min(from + offset, folder.apps.count - 1))
        guard target != from else { return false }
        moveInFolder(openFolderID, appID: selectedFolderAppID, toIndex: target)
        self.selectedFolderAppID = selectedFolderAppID
        return true
    }

    @discardableResult
    func extractSelectedFolderApp() -> Bool {
        guard let openFolderID, let selectedFolderAppID else { return false }
        extractApp(selectedFolderAppID, fromFolder: openFolderID)
        self.selectedGridItemID = "app:" + selectedFolderAppID
        return true
    }

    // MARK: - Перенос между страницами

    /// Переносит элемент в конец указанной страницы. Если индекс за пределами —
    /// создаёт новую страницу.
    func moveItem(_ sourceID: String, toPage index: Int) {
        let before = snapshot(L("Перемещение"))
        defer { recordChange(before) }
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

    /// Системные приложения защищены; остальные может удалить Finder,
    /// при необходимости запросив разрешение у пользователя.
    func canDelete(_ app: AppEntry) -> Bool {
        !app.path.hasPrefix("/System/")
    }

    /// Перемещает приложение в Корзину и убирает его из раскладки.
    @discardableResult
    func deleteApp(_ app: AppEntry) async -> Bool {
        guard canDelete(app), deletingAppIDs.insert(app.id).inserted else { return false }
        defer { deletingAppIDs.remove(app.id) }
        operationError = nil
        let url = URL(fileURLWithPath: app.path)
        do {
            try await trashApp(url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                return false
            }
            operationError = L("Не удалось переместить «%@» в Корзину: %@", app.name, error.localizedDescription)
            return false
        }
        removeAppEverywhere(app.id)
        // Удалили из папки, и она распалась — закрываем оверлей.
        if let id = openFolderID, folder(withID: id) == nil { closeFolder() }
        allApps.removeAll { $0.id == app.id }
        knownApps.removeAll { $0.id == app.id }
        hiddenApps.removeAll { $0.id == app.id }
        pages = normalize(pages)
        clearHistory()
        updateSearchResults()
        clampCurrentPage()
        save()
        return true
    }

    /// Удаляет приложение отовсюду (верхний уровень и из папок).
    private func removeAppEverywhere(_ appID: String) {
        for p in pages.indices {
            var items = pages[p].items
            var changed = false
            var result: [LaunchpadItem] = []
            for item in items {
                switch item {
                case .app(let a):
                    if a.id == appID { changed = true; continue }
                    result.append(item)
                case .folder(var f):
                    if f.apps.contains(where: { $0.id == appID }) {
                        f.apps.removeAll { $0.id == appID }
                        changed = true
                        if f.apps.count == 1 { result.append(.app(f.apps[0])) }
                        else if !f.apps.isEmpty { result.append(.folder(f)) }
                        // пустая папка — выкидываем
                    } else {
                        result.append(item)
                    }
                }
            }
            if changed { items = result; pages[p].items = items }
        }
    }

    /// Перемещает приложение (найденное поиском) на страницу `p` в позицию `index`,
    /// вынимая его из прежнего места (в т.ч. из папки).
    func relocateApp(_ app: AppEntry, toPage p: Int, at index: Int) {
        let before = snapshot(L("Перемещение"))
        defer { recordChange(before) }
        removeAppEverywhere(app.id)
        var target = p
        if target < 0 { target = 0 }
        if target >= pages.count {
            pages.append(Page(items: []))
            target = pages.count - 1
        }
        let idx = max(0, min(index, pages[target].items.count))
        pages[target].items.insert(.app(app), at: idx)
        pages = normalize(pages)
        clampCurrentPage()
        save()
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
        let before = snapshot(L("Перемещение"))
        defer { recordChange(before) }
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

extension LaunchpadModel {
    /// Сразу показываем последнюю раскладку, не обходя каталоги приложений.
    func loadCachedLayout() {
        if let saved = layoutStore.load() {
            var seen = Set<String>()
            knownApps = saved.pages.flatMap(\.items).flatMap(\.containedApps)
                .filter { seen.insert($0.id).inserted }
            applyVisibilityFilter()
            pages = reconcile(saved)
            hasLoadedLayout = true
        } else {
            pages = [Page(items: [])]
        }
        updateSearchResults()
        clampCurrentPage()
        restoreNavigationState()
    }

    /// Один обход за раз. Файловая система и метаданные Bundle читаются вне MainActor.
    func refreshApps(scan: @escaping @Sendable () -> AppScanner.ScanResult = { AppScanner.scanResult() }) async {
        guard !isScanning else { return }
        let trace = PerformanceTrace.begin("Application scan")
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            PerformanceTrace.end("Application scan", id: trace)
            PerformanceMetrics.shared.recordScan(
                ProcessInfo.processInfo.systemUptime - startedAt)
        }
        isScanning = true
        defer { isScanning = false }
        let result = await Task.detached(priority: .utility, operation: scan).value
        if layoutInteractionActive {
            pendingScan = result
        } else {
            applyScan(result)
        }
    }

    func applyScan(_ result: AppScanner.ScanResult) {
        var apps = result.apps
        var seen = Set(apps.map(\.id))
        for app in knownApps where !seen.contains(app.id) {
            if result.unavailablePaths.contains(where: { app.path == $0 || app.path.hasPrefix($0 + "/") }) {
                apps.append(app)
                seen.insert(app.id)
            }
        }
        apps.sort {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        statusMessage = result.unavailablePaths.isEmpty ? nil
            : L("Часть каталогов недоступна. Их приложения сохранены в раскладке.")
        guard !hasLoadedLayout || apps != knownApps else { return }
        knownApps = apps
        applyVisibilityFilter()
        if hasLoadedLayout {
            // Используем живую раскладку: пользователь мог изменить её во время обхода.
            pages = reconcile(Layout(pages: pages))
            // История остаётся доступной: снимки приводим к новому набору приложений,
            // чтобы отмена не вернула удалённое приложение и не потеряла новое.
            undoStack = undoStack.map(reconciled)
            redoStack = redoStack.map(reconciled)
            updateHistoryState()
        } else {
            pages = tryImport() ?? normalize([Page(items: allApps.map { .app($0) })])
            hasLoadedLayout = true
            clearHistory()
        }
        updateSearchResults()
        save()
    }

    private func reconciled(_ state: Snapshot) -> Snapshot {
        Snapshot(pages: reconcile(Layout(pages: state.pages)),
                 currentPage: state.currentPage, name: state.name)
    }

    private func snapshot(_ name: String) -> Snapshot {
        Snapshot(pages: normalize(pages), currentPage: currentPage, name: name)
    }

    private func recordChange(_ before: Snapshot) {
        guard before.pages != normalize(pages) else { return }
        undoStack.append(before)
        redoStack.removeAll()
        updateHistoryState()
    }

    private func updateHistoryState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoTitle = undoStack.last.map { L("Отменить: %@", $0.name) } ?? L("Отменить")
        redoTitle = redoStack.last.map { L("Повторить: %@", $0.name) } ?? L("Повторить")
    }

    private func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateHistoryState()
    }

    func undoLayoutChange() {
        guard !layoutInteractionActive, let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot(previous.name))
        restore(previous)
    }

    func redoLayoutChange() {
        guard !layoutInteractionActive, let next = redoStack.popLast() else { return }
        undoStack.append(snapshot(next.name))
        restore(next)
    }

    private func restore(_ state: Snapshot) {
        cancelEdgeHover()
        pages = normalize(state.pages)
        currentPage = state.currentPage
        openFolderID = nil
        searchText = ""
        save()
        updateHistoryState()
    }

    private func backupLayout() -> Bool {
        do {
            try layoutStore.backup(Layout(pages: normalize(pages)))
            return true
        } catch {
            statusMessage = L("Не удалось создать резервную копию раскладки: %@", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func restoreLatestBackup() -> Bool {
        do {
            guard let layout = try layoutStore.latestBackup() else {
                statusMessage = L("Резервных копий пока нет.")
                return false
            }
            let before = snapshot(L("Восстановление раскладки"))
            guard backupLayout() else { return false }
            pages = reconcile(layout)
            currentPage = 0
            save()
            recordChange(before)
            statusMessage = L("Раскладка восстановлена.")
            return true
        } catch {
            statusMessage = L("Не удалось восстановить раскладку: %@", error.localizedDescription)
            return false
        }
    }
}
