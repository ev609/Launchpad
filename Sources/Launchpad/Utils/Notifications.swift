import Foundation

extension Notification.Name {
    /// Просьба закрыть окно Launchpad (например, после запуска приложения).
    static let launchpadShouldClose = Notification.Name("launchpadShouldClose")
    /// Просьба переключить видимость окна Launchpad.
    static let launchpadToggle = Notification.Name("launchpadToggle")
}
