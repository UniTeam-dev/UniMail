import Foundation

/// Системная роль папки. Одинаковые роли разных аккаунтов объединяются в едином ящике.
enum MailboxRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox, snoozed, flagged, drafts, scheduled, sent, archive, spam, trash
    /// Своя папка на сервере (Outlook, Gmail-ярлык, папка IMAP). Какая именно — в `Message.folder`.
    case custom

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
        case .custom: "Папка"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .snoozed: "clock"
        case .flagged: "flag"
        case .drafts: "doc"
        case .scheduled: "paperplane.circle"
        case .sent: "paperplane"
        case .archive: "archivebox"
        case .spam: "exclamationmark.octagon"
        case .trash: "trash"
        case .custom: "folder"
        }
    }

    var selectedSymbol: String { "\(symbol).fill" }

    /// Основные папки и «Ещё» — как в макете.
    static let primary: [MailboxRole] = [.inbox, .snoozed, .flagged, .drafts, .scheduled, .sent]
    static let secondary: [MailboxRole] = [.archive, .spam, .trash]
    /// Папки в меню «Перейти» (свои папки — отдельно).
    static let navigable: [MailboxRole] = primary + secondary

    /// Какой счётчик показывать у папки: непрочитанные, всего или ничего.
    enum Counter { case unread, total, none }
    var counter: Counter {
        switch self {
        case .inbox: .unread
        case .snoozed, .flagged, .drafts, .scheduled, .spam: .total
        case .sent, .archive, .trash: .none
        case .custom: .unread
        }
    }
}

struct Address: Codable, Hashable, Sendable {
    var name: String?
    var email: String

    var display: String { name?.isEmpty == false ? name! : email }
    var full: String { name.map { "\($0) <\(email)>" } ?? email }

    var initials: String {
        let parts = display.split(whereSeparator: { $0 == " " || $0 == "·" }).prefix(2)
        let value = parts.compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "?" : value
    }

    var isValid: Bool {
        email.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-zА-Яа-я]{2,}$"#, options: .regularExpression) != nil
    }
}

struct Attachment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var filename: String
    var size: Int
    var mimeType: String
    /// Номер MIME-части на сервере (IMAP BODY[1.2]) — для ленивой загрузки.
    var partID: String?
    /// Content-ID для встроенных картинок (cid:).
    var contentID: String?
    /// Путь к скачанному файлу в кэше.
    var localPath: String?

    enum Kind { case pdf, design, image, table, slides, archive, document }

    var kind: Kind {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "fig", "sketch", "psd": return .design
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return .image
        case "xlsx", "xls", "csv", "numbers": return .table
        case "key", "pptx", "ppt": return .slides
        case "zip", "rar", "7z": return .archive
        default: return mimeType.hasPrefix("image/") ? .image : .document
        }
    }

    var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
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

    var shortTitle: String { self == .notifications ? "Уведомл." : title }
}

/// Приглашение в календарь из письма (.ics).
struct Invite: Codable, Hashable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var location: String
    /// Организатор и исходный iCalendar — чтобы ответить (METHOD:REPLY).
    var organizer: Address?
    var ics: String?
    /// Ответ, который мы уже отправили: ACCEPTED / TENTATIVE / DECLINED.
    var response: String?
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
    var invite: Invite?
    /// Одноразовый код, если провайдер или разбор письма его нашёл.
    var oneTimeCode: String?

    // MARK: Поля синхронизации (для демо — nil)

    /// Имя папки на сервере и UID внутри неё.
    var folder: String?
    var uid: UInt32?
    /// Заголовки для тредов и ответов.
    var headerMessageID: String?
    var inReplyToHeader: String?
    var references: [String]?
    /// List-Unsubscribe (mailto: или https:) и поддержка one-click (RFC 8058).
    var listUnsubscribe: String?
    var listUnsubscribePost: Bool?
    /// Метки Gmail (X-GM-LABELS).
    var labels: [String]?
    /// Тело ещё не скачано — только заголовки и превью.
    var bodyPending: Bool?
    /// Ждём ответа на это исходящее письмо до указанной даты (follow-up).
    var followUpAt: Date?
    /// Входящее вернулось из follow-up: «Нет ответа».
    var noReplyNotice: Bool?
    /// Есть вложения (известно по BODYSTRUCTURE до скачивания тела).
    var attachmentHint: Bool?

    var hasAttachments: Bool { !attachments.isEmpty || attachmentHint == true }

    var hasInvite: Bool { invite != nil }

    var snippet: String {
        body.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .prefix(180)
            .description
    }

    /// Абзацы тела для экрана чтения.
    var paragraphs: [String] {
        body.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Код подтверждения: из поля или найденный в теме и тексте.
    var detectedCode: String? {
        if let oneTimeCode { return oneTimeCode }
        let text = subject + " " + body
        let lower = text.lowercased()
        guard lower.contains("код") || lower.contains("code") else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{3})[ -]?(\d{3})\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text),
              let b = Range(match.range(at: 2), in: text) else { return nil }
        return "\(text[a]) \(text[b])"
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
    /// Напомнить, если на письмо не ответят.
    var remindIfNoReply: Bool = false
    /// Текст в HTML, если письмо писали с форматированием.
    var htmlBody: String?
    /// Вложенные файлы.
    var attachmentURLs: [URL] = []
    /// Заголовки для треда на сервере (заполняет MailStore перед отправкой).
    var inReplyToHeader: String?
    var referenceHeaders: [String]?
    /// Ответ на приглашение (iCalendar METHOD:REPLY) или само приглашение (REQUEST / CANCEL).
    var calendarReply: String?
    /// METHOD части text/calendar: nil — REPLY.
    var calendarMethod: String?
}

/// Склонение: 1 письмо, 2 письма, 5 писем.
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}
