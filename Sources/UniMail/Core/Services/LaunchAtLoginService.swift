import AppKit
import Foundation
import Observation
import ServiceManagement

/// Автозапуск при входе в систему через `SMAppService.mainApp` (macOS 13+).
///
/// Как понять, что нас запустили при входе: macOS присылает событие «открыть приложение»
/// (`kAEOpenApplication`) с параметром `keyAELaunchedAsLogInItem`. Его нужно прочитать
/// в `applicationDidFinishLaunching` — позже текущее Apple Event уже другое.
/// Для отладки то же поведение включает переменная окружения `UNIMAIL_LAUNCHED_AT_LOGIN=1`.
@MainActor
@Observable
final class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?
    /// Приложение запущено как объект входа (вычисляется в `captureLaunchContext()`).
    private(set) var wasLaunchedAtLogin = false

    /// Включено (или ждёт подтверждения пользователя в Системных настройках).
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    private init() {
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = enabled
                ? "Не удалось включить автозапуск: \(error.localizedDescription). Приложение должно быть подписано и лежать в «Программах»."
                : "Не удалось выключить автозапуск: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Системные настройки → Основные → Объекты входа (там пользователь подтверждает автозапуск).
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Вызывать из `applicationDidFinishLaunching`.
    func captureLaunchContext() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let fromLoginEvent = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let fromEnvironment = ProcessInfo.processInfo.environment["UNIMAIL_LAUNCHED_AT_LOGIN"] == "1"
        wasLaunchedAtLogin = fromLoginEvent || fromEnvironment
        refresh()
    }

    /// Стартовать без главного окна: запущены при входе и включено «Запускать скрытым».
    var shouldStartHidden: Bool {
        wasLaunchedAtLogin && AppSettings.bool(AppSettings.startHidden)
    }
}
