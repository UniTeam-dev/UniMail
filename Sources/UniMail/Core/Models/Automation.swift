import Foundation

/// Шаблон письма (быстрый ответ).
struct MailTemplate: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var subject: String
    var body: String
}

/// Правило обработки входящих: если все (или любое) условия выполнены — применить действия.
struct MailRule: Codable, Identifiable, Hashable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable { case from, to, subject, body, anyAddress }
    enum Match: String, Codable, CaseIterable, Sendable { case contains, notContains, equals, startsWith, endsWith }

    struct Condition: Codable, Hashable, Sendable {
        var field: Field
        var match: Match
        var value: String
    }

    enum Action: Codable, Hashable, Sendable {
        case moveTo(MailboxRole)
        case markRead
        case flag
        case setCategory(InboxCategory)
        case snooze(hours: Int)
        case notify(Bool)
    }

    var id: UUID = UUID()
    var name: String
    var isEnabled: Bool = true
    /// nil — для всех ящиков.
    var accountID: UUID?
    var matchAll: Bool = true
    var conditions: [Condition]
    var actions: [Action]
    var stopProcessing: Bool = false
}

/// Ручная поправка категории: «письма от этого отправителя — в Рассылки».
struct CategoryOverride: Codable, Hashable, Sendable {
    /// Адрес целиком (a@b.ru) или домен (@b.ru).
    var key: String
    var category: InboxCategory
}
