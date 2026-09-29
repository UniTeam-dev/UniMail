import Foundation

/// Разбор строки поиска: свободный текст + токены
/// `from:` `to:` `subject:` `has:attachment` `is:unread` `is:flagged`.
struct SearchQuery {
    var terms: [String] = []
    var from: String?
    var to: String?
    var subject: String?
    var hasAttachment = false
    var isUnread = false
    var isFlagged = false

    var isEmpty: Bool {
        terms.isEmpty && from == nil && to == nil && subject == nil && !hasAttachment && !isUnread && !isFlagged
    }

    init(_ raw: String) {
        for token in raw.lowercased().split(separator: " ").map(String.init) {
            if token.hasPrefix("from:") { from = String(token.dropFirst(5)) }
            else if token.hasPrefix("to:") { to = String(token.dropFirst(3)) }
            else if token.hasPrefix("subject:") { subject = String(token.dropFirst(8)) }
            else if token == "has:attachment" || token == "has:вложение" { hasAttachment = true }
            else if token == "is:unread" { isUnread = true }
            else if token == "is:flagged" { isFlagged = true }
            else if !token.isEmpty { terms.append(token) }
        }
    }

    func matches(_ m: Message) -> Bool {
        if hasAttachment && m.attachments.isEmpty { return false }
        if isUnread && m.isRead { return false }
        if isFlagged && !m.isFlagged { return false }
        if let from, !(m.from.email.lowercased().contains(from) || m.from.display.lowercased().contains(from)) { return false }
        if let to, !m.to.contains(where: { $0.email.lowercased().contains(to) || $0.display.lowercased().contains(to) }) { return false }
        if let subject, !m.subject.lowercased().contains(subject) { return false }
        if terms.isEmpty { return true }
        let haystack = [m.subject, m.body, m.from.display, m.from.email]
            .joined(separator: " ")
            .lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}
