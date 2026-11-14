import SwiftUI

/// Корневой экран Launchpad с жестовым перетаскиванием иконок.
struct LaunchpadRootView: View {
    @ObservedObject var model: LaunchpadModel
    @ObservedObject var scrollState: PageScrollState
    let safeTop: CGFloat
    let onFirstFrame: () -> Void
    @FocusState private var searchFocused: Bool

    // Активное перетаскивание.
    @State private var drag: DragState?
    /// Отдельный отображаемый индекс позволяет анимировать замену страницы,
    /// не создавая сразу все страницы и сотни Core Animation textures.
    @State private var visiblePage: Int
    @State private var previousPage: Int?
    @State private var pageTransitionGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    init(model: LaunchpadModel, scrollState: PageScrollState,
         safeTop: CGFloat = 0, onFirstFrame: @escaping () -> Void = {}) {
        self.model = model
        self.scrollState = scrollState
        self.safeTop = safeTop
        self.onFirstFrame = onFirstFrame
        _visiblePage = State(initialValue: model.currentPage)
    }
    // Кандидат в папку и момент начала наведения (для задержки).

    var body: some View {
        GeometryReader { geo in
            let metrics = GridMetrics(size: geo.size, columns: model.columns,
                                      rows: model.rows, safeTop: safeTop)

            ZStack {
                // Фон: размытие рабочего стола + затемнение.
                if reduceTransparency || scrollState.useLightweightBackground {
                    Color(red: 0.08, green: 0.09, blue: 0.11)
                        .ignoresSafeArea()
                } else {
                    VisualEffectView(material: .fullScreenUI, blending: .behindWindow)
                        .ignoresSafeArea()
                }
                Color.black.opacity(contrast == .increased ? 0.42
                                    : (reduceTransparency || scrollState.useLightweightBackground
                                       ? 0.12 : 0.28))
                    .ignoresSafeArea()
                    .onTapGesture {
                        if model.openFolderID != nil { return }
                        if model.editing {
                            model.editing = false      // выход из режима покачивания
                        } else if model.isSearching {
                            model.searchText = ""      // клик вне результатов сбрасывает поиск
                        } else {
                            NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
                        }
                    }

                // Сетка и подсказки краёв. Показываем вне поиска, А ТАКЖЕ во время
                // драга из поиска — чтобы было видно, на какую страницу кладём.
                if !model.isSearching || drag != nil {
                    pager(metrics)
                    edgeHint(metrics, direction: -1)
                    edgeHint(metrics, direction: 1)
                }

                // Поле поиска ВСЕГДА в одной и той же позиции иерархии —
                // иначе при переключении режима TextField пересоздаётся и теряет фокус.
                VStack(spacing: 0) {
                    searchField.padding(.top, safeTop + 16)
                    if model.isSearching {
                        // Во время драга из поиска результаты остаются смонтированными
                        // (ради живого жеста), но прячутся — сверху видна сетка.
                        SearchResultsView(model: model,
                                          onBeginDrag: { app, value in beginSearchDrag(app, value, metrics) },
                                          onDragChange: { value in updateDrag(value, metrics) },
                                          onDragEnd: { _ in endDrag() })
                            .opacity(drag != nil ? 0 : 1)
                    } else {
                        Spacer()
                        pageDots.padding(.bottom, 24)
                    }
                }

                // Летящая под курсором иконка (из сетки или из поиска).
                if let d = drag {
                    let item: LaunchpadItem? = d.searchApp.map { .app($0) } ?? model.item(withID: d.itemID)
                    if let item {
                        draggedIcon(item, metrics: metrics)
                            .position(d.location)
                            .allowsHitTesting(false)
                            .transition(.identity)
                            // Preview должен сразу появляться под указателем и
                            // следовать за ним без унаследованной spring-анимации.
                            .transaction { transaction in
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                    }
                }

                // Оверлей открытой папки.
                if let id = model.openFolderID {
                    FolderOverlay(folderID: id, model: model)
                        .zIndex(10)
                }

                if model.showsKeyboardHelp {
                    KeyboardShortcutHelpView(model: model)
                        .zIndex(20)
                }
            }
            .coordinateSpace(name: "root")
            .gesture(
                MagnificationGesture()
                    .onEnded { scale in
                        if scale < 0.85 {
                            NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
                        }
                    }
            )
            .onDisappear {
                model.cancelEdgeHover()
                model.layoutInteractionActive = false
            }
            .onAppear {
                DispatchQueue.main.async { onFirstFrame() }
                guard !searchFocused else { return }
                DispatchQueue.main.async { searchFocused = true }
                prefetchNeighborIcons(around: model.currentPage)
            }
            .onChange(of: model.currentPage) { newPage in
                prefetchNeighborIcons(around: newPage)
            }
            .onChange(of: model.openFolderID) { newValue in
                // При закрытии папки возвращаем фокус полю поиска — иначе первый
                // клик по фону уходит на переактивацию окна (нужно было два клика).
                if newValue == nil, !searchFocused {
                    DispatchQueue.main.async { searchFocused = true }
                }
            }
            .alert("Не удалось выполнить действие", isPresented: Binding(
                get: { model.operationError != nil },
                set: { if !$0 { model.operationError = nil } })) {
                Button("OK") { model.operationError = nil }
            } message: {
                Text(model.operationError ?? "")
            }
            .confirmationDialog(
                model.pendingDelete.map { "Удалить «\($0.name)»?" } ?? "",
                isPresented: Binding(get: { model.pendingDelete != nil },
                                     set: { if !$0 { model.pendingDelete = nil } }),
                presenting: model.pendingDelete
            ) { app in
                Button("Переместить в Корзину", role: .destructive) {
                    Task {
                        // Полноэкранное окно не должно закрывать системный
                        // запрос разрешения на удаление приложения.
                        NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
                        if !(await model.deleteApp(app)) {
                            NotificationCenter.default.post(name: .launchpadShouldShow, object: nil)
                        }
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: { app in
                Text("«\(app.name)» будет перемещено в Корзину.")
            }
        }
    }

    // MARK: - Поле поиска

    private var searchField: some View {
        SearchField(text: $model.searchText, focused: $searchFocused)
    }

    // MARK: - Пейджер

    private func pager(_ metrics: GridMetrics) -> some View {
        let visibleIndex = max(0, min(visiblePage, model.pages.count - 1))
        // Соседние страницы уже смонтированы до начала анимации. Их offset
        // меняется вместе с текущей страницей; пересоздания иконок на свайпе нет.
        var mountedIndexes = Set([visibleIndex - 1, visibleIndex, visibleIndex + 1]
            .filter { model.pages.indices.contains($0) })
        if let previousPage, model.pages.indices.contains(previousPage) { mountedIndexes.insert(previousPage) }
        if let source = drag?.originPage, drag?.fromSearch != true,
           model.pages.indices.contains(source) { mountedIndexes.insert(source) }

        return ZStack {
            ForEach(mountedIndexes.sorted(), id: \.self) { index in
                PageView(page: model.pages[index],
                         pageIndex: index,
                         metrics: metrics,
                         drag: drag,
                         reduceEffects: scrollState.isInteracting,
                         model: model,
                         onBeginDrag: { item, value in beginDrag(item, value, metrics) },
                         onDragChange: { value in updateDrag(value, metrics) },
                         onDragEnd: { _ in endDrag() })
                    .frame(width: metrics.size.width, height: metrics.size.height)
                    .modifier(PageScrollOffsetModifier(
                        position: scrollState.position,
                        baseOffset: CGFloat(index - visiblePage) * metrics.size.width))
                    .allowsHitTesting(index == visibleIndex)
                    .accessibilityHidden(index != visibleIndex)
                    .id(model.pages[index].id)
                    .transition(.identity)
            }
        }
        .frame(width: metrics.size.width)
        .clipped()
        .onAppear { visiblePage = model.currentPage }
        .onChange(of: model.currentPage) { newPage in
            let target = max(0, min(newPage, model.pages.count - 1))
            guard target != visiblePage else { return }
            previousPage = visiblePage
            pageTransitionGeneration += 1
            let generation = pageTransitionGeneration
            let suppressAnimation = model.suppressNextPageAnimation
            model.suppressNextPageAnimation = false
            let animation: Animation? = !suppressAnimation && !reduceMotion
                && abs(target - visiblePage) == 1
                ? .easeOut(duration: 0.18) : nil
            withAnimation(animation) { visiblePage = target }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                guard generation == pageTransitionGeneration else { return }
                previousPage = nil
            }
        }
        .onChange(of: model.pages.count) { _ in
            if !model.pages.indices.contains(visiblePage) { visiblePage = model.currentPage }
        }
        // Свайп-жеста здесь НЕТ намеренно: он конкурировал с перетаскиванием иконок.
        // Листание страниц — двухпальцевым скроллом (это scroll, а не drag),
        // стрелками ←/→ и точками внизу.
    }

    /// После перехода прогреваем ограниченный кеш иконок соседних страниц.
    private func prefetchNeighborIcons(around pageIndex: Int) {
        let indexes = [pageIndex - 1, pageIndex + 1]
            .filter { model.pages.indices.contains($0) }
        let paths = indexes.flatMap { index in
            model.pages[index].items.flatMap { item -> [String] in
                switch item {
                case .app(let app):
                    return [app.path]
                case .folder(let folder):
                    return folder.apps.prefix(9).map(\.path)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard model.currentPage == pageIndex else { return }
            IconCache.shared.prefetch(paths: paths)
        }
    }

    /// Подсказка-стрелка у края, видна при перетаскивании.
    @ViewBuilder
    private func edgeHint(_ metrics: GridMetrics, direction: Int) -> some View {
        if drag != nil {
            HStack {
                if direction > 0 { Spacer() }
                Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 22)
                if direction < 0 { Spacer() }
            }
            .allowsHitTesting(false)
        }
    }

    private func draggedIcon(_ item: LaunchpadItem, metrics: GridMetrics) -> some View {
        Group {
            switch item {
            case .app(let app):       AppIconView(app: app, iconSize: metrics.iconSize)
            case .folder(let folder): FolderIconView(folder: folder, iconSize: metrics.iconSize)
            }
        }
        .frame(width: metrics.cellW, height: metrics.cellH)
        .scaleEffect(1.15)
        .opacity(0.95)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }

    // MARK: - Точки страниц

    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(model.pages.indices, id: \.self) { index in
                Button { model.goToPage(index) } label: {
                    Circle()
                        .fill(index == model.currentPage ? Color.white
                              : Color.white.opacity(contrast == .increased ? 0.68 : 0.35))
                        .frame(width: 8, height: 8)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Страница \(index + 1)"))
                .accessibilityValue(index == model.currentPage ? "Выбрано" : "")
                .accessibilityIdentifier("page.\(index)")
            }
        }
        .frame(height: 20)
    }

    // MARK: - Логика перетаскивания

    private func beginDrag(_ item: LaunchpadItem, _ value: DragGesture.Value, _ metrics: GridMetrics) {
        model.layoutInteractionActive = true
        let origin = model.pageIndex(of: item.id) ?? model.currentPage
        var state = DragState(itemID: item.id,
                              originPage: origin,
                              location: value.location,
                              insertionIndex: 0,
                              folderTargetID: nil)
        // Сначала полностью вычисляем слот, затем публикуем DragState один раз.
        // Промежуточный insertionIndex=0 заставлял оригинал анимированно
        // улетать в верхний левый слот перед исчезновением.
        updateDrag(value, metrics, initial: &state)
    }

    /// Начало драга из результатов поиска: приложение уже есть в раскладке,
    /// перемещаем его на выбранную страницу.
    private func beginSearchDrag(_ app: AppEntry, _ value: DragGesture.Value, _ metrics: GridMetrics) {
        model.layoutInteractionActive = true
        var state = DragState(itemID: "app:" + app.id,
                              originPage: model.currentPage,
                              location: value.location,
                              insertionIndex: 0,
                              folderTargetID: nil,
                              fromSearch: true,
                              searchApp: app)
        updateDrag(value, metrics, initial: &state)
    }

    private func updateDrag(_ value: DragGesture.Value, _ metrics: GridMetrics) {
        guard var d = drag else { return }
        updateDrag(value, metrics, initial: &d)
    }

    private func updateDrag(_ value: DragGesture.Value, _ metrics: GridMetrics, initial d: inout DragState) {
        d.location = value.location
        handleEdge(value.location, metrics)

        let others = model.pages[model.currentPage].items.filter { $0.id != d.itemID }

        // Ячейка сетки под курсором. Сетка привязана к экрану и не «уезжает»,
        // поэтому решение стабильно (иконки анимируются внутри ячеек).
        let p = value.location
        let col = min(max(Int((p.x - metrics.sidePad) / metrics.cellW), 0), metrics.columns - 1)
        let row = min(max(Int((p.y - metrics.topInset) / metrics.cellH), 0), metrics.rows - 1)
        let cellIndex = row * metrics.columns + col
        // Доля по горизонтали внутри ячейки: центральная треть → папка, края → перестановка.
        let cellLeft = metrics.sidePad + CGFloat(col) * metrics.cellW
        let fx = (p.x - cellLeft) / metrics.cellW

        if cellIndex < others.count {
            let target = others[cellIndex]
            if fx > 0.30, fx < 0.70, canCombine(d.itemID, target.id) {
                // Центр ячейки → папка: соседи замирают, цель подсвечивается сразу.
                d.folderTargetID = target.id
                d.reflow = false
                d.insertionIndex = cellIndex
            } else {
                // Край ячейки → перестановка: вставка до/после, соседи расступаются.
                d.folderTargetID = nil
                d.reflow = true
                d.insertionIndex = fx <= 0.5 ? cellIndex : cellIndex + 1
            }
        } else {
            // Пустая зона за последней иконкой → в конец.
            d.folderTargetID = nil
            d.reflow = true
            d.insertionIndex = others.count
        }

        drag = d
    }

    private func canCombine(_ dragID: String, _ targetID: String) -> Bool {
        if targetID.hasPrefix("folder:") { return true }
        return dragID.hasPrefix("app:") && targetID.hasPrefix("app:")
    }

    private func handleEdge(_ point: CGPoint, _ metrics: GridMetrics) {
        let zone = metrics.sidePad * 0.55
        if point.x < zone {
            model.beginEdgeHover(-1)
        } else if point.x > metrics.size.width - zone {
            model.beginEdgeHover(1)
        } else {
            model.cancelEdgeHover()
        }
    }

    private func endDrag() {
        model.cancelEdgeHover()
        guard let d = drag else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if d.fromSearch, let app = d.searchApp {
                // Драг из поиска: кладём приложение на текущую страницу и выходим из поиска.
                model.relocateApp(app, toPage: model.currentPage, at: d.insertionIndex)
                model.searchText = ""
            } else if let target = d.folderTargetID {
                model.combine(d.itemID, into: target)
            } else {
                model.placeItem(d.itemID, onPage: model.currentPage, at: d.insertionIndex)
            }
        }
        drag = nil
        model.pruneEmptyPages()
        model.layoutInteractionActive = false
    }
}

/// Изолирует высокочастотное движение слоя от пересчёта всего корневого View.
private struct PageScrollOffsetModifier: ViewModifier {
    @ObservedObject var position: PageScrollPosition
    let baseOffset: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: baseOffset + position.value)
    }
}

