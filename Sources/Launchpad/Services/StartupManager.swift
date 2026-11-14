import Foundation

/// Согласованная политика фонового запуска.
///
/// Есть два механизма: login item (`SMAppService`) и LaunchAgent с авто-перезапуском.
/// LaunchAgent сам стартует при входе, поэтому включённые одновременно они запускали
/// два экземпляра. Здесь они взаимоисключающие: при авто-перезапуске login item снят.
enum StartupManager {
    /// Приложение стартует при входе — любым из двух механизмов.
    static var launchesAtLogin: Bool { LoginItem.isEnabled || KeepAliveService.isEnabled }

    static var keepsAlive: Bool { KeepAliveService.isEnabled }

    /// Применяет выбор пользователя. Возвращает false, если система что-то отклонила.
    @discardableResult
    static func apply(launchAtLogin: Bool, keepAlive: Bool) -> Bool {
        if keepAlive {
            guard KeepAliveService.isEnabled || KeepAliveService.setEnabled(true) else {
                // Авто-перезапуск не включился — хотя бы обычный автозапуск.
                _ = setLoginItem(true)
                return false
            }
            return setLoginItem(false)
        }
        let keepAliveOff = !KeepAliveService.isEnabled || KeepAliveService.setEnabled(false)
        return setLoginItem(launchAtLogin) && keepAliveOff
    }

    /// Переключатель «Запускать при входе». Выключение снимает и авто-перезапуск:
    /// LaunchAgent без старта при входе не бывает.
    @discardableResult
    static func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        apply(launchAtLogin: enabled, keepAlive: enabled && keepsAlive)
    }

    /// Переключатель «Перезапускать после сбоя». При выключении автозапуск при входе
    /// сохраняется через login item, если был включён.
    @discardableResult
    static func setKeepAlive(_ enabled: Bool) -> Bool {
        apply(launchAtLogin: enabled || launchesAtLogin, keepAlive: enabled)
    }

    /// Вызывается при каждом старте: снимает дубль автозапуска у тех, кто включил оба
    /// механизма в прежних версиях, и обновляет путь в LaunchAgent после переноса.
    static func repairOnLaunch() {
        if KeepAliveService.isEnabled, LoginItem.isEnabled {
            _ = setLoginItem(false)
        }
        KeepAliveService.repairProgramPathIfNeeded()
    }

    private static func setLoginItem(_ enabled: Bool) -> Bool {
        LoginItem.isEnabled == enabled || LoginItem.setEnabled(enabled)
    }
}
