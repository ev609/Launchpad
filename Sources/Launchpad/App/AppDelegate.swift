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
    private var statusItem: NSStatusItem!
    private var hotKeys: [GlobalHotKey] = []

    // Мониторы событий (активны только при открытом окне).
    private var keyMonitor: Any?
    private var scrollAccumulator: CGFloat = 0
    private var scrollCooldown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.load()
        buildWindow()
        buildStatusItem()
        registerHotKeys()
        observeNotifications()
    }

    // MARK: - Построение UI

    private func buildWindow() {
        let screen = activeScreen()
        window = KeyableWindow(contentRect: screen.frame,
                               styleMask: .borderless,
                               backing: .buffered,
                               defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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
        menu.addItem(withTitle: "Открыть Launchpad", action: #selector(showLaunchpad), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Импортировать раскладку старого Launchpad",
                     action: #selector(importLayout), keyEquivalent: "")
        menu.addItem(withTitle: "Сбросить раскладку (по алфавиту)",
                     action: #selector(resetLayout), keyEquivalent: "")
        menu.addItem(withTitle: "Обновить список приложений",
                     action: #selector(rescan), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func registerHotKeys() {
        // F4 — классическая клавиша Launchpad.
        if let hk = GlobalHotKey(keyCode: UInt32(kVK_F4), modifiers: 0, id: 1,
                                 callback: { [weak self] in self?.toggle() }) {
            hotKeys.append(hk)
        }
        // ⌥⌘Space — запасная комбинация.
        let optCmd = UInt32(optionKey | cmdKey)
        if let hk = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: optCmd, id: 2,
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
    }

    func toggle() {
        window.isVisible ? hide() : show()
    }

    // MARK: - Мониторы клавиш и скролла

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        scrollAccumulator = 0
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            return handleKey(event)
        case .scrollWheel:
            handleScroll(event)
            return event
        default:
            return event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch Int(event.keyCode) {
        case kVK_Escape:
            if model.isSearching {
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
        // Горизонтальный скролл двумя пальцами листает страницы.
        let dx = event.scrollingDeltaX
        guard abs(dx) > abs(event.scrollingDeltaY) else { return }
        scrollAccumulator += dx
        guard !scrollCooldown, abs(scrollAccumulator) > 50 else { return }

        if scrollAccumulator < 0 { model.nextPage() } else { model.prevPage() }
        scrollAccumulator = 0
        scrollCooldown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.scrollCooldown = false
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
