import SwiftUI

/// Окно настроек: размер сетки, горячая клавиша, действия с раскладкой.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var model: LaunchpadModel
    @State private var importResult: String?

    var body: some View {
        Form {
            Section("Сетка") {
                Stepper("Колонок: \(settings.columns)", value: $settings.columns, in: 4...10)
                Stepper("Строк: \(settings.rows)", value: $settings.rows, in: 3...8)
                Text("Всего иконок на странице: \(settings.columns * settings.rows)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Горячая клавиша") {
                Picker("Открыть Launchpad", selection: $settings.hotkey) {
                    ForEach(HotkeyPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            }

            Section("Раскладка") {
                Button("Импортировать раскладку старого Launchpad") {
                    let ok = model.importFromSystemLaunchpad()
                    importResult = ok ? "Раскладка импортирована." : "База старого Launchpad не найдена."
                }
                Button("Сбросить (по алфавиту)") {
                    model.resetLayout()
                    importResult = "Раскладка сброшена."
                }
                Button("Обновить список приложений") {
                    model.load()
                    importResult = "Список приложений обновлён."
                }
                if let importResult {
                    Text(importResult).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 460)
        .onChange(of: settings.columns) { _ in notifyChanged() }
        .onChange(of: settings.rows) { _ in notifyChanged() }
        .onChange(of: settings.hotkey) { _ in notifyChanged() }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .launchpadSettingsChanged, object: nil)
    }
}
