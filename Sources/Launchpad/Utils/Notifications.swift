import Foundation

extension Notification.Name {
    static let launchpadLaunchFailed = Notification.Name("launchpadLaunchFailed")
    /// Фоновая запись раскладки не удалась; object содержит текст ошибки.
    static let launchpadLayoutSaveFailed = Notification.Name("launchpadLayoutSaveFailed")
    /// Просьба закрыть окно Launchpad (например, после запуска приложения).
    static let launchpadShouldClose = Notification.Name("launchpadShouldClose")
    /// Просьба снова показать Launchpad (например, если приложение не запустилось).
    static let launchpadShouldShow = Notification.Name("launchpadShouldShow")
    /// Просьба переключить видимость окна Launchpad.
    static let launchpadToggle = Notification.Name("launchpadToggle")
    /// Настройки изменились (сетка / горячая клавиша).
    static let launchpadSettingsChanged = Notification.Name("launchpadSettingsChanged")
    /// Изменился набор пользовательских каталогов приложений.
    static let launchpadAppDirectoriesChanged = Notification.Name("launchpadAppDirectoriesChanged")
    /// Началась (object = true) или закончилась запись горячей клавиши в настройках:
    /// на это время глобальное сочетание снимается, иначе его нельзя записать.
    static let launchpadHotkeyRecording = Notification.Name("launchpadHotkeyRecording")
}
