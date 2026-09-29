import Foundation

/// Что сейчас открыто: папка одного аккаунта или та же папка во всех аккаунтах сразу.
enum MailScope: Hashable, Codable, Sendable {
    case unified(MailboxRole)
    case account(UUID, MailboxRole)

    var role: MailboxRole {
        switch self {
        case .unified(let role), .account(_, let role): role
        }
    }

    var accountID: UUID? {
        if case .account(let id, _) = self { return id }
        return nil
    }

    func with(role: MailboxRole) -> MailScope {
        switch self {
        case .unified: .unified(role)
        case .account(let id, _): .account(id, role)
        }
    }
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
