import SwiftUI

/// Оверлей открытой папки: затемнение + сетка приложений с перемещением
/// внутри папки и извлечением наружу. Читает актуальную папку из модели,
/// поэтому изменения (реордер/извлечение) отражаются сразу.
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
                // Клик по затемнению закрывает папку.
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
                        .frame(maxWidth: 300)
                        .onSubmit { commitName() }

                    grid(folder)
                }
                .padding(36)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(.white.opacity(0.12), lineWidth: 1)
                        )
                )
                .padding(60)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            .onAppear { name = folder.name }
        }
    }

    // MARK: - Сетка папки

    @ViewBuilder
    private func grid(_ folder: Folder) -> some View {
        let n = folder.apps.count
        let columns = max(1, min(n, cols))
        let rows = (n + columns - 1) / columns
        let w = CGFloat(columns) * cellW
        let h = CGFloat(rows) * cellH

        ZStack(alignment: .topLeading) {
            ForEach(Array(folder.apps.enumerated()), id: \.element.id) { index, app in
                let base = center(index, columns: columns)
                let dragging = dragAppID == app.id
                AppIconView(app: app)
                    .frame(width: cellW, height: cellH)
                    .scaleEffect(dragging ? 1.12 : 1.0)
                    .position(x: base.x + (dragging ? dragTranslation.width : 0),
                              y: base.y + (dragging ? dragTranslation.height : 0))
                    .zIndex(dragging ? 1 : 0)
                    .onTapGesture { launch(app) }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragAppID = app.id
                                dragTranslation = value.translation
                            }
                            .onEnded { value in
                                endDrag(app: app, index: index, columns: columns,
                                        gridSize: CGSize(width: w, height: h), value: value)
                            }
                    )
            }
        }
        .frame(width: w, height: h)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: folder.apps)
    }

    private func center(_ index: Int, columns: Int) -> CGPoint {
        let col = index % columns
        let row = index / columns
        return CGPoint(x: CGFloat(col) * cellW + cellW / 2,
                       y: CGFloat(row) * cellH + cellH / 2)
    }

    private func endDrag(app: AppEntry, index: Int, columns: Int,
                         gridSize: CGSize, value: DragGesture.Value) {
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

        // Иначе — перестановка внутри папки на ближайший слот.
        let n = model.folder(withID: folderID)?.apps.count ?? 1
        let rows = (n + columns - 1) / columns
        let col = min(max(Int(final.x / cellW), 0), columns - 1)
        let row = min(max(Int(final.y / cellH), 0), max(rows - 1, 0))
        let target = min(max(row * columns + col, 0), n - 1)
        model.moveInFolder(folderID, appID: app.id, toIndex: target)
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            model.openFolderID = nil
        }
    }
}
