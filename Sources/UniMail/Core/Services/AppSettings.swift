import Foundation

/// Ключи пользовательских настроек сервисов (@AppStorage / UserDefaults) и их значения по умолчанию.
///
/// Значения по умолчанию регистрируются один раз при старте (`registerDefaults()`),
/// поэтому `UserDefaults.standard.bool(forKey:)` в сервисах и `@AppStorage` во вью
/// видят одно и то же, даже если пользователь ещё не открывал настройки.
enum AppSettings {
    /// Показывать уведомления о новых письмах.
    static let notificationsEnabled = "notificationsEnabled"
    /// Уведомлять и о рассылках (категория «Рассылки»). По умолчанию выключено.
    static let notifyNewsletters = "notifyNewsletters"
    /// Иконка в строке меню.
    static let showMenuBarExtra = "showMenuBarExtra"
    /// Число непрочитанных на иконке в Dock.
    static let showDockBadge = "showDockBadge"
    /// При автозапуске (вход в систему) не показывать главное окно.
    static let startHidden = "startHidden"
    /// AI-функции (сводка, черновик). Выключены по умолчанию.
    static let aiEnabled = "aiEnabled"
    /// Идентификатор модели Anthropic.
    static let aiModel = "aiModel"

    static let defaultAIModel = "claude-sonnet-4-5"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            notificationsEnabled: true,
            notifyNewsletters: false,
            showMenuBarExtra: true,
            showDockBadge: true,
            startHidden: false,
            aiEnabled: false,
            aiModel: defaultAIModel,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    static var model: String {
        let value = UserDefaults.standard.string(forKey: aiModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultAIModel : value
    }
}
