import SwiftUI

/// Короткая настройка первого запуска. Никакие фоновые службы не включаются,
/// пока пользователь явно не подтвердит выбранные параметры.
struct OnboardingView: View {
    @State private var launchAtLogin = true
    @State private var keepAlive = true
    @State private var autoUpdate = true
    @State private var importLayout = false

    let onFinish: (Bool, Bool, Bool, Bool) -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Launchpad снова на месте")
                        .font(.title.bold())
                    Text("Настройте быстрый запуск — всё можно изменить позже.")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Как открыть") {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Нажмите F4 или используйте значок в строке меню.", systemImage: "keyboard")
                    Label("Для жеста щипка разрешите «Мониторинг ввода» в системных настройках.",
                          systemImage: "hand.draw")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Фоновая работа") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    Toggle("Перезапускать после сбоя", isOn: $keepAlive)
                    Toggle("Автоматически устанавливать обновления", isOn: $autoUpdate)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Toggle("Импортировать страницы и папки старого Launchpad", isOn: $importLayout)

            Spacer(minLength: 0)

            HStack {
                Button("Настроить позже", action: onSkip)
                Spacer()
                Button("Начать работу") {
                    onFinish(launchAtLogin, keepAlive, autoUpdate, importLayout)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560, height: 590)
    }
}
