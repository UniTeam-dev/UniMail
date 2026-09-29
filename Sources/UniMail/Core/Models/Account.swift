import Foundation

/// Тип подключения. Все реальные ящики работают по IMAP/SMTP с паролем;
/// тип задаёт пресет серверов и подсказки в мастере.
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
        case .outlook: "Outlook / Exchange"
        case .icloud: "iCloud"
        case .imap: "Другой IMAP"
        case .demo: "Демо"
        }
    }

    /// Подпись на карточке мастера.
    var subtitle: String {
        switch self {
        case .gmail: "Пароль приложения"
        case .outlook: "Корпоративный сервер"
        case .icloud: "Пароль приложения"
        case .imap: "Любой сервер"
        case .demo: "Ящик с примерами"
        }
    }

    /// Подзаголовок на втором шаге мастера.
    var detail: String {
        switch self {
        case .gmail: "Нужны двухэтапная аутентификация и пароль приложения Google"
        case .outlook: "Exchange: доменный логин и пароль"
        case .icloud: "Пароль приложения с account.apple.com"
        case .imap: "Fastmail, Яндекс, Mail.ru, собственный сервер"
        case .demo: "Тестовые письма, чтобы посмотреть интерфейс"
        }
    }

    /// Буква на плитке (для Gmail и Outlook) или символ SF Symbols.
    var letter: String? {
        switch self {
        case .gmail: "G"
        case .outlook: "O"
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .gmail: "envelope.fill"
        case .outlook: "building.2.fill"
        case .icloud: "icloud.fill"
        case .imap: "server.rack"
        case .demo: "testtube.2"
        }
    }

    /// Цвет плитки в мастере (hex).
    var tileHex: UInt32 {
        switch self {
        case .gmail: 0xF04545
        case .outlook: 0x3B82F6
        case .icloud: 0x14B8BF
        case .imap: 0x5C5C66
        case .demo: 0x8C5CF5
        }
    }

    /// Этап плана, на котором появится настоящая синхронизация.
    var isAvailable: Bool { self == .demo }

    /// Все реальные аккаунты подключаются по IMAP/SMTP с паролем.
    var usesPassword: Bool { self != .demo }
}

/// Цвет аккаунта — метка в едином ящике и в панели аккаунтов. Порядок — как в макете.
enum AccountTint: String, Codable, CaseIterable, Sendable {
    case blue, orange, purple, pink, green, teal, indigo, red

    var title: String {
        switch self {
        case .blue: "Синий"
        case .orange: "Оранжевый"
        case .purple: "Фиолетовый"
        case .pink: "Розовый"
        case .green: "Зелёный"
        case .teal: "Бирюзовый"
        case .indigo: "Индиго"
        case .red: "Красный"
        }
    }
}

enum ConnectionSecurity: String, Codable, CaseIterable, Sendable {
    case tls, starttls
    var title: String { self == .tls ? "SSL/TLS" : "STARTTLS" }
}

/// Настройки сервера для IMAP/SMTP-аккаунтов. Пароль хранится в Keychain, не здесь.
struct ServerSettings: Codable, Hashable, Sendable {
    var imapHost: String
    var imapPort: Int = 993
    var smtpHost: String
    var smtpPort: Int = 465
    var username: String
    var imapSecurity: ConnectionSecurity? = .tls
    var smtpSecurity: ConnectionSecurity? = .tls
}

struct Account: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Название ящика: «Работа», «Личное».
    var displayName: String
    var email: String
    var kind: ProviderKind
    var tint: AccountTint
    var server: ServerSettings?
    var signature: String = ""
    /// Дополнительные адреса отправителя (алиасы, Gmail «Send mail as»).
    var aliases: [String] = []
    /// Имя отправителя в письмах: «Анна Волкова».
    var senderName: String?
    /// Скрыт из «Все ящики».
    var hiddenFromUnified: Bool?
    /// Подпись под адресом в настройках и палитре: «Google Workspace», «IMAP · Fastmail».
    var providerLabel: String?

    /// Буква на плитке аккаунта.
    var initial: String { String(displayName.prefix(1)).uppercased() }
    var initials: String { initial }

    var providerTitle: String {
        if let providerLabel { return providerLabel }
        switch kind {
        case .gmail: return "Gmail"
        case .outlook: return "Exchange"
        case .icloud: return "iCloud"
        case .imap: return "IMAP · \(server?.imapHost ?? "")"
        case .demo: return "Демо"
        }
    }
}
