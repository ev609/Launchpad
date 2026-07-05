import SwiftUI

/// Оверлей открытой папки: затемнённый фон + сетка приложений + редактируемое имя.
struct FolderOverlay: View {
    let folder: Folder
    @ObservedObject var model: LaunchpadModel

    @State private var name: String
    @FocusState private var nameFocused: Bool

    // Извлечение приложения из папки перетаскиванием наружу.
    @State private var dragAppID: String?
    @State private var dragOffset: CGSize = .zero

    init(folder: Folder, model: LaunchpadModel) {
        self.folder = folder
        self.model = model
        _name = State(initialValue: folder.name)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 24), count: min(folder.apps.count, 5))
    }

    var body: some View {
        ZStack {
            // Клик по затемнению закрывает папку.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 20) {
                TextField("Имя папки", text: $name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .focused($nameFocused)
                    .frame(maxWidth: 300)
                    .onSubmit { model.renameFolder(folder.id, to: name) }

                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(folder.apps) { app in
                        AppIconView(app: app)
                            .offset(dragAppID == app.id ? dragOffset : .zero)
                            .zIndex(dragAppID == app.id ? 1 : 0)
                            .onTapGesture {
                                AppLauncher.launch(app)
                                NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
                            }
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        dragAppID = app.id
                                        dragOffset = value.translation
                                    }
                                    .onEnded { value in
                                        let dist = hypot(value.translation.width, value.translation.height)
                                        // Вытащили за пределы папки → извлекаем на страницу.
                                        if dist > 150 {
                                            model.extractApp(app.id, fromFolder: folder.id)
                                        }
                                        dragAppID = nil
                                        dragOffset = .zero
                                    }
                            )
                    }
                }
                .frame(maxWidth: 760)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragOffset)
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .frame(maxWidth: 820)
            .padding(60)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
        .onDisappear { model.renameFolder(folder.id, to: name) }
    }

    private func close() {
        model.renameFolder(folder.id, to: name)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            model.openFolderID = nil
        }
    }
}
