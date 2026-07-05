import Carbon.HIToolbox

/// Регистрирует системную горячую клавишу через Carbon (работает без прав Accessibility).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private let callback: () -> Void
    private let id: UInt32

    /// Активные экземпляры по id — нужны, чтобы обработчик C-функции нашёл нужный callback.
    private static var instances: [UInt32: GlobalHotKey] = [:]
    private static var handlerInstalled = false

    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32, callback: @escaping () -> Void) {
        self.callback = callback
        self.id = id
        GlobalHotKey.installHandlerIfNeeded()
        GlobalHotKey.instances[id] = self

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C504144) /* 'LPAD' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            GlobalHotKey.instances[id] = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        GlobalHotKey.instances[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            GlobalHotKey.instances[hkID.id]?.callback()
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
