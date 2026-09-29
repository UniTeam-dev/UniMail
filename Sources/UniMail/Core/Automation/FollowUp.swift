import Foundation

/// Напоминания «нет ответа» (follow-up) для исходящих писем.
///
/// Исходящее с `followUpAt` считается отвеченным, если в том же треде (`threadID`) есть
/// более новое письмо от кого-то другого — не от адреса отправителя исходящего и не с адресов
/// из `myAddresses` (алиасы, другие ящики пользователя). Черновики и запланированные
/// ответом не считаются.
enum FollowUp {
    /// Исходящие (`role == .sent`), у которых подошёл срок (`followUpAt <= now`) и нет ответа.
    /// Отсортированы по сроку напоминания.
    static func due(_ messages: [Message], now: Date) -> [Message] {
        due(messages, now: now, myAddresses: [])
    }

    static func due(_ messages: [Message], now: Date, myAddresses: Set<String>) -> [Message] {
        let byThread = Dictionary(grouping: messages, by: \.threadID)
        return messages
            .filter { m in
                guard m.role == .sent, let at = m.followUpAt, at <= now else { return false }
                return !hasReply(to: m, in: byThread[m.threadID] ?? [], myAddresses: myAddresses)
            }
            .sorted { ($0.followUpAt ?? .distantPast, $0.id) < ($1.followUpAt ?? .distantPast, $1.id) }
    }

    /// Id исходящих с `followUpAt`, на которые уже ответили, — напоминание можно снять
    /// (обнулить `followUpAt`, убрать `noReplyNotice`). Срок не важен.
    static func resolved(_ messages: [Message]) -> [String] {
        resolved(messages, myAddresses: [])
    }

    static func resolved(_ messages: [Message], myAddresses: Set<String>) -> [String] {
        let byThread = Dictionary(grouping: messages, by: \.threadID)
        return messages
            .filter { m in
                guard m.role == .sent, m.followUpAt != nil else { return false }
                return hasReply(to: m, in: byThread[m.threadID] ?? [], myAddresses: myAddresses)
            }
            .map(\.id)
            .sorted()
    }

    /// Есть ли в треде более новое письмо от другого человека.
    static func hasReply(to sent: Message, in thread: [Message], myAddresses: Set<String> = []) -> Bool {
        let mine = Set(myAddresses.map(Categorizer.normalize)).union([Categorizer.normalize(sent.from.email)])
        return thread.contains { other in
            other.id != sent.id
                && other.threadID == sent.threadID
                && other.date > sent.date
                && ![.sent, .drafts, .scheduled].contains(other.role)
                && !mine.contains(Categorizer.normalize(other.from.email))
        }
    }

    /// Когда напомнить об исходящем, отправленном `date`, через `days` дней.
    static func reminderDate(after date: Date, days: Int, calendar: Calendar = .current) -> Date {
        let days = max(1, days)
        return calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(TimeInterval(days) * 86_400)
    }
}
