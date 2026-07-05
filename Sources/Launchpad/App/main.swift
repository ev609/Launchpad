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

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
