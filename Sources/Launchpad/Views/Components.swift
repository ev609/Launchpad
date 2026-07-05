import SwiftUI
import AppKit

/// Размытие содержимого позади окна (как у настоящего Launchpad).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Иконка приложения с подписью.
struct AppIconView: View {
    let app: AppEntry
    var iconSize: CGFloat = 88
    /// Показывать крестик удаления (в режиме редактирования).
    var showDelete: Bool = false
    var onDelete: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: IconCache.shared.icon(for: app.path))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .overlay(alignment: .topLeading) {
                    if showDelete {
                        Button(action: onDelete) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: iconSize * 0.26))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        // Крестик сидит точно на верхнем-левом углу иконки.
                        .offset(x: -iconSize * 0.09, y: -iconSize * 0.09)
                    }
                }
            Text(app.name)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        }
    }
}

/// Иконка папки — мини-превью из иконок вложенных приложений.
struct FolderIconView: View {
    let folder: Folder
    var iconSize: CGFloat = 88

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
                .fill(.white.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )
                .frame(width: iconSize, height: iconSize)
                .overlay(miniGrid.padding(iconSize * 0.13))
            Text(folder.name)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        }
    }

    private var miniGrid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
        return LazyVGrid(columns: cols, spacing: 3) {
            ForEach(Array(folder.apps.prefix(9))) { app in
                Image(nsImage: IconCache.shared.icon(for: app.path))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
    }
}

/// Поле поиска сверху.
struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.7))
            TextField("Поиск", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .focused(focused)
                .frame(width: 220)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(.white.opacity(0.15))
        )
    }
}
