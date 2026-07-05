import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Окно, которое может стать ключевым, несмотря на стиль `.borderless`
/// (иначе поле поиска не получит фокус ввода).
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = LaunchpadModel()
    private var window: KeyableWindow!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var loginItemMenuItem: NSMenuItem?
    private var keepAliveMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var autoUpdateMenuItem: NSMenuItem?
    private var pendingUpdate: Updater.Update?
    private var updateTimer: Timer?
    private var hotKeys: [GlobalHotKey] = []

    // Мониторы событий (активны только при открытом окне).
    private var keyMonitor: Any?
    private var scrollAccumulator: CGFloat = 0
    private var scrollHandled = false
    private var scrollCooldown = false

    // Распознавание щипка трекпадом (открытие Launchpad жестом).
    private let multitouch = MultitouchManager()

    /// Distributed-уведомление «показать Launchpad» (посылается вторым экземпляром).
    static let showNotification = Notification.Name("com.openlaunchpad.show")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: если уже запущена копия — просим её показать
        // Launchpad (клик по иконке приложения открывает ланч) и выходим.
        if isDuplicateInstance() {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        model.load()
        buildWindow()
        buildStatusItem()
        registerHotKeys()
        observeNotifications()
        firstRunSetup()

        // Щипок трекпадом: сведение пальцев открывает, разведение — закрывает.
        multitouch.onPinchIn = { [weak self] in
            guard let self, !self.window.isVisible else { return }
            self.show()
        }
        multitouch.onPinchOut = { [weak self] in
            guard let self, self.window.isVisible, self.model.openFolderID == nil else { return }
            self.hide()
        }
        multitouch.start()

        // Проверка обновлений при запуске (через 4 с, не мешая старту) и далее
        // каждые 6 часов — меню-бар агент живёт днями без перезапуска.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.scheduledUpdateCheck()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduledUpdateCheck() }
        }

        // Тестовый флаг: сразу открыть Launchpad.
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.show()
            }
        }
    }

    /// Клик по иконке уже запущенного приложения (Finder/Dock/Launchpad) → открываем ланч.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        show()
        return true
    }

    // MARK: - Построение UI

    private func buildWindow() {
        let screen = activeScreen()
        window = KeyableWindow(contentRect: screen.frame,
                               styleMask: .borderless,
                               backing: .buffered,
                               defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // .moveToActiveSpace: окно приходит на ТЕКУЩЕЕ пространство при активации
        // (иначе ордерится на старом столе и система туда «прыгает»). НЕ
        // .canJoinAllSpaces (тот вешал окно на все столы). Закрытие при смене
        // стола — наблюдатель activeSpaceDidChange ниже.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LaunchpadRootView(model: model))
        window.orderOut(nil)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x3.fill",
                                   accessibilityDescription: "Launchpad")
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        let menu = NSMenu()
        // Неактивная строка-заголовок с версией.
        let versionItem = NSMenuItem(title: "Launchpad \(Updater.currentVersion)",
                                     action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Открыть Launchpad", action: #selector(showLaunchpad), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Импортировать раскладку старого Launchpad",
                     action: #selector(importLayout), keyEquivalent: "")
        menu.addItem(withTitle: "Сбросить раскладку (по алфавиту)",
                     action: #selector(resetLayout), keyEquivalent: "")
        menu.addItem(withTitle: "Обновить список приложений",
                     action: #selector(rescan), keyEquivalent: "")
        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "Запускать при входе",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = LoginItem.isEnabled ? .on : .off
        loginItemMenuItem = loginItem
        menu.addItem(loginItem)

        let keepAlive = NSMenuItem(title: "Держать запущенным (авто-перезапуск)",
                                   action: #selector(toggleKeepAlive), keyEquivalent: "")
        keepAlive.state = KeepAliveService.isEnabled ? .on : .off
        keepAliveMenuItem = keepAlive
        menu.addItem(keepAlive)

        menu.addItem(.separator())
        let update = NSMenuItem(title: "Проверить обновления…",
                                action: #selector(checkUpdatesClicked), keyEquivalent: "")
        updateMenuItem = update
        menu.addItem(update)
        let autoUpdate = NSMenuItem(title: "Обновлять автоматически",
                                    action: #selector(toggleAutoUpdate), keyEquivalent: "")
        autoUpdate.state = AppSettings.shared.autoUpdate ? .on : .off
        autoUpdateMenuItem = autoUpdate
        menu.addItem(autoUpdate)
        menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        menu.delegate = self
        statusItem.menu = menu
    }

    private func registerHotKeys() {
        hotKeys.removeAll() // deinit снимает старую регистрацию
        let preset = AppSettings.shared.hotkey
        guard let code = preset.keyCode else { return }
        if let hk = GlobalHotKey(keyCode: code, modifiers: preset.modifiers, id: 1,
                                 callback: { [weak self] in self?.toggle() }) {
            hotKeys.append(hk)
        }
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            forName: .launchpadShouldClose, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        NotificationCenter.default.addObserver(
            forName: .launchpadToggle, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        }
        NotificationCenter.default.addObserver(
            forName: .launchpadSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.applyGridChange()
                self?.registerHotKeys()
            }
        }
        // Второй экземпляр (клик по иконке приложения) просит показать Launchpad.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
        // Смена рабочего стола — закрываем Launchpad (как в оригинале),
        // чтобы он не висел на всех пространствах.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.window.isVisible == true { self?.hide() }
            }
        }
    }

    // MARK: - Показ / скрытие

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    func show() {
        let screen = activeScreen()
        window.setFrame(screen.frame, display: true)
        model.searchText = ""
        model.openFolderID = nil
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func hide() {
        window.orderOut(nil)
        removeMonitors()
        model.searchText = ""
        model.openFolderID = nil
        model.editing = false
    }

    func toggle() {
        window.isVisible ? hide() : show()
    }

    // MARK: - Мониторы клавиш и скролла

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        scrollAccumulator = 0
        model.optionHeld = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            return handleKey(event)
        case .scrollWheel:
            handleScroll(event)
            return event
        case .flagsChanged:
            // Зажатие ⌥ показывает крестики удаления (как в оригинале Launchpad).
            model.optionHeld = event.modifierFlags.contains(.option)
            return event
        default:
            return event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch Int(event.keyCode) {
        case kVK_Escape:
            if model.editing {
                model.editing = false          // сначала выходим из режима покачивания
            } else if model.isSearching {
                model.searchText = ""
            } else if model.openFolderID != nil {
                model.openFolderID = nil
            } else {
                hide()
            }
            return nil
        case kVK_LeftArrow where !model.isSearching:
            model.prevPage()
            return nil
        case kVK_RightArrow where !model.isSearching:
            model.nextPage()
            return nil
        case kVK_Return where model.isSearching:
            if let first = model.searchResults.first {
                AppLauncher.launch(first)
                hide()
            }
            return nil
        default:
            return event
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard !model.isSearching, model.openFolderID == nil else { return }

        if event.hasPreciseScrollingDeltas {
            // Трекпад: листаем ровно один раз за физический свайп, инерцию игнорируем.
            if event.momentumPhase != [] { return }
            if event.phase == .began {
                scrollAccumulator = 0
                scrollHandled = false
            }
            scrollAccumulator += event.scrollingDeltaX
            if !scrollHandled,
               abs(scrollAccumulator) > 40,
               abs(scrollAccumulator) > abs(event.scrollingDeltaY) {
                if scrollAccumulator < 0 { model.nextPage() } else { model.prevPage() }
                scrollHandled = true
            }
            if event.phase == .ended || event.phase == .cancelled {
                scrollAccumulator = 0
                scrollHandled = false
            }
        } else {
            // Обычная мышь: дискретные щелчки с небольшим кулдауном.
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
            guard !scrollCooldown else { return }
            if event.scrollingDeltaX < 0 { model.nextPage() } else { model.prevPage() }
            scrollCooldown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.scrollCooldown = false
            }
        }
    }

    // MARK: - Действия меню

    @objc private func statusItemClicked() { showLaunchpad() }

    @objc private func showLaunchpad() { show() }

    @objc private func importLayout() {
        let ok = model.importFromSystemLaunchpad()
        let alert = NSAlert()
        if ok {
            alert.messageText = "Раскладка импортирована"
            alert.informativeText = "Страницы и папки старого Launchpad восстановлены."
        } else {
            alert.messageText = "Не удалось импортировать"
            alert.informativeText = "База данных старого Launchpad не найдена в ~/Library/Application Support/Dock/."
        }
        alert.runModal()
    }

    @objc private func resetLayout() {
        model.resetLayout()
    }

    @objc private func rescan() {
        model.load()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Настройки Launchpad"
            w.isReleasedWhenClosed = false
            w.center()
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.level = .floating
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        loginItemMenuItem?.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func toggleKeepAlive() {
        KeepAliveService.setEnabled(!KeepAliveService.isEnabled)
        keepAliveMenuItem?.state = KeepAliveService.isEnabled ? .on : .off
    }

    private func isDuplicateInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me.processIdentifier }
    }

    // MARK: - Первый запуск

    /// При первом запуске на любой машине делаем ланч резидентным автоматически:
    /// прописываем автозапуск при входе (login item) и авто-перезапуск (keep-alive).
    /// Так глобальный хоткей работает «из коробки» — процесс, который его слушает,
    /// поднимается при каждом входе и переживает крах. macOS не позволяет
    /// приложению самому назначить системную клавишу, переживающую его смерть
    /// (защита ОС) — поэтому единственный надёжный путь «работает везде сам» —
    /// держать ланч запущенным.
    private func firstRunSetup() {
        let key = "didFirstRunSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        LoginItem.setEnabled(true)
        KeepAliveService.setEnabled(true)
        loginItemMenuItem?.state = LoginItem.isEnabled ? .on : .off
        keepAliveMenuItem?.state = KeepAliveService.isEnabled ? .on : .off
    }

    // MARK: - Обновления

    @objc private func checkUpdatesClicked() {
        if let update = pendingUpdate {
            promptInstall(update)
            return
        }
        Updater.checkForUpdate { [weak self] update in
            MainActor.assumeIsolated {
                if let update {
                    self?.pendingUpdate = update
                    self?.promptInstall(update)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Обновлений нет"
                    alert.informativeText = "Установлена последняя версия \(Updater.currentVersion)."
                    alert.runModal()
                }
            }
        }
    }

    /// Фоновая проверка: при запуске и по таймеру. Если включено «Обновлять
    /// автоматически» и оверлей скрыт — тихо ставит обновление (перезапуск
    /// меню-бар агента незаметен). Иначе только помечает в меню.
    private func scheduledUpdateCheck() {
        Updater.checkForUpdate { [weak self] update in
            MainActor.assumeIsolated {
                guard let self, let update else { return }
                self.pendingUpdate = update
                self.updateMenuItem?.title = "Обновить до \(update.version)…"
                if AppSettings.shared.autoUpdate && !self.window.isVisible {
                    Updater.downloadAndInstall(update) { _ in }
                }
            }
        }
    }

    @objc private func toggleAutoUpdate() {
        AppSettings.shared.autoUpdate.toggle()
        autoUpdateMenuItem?.state = AppSettings.shared.autoUpdate ? .on : .off
        // Только что включили и обновление уже найдено — поставить сразу (если скрыт).
        if AppSettings.shared.autoUpdate, let update = pendingUpdate, !window.isVisible {
            Updater.downloadAndInstall(update) { _ in }
        }
    }

    private func promptInstall(_ update: Updater.Update) {
        let alert = NSAlert()
        alert.messageText = "Доступно обновление \(update.version)"
        alert.informativeText = update.notes.isEmpty
            ? "Установить сейчас? Launchpad перезапустится."
            : update.notes
        alert.addButton(withTitle: "Обновить")
        alert.addButton(withTitle: "Позже")
        if alert.runModal() == .alertFirstButtonReturn {
            Updater.downloadAndInstall(update) { _ in }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Актуализируем галочки при открытии меню.
        loginItemMenuItem?.state = LoginItem.isEnabled ? .on : .off
        keepAliveMenuItem?.state = KeepAliveService.isEnabled ? .on : .off
        autoUpdateMenuItem?.state = AppSettings.shared.autoUpdate ? .on : .off
    }
}
