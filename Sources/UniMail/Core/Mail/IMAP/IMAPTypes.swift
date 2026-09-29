import Foundation

// MARK: - Публичные типы IMAP-модуля (см. docs/ARCHITECTURE.md, раздел «Core/Mail/IMAP»)

/// Папка IMAP. `name` — полный путь в обычном Unicode (уже декодирован из modified UTF-7).
struct IMAPFolder: Sendable, Hashable {
    var name: String
    var delimiter: String?
    /// Атрибуты как прислал сервер: `\HasNoChildren`, `\Sent`, `\Noselect`…
    var attributes: Set<String>
    /// Системная роль: из SPECIAL-USE или по эвристике имени.
    var role: MailboxRole?

    /// Папку можно открыть через SELECT.
    var isSelectable: Bool {
        !attributes.contains { a in
            let l = a.lowercased()
            return l == "\\noselect" || l == "\\nonexistent"
        }
    }

    /// Последний компонент пути («Работа/Отчёты» → «Отчёты»).
    var displayName: String {
        guard let delimiter, !delimiter.isEmpty else { return name }
        return name.components(separatedBy: delimiter).last ?? name
    }
}

/// Результат SELECT/EXAMINE.
struct IMAPSelectInfo: Sendable {
    /// 0, если сервер не прислал UIDVALIDITY (некорректный сервер).
    var uidValidity: UInt32
    var uidNext: UInt32?
    var exists: Int
    var highestModSeq: UInt64?
}

/// ENVELOPE письма (RFC 3501 §7.4.2) с уже декодированными RFC 2047 темой и именами.
struct IMAPEnvelope: Sendable {
    var date: Date?
    var subject: String?
    var from: [Address]
    var to: [Address]
    var cc: [Address]
    var replyTo: [Address]
    var messageID: String?
    var inReplyTo: String?

    init(date: Date? = nil, subject: String? = nil, from: [Address] = [], to: [Address] = [],
         cc: [Address] = [], replyTo: [Address] = [], messageID: String? = nil, inReplyTo: String? = nil) {
        self.date = date
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.replyTo = replyTo
        self.messageID = messageID
        self.inReplyTo = inReplyTo
    }
}

/// Сводка письма для списка: всё, что нужно без скачивания тела.
struct IMAPMessageSummary: Sendable {
    var uid: UInt32
    var flags: Set<String>
    var internalDate: Date?
    var size: Int?
    var modSeq: UInt64?
    var envelope: IMAPEnvelope
    var gmailThreadID: UInt64?
    var gmailLabels: [String]
    /// Ключи в нижнем регистре: references, list-unsubscribe, list-unsubscribe-post, content-type.
    var headers: [String: String]
    /// multipart/mixed с вложением или есть часть с Content-Disposition: attachment.
    var hasAttachments: Bool
    /// Первые ~200 символов текста, если превью запрашивалось.
    var preview: String?
}

/// Изменение флагов (для синхронизации по CONDSTORE или полной сверки).
struct IMAPFlagUpdate: Sendable {
    var uid: UInt32
    var flags: Set<String>
    var modSeq: UInt64?
}

enum IMAPError: LocalizedError {
    /// Сервер ответил NO.
    case no(String)
    /// Сервер ответил BAD (ошибка протокола/синтаксиса).
    case bad(String)
    /// Неожиданный ответ или разрыв (BYE, битый ответ, нет нужных данных).
    case unexpected(String)
    /// Неверный логин/пароль или метод входа недоступен.
    case authenticationFailed(String)

    var errorDescription: String? {
        switch self {
        case .no(let s): "Сервер отклонил команду: \(s)"
        case .bad(let s): "Ошибка протокола IMAP: \(s)"
        case .unexpected(let s): "Неожиданный ответ сервера: \(s)"
        case .authenticationFailed(let s): "Не удалось войти: \(s)"
        }
    }
}
