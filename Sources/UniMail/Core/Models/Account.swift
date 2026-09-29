import Foundation

/// Тип подключения. Определяет, какой провайдер обслуживает аккаунт.
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case gmail
    case outlook
    case icloud
    case imap
    case demo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: "Gmail"
        case .outlook: "Outlook / Microsoft 365"
        case .icloud: "iCloud"
        case .imap: "Другой IMAP"
        case .demo: "Демо-аккаунт"
        }
    }

    var subtitle: String {
        switch self {
        case .gmail: "Вход через Google"
        case .outlook: "Вход через Microsoft, включая Exchange Online"
        case .icloud: "Нужен пароль приложения с appleid.apple.com"
        case .imap: "Яндекс, Mail.ru, корпоративная почта"
        case .demo: "Тестовые письма, чтобы посмотреть интерфейс"
        }
    }

    var symbol: String {
        switch self {
        case .gmail: "envelope.badge"
        case .outlook: "building.2"
        case .icloud: "icloud"
        case .imap: "server.rack"
        case .demo: "sparkles"
        }
    }

    /// Этап плана, на котором появится настоящая синхронизация.
    var isAvailable: Bool { self == .demo }
}

/// Цвет аккаунта — метка в едином ящике и в панели аккаунтов.
enum AccountTint: String, Codable, CaseIterable, Sendable {
    case blue, purple, pink, orange, green, teal, indigo, red
}

/// Настройки сервера для IMAP/SMTP-аккаунтов. Пароль хранится в Keychain, не здесь.
struct ServerSettings: Codable, Hashable, Sendable {
    var imapHost: String
    var imapPort: Int = 993
    var smtpHost: String
    var smtpPort: Int = 465
    var username: String
}

struct Account: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var displayName: String
    var email: String
    var kind: ProviderKind
    var tint: AccountTint
    var server: ServerSettings?
    var signature: String = ""
    /// Дополнительные адреса отправителя (алиасы, Gmail «Send mail as»).
    var aliases: [String] = []

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? String(email.prefix(1)).uppercased() : letters.uppercased()
    }
}