/// Сетка результатов поиска. Иконки можно перетаскивать на сетку для сортировки.
struct SearchResultsView: View {
    @ObservedObject var model: LaunchpadModel
    let onBeginDrag: (AppEntry, DragGesture.Value) -> Void
    let onDragChange: (DragGesture.Value) -> Void
    let onDragEnd: (DragGesture.Value) -> Void

    @State private var draggingAppID: String?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 24), count: model.columns)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(model.searchResults) { app in
                    AppIconView(app: app)
                        .frame(width: 120, height: 128)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(.white.opacity(model.selectedSearchID == app.id ? 0.18 : 0)))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(.white.opacity(model.selectedSearchID == app.id ? 0.7 : 0), lineWidth: 2))
                        .id(app.id)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
                                .onChanged { value in
                                    guard hypot(value.translation.width,
                                                value.translation.height) >= 10 else { return }
                                    if draggingAppID == nil {
                                        draggingAppID = app.id
                                        onBeginDrag(app, value)
                                    } else if draggingAppID == app.id {
                                        onDragChange(value)
                                    }
                                }
                                .onEnded { value in
                                    if draggingAppID == app.id {
                                        draggingAppID = nil
                                        onDragEnd(value)
                                    } else {
                                        AppLauncher.launch(app)
                                    }
                                }
                        )
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(app.name))
                        .accessibilityIdentifier("search." + app.id)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityValue(model.selectedSearchID == app.id ? "Выбрано" : "")
                        .accessibilityAction { AppLauncher.launch(app) }
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 30)
            .frame(maxWidth: .infinity, minHeight: 700, alignment: .top)
        }
        .overlay(alignment: .top) {
            if model.searchResults.isEmpty {
                VStack(spacing: 8) {
                    Text("Ничего не найдено").font(.title2)
                    Text("Попробуйте другое название или сокращение.").foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .padding(.top, 60)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: model.selectedSearchID) { id in
            if let id { proxy.scrollTo(id) }
        }
        .contentShape(Rectangle())
        // Клик по пустому месту результатов сбрасывает поиск (иконки перехватывают свой tap).
        .onTapGesture { model.searchText = "" }
        }
    }
}
