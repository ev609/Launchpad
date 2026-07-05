import SwiftUI

/// Корневой экран Launchpad с жестовым перетаскиванием иконок.
struct LaunchpadRootView: View {
    @ObservedObject var model: LaunchpadModel
    @FocusState private var searchFocused: Bool

    // Активное перетаскивание.
    @State private var drag: DragState?
    // Кандидат в папку и момент начала наведения (для задержки).
    @State private var folderCandidateID: String?
    @State private var folderCandidateSince: UInt64 = 0

    var body: some View {
        GeometryReader { geo in
            let metrics = GridMetrics(size: geo.size, columns: model.columns, rows: model.rows)

            ZStack {
                // Фон: размытие рабочего стола + затемнение.
                VisualEffectView(material: .fullScreenUI, blending: .behindWindow)
                    .ignoresSafeArea()
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if model.openFolderID == nil && !model.isSearching {
                            NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
                        }
                    }

                if model.isSearching {
                    VStack(spacing: 0) {
                        searchField.padding(.top, 28)
                        SearchResultsView(model: model)
                    }
                } else {
                    pager(metrics)
                    VStack(spacing: 0) {
                        searchField.padding(.top, 28)
                        Spacer()
                        pageDots.padding(.bottom, 24)
                    }
                    edgeHint(metrics, direction: -1)
                    edgeHint(metrics, direction: 1)
                }

                // Летящая под курсором иконка.
                if let d = drag, let item = model.item(withID: d.itemID) {
                    draggedIcon(item, metrics: metrics)
                        .position(d.location)
                        .allowsHitTesting(false)
                        .transition(.identity)
                }

                // Оверлей открытой папки.
                if let id = model.openFolderID, let folder = model.folder(withID: id) {
                    FolderOverlay(folder: folder, model: model)
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
        folderCandidateID = nil
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
        d.insertionIndex = metrics.slot(at: value.location, count: others.count)
        d.folderTargetID = folderTarget(at: value.location, others: others, metrics: metrics, dragID: d.itemID)

        drag = d
    }

    /// Ищет иконку под курсором; при достаточной задержке возвращает её как цель для папки.
    private func folderTarget(at point: CGPoint, others: [LaunchpadItem],
                              metrics: GridMetrics, dragID: String) -> String? {
        // Ближайшая иконка (по «естественным» слотам без дыры).
        var nearest: (id: String, dist: CGFloat)?
        for (i, item) in others.enumerated() {
            let c = metrics.center(i)
            let dist = hypot(point.x - c.x, point.y - c.y)
            if nearest == nil || dist < nearest!.dist { nearest = (item.id, dist) }
        }
        let threshold = min(metrics.cellW, metrics.cellH) * 0.32
        guard let near = nearest, near.dist < threshold, canCombine(dragID, near.id) else {
            folderCandidateID = nil
            return nil
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if folderCandidateID != near.id {
            folderCandidateID = near.id
            folderCandidateSince = now
            return nil
        }
        // Задержка ~0.45 c над иконкой → создаём папку.
        let elapsed = Double(now - folderCandidateSince) / 1_000_000_000
        return elapsed > 0.45 ? near.id : nil
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
            if let target = d.folderTargetID {
                model.combine(d.itemID, into: target)
            } else {
                model.placeItem(d.itemID, onPage: model.currentPage, at: d.insertionIndex)
            }
        }
        drag = nil
        folderCandidateID = nil
        model.pruneEmptyPages()
    }
}

/// Сетка результатов поиска.
struct SearchResultsView: View {
    @ObservedObject var model: LaunchpadModel

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
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 30)
        }
    }
}
