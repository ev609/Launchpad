import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Carbon.HIToolbox

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
                Stepper(L("Колонок: %@", String(settings.columns)), value: $settings.columns, in: 4...10)
                Stepper(L("Строк: %@", String(settings.rows)), value: $settings.rows, in: 3...8)
                Text(L("Всего иконок на странице: %@", String(settings.columns * settings.rows)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Горячая клавиша") {
                Picker("Открыть Launchpad", selection: $settings.hotkey) {
                    ForEach(HotkeyPreset.allCases.filter { $0 != .custom || settings.customHotkey != nil }) { preset in
                        Text(preset == .custom ? settings.customHotkey?.title ?? preset.title : preset.title)
                            .tag(preset)
                    }
                }
                HotkeyRecorder { recorded in
                    settings.customHotkey = recorded
                    if settings.hotkey == .custom {
                        notifyChanged()
                    } else {
                        settings.hotkey = .custom
                    }
                }
            }

            if let error = model.hotkeyError {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            Section("Жест") {
                Toggle("Открывать и закрывать щипком трекпада", isOn: $settings.pinchGesture)
                Text("Сведение 3–5 пальцев открывает Launchpad, разведение — закрывает. Использует закрытый системный фреймворк трекпада.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    importResult = model.statusMessage ?? L("Раскладка сброшена.")
                }
                Button("Обновить список приложений") {
                    Task {
                        await model.refreshApps()
                        importResult = model.statusMessage ?? L("Список приложений обновлён.")
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
                               value: L("%@ раз", String(performance.adaptiveActivationCount)))
                Button("Скопировать диагностический отчёт") {
                    let report = Diagnostics.report(model: model)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    reportStatus = L("Отчёт скопирован.")
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
        .onChange(of: settings.pinchGesture) { _ in notifyChanged() }
    }

    private func applyStartup(_ change: () -> Bool) {
        startupError = change()
            ? nil
            : L("Система не дала изменить автозапуск. Проверьте «Системные настройки → Основные → Объекты входа».")
        // Перечитываем фактическое состояние: механизмы взаимоисключающие.
        launchAtLogin = StartupManager.launchesAtLogin
        keepAlive = StartupManager.keepsAlive
    }

    fileprivate func notifyChanged() {
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
            importResult = L("Раскладка экспортирована.")
        } catch {
            importResult = L("Не удалось экспортировать раскладку: %@", error.localizedDescription)
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
        panel.prompt = L("Добавить")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if settings.addCustomDirectory(url.path) {
            notifyDirectoriesChanged()
            importResult = L("Каталог добавлен.")
        } else {
            importResult = L("Этот каталог уже добавлен.")
        }
    }
}

/// Кнопка записи сочетания: следующее нажатие в окне настроек становится
/// горячей клавишей. Esc отменяет запись.
private struct HotkeyRecorder: View {
    let onRecord: (CustomHotkey) -> Void

    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack {
            Button(monitor == nil ? L("Записать своё сочетание…") : L("Нажмите сочетание (Esc — отмена)")) {
                monitor == nil ? start() : stop()
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = nil
        NotificationCenter.default.post(name: .launchpadHotkeyRecording, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            if let hotkey = CustomHotkey.make(keyCode: event.keyCode,
                                              modifierFlags: event.modifierFlags,
                                              characters: event.charactersIgnoringModifiers) {
                stop()
                onRecord(hotkey)
            } else {
                hint = L("Добавьте ⌘, ⌥ или ⌃ (без них можно только F1–F20).")
            }
            return nil
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        NotificationCenter.default.post(name: .launchpadHotkeyRecording, object: false)
    }
}
