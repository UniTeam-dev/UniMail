import Foundation

// Подписи и краткие описания правил для настроек. Без SwiftUI — проверяются на Linux.

extension MailRule.Field {
    var title: String {
        switch self {
        case .from: "От"
        case .to: "Кому"
        case .subject: "Тема"
        case .body: "Текст"
        case .anyAddress: "Любой адрес"
        }
    }
}

extension MailRule.Match {
    var title: String {
        switch self {
        case .contains: "содержит"
        case .notContains: "не содержит"
        case .equals: "равно"
        case .startsWith: "начинается с"
        case .endsWith: "заканчивается на"
        }
    }
}

extension MailRule.Action {
    /// Тип действия без параметра — для пикера в редакторе.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case moveTo, markRead, flag, setCategory, snooze, notify

        var id: String { rawValue }

        var title: String {
            switch self {
            case .moveTo: "Переместить в"
            case .markRead: "Отметить прочитанным"
            case .flag: "Поставить флажок"
            case .setCategory: "Категория"
            case .snooze: "Отложить на"
            case .notify: "Уведомление"
            }
        }

        /// Действие с параметром по умолчанию.
        var defaultAction: MailRule.Action {
            switch self {
            case .moveTo: .moveTo(.archive)
            case .markRead: .markRead
            case .flag: .flag
            case .setCategory: .setCategory(.newsletters)
            case .snooze: .snooze(hours: 3)
            case .notify: .notify(false)
            }
        }
    }

    var kind: Kind {
        switch self {
        case .moveTo: .moveTo
        case .markRead: .markRead
        case .flag: .flag
        case .setCategory: .setCategory
        case .snooze: .snooze
        case .notify: .notify
        }
    }

    /// Папки, доступные в действии «Переместить в».
    static let movableRoles: [MailboxRole] = [.inbox, .archive, .spam, .trash]

    /// «в Архив», «прочитано», «отложить на 3 часа».
    var summary: String {
        switch self {
        case .moveTo(let role): "в «\(role.title)»"
        case .markRead: "прочитано"
        case .flag: "флажок"
        case .setCategory(let category): "в «\(category.title)»"
        case .snooze(let hours): "отложить на \(MailRule.Action.hoursText(hours))"
        case .notify(let on): on ? "с уведомлением" : "без уведомления"
        }
    }

    /// «1 час», «3 часа», «2 дня» (кратные 24 — в днях).
    static func hoursText(_ hours: Int) -> String {
        if hours >= 24 && hours % 24 == 0 {
            let d = hours / 24
            return "\(d) \(plural(d, "день", "дня", "дней"))"
        }
        return "\(hours) \(plural(hours, "час", "часа", "часов"))"
    }
}

extension MailRule.Condition {
    /// «От содержит «github»».
    var summary: String { "\(field.title) \(match.title) «\(value)»" }
}

extension MailRule {
    /// Новое пустое правило для редактора.
    static func blank() -> MailRule {
        MailRule(name: "Новое правило",
                 conditions: [Condition(field: .from, match: .contains, value: "")],
                 actions: [.moveTo(.archive)])
    }

    /// Непустые условия — только они участвуют в проверке.
    var effectiveConditions: [Condition] {
        conditions.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Строка под названием правила: «От содержит «github» и Тема содержит «PR» → в «Архив», прочитано».
    var summary: String {
        let conds = effectiveConditions
        let left = conds.isEmpty ? "Нет условий" : conds.map(\.summary).joined(separator: matchAll ? " и " : " или ")
        let right = actions.isEmpty ? "ничего не делать" : actions.map(\.summary).joined(separator: ", ")
        return left + " → " + right + (stopProcessing ? " · стоп" : "")
    }
}

extension CategoryOverride {
    var isDomain: Bool { key.hasPrefix("@") }
    /// «Все с @b.ru» или сам адрес.
    var displayKey: String { isDomain ? "Все с \(key)" : key }
}
