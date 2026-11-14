import Carbon.HIToolbox

/// Регистрирует системную горячую клавишу через Carbon (работает без прав Accessibility).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private let callback: () -> Void
    private let id: UInt32

    /// Активные экземпляры по id — нужны, чтобы обработчик C-функции нашёл нужный callback.
    private final class WeakReference {
        weak var value: GlobalHotKey?
        init(_ value: GlobalHotKey) { self.value = value }
    }
    private static var instances: [UInt32: WeakReference] = [:]
    private static var handlerInstalled = false

    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32, callback: @escaping () -> Void) {
        self.callback = callback
        self.id = id
        guard GlobalHotKey.installHandlerIfNeeded(), GlobalHotKey.instances[id]?.value == nil else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C504144) /* 'LPAD' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            return nil
        }
        GlobalHotKey.instances[id] = WeakReference(self)
    }

    deinit { unregister() }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if GlobalHotKey.instances[id]?.value === self {
            GlobalHotKey.instances[id] = nil
        }
    }

    private static func installHandlerIfNeeded() -> Bool {
        if handlerInstalled { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            GlobalHotKey.instances[hkID.id]?.value?.callback()
            return noErr
        }, 1, &eventType, nil, nil)
        handlerInstalled = status == noErr
        return handlerInstalled
    }
}
