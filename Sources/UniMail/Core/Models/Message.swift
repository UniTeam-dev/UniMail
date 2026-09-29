import Foundation

/// Системная роль папки. Одинаковые роли разных аккаунтов объединяются в едином ящике.
enum MailboxRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox, snoozed, flagged, drafts, scheduled, sent, archive, spam, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: "Входящие"
        case .snoozed: "Отложенные"
        case .flagged: "Отмеченные"
        case .drafts: "Черновики"
        case .scheduled: "Запланированные"
        case .sent: "Отправленные"
        case .archive: "Архив"
        case .spam: "Спам"
        case .trash: "Корзина"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .snoozed: "clock"
        case .flagged: "flag"
        case .drafts: "doc"
        case .scheduled: "calendar.badge.clock"
        case .sent: "paperplane"
        case .archive: "archivebox"
        case .spam: "xmark.bin"
        case .trash: "trash"
        }
    }

    var selectedSymbol: String {
        self == .scheduled ? symbol : "\(symbol).fill"
    }

    /// Показывать ли счётчик непрочитанных (у «Отправленных» он бессмысленен).
    var countsUnread: Bool { [.inbox, .snoozed, .flagged, .spam].contains(self) }
}

struct Address: Codable, Hashable, Sendable {
    var name: String?
    var email: String

    var display: String { name?.isEmpty == false ? name! : email }
    var full: String { name.map { "\($0) <\(email)>" } ?? email }

    var initials: String {
        let base = display
        let parts = base.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct Attachment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var filename: String
    var size: Int
    var mimeType: String

    var symbol: String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType.contains("spreadsheet") || filename.hasSuffix(".xlsx") { return "tablecells" }
        if mimeType.contains("zip") { return "doc.zipper" }
        return "doc"
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

/// Автоматическая категория входящих.
enum InboxCategory: String, Codable, CaseIterable, Sendable {
    case people, notifications, newsletters

    var title: String {
        switch self {
        case .people: "Люди"
        case .notifications: "Уведомления"
        case .newsletters: "Рассылки"
        }
    }
}

struct Message: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var accountID: UUID
    var threadID: String
    var role: MailboxRole
    var from: Address
    var to: [Address]
    var cc: [Address] = []
    var subject: String
    var body: String
    var htmlBody: String?
    var date: Date
    var isRead: Bool
    var isFlagged: Bool = false
    var attachments: [Attachment] = []
    var category: InboxCategory = .people
    var snoozedUntil: Date?
    var scheduledAt: Date?
    /// Есть ли в письме приглашение в календарь (.ics).
    var hasInvite: Bool = false

    var snippet: String {
        body.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .prefix(160)
            .description
    }
}

/// Черновик / исходящее письмо.
struct OutgoingMessage: Codable, Hashable, Sendable {
    var accountID: UUID
    var fromAddress: String
    var to: [Address]
    var cc: [Address]
    var bcc: [Address]
    var subject: String
    var body: String
    var inReplyTo: String?
    var threadID: String?
    var sendAt: Date?
    /// Отправить каждому получателю отдельное письмо.
    var sendSeparately: Bool = false
}
