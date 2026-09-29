import Foundation

/// Что сейчас открыто: папка одного аккаунта, та же папка во всех аккаунтах сразу или своя папка ящика.
enum MailScope: Hashable, Codable, Sendable {
    case unified(MailboxRole)
    case account(UUID, MailboxRole)
    /// Своя папка на сервере (ключ — `MailFolder.id`).
    case folder(UUID, String)

    var role: MailboxRole {
        switch self {
        case .unified(let role), .account(_, let role): role
        case .folder: .custom
        }
    }

    var accountID: UUID? {
        switch self {
        case .unified: nil
        case .account(let id, _), .folder(let id, _): id
        }
    }

    /// Ключ своей папки, если открыта она.
    var folderKey: String? {
        if case .folder(_, let key) = self { return key }
        return nil
    }

    func with(role: MailboxRole) -> MailScope {
        switch self {
        case .unified: .unified(role)
        case .account(let id, _), .folder(let id, _): .account(id, role)
        }
    }
}

/// Своя папка ящика на сервере: папки Outlook (в том числе куда раскладывают правила), ярлыки Gmail, папки IMAP.
struct MailFolder: Identifiable, Codable, Hashable, Sendable {
    /// Ключ папки: имя IMAP-папки или id папки Exchange.
    var id: String
    var name: String
    var parentID: String?
    /// Вложенность для отступа в списке (0 — верхний уровень).
    var depth: Int = 0
    /// Счётчики с сервера (Exchange); у IMAP — nil.
    var unread: Int?
    var total: Int?
}

/// Строка списка: тред, представленный последним письмом.
struct ThreadSummary: Identifiable, Hashable {
    var id: String            // threadID
    var latest: Message
    var messageIDs: [String]
    var participants: [Address]
    var count: Int
    var hasUnread: Bool
    var isFlagged: Bool
    var hasAttachments: Bool
}
