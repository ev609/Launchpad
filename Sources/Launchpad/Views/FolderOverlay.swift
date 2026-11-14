import SwiftUI

/// Оверлей открытой папки: матовая панель (вибрантность, размывает фон
/// позади — как в оригинале) + сетка с перестановкой и извлечением.
struct FolderOverlay: View {
    let folderID: String
    @ObservedObject var model: LaunchpadModel

    @State private var name: String = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    // Перетаскивание приложения внутри папки / наружу.
    @State private var dragAppID: String?
    @State private var dragTranslation: CGSize = .zero

    private var folder: Folder? { model.folder(withID: folderID) }

    var body: some View {
        if let folder {
            GeometryReader { geometry in
            let availableWidth = max(150, geometry.size.width - 120)
            let columns = min(5, max(1, Int(availableWidth / 150)))
            let cellWidth = min(150, availableWidth / CGFloat(columns))
            let cellHeight = min(118, max(92, cellWidth * 0.79))
            ZStack {
                // Затемнение фона; клик закрывает папку.
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(spacing: 18) {
                    TextField("Имя папки", text: $name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .focused($nameFocused)
                        .onChange(of: nameFocused) { focused in
                            model.folderNameEditing = focused
                        }
                        .frame(maxWidth: 320)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            // Подсказка, что имя можно редактировать.
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(nameFocused ? 0.18 : 0.06))
                        )
                        .onSubmit { commitName() }
                        .help("Нажмите, чтобы переименовать папку")

                    ScrollView(.vertical) {
                        grid(folder, columns: columns,
                             cellWidth: cellWidth, cellHeight: cellHeight)
                    }
                    .frame(width: CGFloat(max(1, min(folder.apps.count, columns))) * cellWidth,
                           height: min(CGFloat((folder.apps.count + columns - 1) / columns) * cellHeight,
                                       max(cellHeight, geometry.size.height - 250)))
                }
                .padding(36)
                .background(
                    // Матовое стекло: размывает сетку позади панели (.withinWindow).
                    ZStack {
                        if reduceTransparency {
                            Color(red: 0.12, green: 0.13, blue: 0.16)
                        } else {
                            VisualEffectView(material: .hudWindow, blending: .withinWindow)
                            Color.black.opacity(contrast == .increased ? 0.34 : 0.18)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(.white.opacity(contrast == .increased ? 0.58 : 0.18),
                                    lineWidth: contrast == .increased ? 2 : 1)
                    )
                )
                .padding(60)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
            }
            .onAppear {
                name = folder.name
                model.folderKeyboardColumns = columns
            }
            .onChange(of: columns) { model.folderKeyboardColumns = $0 }
            .onDisappear {
                commitName()
                model.folderNameEditing = false
                model.layoutInteractionActive = false
            }
            }
        }
    }

    // MARK: - Сетка папки с расступанием

