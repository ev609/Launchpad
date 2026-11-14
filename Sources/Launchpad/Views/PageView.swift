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
    /// Иконки уменьшаются на плотных сетках и небольших экранах, но не
    /// разрастаются сверх привычного размера Launchpad на больших дисплеях.
    var iconSize: CGFloat { min(88, max(32, min(cellW * 0.62, cellH - 24))) }

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
@MainActor
struct PageView: View {
    let page: Page
    let pageIndex: Int
    let metrics: GridMetrics
    let drag: DragState?
    let reduceEffects: Bool
    /// Владельцем наблюдения остаётся LaunchpadRootView. Если каждая из трёх
    /// смонтированных страниц подписана на всю модель отдельно, одно изменение
    /// `@Published` порождает до четырёх независимых проходов SwiftUI.
    let model: LaunchpadModel

    let onBeginDrag: (LaunchpadItem, DragGesture.Value) -> Void
    let onDragChange: (DragGesture.Value) -> Void
    let onDragEnd: (DragGesture.Value) -> Void

    @State private var wiggle = false
    @State private var draggingItemID: String?
    @State private var longPressedItemID: String?
    @Environment(\.colorSchemeContrast) private var contrast

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
                    // Соседи плавно расступаются, но перетаскиваемый оригинал
                    // должен исчезнуть мгновенно. Иначе opacity и position тоже
                    // интерполируются, создавая видимый «клон», летящий к дыре.
                    .animation(placed.dragged || reduceEffects ? nil : .spring(response: 0.32,
                                                                               dampingFraction: 0.75),
                               value: placed.slot)
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
        let isKeyboardSelected = model.selectedGridItemID == item.id && pageIndex == model.currentPage
        let wiggling = model.showDeleteBadges && drag == nil && !reduceEffects
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
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white.opacity(isKeyboardSelected
                                         ? (contrast == .increased ? 0.20 : 0.10) : 0))
                    .padding(.horizontal, 7)
                    .padding(.top, 1)
                    .padding(.bottom, 23)
                    .allowsHitTesting(false)
            )
            .animation(reduceEffects ? nil : .spring(response: 0.3, dampingFraction: 0.7),
                       value: isFolderTarget)
            // Покачивание в режиме редактирования (как в оригинале).
            .rotationEffect(.degrees(wiggling ? (wiggle ? 1.6 : -1.6) : 0))
            .animation(wiggling ? .easeInOut(duration: wiggleDuration(item)).repeatForever(autoreverses: true)
                                : .easeOut(duration: 0.12),
                       value: wiggle)
            .contentShape(Rectangle())
            // Долгое нажатие → режим редактирования. simultaneousGesture, чтобы
            // работать параллельно с драгом (иначе highPriority-драг его глушит).
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        if case .app = item {
                            longPressedItemID = item.id
                            model.editing = true
                        }
                    }
            )
            .highPriorityGesture(
                // Один recognizer различает клик и drag. Отдельные TapGesture и
                // DragGesture конкурировали: движение мыши на несколько точек
                // отменяло tap, но ещё не начинало drag — и клик пропадал.
                DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
                    .onChanged { value in
                        guard hypot(value.translation.width, value.translation.height) >= 10 else {
                            return
                        }
                        if draggingItemID == nil {
                            draggingItemID = item.id
                            longPressedItemID = nil
                            onBeginDrag(item, value)
                        } else if draggingItemID == item.id {
                            onDragChange(value)
                        }
                    }
                    .onEnded { value in
                        if draggingItemID == item.id {
                            draggingItemID = nil
                            onDragEnd(value)
                        } else if longPressedItemID == item.id {
                            longPressedItemID = nil
                        } else {
                            model.selectedGridItemID = item.id
                            activate(item)
                        }
                    }
            )
            .contextMenu {
                if case .app(let app) = item {
                    Button("Скрыть из Launchpad") { model.hideApp(app) }
                    if model.canDelete(app) {
                        Button("Удалить «\(app.name)»", role: .destructive) {
                            model.pendingDelete = app
                        }
                    }
                }
            }
            // Кнопка — сосед слоя с жестами, а не его потомок: иначе
            // highPriorityGesture перехватывает крестик как запуск/drag.
            .overlay(alignment: .top) {
                if case .app(let app) = item,
                   drag == nil && model.showDeleteBadges && model.canDelete(app) {
                    Button { model.pendingDelete = app } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: metrics.iconSize * 0.26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.65))
                            .frame(width: metrics.iconSize * 0.26,
                                   height: metrics.iconSize * 0.26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -metrics.iconSize * 0.46, y: -metrics.iconSize * 0.09)
                    .help("Удалить «\(app.name)»")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(item.displayName))
            .accessibilityValue(isKeyboardSelected ? Text("Выбрано") : Text(""))
            .accessibilityHint(Text(accessibilityHint(for: item)))
            .accessibilityIdentifier("grid." + item.id)
            .accessibilityAddTraits(isKeyboardSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { activate(item) }
            .accessibilityActions {
                Button("Переместить влево") { move(item, horizontal: -1) }
                Button("Переместить вправо") { move(item, horizontal: 1) }
                Button("Переместить вверх") { move(item, vertical: -1) }
                Button("Переместить вниз") { move(item, vertical: 1) }
                Button("Объединить с предыдущим") { combine(item, offset: -1) }
                Button("Объединить со следующим") { combine(item, offset: 1) }
                if case .app(let app) = item {
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                    }
                    Button("Скрыть из Launchpad") { model.hideApp(app) }
                    if model.canDelete(app) {
                        Button("Удалить «\(app.name)»") { model.pendingDelete = app }
                    }
                }
            }
    }

    /// Небольшой разброс периода покачивания, чтобы иконки не качались синхронно.
    private func wiggleDuration(_ item: LaunchpadItem) -> Double {
        0.12 + Double(item.id.hashValue.magnitude % 5) * 0.012
    }

    @ViewBuilder
    private func content(_ item: LaunchpadItem) -> some View {
        switch item {
        case .app(let app):
            AppIconView(app: app,
                        iconSize: metrics.iconSize,
                        reduceEffects: reduceEffects)
        case .folder(let folder):
            FolderIconView(folder: folder, iconSize: metrics.iconSize,
                           reduceEffects: reduceEffects)
        }
    }

    private func activate(_ item: LaunchpadItem) {
        switch item {
        case .app(let app):
            AppLauncher.launch(app)

        case .folder(let folder):
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                model.openFolder(folder.id)
            }
        }
    }

    private func accessibilityHint(for item: LaunchpadItem) -> String {
        switch item {
        case .app:
            return "Нажмите Return, чтобы открыть приложение"
        case .folder:
            return "Нажмите Return, чтобы открыть папку"
        }
    }

    private func move(_ item: LaunchpadItem, horizontal: Int = 0, vertical: Int = 0) {
        model.selectedGridItemID = item.id
        model.moveSelectedGridItem(horizontal: horizontal, vertical: vertical)
    }

    private func combine(_ item: LaunchpadItem, offset: Int) {
        model.selectedGridItemID = item.id
        model.combineSelectedGridItem(withNeighbor: offset)
    }
}
