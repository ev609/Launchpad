import SwiftUI

/// Встроенная памятка: сочетания остаются доступными без README и не требуют
/// покидать полноэкранную сетку.
struct KeyboardShortcutHelpView: View {
    @ObservedObject var model: LaunchpadModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    private let navigation = [
        Shortcut(keys: "←  ↑  ↓  →", action: L("Выбрать приложение")),
        Shortcut(keys: "Tab / ⇧Tab", action: L("Следующее / предыдущее")),
        Shortcut(keys: "Home / End", action: L("Начало / конец страницы")),
        Shortcut(keys: "Page Up / Page Down", action: L("Перейти на другую страницу")),
        Shortcut(keys: "Return / Space", action: L("Открыть выбранное")),
        Shortcut(keys: "Esc", action: L("Назад или закрыть Launchpad")),
    ]

    private let editing = [
        Shortcut(keys: L("⌥ + стрелки"), action: L("Переставить выбранное")),
        Shortcut(keys: "⌥⌘← / ⌥⌘→", action: L("Объединить с соседом")),
        Shortcut(keys: "⌥⌘↑", action: L("Извлечь приложение из папки")),
        Shortcut(keys: "⌘Z", action: L("Отменить изменение")),
        Shortcut(keys: "⇧⌘Z", action: L("Повторить изменение")),
        Shortcut(keys: "? / ⌘?", action: L("Показать эту памятку")),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(contrast == .increased ? 0.62 : 0.46)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Сочетания клавиш")
                            .font(.system(size: 28, weight: .semibold))
                        Text("Launchpad можно полностью использовать без мыши")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Закрыть справку")
                }

                HStack(alignment: .top, spacing: 32) {
                    section(L("Навигация"), shortcuts: navigation)
                    Divider()
                    section(L("Раскладка"), shortcuts: editing)
                }

                Text("Во время поиска стрелки и Tab выбирают результат, Return запускает приложение.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(30)
            .frame(maxWidth: 760)
            .background(panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(contrast == .increased ? 0.72 : 0.22),
                            lineWidth: contrast == .increased ? 2 : 1)
            )
            .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.42), radius: 30, y: 12)
            .padding(40)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Справка по сочетаниям клавиш Launchpad")
        }
    }

    @ViewBuilder
    private func section(_ title: String, shortcuts: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            ForEach(shortcuts) { shortcut in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(shortcut.keys)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.white.opacity(contrast == .increased ? 0.22 : 0.11))
                        )
                        .frame(minWidth: 128, alignment: .leading)
                    Text(shortcut.action)
                        .font(.system(size: 14))
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if reduceTransparency {
            Color(red: 0.12, green: 0.13, blue: 0.16)
        } else {
            VisualEffectView(material: .hudWindow, blending: .withinWindow)
                .overlay(Color.black.opacity(contrast == .increased ? 0.32 : 0.14))
        }
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            model.showsKeyboardHelp = false
        }
    }
}
