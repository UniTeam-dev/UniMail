import Foundation
import Observation

/// Шаблоны, правила, выученные категории и срок follow-up.
///
/// Хранится в ~/Library/Application Support/UniMail/automation.json (атомарная запись).
/// Чтение терпимое: отсутствующие поля получают значения по умолчанию, битые элементы
/// массивов пропускаются, а нечитаемый файл откладывается в `automation.corrupt-<время>.json`,
/// чтобы следующее сохранение не стёрло его молча.
@MainActor
@Observable
final class AutomationStore {
    static let shared = AutomationStore()

    var templates: [MailTemplate]
    var rules: [MailRule]
    var categoryOverrides: [CategoryOverride]
    /// Через сколько дней напомнить, если на письмо не ответили.
    var followUpDays: Int

    nonisolated static let followUpRange = 1...30

    let fileURL: URL

    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("UniMail", isDirectory: true).appendingPathComponent("automation.json")
    }

    convenience init() {
        self.init(fileURL: AutomationStore.defaultFileURL)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        let loaded = AutomationStore.load(from: fileURL)
        templates = loaded.templates
        rules = loaded.rules
        categoryOverrides = loaded.categoryOverrides
        followUpDays = loaded.followUpDays
    }

    // MARK: - Сохранение

    @discardableResult
    func save() -> Bool {
        let file = AutomationFile(templates: templates, rules: rules, categoryOverrides: categoryOverrides,
                                  followUpDays: Self.clampDays(followUpDays))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("UniMail: не удалось сохранить automation.json: \(error)")
            return false
        }
    }

    private static func load(from url: URL) -> AutomationFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return .firstRun }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AutomationFile.self, from: data)
        } catch {
            NSLog("UniMail: automation.json не читается, беру значения по умолчанию: \(error)")
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent().appendingPathComponent("automation.corrupt-\(stamp).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            return .firstRun
        }
    }

    nonisolated static func clampDays(_ days: Int) -> Int {
        min(max(days, followUpRange.lowerBound), followUpRange.upperBound)
    }

    // MARK: - Категории

    /// Пользователь переложил письмо отправителя в категорию: запоминаем точный адрес.
    /// Если так же поправлены два разных адреса одного домена — добавляем правило на весь домен (`@домен`).
    /// Для бесплатных почтовиков (gmail.com, mail.ru…) домен не выучивается.
    func learnCategory(for address: Address, category: InboxCategory) {
        let email = Categorizer.normalize(address.email)
        guard !email.isEmpty, let domain = Categorizer.domain(of: email) else { return }
        setOverride(key: email, category: category)

        let sameDomain = Set(categoryOverrides
            .filter { !$0.isDomain && $0.category == category && Categorizer.domain(of: $0.key) == domain }
            .map { Categorizer.normalize($0.key) })
        if sameDomain.count >= 2 && !Categorizer.isPublicMailDomain(domain) {
            setOverride(key: "@" + domain, category: category)
        }
        save()
    }

    /// Убрать поправку по ключу (адрес или `@домен`).
    func removeOverride(_ key: String) {
        let key = Categorizer.normalize(key)
        categoryOverrides.removeAll { Categorizer.normalize($0.key) == key }
        save()
    }

    func removeOverride(_ override: CategoryOverride) {
        removeOverride(override.key)
    }

    /// Ручная категория для адреса, если она есть (точный адрес → домен).
    func overrideCategory(for address: Address) -> InboxCategory? {
        Categorizer.overrideCategory(for: address.email, overrides: categoryOverrides)
    }

    private func setOverride(key: String, category: InboxCategory) {
        let key = Categorizer.normalize(key)
        categoryOverrides.removeAll { Categorizer.normalize($0.key) == key }
        categoryOverrides.append(CategoryOverride(key: key, category: category))
    }

    // MARK: - Обработка входящих

    /// Категория + правила для нового входящего письма. Единая точка входа для MailStore.
    func process(_ message: Message, headers: [String: String] = [:], now: Date = Date()) -> (Message, notify: Bool) {
        var m = message
        m.category = Categorizer.category(for: message, headers: headers, overrides: categoryOverrides)
        return RuleEngine.apply(rules, to: m, now: now)
    }

    /// Дата напоминания для исходящего, отправленного `date`.
    func followUpDate(after date: Date = Date()) -> Date {
        FollowUp.reminderDate(after: date, days: Self.clampDays(followUpDays))
    }

    // MARK: - Правила и шаблоны

    func upsertRule(_ rule: MailRule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
        save()
    }

    func deleteRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    /// Сдвинуть правило на `offset` позиций (−1 — выше, +1 — ниже). Порядок важен для `stopProcessing`.
    func moveRule(_ id: UUID, by offset: Int) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard rules.indices.contains(j) else { return }
        rules.swapAt(i, j)
        save()
    }

    func setRuleEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].isEnabled = enabled
        save()
    }

    @discardableResult
    func addTemplate(name: String = "Новый шаблон", subject: String = "", body: String = "") -> MailTemplate {
        let template = MailTemplate(name: name, subject: subject, body: body)
        templates.append(template)
        save()
        return template
    }

    func deleteTemplate(_ id: UUID) {
        templates.removeAll { $0.id == id }
        save()
    }

    nonisolated static let defaultTemplates: [MailTemplate] = [
        MailTemplate(name: "Спасибо, получил", subject: "",
                     body: "Спасибо, получил. Посмотрю и вернусь с ответом."),
        MailTemplate(name: "Перезвоню позже", subject: "",
                     body: "Сейчас не могу говорить — перезвоню позже сегодня."),
        MailTemplate(name: "Отправлю завтра", subject: "",
                     body: "Подготовлю и отправлю завтра до конца дня."),
    ]
}

// MARK: - Файл

/// Формат automation.json. Все поля необязательные при чтении.
struct AutomationFile: Codable {
    var version: Int = 1
    var templates: [MailTemplate]
    var rules: [MailRule]
    var categoryOverrides: [CategoryOverride]
    var followUpDays: Int

    static let defaultFollowUpDays = 3

    static var firstRun: AutomationFile {
        AutomationFile(templates: AutomationStore.defaultTemplates, rules: [], categoryOverrides: [],
                       followUpDays: defaultFollowUpDays)
    }

    init(templates: [MailTemplate], rules: [MailRule], categoryOverrides: [CategoryOverride], followUpDays: Int) {
        self.templates = templates
        self.rules = rules
        self.categoryOverrides = categoryOverrides
        self.followUpDays = followUpDays
    }

    private enum CodingKeys: String, CodingKey { case version, templates, rules, categoryOverrides, followUpDays }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        // Нет ключа (старый файл) — шаблоны по умолчанию; пустой массив — пользователь всё удалил.
        if c.contains(.templates) {
            templates = Self.lossy(MailTemplate.self, c, .templates)
        } else {
            templates = AutomationStore.defaultTemplates
        }
        rules = Self.lossy(MailRule.self, c, .rules)
        categoryOverrides = Self.lossy(CategoryOverride.self, c, .categoryOverrides)
        let days = (try? c.decodeIfPresent(Int.self, forKey: .followUpDays)) ?? nil
        followUpDays = AutomationStore.clampDays(days ?? Self.defaultFollowUpDays)
    }

    private static func lossy<T: Decodable>(_ type: T.Type, _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        let items = (try? c.decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil
        return items?.compactMap(\.value) ?? []
    }
}

/// Элемент массива, который не валит весь массив, если сам не читается.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

