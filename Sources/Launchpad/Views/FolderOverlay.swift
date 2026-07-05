import SwiftUI

/// Оверлей открытой папки: матовая панель (вибрантность, размывает фон
/// позади — как в оригинале) + сетка с перестановкой и извлечением.
struct FolderOverlay: View {
    let folderID: String
    @ObservedObject var model: LaunchpadModel

    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    // Перетаскивание приложения внутри папки / наружу.
    @State private var dragAppID: String?
    @State private var dragTranslation: CGSize = .zero

    private let cols = 5
    private let cellW: CGFloat = 150
    private let cellH: CGFloat = 118

    private var folder: Folder? { model.folder(withID: folderID) }

    var body: some View {
        if let folder {
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

                    grid(folder)
                }
                .padding(36)
                .background(
                    // Матовое стекло: размывает сетку позади панели (.withinWindow).
                    ZStack {
                        VisualEffectView(material: .hudWindow, blending: .withinWindow)
                        Color.black.opacity(0.18)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )
                )
                .padding(60)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
            .onAppear { name = folder.name }
        }
    }

    // MARK: - Сетка папки с расступанием

    @ViewBuilder
    private func grid(_ folder: Folder) -> some View {
        let apps = folder.apps
        let n = apps.count
        let columns = max(1, min(n, cols))
        let rows = (n + columns - 1) / columns
        let w = CGFloat(columns) * cellW
        let h = CGFloat(rows) * cellH

        let draggedIndex = apps.firstIndex { $0.id == dragAppID }
        let target = targetInOthers(draggedIndex: draggedIndex, count: n, columns: columns)

        ZStack(alignment: .topLeading) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                let dragging = dragAppID == app.id
                let pos = position(index: index, dragging: dragging,
                                   draggedIndex: draggedIndex, target: target, columns: columns)
                AppIconView(app: app)
                    .frame(width: cellW, height: cellH)
                    .scaleEffect(dragging ? 1.12 : 1.0)
                    .position(pos)
                    .zIndex(dragging ? 1 : 0)
                    .animation(dragging ? .none : .spring(response: 0.28, dampingFraction: 0.74),
                               value: pos)
                    .onTapGesture { launch(app) }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragAppID = app.id
                                dragTranslation = value.translation
                            }
                            .onEnded { value in
                                endDrag(app: app, index: index, columns: columns,
                                        gridSize: CGSize(width: w, height: h),
                                        target: target, value: value)
                            }
                    )
            }
        }
        .frame(width: w, height: h)
    }

    /// Позиция вставки перетаскиваемого элемента в списке без него (others-space).
    private func targetInOthers(draggedIndex: Int?, count: Int, columns: Int) -> Int? {
        guard let di = draggedIndex else { return nil }
        let base = center(di, columns: columns)
        let cur = CGPoint(x: base.x + dragTranslation.width, y: base.y + dragTranslation.height)
        let rows = (count + columns - 1) / columns
        let col = min(max(Int(cur.x / cellW), 0), columns - 1)
        let row = min(max(Int(cur.y / cellH), 0), max(rows - 1, 0))
        return min(max(row * columns + col, 0), count - 1)
    }

    private func position(index: Int, dragging: Bool, draggedIndex: Int?,
                          target: Int?, columns: Int) -> CGPoint {
        if dragging {
            let base = center(index, columns: columns)
            return CGPoint(x: base.x + dragTranslation.width, y: base.y + dragTranslation.height)
        }
        guard let di = draggedIndex, let t = target else {
            return center(index, columns: columns)
        }
        // Индекс в списке без перетаскиваемого; соседи расступаются вокруг «дыры».
        let p = index < di ? index : index - 1
        let slot = p < t ? p : p + 1
        return center(slot, columns: columns)
    }

    private func center(_ index: Int, columns: Int) -> CGPoint {
        let col = index % columns
        let row = index / columns
        return CGPoint(x: CGFloat(col) * cellW + cellW / 2,
                       y: CGFloat(row) * cellH + cellH / 2)
    }

    private func endDrag(app: AppEntry, index: Int, columns: Int,
                         gridSize: CGSize, target: Int?, value: DragGesture.Value) {
        defer { dragAppID = nil; dragTranslation = .zero }
        let base = center(index, columns: columns)
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
        NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
    }

    private func commitName() {
        model.renameFolder(folderID, to: name)
    }

    private func close() {
        commitName()
        // Без анимации: анимированно исчезающий оверлей ещё ловит клики,
        // из-за чего первый клик по сетке был «мёртвым» (нужно было два клика).
        model.openFolderID = nil
    }
}
