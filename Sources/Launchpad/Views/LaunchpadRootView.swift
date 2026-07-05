import SwiftUI

/// Корневой экран Launchpad с жестовым перетаскиванием иконок.
struct LaunchpadRootView: View {
    @ObservedObject var model: LaunchpadModel
    @FocusState private var searchFocused: Bool

    // Активное перетаскивание.
    @State private var drag: DragState?
    // Кандидат в папку и момент начала наведения (для задержки).

    var body: some View {
        GeometryReader { geo in
            let safeTop = NSScreen.main?.safeAreaInsets.top ?? 0
            let metrics = GridMetrics(size: geo.size, columns: model.columns,
                                      rows: model.rows, safeTop: safeTop)

            ZStack {
                // Фон: размытие рабочего стола + затемнение.
                VisualEffectView(material: .fullScreenUI, blending: .behindWindow)
                    .ignoresSafeArea()
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if model.openFolderID != nil { return }
                        if model.isSearching {
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
                    }
                }

                // Оверлей открытой папки.
                if let id = model.openFolderID {
                    FolderOverlay(folderID: id, model: model)
                        .zIndex(10)
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
            .onAppear { DispatchQueue.main.async { searchFocused = true } }
            .onChange(of: model.openFolderID) { newValue in
                // При закрытии папки возвращаем фокус полю поиска — иначе первый
                // клик по фону уходит на переактивацию окна (нужно было два клика).
                if newValue == nil {
                    DispatchQueue.main.async { searchFocused = true }
                }
            }
        }
    }

    // MARK: - Поле поиска

    private var searchField: some View {
        SearchField(text: $model.searchText, focused: $searchFocused)
    }

    // MARK: - Пейджер

    private func pager(_ metrics: GridMetrics) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                PageView(page: page,
                         pageIndex: index,
                         metrics: metrics,
                         drag: drag,
                         model: model,
                         onBeginDrag: { item, value in beginDrag(item, value, metrics) },
                         onDragChange: { value in updateDrag(value, metrics) },
                         onDragEnd: { _ in endDrag() })
                    .frame(width: metrics.size.width)
            }
        }
        .frame(width: metrics.size.width, alignment: .leading)
        .offset(x: -CGFloat(model.currentPage) * metrics.size.width)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.currentPage)
        // Свайп-жеста здесь НЕТ намеренно: он конкурировал с перетаскиванием иконок.
        // Листание страниц — двухпальцевым скроллом (это scroll, а не drag),
        // стрелками ←/→ и точками внизу.
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
            case .app(let app):       AppIconView(app: app)
            case .folder(let folder): FolderIconView(folder: folder)
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
                Circle()
                    .fill(index == model.currentPage ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .onTapGesture { withAnimation { model.goToPage(index) } }
            }
        }
        .frame(height: 20)
    }

    // MARK: - Логика перетаскивания

    private func beginDrag(_ item: LaunchpadItem, _ value: DragGesture.Value, _ metrics: GridMetrics) {
        let origin = model.pageIndex(of: item.id) ?? model.currentPage
        var state = DragState(itemID: item.id,
                              originPage: origin,
                              location: value.location,
                              insertionIndex: 0,
                              folderTargetID: nil)
        drag = state
        updateDrag(value, metrics, initial: &state)
    }

    /// Начало драга из результатов поиска: приложение уже есть в раскладке,
    /// перемещаем его на выбранную страницу.
    private func beginSearchDrag(_ app: AppEntry, _ value: DragGesture.Value, _ metrics: GridMetrics) {
        var state = DragState(itemID: "app:" + app.id,
                              originPage: model.currentPage,
                              location: value.location,
                              insertionIndex: 0,
                              folderTargetID: nil,
                              fromSearch: true,
                              searchApp: app)
        drag = state
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
        ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(model.searchResults) { app in
                    AppIconView(app: app)
                        .frame(width: 120, height: 128)
                        .onTapGesture {
                            AppLauncher.launch(app)
                            NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 8, coordinateSpace: .named("root"))
                                .onChanged { value in
                                    if draggingAppID == nil {
                                        draggingAppID = app.id
                                        onBeginDrag(app, value)
                                    } else {
                                        onDragChange(value)
                                    }
                                }
                                .onEnded { value in
                                    draggingAppID = nil
                                    onDragEnd(value)
                                }
                        )
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 30)
            .frame(maxWidth: .infinity, minHeight: 700, alignment: .top)
        }
        .contentShape(Rectangle())
        // Клик по пустому месту результатов сбрасывает поиск (иконки перехватывают свой tap).
        .onTapGesture { model.searchText = "" }
    }
}
