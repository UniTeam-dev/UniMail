import Foundation

/// Применение пользовательских правил к входящему письму.
///
/// - Правила проверяются по порядку; выключенные и правила чужого ящика (`accountID`) пропускаются.
/// - `matchAll` — нужны все условия, иначе хватает любого. Условия с пустым значением игнорируются;
///   правило без непустых условий не срабатывает никогда (защита от «правила на всё» из пустой формы).
/// - Сравнение без учёта регистра и диакритики, в том числе для кириллицы (ё = е), одинаково на macOS и Linux.
/// - Для адресных полей условие проверяется по e-mail, имени и «Имя <e-mail>»: позитивные операторы
///   срабатывают, если подошёл хоть один вариант; `notContains` — если не подошёл ни один.
/// - Действия выполняются в порядке записи; `stopProcessing` останавливает проверку следующих правил.
///
/// Уведомление: явное действие `notify(_:)` (последнее побеждает), иначе по умолчанию —
/// да, если письмо после правил осталось во «Входящих», не прочитано и не в «Рассылках».
enum RuleEngine {
    static func apply(_ rules: [MailRule], to message: Message) -> (Message, notify: Bool) {
        apply(rules, to: message, now: Date())
    }

    /// То же с явным «сейчас» — для отложенных писем (`snooze`) и тестов.
    static func apply(_ rules: [MailRule], to message: Message, now: Date) -> (Message, notify: Bool) {
        var result = message
        var explicitNotify: Bool?
        for rule in rules where rule.isEnabled {
            guard matches(rule, result) else { continue }
            for action in rule.actions {
                perform(action, on: &result, now: now, notify: &explicitNotify)
            }
            if rule.stopProcessing { break }
        }
        let notify = explicitNotify ?? defaultNotify(for: result)
        return (result, notify)
    }

    /// Уведомлять ли о письме, если правила ничего не сказали явно.
    static func defaultNotify(for message: Message) -> Bool {
        message.category != .newsletters && message.role == .inbox && !message.isRead
    }

    // MARK: - Условия

    /// Подходит ли письмо под правило (включённость не проверяется — её смотрит `apply`).
    static func matches(_ rule: MailRule, _ message: Message) -> Bool {
        if let accountID = rule.accountID, accountID != message.accountID { return false }
        let effective = rule.conditions.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !effective.isEmpty else { return false }
        return rule.matchAll
            ? effective.allSatisfy { matches($0, message) }
            : effective.contains { matches($0, message) }
    }

    static func matches(_ condition: MailRule.Condition, _ message: Message) -> Bool {
        let needle = fold(condition.value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return false }
        let haystacks = candidates(for: condition.field, in: message).map(fold)
        switch condition.match {
        case .contains: return haystacks.contains { $0.contains(needle) }
        case .notContains: return !haystacks.contains { $0.contains(needle) }
        case .equals: return haystacks.contains { $0 == needle }
        case .startsWith: return haystacks.contains { $0.hasPrefix(needle) }
        case .endsWith: return haystacks.contains { $0.hasSuffix(needle) }
        }
    }

    /// Строки, с которыми сравнивается условие.
    static func candidates(for field: MailRule.Field, in message: Message) -> [String] {
        func variants(_ a: Address) -> [String] {
            var result = [a.email]
            if let name = a.name, !name.isEmpty { result += [name, "\(name) <\(a.email)>"] }
            return result
        }
        switch field {
        case .from: return variants(message.from)
        case .to: return (message.to + message.cc).flatMap(variants)
        case .anyAddress: return ([message.from] + message.to + message.cc).flatMap(variants)
        case .subject: return [message.subject]
        case .body: return [message.body]
        }
    }

    /// Свёртка для сравнения: регистр и диакритика (ё → е, é → e), пробелы по краям.
    /// `folding(options:locale:)` есть и в swift-corelibs-foundation, поэтому поведение совпадает с macOS.
    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Действия

    private static func perform(_ action: MailRule.Action, on message: inout Message, now: Date, notify: inout Bool?) {
        switch action {
        case .moveTo(let role):
            message.role = role
            if role != .snoozed { message.snoozedUntil = nil }
        case .markRead:
            message.isRead = true
        case .flag:
            message.isFlagged = true
        case .setCategory(let category):
            message.category = category
        case .snooze(let hours):
            guard hours > 0 else { return }
            message.role = .snoozed
            message.snoozedUntil = now.addingTimeInterval(TimeInterval(hours) * 3600)
            // Как у ручного «Отложить»: вернётся непрочитанным, когда подойдёт время.
            message.isRead = true
        case .notify(let value):
            notify = value
        }
    }
}
