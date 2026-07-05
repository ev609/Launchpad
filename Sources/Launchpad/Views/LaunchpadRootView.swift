import SwiftUI

/// Корневой экран Launchpad.
struct LaunchpadRootView: View {
    @ObservedObject var model: LaunchpadModel
    @FocusState private var searchFocused: Bool
    @State private var draggingID: String?
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Фон: размытие рабочего стола + затемнение.
            VisualEffectView(material: .fullScreenUI, blending: .behindWindow)
                .ignoresSafeArea()
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    // Клик по фону (поля вокруг сетки) закрывает Launchpad.
                    if model.openFolderID == nil && !model.isSearching {
                        NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
                    }
                }

            VStack(spacing: 0) {
                SearchField(text: $model.searchText, focused: $searchFocused)
                    .padding(.top, 28)

                if model.isSearching {
                    SearchResultsView(model: model)
                } else {
                    pager
                    pageDots
                        .padding(.bottom, 24)
                }
            }

            // Оверлей открытой папки.
            if let id = model.openFolderID, let folder = model.folder(withID: id) {
                FolderOverlay(folder: folder, model: model)
                    .zIndex(10)
            }
        }
        .gesture(
            // Щипок «внутрь» закрывает Launchpad (как в оригинале).
            MagnificationGesture()
                .onEnded { scale in
                    if scale < 0.85 {
                        NotificationCenter.default.post(name: .launchpadShouldClose, object: nil)
                    }
                }
        )
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    // MARK: - Пейджер

    private var pager: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                    PageView(page: page,
                             pageIndex: index,
                             model: model,
                             draggingID: $draggingID)
                        .frame(width: geo.size.width)
                }
            }
            .offset(x: -CGFloat(model.currentPage) * geo.size.width + dragOffset)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.currentPage)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // Реагируем только на горизонтальные жесты, если ничего не тащим.
                        if draggingID == nil {
                            dragOffset = value.translation.width
                        }
                    }
                    .onEnded { value in
                        guard draggingID == nil else { dragOffset = 0; return }
                        let threshold = geo.size.width * 0.2
                        if value.translation.width < -threshold {
                            model.nextPage()
                        } else if value.translation.width > threshold {
                            model.prevPage()
                        }
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
            )
        }
    }

    // MARK: - Точки страниц

    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(model.pages.indices, id: \.self) { index in
                Circle()
                    .fill(index == model.currentPage ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .onTapGesture {
                        withAnimation { model.goToPage(index) }
                    }
            }
        }
        .frame(height: 20)
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

