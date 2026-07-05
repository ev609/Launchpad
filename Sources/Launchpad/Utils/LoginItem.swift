import Foundation
import ServiceManagement

/// Управление запуском приложения при входе в систему (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Включает или отключает автозапуск. Возвращает true при успехе.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("LoginItem: не удалось изменить автозапуск — \(error.localizedDescription)")
            return false
        }
    }
}
