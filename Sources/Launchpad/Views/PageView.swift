import SwiftUI

/// Геометрия сетки: размеры ячеек и перевод «точка ↔ слот».
struct GridMetrics {
    let size: CGSize
    let columns: Int
    let rows: Int

    let topInset: CGFloat = 96     // место под поле поиска
    let bottomInset: CGFloat = 72  // место под точки страниц
    let sidePad: CGFloat = 80

    var gridHeight: CGFloat { max(1, size.height - topInset - bottomInset) }
    var cellW: CGFloat { max(1, (size.width - 2 * sidePad) / CGFloat(columns)) }
    var cellH: CGFloat { max(1, gridHeight / CGFloat(rows)) }

    /// Центр слота с индексом `slot`.
    func center(_ slot: Int) -> CGPoint {
        let r = slot / columns
        let c = slot % columns
        let x = sidePad + (CGFloat(c) + 0.5) * cellW
        let y = topInset + (CGFloat(r) + 0.5) * cellH
        return CGPoint(x: x, y: y)
    }

    /// Индекс слота (позиция вставки) под точкой `p`, ограниченный `[0, count]`.
    func slot(at p: CGPoint, count: Int) -> Int {
        let c = min(max(Int(((p.x - sidePad) / cellW).rounded(.down)), 0), columns - 1)
        let r = min(max(Int(((p.y - topInset) / cellH).rounded(.down)), 0), rows - 1)
        return min(max(r * columns + c, 0), count)
    }
}

/// Состояние активного перетаскивания.
struct DragState {
    var itemID: String
    var originPage: Int
    var location: CGPoint       // в координатах экрана ("root")
    var insertionIndex: Int
    var folderTargetID: String? // если задержались над иконкой — цель для папки
}

/// Одна страница сетки. Иконки расставлены вручную по слотам, чтобы поддержать
/// расступание и «дыру» под перетаскиваемый элемент.
struct PageView: View {
    let page: Page
    let pageIndex: Int
    let metrics: GridMetrics
    let drag: DragState?
    @ObservedObject var model: LaunchpadModel

    let onBeginDrag: (LaunchpadItem, DragGesture.Value) -> Void
    let onDragChange: (DragGesture.Value) -> Void
    let onDragEnd: (DragGesture.Value) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    // Клик по пустому месту между иконками закрывает Launchpad.
                    if drag == nil && model.openFolderID == nil {
                        NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
                    }
                }
            ForEach(Array(layout.enumerated()), id: \.element.item.id) { _, placed in
                cell(placed.item)
                    .frame(width: metrics.cellW, height: metrics.cellH)
                    .position(metrics.center(placed.slot))
                    .animation(.spring(response: 0.32, dampingFraction: 0.75), value: placed.slot)
            }
        }
    }

    // MARK: - Раскладка со «дырой»

    private struct Placed { let item: LaunchpadItem; let slot: Int }

    /// Вычисляет, в каком слоте показать каждый элемент с учётом перетаскивания.
    private var layout: [Placed] {
        var items = page.items
        // Перетаскиваемый элемент со своей страницы убираем (он «летит» отдельно).
        if let d = drag, let idx = items.firstIndex(where: { $0.id == d.itemID }) {
            items.remove(at: idx)
        }

        let isTargetPage = drag != nil && pageIndex == model.currentPage
        // При режиме «папка» дыру не делаем — просто подсвечиваем цель.
        let hole = (isTargetPage && drag?.folderTargetID == nil) ? drag?.insertionIndex : nil

        return items.enumerated().map { p, item in
            var slot = p
            if let hole, p >= hole { slot = p + 1 }
            return Placed(item: item, slot: slot)
        }
    }

    // MARK: - Ячейка

    @ViewBuilder
    private func cell(_ item: LaunchpadItem) -> some View {
        let isFolderTarget = drag?.folderTargetID == item.id
        content(item)
            .scaleEffect(isFolderTarget ? 1.18 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(isFolderTarget ? 0.15 : 0))
                    .padding(6)
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFolderTarget)
            .contentShape(Rectangle())
            .onTapGesture { activate(item) }
            .highPriorityGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("root"))
                    .onChanged { value in
                        if drag == nil {
                            onBeginDrag(item, value)
                        } else {
                            onDragChange(value)
                        }
                    }
                    .onEnded { value in onDragEnd(value) }
            )
    }

    @ViewBuilder
    private func content(_ item: LaunchpadItem) -> some View {
        switch item {
        case .app(let app):       AppIconView(app: app)
        case .folder(let folder): FolderIconView(folder: folder)
        }
    }

    private func activate(_ item: LaunchpadItem) {
        switch item {
        case .app(let app):
            AppLauncher.launch(app)
            NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
        case .folder(let folder):
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                model.openFolderID = folder.id
            }
        }
    }
}
