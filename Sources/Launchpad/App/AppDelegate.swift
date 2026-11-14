import AppKit
import SwiftUI
import Carbon.HIToolbox
import os.signpost

/// Окно, которое может стать ключевым, несмотря на стиль `.borderless`
/// (иначе поле поиска не получит фокус ввода).
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = LaunchpadModel()
    private var testingUI: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--ui-test") && ProcessInfo.processInfo.environment["LAUNCHPAD_SUPPORT_DIR"] != nil
        #else
        return false
        #endif
    }
    private var window: KeyableWindow!
    private var rootHostingView: NSHostingView<LaunchpadRootView>?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var loginItemMenuItem: NSMenuItem?
    private var keepAliveMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var updateStatusMenuItem: NSMenuItem?
    private var autoUpdateMenuItem: NSMenuItem?
    private var isInstallingUpdate = false
    private var appDirectoryWatcher: AppDirectoryWatcher?
    private var pendingUpdate: Updater.Update?
    private var updateTimer: Timer?
    private var hotKeys: [GlobalHotKey] = []

    // Мониторы событий (активны только при открытом окне).
    private var keyMonitor: Any?
    private var pageScroll = PageScrollController()
    private let pageScrollState = PageScrollState()
    private var pageScrollSettling = false
    private var pageScrollSettleWork: DispatchWorkItem?
    private var showTrace: OSSignpostID?
    private var scrollTrace: OSSignpostID?
    private var showStartedAt: TimeInterval?
    private var scrollStartedAt: TimeInterval?
    private var framePulseTimer: DispatchSourceTimer?
    private var expectedFramePulse: TimeInterval = 0
    private var swipeStallCount = 0
    /// Создание нового окна с `.moveToActiveSpace` само может породить уведомление
    /// смены Space. Коротко игнорируем его, чтобы только что открытая сетка не закрылась.
    private var ignoreSpaceChangesUntil: TimeInterval = 0

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
        model.loadCachedLayout()
        buildEditMenu()
        if !testingUI { Task { await model.refreshApps() } }
        if !testingUI { restartAppDirectoryWatcher() }
        buildWindow()
        buildStatusItem()
        registerHotKeys()
        observeNotifications()
        if !testingUI { firstRunSetup() }

        // Щипок трекпадом: сведение пальцев открывает, разведение — закрывает.
        multitouch.onPinchIn = { [weak self] in
            guard let self, self.window?.isVisible != true else { return }
            self.show()
        }
        multitouch.onPinchOut = { [weak self] in
            guard let self, self.window?.isVisible == true, self.model.openFolderID == nil else { return }
            self.hide()
        }
        if !testingUI { multitouch.start() }

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

    func applicationWillTerminate(_ notification: Notification) {
        // При скрытии состояние уже сохранено до очистки временных оверлеев.
        if window?.isVisible == true { model.saveNavigationState() }
        model.flushPendingSave()
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
        // Тяжёлое SwiftUI-дерево создаётся только при показе. Меню-бар агент
        // большую часть времени скрыт и не должен держать графические поверхности.
        window.contentView = NSView()
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
        let versionItem = NSMenuItem(title: "Launchpad \(Updater.displayVersion)",
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
        let updateStatus = NSMenuItem(title: "Обновления ещё не проверялись",
                                      action: nil, keyEquivalent: "")
        updateStatus.isEnabled = false
        updateStatusMenuItem = updateStatus
        menu.addItem(updateStatus)
        let autoUpdate = NSMenuItem(title: "Обновлять автоматически",
                                    action: #selector(toggleAutoUpdate), keyEquivalent: "")
        autoUpdate.state = AppSettings.shared.autoUpdate ? .on : .off
        autoUpdateMenuItem = autoUpdate
        menu.addItem(autoUpdate)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Сочетания клавиш…",
                     action: #selector(openKeyboardHelp), keyEquivalent: "?")
        menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        menu.delegate = self
        statusItem.menu = menu
    }

    private func buildEditMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Launchpad", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Launchpad")
        appMenu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Выйти из Launchpad", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let item = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Правка")
        edit.delegate = self
        edit.addItem(withTitle: "Отменить", action: #selector(undoLayout), keyEquivalent: "z").target = self
        let redo = edit.addItem(withTitle: "Повторить", action: #selector(redoLayout), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.target = self
        edit.addItem(.separator())
        for (title, action, key) in [("Вырезать", "cut:", "x"), ("Копировать", "copy:", "c"),
                                      ("Вставить", "paste:", "v"), ("Выбрать всё", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        item.submenu = edit
        menu.addItem(item)
        let helpItem = NSMenuItem(title: "Справка", action: nil, keyEquivalent: "")
        let help = NSMenu(title: "Справка")
        let shortcuts = help.addItem(withTitle: "Сочетания клавиш Launchpad",
                                     action: #selector(openKeyboardHelp), keyEquivalent: "/")
        shortcuts.keyEquivalentModifierMask = [.command, .shift]
        shortcuts.target = self
        helpItem.submenu = help
        menu.addItem(helpItem)
        NSApp.mainMenu = menu
    }

    private var textUndoManager: UndoManager? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              NSApp.keyWindow !== window || model.isSearching || model.openFolderID != nil else { return nil }
        return editor.undoManager
    }

    @objc private func undoLayout() {
        if let manager = textUndoManager { manager.undo() } else { model.undoLayoutChange() }
    }

    @objc private func redoLayout() {
        if let manager = textUndoManager { manager.redo() } else { model.redoLayoutChange() }
    }

    private func registerHotKeys() {
        hotKeys.forEach { $0.unregister() }
        hotKeys.removeAll()
        model.hotkeyError = nil
        let preset = AppSettings.shared.hotkey
        guard let code = preset.keyCode else { return }
        if let hk = GlobalHotKey(keyCode: code, modifiers: preset.modifiers, id: 1,
                                 callback: { [weak self] in self?.toggle() }) {
            hotKeys.append(hk)
        } else {
            model.hotkeyError = "Не удалось назначить «\(preset.title)». Возможно, сочетание занято. Выберите другое в настройках."
        }
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(forName: .launchpadLaunchFailed, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated { self?.model.operationError = notification.object as? String }
        }
        NotificationCenter.default.addObserver(forName: .launchpadLayoutSaveFailed, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated { self?.model.operationError = notification.object as? String }
        }
        NotificationCenter.default.addObserver(
            forName: .launchpadShouldClose, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        NotificationCenter.default.addObserver(
            forName: .launchpadShouldShow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
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
        NotificationCenter.default.addObserver(
            forName: .launchpadAppDirectoriesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restartAppDirectoryWatcher()
                Task { await self.model.refreshApps() }
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
                guard let self,
                      ProcessInfo.processInfo.systemUptime >= self.ignoreSpaceChangesUntil else { return }
                if self.window?.isVisible == true { self.hide() }
            }
        }
    }

    private func restartAppDirectoryWatcher() {
        appDirectoryWatcher?.stop()
        appDirectoryWatcher = AppDirectoryWatcher(paths: AppScanner.searchPaths) { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            Task { await self.model.refreshApps() }
        }
        appDirectoryWatcher?.start()
    }

    // MARK: - Показ / скрытие

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    func show() {
        if let showTrace { PerformanceTrace.end("Launchpad show", id: showTrace) }
        showTrace = PerformanceTrace.begin("Launchpad show")
        showStartedAt = ProcessInfo.processInfo.systemUptime
        let reusedView = rootHostingView != nil
        refreshAppsIfChanged()
        if window == nil { buildWindow() }
        let screen = activeScreen()
        window.setFrame(screen.frame, display: true)
        model.searchText = ""
        model.restoreNavigationState()
        if rootHostingView == nil {
            IconCache.shared.prepareForDisplay()
            let hosting = NSHostingView(rootView: LaunchpadRootView(
                model: model,
                scrollState: pageScrollState,
                safeTop: screen.safeAreaInsets.top,
                onFirstFrame: { [weak self] in self?.finishShowTrace() }))
            rootHostingView = hosting
            window.contentView = hosting
        }
        ignoreSpaceChangesUntil = ProcessInfo.processInfo.systemUptime + 0.75
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installMonitors()
        if reusedView { DispatchQueue.main.async { [weak self] in self?.finishShowTrace() } }
    }

    private func finishShowTrace() {
        guard let showTrace else { return }
        PerformanceTrace.end("Launchpad show", id: showTrace)
        self.showTrace = nil
        if let showStartedAt {
            PerformanceMetrics.shared.recordShow(
                ProcessInfo.processInfo.systemUptime - showStartedAt)
        }
        self.showStartedAt = nil
    }

    private func refreshAppsIfChanged() {
        if !testingUI { Task { await model.refreshApps() } }
    }

    func hide() {
        guard let window else { return }
        finishShowTrace()
        model.saveNavigationState()
        window.orderOut(nil)
        removeMonitors()
        model.searchText = ""
        model.openFolderID = nil
        model.showsKeyboardHelp = false
        model.editing = false
        model.pruneEmptyPages()
        model.layoutInteractionActive = false
        // `orderOut` сам по себе не уничтожает backing store полноэкранного окна.
        // Закрываем и освобождаем окно целиком; при следующем показе оно создастся
        // заново. Так скрытый меню-бар агент возвращается к минимальному footprint.
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
        rootHostingView = nil
        self.window = nil
        IconCache.shared.removeAll()
    }

    func toggle() {
        window?.isVisible == true ? hide() : show()
    }

    // MARK: - Мониторы клавиш и скролла

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        pageScroll.reset()
        pageScrollSettleWork?.cancel()
        pageScrollSettleWork = nil
        pageScrollSettling = false
        pageScrollState.endInteraction()
        finishScrollTrace()
        model.optionHeld = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        switch event.type {
        case .keyDown:
            return handleKey(event)
        case .scrollWheel:
            return handleScroll(event) ? nil : event
        case .flagsChanged:
            // Зажатие ⌥ показывает крестики удаления (как в оригинале Launchpad).
            model.optionHeld = event.modifierFlags.contains(.option)
            return event
        default:
            return event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shortcutModifiers = modifiers.intersection([.command, .control, .option, .shift])
        let helpShortcut = event.keyCode == UInt16(kVK_ANSI_Slash)
            && (shortcutModifiers == .shift || shortcutModifiers == [.command, .shift])
            && (!model.isSearching || shortcutModifiers.contains(.command))
        if helpShortcut {
            withAnimation(.easeOut(duration: 0.14)) {
                model.showsKeyboardHelp.toggle()
            }
            return nil
        }
        if model.showsKeyboardHelp {
            if event.keyCode == UInt16(kVK_Escape) { model.showsKeyboardHelp = false }
            return shortcutModifiers.contains(.command) ? event : nil
        }
        if modifiers.contains(.command), event.keyCode == UInt16(kVK_ANSI_Z) {
            if modifiers.contains(.shift) { redoLayout() } else { undoLayout() }
            return nil
        }
        // Не перехватываем ввод и стрелки, пока пользователь редактирует имя папки.
        if model.openFolderID != nil, model.folderNameEditing,
           event.keyCode != UInt16(kVK_Escape) { return event }
        if model.openFolderID != nil, shortcutModifiers == [.command, .option],
           event.keyCode == UInt16(kVK_UpArrow) {
            if model.extractSelectedFolderApp() { announce("Извлечено из папки") }
            return nil
        }
        if model.openFolderID != nil, shortcutModifiers == .option {
            let moved: Bool
            switch Int(event.keyCode) {
            case kVK_LeftArrow:
                moved = model.moveSelectedFolderApp(horizontal: -1, columns: model.folderKeyboardColumns)
            case kVK_RightArrow:
                moved = model.moveSelectedFolderApp(horizontal: 1, columns: model.folderKeyboardColumns)
            case kVK_UpArrow:
                moved = model.moveSelectedFolderApp(vertical: -1, columns: model.folderKeyboardColumns)
            case kVK_DownArrow:
                moved = model.moveSelectedFolderApp(vertical: 1, columns: model.folderKeyboardColumns)
            default:
                return event
            }
            if moved { announce("Перемещено") }
            return nil
        }
        if model.openFolderID == nil, !model.isSearching,
           shortcutModifiers == [.command, .option] {
            let combined: Bool
            switch Int(event.keyCode) {
            case kVK_LeftArrow:
                combined = model.combineSelectedGridItem(withNeighbor: -1)
            case kVK_RightArrow:
                combined = model.combineSelectedGridItem(withNeighbor: 1)
            default:
                return event
            }
            if combined { announce("Папка создана") }
            return nil
        }
        if model.openFolderID == nil, !model.isSearching, shortcutModifiers == .option {
            let moved: Bool
            switch Int(event.keyCode) {
            case kVK_LeftArrow:
                moved = model.moveSelectedGridItem(horizontal: -1)
            case kVK_RightArrow:
                moved = model.moveSelectedGridItem(horizontal: 1)
            case kVK_UpArrow:
                moved = model.moveSelectedGridItem(vertical: -1)
            case kVK_DownArrow:
                moved = model.moveSelectedGridItem(vertical: 1)
            default:
                return event
            }
            if moved { announce("Перемещено") }
            return nil
        }
        if model.openFolderID != nil, event.keyCode == UInt16(kVK_Tab),
           modifiers == .shift {
            model.moveFolderSelection(horizontal: -1, columns: model.folderKeyboardColumns)
            announceKeyboardSelection()
            return nil
        }
        if model.isSearching, event.keyCode == UInt16(kVK_Tab), modifiers == .shift {
            model.selectSearchResult(offset: -1)
            return nil
        }
        if !model.isSearching, event.keyCode == UInt16(kVK_Tab), modifiers == .shift {
            model.moveGridSelection(horizontal: -1)
            announceKeyboardSelection()
            return nil
        }
        if !shortcutModifiers.isEmpty { return event }
        if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }

        if model.openFolderID != nil {
            switch Int(event.keyCode) {
            case kVK_Escape:
                model.closeFolder()
            case kVK_LeftArrow:
                model.moveFolderSelection(horizontal: -1, columns: model.folderKeyboardColumns)
                announceKeyboardSelection()
            case kVK_RightArrow, kVK_Tab:
                model.moveFolderSelection(horizontal: 1, columns: model.folderKeyboardColumns)
                announceKeyboardSelection()
            case kVK_UpArrow:
                model.moveFolderSelection(vertical: -1, columns: model.folderKeyboardColumns)
                announceKeyboardSelection()
            case kVK_DownArrow:
                model.moveFolderSelection(vertical: 1, columns: model.folderKeyboardColumns)
                announceKeyboardSelection()
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
                if let app = model.selectedFolderApp { AppLauncher.launch(app) }
            default:
                return event
            }
            return nil
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            if model.editing {
                model.editing = false          // сначала выходим из режима покачивания
            } else if model.isSearching {
                model.searchText = ""
            } else if model.selectedGridItemID != nil {
                model.selectedGridItemID = nil
            } else {
                hide()
            }
            return nil
        case kVK_LeftArrow where model.isSearching:
            model.selectSearchResult(offset: -1)
            return nil
        case kVK_RightArrow where model.isSearching:
            model.selectSearchResult(offset: 1)
            return nil
        case kVK_DownArrow where model.isSearching:
            model.selectSearchResult(offset: model.columns)
            return nil
        case kVK_UpArrow where model.isSearching:
            model.selectSearchResult(offset: -model.columns)
            return nil
        case kVK_Tab where model.isSearching:
            model.selectSearchResult(offset: 1)
            return nil
        case kVK_LeftArrow:
            model.moveGridSelection(horizontal: -1)
            announceKeyboardSelection()
            return nil
        case kVK_RightArrow, kVK_Tab:
            model.moveGridSelection(horizontal: 1)
            announceKeyboardSelection()
            return nil
        case kVK_UpArrow:
            model.moveGridSelection(vertical: -1)
            announceKeyboardSelection()
            return nil
        case kVK_DownArrow:
            model.moveGridSelection(vertical: 1)
            announceKeyboardSelection()
            return nil
        case kVK_PageUp:
            model.prevPage()
            model.selectGridBoundary(first: true)
            announceKeyboardSelection()
            return nil
        case kVK_PageDown:
            model.nextPage()
            model.selectGridBoundary(first: true)
            announceKeyboardSelection()
            return nil
        case kVK_Home:
            model.selectGridBoundary(first: true)
            announceKeyboardSelection()
            return nil
        case kVK_End:
            model.selectGridBoundary(first: false)
            announceKeyboardSelection()
            return nil
        case kVK_Return where model.isSearching:
            if let first = model.selectedSearchApp {
                AppLauncher.launch(first)
            }
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            activateSelectedGridItem()
            return nil
        default:
            return event
        }
    }

    private func activateSelectedGridItem() {
        guard let item = model.selectedGridItem else {
            model.selectGridBoundary(first: true)
            announceKeyboardSelection()
            return
        }
        switch item {
        case .app(let app):
            AppLauncher.launch(app)
        case .folder(let folder):
            model.openFolder(folder.id)
            announceKeyboardSelection()
        }
    }

    /// VoiceOver не следует за собственным логическим фокусом SwiftUI сам,
    /// поэтому озвучиваем изменения, вызванные глобальным монитором клавиатуры.
    private func announceKeyboardSelection() {
        let text: String?
        if let app = model.selectedFolderApp {
            text = app.name
        } else if let item = model.selectedGridItem {
            text = "\(item.displayName), страница \(model.currentPage + 1) из \(model.pages.count)"
        } else {
            text = nil
        }
        guard let text, let window else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [.announcement: text,
                       .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }

    private func announce(_ prefix: String) {
        let selection = model.selectedFolderApp?.name ?? model.selectedGridItem?.displayName
        let text = selection.map { "\(prefix): \($0)" } ?? prefix
        guard let window else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [.announcement: text,
                       .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard !model.isSearching, model.openFolderID == nil, !model.layoutInteractionActive else {
            pageScroll.reset()
            pageScrollSettleWork?.cancel()
            pageScrollSettleWork = nil
            pageScrollSettling = false
            pageScrollState.endInteraction()
            finishScrollTrace()
            return false
        }
        if pageScrollSettling { return true }
        let result = pageScroll.handle(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                       precise: event.hasPreciseScrollingDeltas,
                                       phase: event.phase, momentum: event.momentumPhase,
                                       time: event.timestamp)
        if let offset = result.offset {
            pageScrollState.beginInteraction()
            beginScrollTraceIfNeeded()
            let atLeadingEdge = model.currentPage == 0 && offset > 0
            let atTrailingEdge = model.currentPage == model.pages.count - 1 && offset < 0
            let resistance: CGFloat = atLeadingEdge || atTrailingEdge ? 0.18 : 1
            let width = max(1, window?.frame.width ?? 1)
            pageScrollState.setOffset(min(width, max(-width, offset * resistance)))
        }
        if result.finished {
            finishInteractiveScroll(direction: result.direction)
        } else if result.offset == nil {
            if result.direction > 0 { model.nextPage() }
            else if result.direction < 0 { model.prevPage() }
        }
        return result.consumed
    }

    private func finishInteractiveScroll(direction: Int) {
        let canMove = direction > 0
            ? model.currentPage < model.pages.count - 1
            : direction < 0 ? model.currentPage > 0 : false
        guard direction != 0, canMove else {
            pageScrollSettling = true
            withAnimation(.easeOut(duration: 0.14)) { pageScrollState.setOffset(0) }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pageScroll.reset()
                self.pageScrollSettling = false
                self.pageScrollSettleWork = nil
                self.pageScrollState.endInteraction()
                self.finishScrollTrace()
            }
            pageScrollSettleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
            return
        }

        pageScrollSettling = true
        let width = max(1, window?.frame.width ?? 1)
        let destination = direction > 0 ? -width : width
        withAnimation(.easeOut(duration: 0.16)) {
            pageScrollState.setOffset(destination)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.suppressNextPageAnimation = true
            if direction > 0 { self.model.nextPage() } else { self.model.prevPage() }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { self.pageScrollState.setOffset(0) }
            self.pageScroll.reset()
            self.pageScrollSettling = false
            self.pageScrollSettleWork = nil
            self.pageScrollState.endInteraction()
            self.finishScrollTrace()
        }
        pageScrollSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func beginScrollTraceIfNeeded() {
        guard scrollTrace == nil else { return }
        scrollTrace = PerformanceTrace.begin("Page swipe")
        scrollStartedAt = ProcessInfo.processInfo.systemUptime
        startFramePulseMonitor()
    }

    private func finishScrollTrace() {
        guard let scrollTrace else { return }
        PerformanceTrace.end("Page swipe", id: scrollTrace)
        self.scrollTrace = nil
        stopFramePulseMonitor()
        if let scrollStartedAt {
            PerformanceMetrics.shared.recordSwipe(
                ProcessInfo.processInfo.systemUptime - scrollStartedAt,
                stalls: swipeStallCount)
        }
        self.scrollStartedAt = nil
    }

    /// Таймер на main queue измеряет не FPS видеокарты, а задержки самой
    /// очереди интерфейса. Несколько пропущенных 60-Hz интервалов означают, что
    /// тяжёлый SwiftUI/blur кадр блокировал обработку, и фон упрощается до конца жеста.
    private func startFramePulseMonitor() {
        stopFramePulseMonitor()
        let interval = 1.0 / 60.0
        swipeStallCount = 0
        expectedFramePulse = ProcessInfo.processInfo.systemUptime + interval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval,
                       repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let delay = now - self.expectedFramePulse
            self.expectedFramePulse = now + interval
            guard delay > 0.025 else { return }
            self.swipeStallCount += max(1, Int(delay / interval))
            if self.swipeStallCount >= 2,
               self.pageScrollState.enableLightweightBackground() {
                PerformanceMetrics.shared.recordAdaptiveActivation()
            }
        }
        framePulseTimer = timer
        timer.resume()
    }

    private func stopFramePulseMonitor() {
        framePulseTimer?.cancel()
        framePulseTimer = nil
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
        Task { await model.refreshApps() }
    }

    @objc private func openKeyboardHelp() {
        if window?.isVisible != true { show() }
        withAnimation(.easeOut(duration: 0.14)) {
            model.showsKeyboardHelp = true
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
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

    private func firstRunSetup() {
        let key = "didFirstRunSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        showOnboarding(completionKey: key)
    }

    private func showOnboarding(completionKey: String) {
        guard onboardingWindow == nil else { return }
        let view = OnboardingView(
            onFinish: { [weak self] launchAtLogin, keepAlive, autoUpdate, importLayout in
                guard let self else { return }
                let loginOK = LoginItem.isEnabled == launchAtLogin
                    || LoginItem.setEnabled(launchAtLogin)
                let keepAliveOK = KeepAliveService.isEnabled == keepAlive
                    || KeepAliveService.setEnabled(keepAlive)
                AppSettings.shared.autoUpdate = autoUpdate
                if importLayout { _ = self.model.importFromSystemLaunchpad() }
                UserDefaults.standard.set(true, forKey: completionKey)
                self.loginItemMenuItem?.state = LoginItem.isEnabled ? .on : .off
                self.keepAliveMenuItem?.state = KeepAliveService.isEnabled ? .on : .off
                self.autoUpdateMenuItem?.state = autoUpdate ? .on : .off
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
                self.scheduledUpdateCheck()
                if !loginOK || !keepAliveOK {
                    self.model.operationError = "Не все параметры фонового запуска удалось применить. Их можно изменить в настройках."
                    self.openSettings()
                } else {
                    self.show()
                }
            },
            onSkip: { [weak self] in
                AppSettings.shared.autoUpdate = false
                UserDefaults.standard.set(true, forKey: completionKey)
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 590),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Добро пожаловать в Launchpad"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Обновления

    @objc private func checkUpdatesClicked() {
        guard !isInstallingUpdate else { return }
        if let update = pendingUpdate {
            promptInstall(update)
            return
        }
        setUpdateStatus("Проверка обновлений…")
        Updater.checkForUpdate { [weak self] result in
            MainActor.assumeIsolated {
                if case .failure(let error) = result {
                    self?.setUpdateStatus("Ошибка проверки: \(error.localizedDescription)")
                    let alert = NSAlert()
                    alert.messageText = "Не удалось проверить обновления"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                } else if case .success(let update?) = result {
                    self?.pendingUpdate = update
                    self?.setUpdateStatus("Доступна версия \(update.version)")
                    self?.promptInstall(update)
                } else {
                    self?.setUpdateStatus("Установлена последняя версия")
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
        // Пока пользователь не выбрал политику первого запуска, не начинаем
        // даже фоновую загрузку обновления с прежним значением по умолчанию.
        guard !testingUI, onboardingWindow == nil else { return }
        Updater.checkForUpdate { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.setUpdateStatus("Ошибка проверки: \(error.localizedDescription)")
                case .success(nil):
                    self.setUpdateStatus("Проверено: обновлений нет")
                case .success(let update?):
                    self.pendingUpdate = update
                    self.updateMenuItem?.title = "Обновить до \(update.version)…"
                    self.setUpdateStatus("Доступна версия \(update.version)")
                    if AppSettings.shared.autoUpdate && self.window?.isVisible != true {
                        self.install(update)
                    }
                }
            }
        }
    }

    @objc private func toggleAutoUpdate() {
        AppSettings.shared.autoUpdate.toggle()
        autoUpdateMenuItem?.state = AppSettings.shared.autoUpdate ? .on : .off
        // Только что включили и обновление уже найдено — поставить сразу (если скрыт).
        if AppSettings.shared.autoUpdate, let update = pendingUpdate, window?.isVisible != true {
            install(update)
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
            install(update)
        }
    }

    private func install(_ update: Updater.Update) {
        guard !isInstallingUpdate else { return }
        isInstallingUpdate = true
        updateMenuItem?.isEnabled = false
        Updater.downloadAndInstall(update) { [weak self] status in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setUpdateStatus(status)
                if status.hasPrefix("Ошибка:") {
                    self.isInstallingUpdate = false
                    self.updateMenuItem?.isEnabled = true
                    self.updateMenuItem?.title = "Повторить обновление до \(update.version)…"
                }
            }
        }
    }

    private func setUpdateStatus(_ status: String) {
        updateStatusMenuItem?.title = status
        updateStatusMenuItem?.toolTip = status
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate, NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoLayout) {
            menuItem.title = textUndoManager == nil ? model.undoTitle : "Отменить ввод"
            return textUndoManager?.canUndo ?? (model.canUndo && !model.layoutInteractionActive)
        }
        if menuItem.action == #selector(redoLayout) {
            menuItem.title = textUndoManager == nil ? model.redoTitle : "Повторить ввод"
            return textUndoManager?.canRedo ?? (model.canRedo && !model.layoutInteractionActive)
        }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Актуализируем галочки при открытии меню.
        loginItemMenuItem?.state = LoginItem.isEnabled ? .on : .off
        keepAliveMenuItem?.state = KeepAliveService.isEnabled ? .on : .off
        autoUpdateMenuItem?.state = AppSettings.shared.autoUpdate ? .on : .off
    }
}
