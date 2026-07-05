import AppKit

// Точка входа. Приложение-агент: живёт в строке меню, без иконки в Dock.
// Верхний уровень исполняется в главном потоке, поэтому безопасно
// считать контекст изолированным на MainActor.
MainActor.assumeIsolated {
    // Диагностика: печатает результат сканирования и импорта раскладки, затем выходит.
    if CommandLine.arguments.contains("--dump-import") {
        Diagnostics.dumpImport()
        exit(0)
    }
    if CommandLine.arguments.contains("--mt-size") {
        print("MTTouch stride = \(MemoryLayout<MTTouch>.stride) (ожидается 96)")
        exit(0)
    }
    if CommandLine.arguments.contains("--login-test") {
        print("статус до: \(LoginItem.isEnabled)")
        _ = LoginItem.setEnabled(true)
        print("после register: \(LoginItem.isEnabled)")
        _ = LoginItem.setEnabled(false)
        print("после unregister: \(LoginItem.isEnabled)")
        exit(0)
    }
    if CommandLine.arguments.contains("--mt-log") {
        let mt = MultitouchManager()
        mt.logging = true
        mt.start()
        print("Устройств: \(mt.deviceCount). Сделайте щипок на трекпаде (10 сек)…")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        exit(0)
    }
    if CommandLine.arguments.contains("--mt-test") {
        let mt = MultitouchManager()
        mt.start()
        print("Трекпад-устройств найдено: \(mt.deviceCount)")
        print("Коснитесь трекпада несколькими пальцами (4 сек)…")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        print("Максимум одновременных касаний: \(mt.maxTouchesSeen)")
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
