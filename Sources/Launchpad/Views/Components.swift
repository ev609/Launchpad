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

/// Иконка подгружается асинхронно: появление новой соседней страницы больше не
/// блокирует главный поток чтением десятков app-бандлов.
private struct CachedAppIcon: View {
    let path: String
    @State private var image: NSImage?

    private static let placeholder = NSImage(
        systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()

    var body: some View {
        Image(nsImage: image ?? Self.placeholder)
            .resizable()
            .interpolation(.high)
            .onAppear {
                IconCache.shared.requestIcon(for: path) { loaded in
                    image = loaded
                }
            }
            .onChange(of: path) { _ in
                image = nil
                IconCache.shared.requestIcon(for: path) { loaded in
                    image = loaded
                }
            }
    }
}

/// Иконка приложения с подписью.
struct AppIconView: View {
    let app: AppEntry
    var iconSize: CGFloat = 88
    var reduceEffects = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 6) {
            CachedAppIcon(path: app.path)
                .frame(width: iconSize, height: iconSize)
            Text(app.name)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(reduceEffects ? 0 : (contrast == .increased ? 0.9 : 0.6)),
                        radius: reduceEffects ? 0 : (contrast == .increased ? 3 : 2),
                        y: reduceEffects ? 0 : 1)
        }
    }
}

/// Иконка папки — мини-превью из иконок вложенных приложений.
struct FolderIconView: View {
    let folder: Folder
    var iconSize: CGFloat = 88
    var reduceEffects = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
                .fill(.white.opacity(contrast == .increased ? 0.32 : 0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
                        .stroke(.white.opacity(contrast == .increased ? 0.65 : 0.15),
                                lineWidth: contrast == .increased ? 2 : 1)
                )
                .frame(width: iconSize, height: iconSize)
                .overlay(miniGrid.padding(iconSize * 0.13))
            Text(folder.name)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(reduceEffects ? 0 : (contrast == .increased ? 0.9 : 0.6)),
                        radius: reduceEffects ? 0 : (contrast == .increased ? 3 : 2),
                        y: reduceEffects ? 0 : 1)
        }
    }

    private var miniGrid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
        return LazyVGrid(columns: cols, spacing: 3) {
            ForEach(Array(folder.apps.prefix(9))) { app in
                CachedAppIcon(path: app.path)
                    .aspectRatio(contentMode: .fit)
            }
        }
    }
}

/// Поле поиска сверху.
struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.7))
            TextField("Поиск", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                // Поле специально остаётся первым responder, чтобы поиск сразу
                // принимал ввод с клавиатуры. У пустого поля скрываем мигающую
                // каретку; после первого символа она появляется как обычно.
                .tint(text.isEmpty ? .clear : .white.opacity(0.9))
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
            Capsule()
                .fill(.white.opacity(contrast == .increased ? 0.28 : 0.15))
                .overlay(
                    Capsule().stroke(.white.opacity(contrast == .increased ? 0.75 : 0),
                                     lineWidth: 2)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Поиск приложений"))
    }
}