    @ViewBuilder
    private func grid(_ folder: Folder, columns maximumColumns: Int,
                      cellWidth: CGFloat, cellHeight: CGFloat) -> some View {
        let apps = folder.apps
        let n = apps.count
        let columns = max(1, min(n, maximumColumns))
        let rows = (n + columns - 1) / columns
        let w = CGFloat(columns) * cellWidth
        let h = CGFloat(rows) * cellHeight

        let draggedIndex = apps.firstIndex { $0.id == dragAppID }
        let target = targetInOthers(draggedIndex: draggedIndex, count: n, columns: columns,
                                    cellWidth: cellWidth, cellHeight: cellHeight)

        ZStack(alignment: .topLeading) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                let dragging = dragAppID == app.id
                let pos = position(index: index, dragging: dragging,
                                   draggedIndex: draggedIndex, target: target, columns: columns,
                                   cellWidth: cellWidth, cellHeight: cellHeight)
                AppIconView(app: app, iconSize: min(88, max(58, cellWidth * 0.58)))
                    .frame(width: cellWidth, height: cellHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.white.opacity(model.selectedFolderAppID == app.id
                                                 ? (contrast == .increased ? 0.20 : 0.10) : 0))
                            .padding(.horizontal, 7)
                            .padding(.bottom, 18)
                    )
                    .scaleEffect(dragging ? 1.12 : 1.0)
                    .position(pos)
                    .zIndex(dragging ? 1 : 0)
                    .animation(dragging || reduceMotion ? .none : .spring(response: 0.28, dampingFraction: 0.74),
                               value: pos)
                    .contextMenu {
                        Button("Извлечь из папки") { model.extractApp(app.id, fromFolder: folderID) }
                        Button("Скрыть из Launchpad") { model.hideApp(app) }
                        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard hypot(value.translation.width,
                                            value.translation.height) >= 10 else { return }
                                model.layoutInteractionActive = true
                                dragAppID = app.id
                                dragTranslation = value.translation
                            }
                            .onEnded { value in
                                if dragAppID == app.id {
                                    endDrag(app: app, index: index, columns: columns,
                                            gridSize: CGSize(width: w, height: h),
                                            target: target, value: value,
                                            cellWidth: cellWidth, cellHeight: cellHeight)
                                } else {
                                    model.selectedFolderAppID = app.id
                                    launch(app)
                                }
                            }
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(app.name))
                    .accessibilityValue(model.selectedFolderAppID == app.id ? Text("Выбрано") : Text(""))
                    .accessibilityHint(Text("Нажмите Return, чтобы открыть приложение"))
                    .accessibilityAddTraits(model.selectedFolderAppID == app.id
                                            ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { launch(app) }
                    .accessibilityActions {
                        Button("Переместить влево") {
                            moveAccessibility(app, horizontal: -1, columns: columns)
                        }
                        Button("Переместить вправо") {
                            moveAccessibility(app, horizontal: 1, columns: columns)
                        }
                        Button("Переместить вверх") {
                            moveAccessibility(app, vertical: -1, columns: columns)
                        }
                        Button("Переместить вниз") {
                            moveAccessibility(app, vertical: 1, columns: columns)
                        }
                        Button("Извлечь из папки") {
                            model.selectedFolderAppID = app.id
                            model.extractSelectedFolderApp()
                        }
                        Button("Показать в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                        }
                        Button("Скрыть из Launchpad") { model.hideApp(app) }
                    }
            }
        }
        .frame(width: w, height: h)
    }

    /// Позиция вставки перетаскиваемого элемента в списке без него (others-space).
    private func targetInOthers(draggedIndex: Int?, count: Int, columns: Int,
                                cellWidth: CGFloat, cellHeight: CGFloat) -> Int? {
        guard let di = draggedIndex else { return nil }
        let base = center(di, columns: columns, cellWidth: cellWidth, cellHeight: cellHeight)
        let cur = CGPoint(x: base.x + dragTranslation.width, y: base.y + dragTranslation.height)
        let rows = (count + columns - 1) / columns
        let col = min(max(Int(cur.x / cellWidth), 0), columns - 1)
        let row = min(max(Int(cur.y / cellHeight), 0), max(rows - 1, 0))
        return min(max(row * columns + col, 0), count - 1)
    }

    private func position(index: Int, dragging: Bool, draggedIndex: Int?,
                          target: Int?, columns: Int,
                          cellWidth: CGFloat, cellHeight: CGFloat) -> CGPoint {
        if dragging {
            let base = center(index, columns: columns,
                              cellWidth: cellWidth, cellHeight: cellHeight)
            return CGPoint(x: base.x + dragTranslation.width, y: base.y + dragTranslation.height)
        }
        guard let di = draggedIndex, let t = target else {
            return center(index, columns: columns,
                          cellWidth: cellWidth, cellHeight: cellHeight)
        }
        // Индекс в списке без перетаскиваемого; соседи расступаются вокруг «дыры».
        let p = index < di ? index : index - 1
        let slot = p < t ? p : p + 1
        return center(slot, columns: columns, cellWidth: cellWidth, cellHeight: cellHeight)
    }

    private func center(_ index: Int, columns: Int,
                        cellWidth: CGFloat, cellHeight: CGFloat) -> CGPoint {
        let col = index % columns
        let row = index / columns
        return CGPoint(x: CGFloat(col) * cellWidth + cellWidth / 2,
                       y: CGFloat(row) * cellHeight + cellHeight / 2)
    }

    private func endDrag(app: AppEntry, index: Int, columns: Int,
                         gridSize: CGSize, target: Int?, value: DragGesture.Value,
                         cellWidth: CGFloat, cellHeight: CGFloat) {
        defer { dragAppID = nil; dragTranslation = .zero; model.layoutInteractionActive = false }
        let base = center(index, columns: columns,
                          cellWidth: cellWidth, cellHeight: cellHeight)
        let final = CGPoint(x: base.x + value.translation.width,
                            y: base.y + value.translation.height)

        // Вытащили заметно за пределы сетки → извлекаем из папки.
        let margin: CGFloat = 75
        if final.x < -margin || final.x > gridSize.width + margin ||
            final.y < -margin || final.y > gridSize.height + margin {
            model.extractApp(app.id, fromFolder: folderID)
            return
        }
        if let t = target {
            model.moveInFolder(folderID, appID: app.id, toIndex: t)
        }
    }

    private func launch(_ app: AppEntry) {
        AppLauncher.launch(app)

    }

    private func moveAccessibility(_ app: AppEntry, horizontal: Int = 0,
                                   vertical: Int = 0, columns: Int) {
        model.selectedFolderAppID = app.id
        model.moveSelectedFolderApp(horizontal: horizontal, vertical: vertical, columns: columns)
    }

    private func commitName() {
        model.renameFolder(folderID, to: name)
    }

    private func close() {
        commitName()
        // Без анимации: анимированно исчезающий оверлей ещё ловит клики,
        // из-за чего первый клик по сетке был «мёртвым» (нужно было два клика).
        model.closeFolder()
    }
}
