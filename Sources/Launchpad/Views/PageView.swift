import SwiftUI

/// Геометрия сетки: размеры ячеек и перевод «точка ↔ слот».
struct GridMetrics {
    let size: CGSize
    let columns: Int
    let rows: Int
    var safeTop: CGFloat = 0        // высота выреза («острова») сверху

    let bottomInset: CGFloat = 72  // место под точки страниц
    let sidePad: CGFloat = 80

    // Верхний отступ = место под поле поиска, с учётом выреза камеры.
    var topInset: CGFloat { max(96, safeTop + 64) }

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
    var reflow: Bool = true     // расступаться ли соседям (false при наведении на иконку)
    var fromSearch: Bool = false // драг начат из результатов поиска
    var searchApp: AppEntry?     // перетаскиваемое приложение (для драга из поиска)
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

    @State private var wiggle = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard drag == nil, model.openFolderID == nil else { return }
                    if model.editing {
                        model.editing = false          // выход из режима покачивания
                    } else {
                        NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
                    }
                }
                .onChange(of: model.showDeleteBadges) { on in
                    if on { wiggle = true } else { wiggle = false }
                }
            ForEach(Array(layout.enumerated()), id: \.element.item.id) { _, placed in
                cell(placed.item)
                    .frame(width: metrics.cellW, height: metrics.cellH)
                    // ВАЖНО: перетаскиваемую ячейку НЕ удаляем, а прячем (opacity 0),
                    // иначе SwiftUI уничтожит view вместе с активным жестом и драг «зависнет».
                    .opacity(placed.dragged ? 0 : 1)
                    .position(metrics.center(placed.slot))
                    .animation(.spring(response: 0.32, dampingFraction: 0.75), value: placed.slot)
            }
        }
    }

    // MARK: - Раскладка со «дырой»

    private struct Placed { let item: LaunchpadItem; let slot: Int; let dragged: Bool }

    /// Вычисляет, в каком слоте показать каждый элемент с учётом перетаскивания.
    /// Перетаскиваемый элемент остаётся смонтированным (невидимым) — чтобы жест
    /// не оборвался; остальные расступаются вокруг «дыры» на позиции вставки.
    private var layout: [Placed] {
        let items = page.items
        guard let d = drag else {
            return items.enumerated().map { Placed(item: $0.element, slot: $0.offset, dragged: false) }
        }

        let isTargetPage = pageIndex == model.currentPage
        // Дыра под вставку только когда соседи расступаются (не при наведении на иконку).
        let hole = (isTargetPage && d.reflow) ? d.insertionIndex : -1

        var placed: [Placed] = []
        var slot = 0
        for item in items {
            if item.id == d.itemID {
                // Паркуем невидимой на позиции «дыры» — view остаётся живой.
                placed.append(Placed(item: item, slot: max(0, hole), dragged: true))
                continue
            }
            if slot == hole { slot += 1 } // пропускаем слот-дыру
            placed.append(Placed(item: item, slot: slot, dragged: false))
            slot += 1
        }
        return placed
    }

    // MARK: - Ячейка

    @ViewBuilder
    private func cell(_ item: LaunchpadItem) -> some View {
        let isFolderTarget = drag?.folderTargetID == item.id
        let wiggling = model.showDeleteBadges && drag == nil
        content(item)
            .scaleEffect(isFolderTarget ? 1.22 : 1.0)
            .background(
                // Явный «поднос» под целью — сигнал, что образуется папка.
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white.opacity(isFolderTarget ? 0.28 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.white.opacity(isFolderTarget ? 0.55 : 0), lineWidth: 2)
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 24)
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFolderTarget)
            // Покачивание в режиме редактирования (как в оригинале).
            .rotationEffect(.degrees(wiggling ? (wiggle ? 1.6 : -1.6) : 0))
            .animation(wiggling ? .easeInOut(duration: wiggleDuration(item)).repeatForever(autoreverses: true)
                                : .easeOut(duration: 0.12),
                       value: wiggle)
            .contentShape(Rectangle())
            .onTapGesture { activate(item) }
            // Долгое нажатие → режим редактирования. simultaneousGesture, чтобы
            // работать параллельно с драгом (иначе highPriority-драг его глушит).
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in if case .app = item { model.editing = true } }
            )
            .highPriorityGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("root"))
                    .onChanged { value in
                        if drag == nil {
                            onBeginDrag(item, value)
                        } else {
                            onDragChange(value)
                        }
                    }
                    .onEnded { value in onDragEnd(value) }
            )
            .contextMenu {
                if case .app(let app) = item, model.canDelete(app) {
                    Button("Удалить «\(app.name)»", role: .destructive) {
                        model.pendingDelete = app
                    }
                }
            }
    }

    /// Небольшой разброс периода покачивания, чтобы иконки не качались синхронно.
    private func wiggleDuration(_ item: LaunchpadItem) -> Double {
        0.12 + Double(abs(item.id.hashValue) % 5) * 0.012
    }

    @ViewBuilder
    private func content(_ item: LaunchpadItem) -> some View {
        switch item {
        case .app(let app):
            AppIconView(app: app,
                        showDelete: drag == nil && model.showDeleteBadges && model.canDelete(app),
                        onDelete: { model.pendingDelete = app })
        case .folder(let folder):
            FolderIconView(folder: folder)
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
