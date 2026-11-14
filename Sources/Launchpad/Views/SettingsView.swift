import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Окно настроек: размер сетки, горячая клавиша, действия с раскладкой.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var model: LaunchpadModel
    @ObservedObject private var performance = PerformanceMetrics.shared
    @State private var importResult: String?
    @State private var launchAtLogin = StartupManager.launchesAtLogin
    @State private var keepAlive = StartupManager.keepsAlive
    @State private var startupError: String?
    private let autostartProblem = InstallLocation.autostartProblem
    @State private var reportStatus: String?

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

            if let error = model.hotkeyError {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            Section("Автозапуск") {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in applyStartup { StartupManager.setLaunchAtLogin(value) } }))
                    .disabled(autostartProblem != nil && !launchAtLogin)
                Toggle("Держать запущенным (авто-перезапуск)", isOn: Binding(
                    get: { keepAlive },
                    set: { value in applyStartup { StartupManager.setKeepAlive(value) } }))
                    .disabled(autostartProblem != nil && !keepAlive)
                Text("Перезапуск при крахе/принудительном завершении и старт при входе. Осознанный «Выйти» уважается. При включении Launchpad один раз перезапустится под управлением системы.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = autostartProblem?.message ?? startupError {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Раскладка") {
                Button("Импортировать раскладку старого Launchpad") {
                    model.importFromSystemLaunchpad()
                    importResult = model.statusMessage
                }
                Button("Сбросить (по алфавиту)") {
                    model.resetLayout()
                    importResult = model.statusMessage ?? "Раскладка сброшена."
                }
                Button("Обновить список приложений") {
                    Task {
                        await model.refreshApps()
                        importResult = model.statusMessage ?? "Список приложений обновлён."
                    }
                }
                .disabled(model.isScanning)
                Button("Восстановить последнюю резервную копию") {
                    model.restoreLatestBackup()
                    importResult = model.statusMessage
                }
                HStack {
                    Button("Экспортировать в файл…") { exportLayout() }
                    Button("Импортировать из файла…") { importLayout() }
                }
                HStack {
                    Button(model.undoTitle) { model.undoLayoutChange() }.disabled(!model.canUndo)
                    Button(model.redoTitle) { model.redoLayoutChange() }.disabled(!model.canRedo)
                }
                if model.isScanning { ProgressView("Обновление списка…") }
                if let importResult {
                    Text(importResult).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Каталоги приложений") {
                ForEach(settings.customAppDirectories, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            settings.removeCustomDirectory(path)
                            notifyDirectoriesChanged()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Убрать каталог")
                    }
                }
                Button("Добавить каталог…") { addApplicationDirectory() }
                Text("Вложенные .app автоматически появятся в Launchpad; изменения каталога отслеживаются через FSEvents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.hiddenApps.isEmpty {
                Section("Скрытые приложения") {
                    ForEach(model.hiddenApps) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Button("Показать") { model.unhideApp(app) }
                        }
                    }
                }
            }

            Section("О приложении") {
                LabeledContent("Версия релиза", value: Updater.currentVersion)
                LabeledContent("Номер сборки", value: Updater.currentBuild)
                LabeledContent("Дата и время сборки", value: Updater.buildDateText)
                    .textSelection(.enabled)
            }

            Section("Производительность") {
                LabeledContent("Последнее открытие",
                               value: PerformanceMetrics.durationText(performance.lastShowDuration))
                LabeledContent("Последний свайп",
                               value: PerformanceMetrics.durationText(performance.lastSwipeDuration))
                LabeledContent("Последнее сканирование",
                               value: PerformanceMetrics.durationText(performance.lastScanDuration))
                LabeledContent("Задержки в последнем свайпе",
                               value: "\(performance.lastSwipeStalls)")
                LabeledContent("Облегчённый режим включался",
                               value: "\(performance.adaptiveActivationCount) раз")
                Button("Скопировать диагностический отчёт") {
                    let report = Diagnostics.report(model: model)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    reportStatus = "Отчёт скопирован."
                }
                if let reportStatus {
                    Text(reportStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 760)
        .onChange(of: settings.columns) { _ in notifyChanged() }
        .onChange(of: settings.rows) { _ in notifyChanged() }
        .onChange(of: settings.hotkey) { _ in notifyChanged() }
    }

    private func applyStartup(_ change: () -> Bool) {
        startupError = change()
            ? nil
            : "Система не дала изменить автозапуск. Проверьте «Системные настройки → Основные → Объекты входа»."
        // Перечитываем фактическое состояние: механизмы взаимоисключающие.
        launchAtLogin = StartupManager.launchesAtLogin
        keepAlive = StartupManager.keepsAlive
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .launchpadSettingsChanged, object: nil)
    }

    private func notifyDirectoriesChanged() {
        NotificationCenter.default.post(name: .launchpadAppDirectoriesChanged, object: nil)
    }

    private func exportLayout() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Launchpad-layout.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportLayout(to: url)
            importResult = "Раскладка экспортирована."
        } catch {
            importResult = "Не удалось экспортировать раскладку: \(error.localizedDescription)"
        }
    }

    private func importLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = model.importLayout(from: url)
        importResult = model.statusMessage
    }

    private func addApplicationDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Добавить"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if settings.addCustomDirectory(url.path) {
            notifyDirectoriesChanged()
            importResult = "Каталог добавлен."
        } else {
            importResult = "Этот каталог уже добавлен."
        }
    }
}
