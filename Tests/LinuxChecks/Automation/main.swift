import Foundation

// Проверки Core/Automation без XCTest. Сборка из корня проекта:
// swiftc -swift-version 5 Sources/UniMail/Core/Models/*.swift Sources/UniMail/Core/Automation/*.swift \
//     Tests/LinuxChecks/Automation/main.swift -o autotest && ./autotest

var passed = 0
var failed = 0

func check(_ condition: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if condition {
        passed += 1
        print("PASS  \(name)")
    } else {
        failed += 1
        print("FAIL  \(name)  (\(file):\(line))")
    }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if actual == expected {
        passed += 1
        print("PASS  \(name)")
    } else {
        failed += 1
        print("FAIL  \(name): ожидалось \(expected), получено \(actual)  (\(file):\(line))")
    }
}

let accA = UUID()
let accB = UUID()
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func msg(
    _ id: String = UUID().uuidString, from: String, name: String? = nil, to: [String] = ["me@severlab.ru"],
    subject: String = "Привет", body: String = "Текст", account: UUID = accA, thread: String? = nil,
    role: MailboxRole = .inbox, date: Date = t0, category: InboxCategory = .people
) -> Message {
    Message(id: id, accountID: account, threadID: thread ?? id, role: role,
            from: Address(name: name, email: from), to: to.map { Address(name: nil, email: $0) },
            subject: subject, body: body, date: date, isRead: false, category: category)
}

func cat(_ m: Message, _ headers: [String: String] = [:], _ overrides: [CategoryOverride] = []) -> InboxCategory {
    Categorizer.category(for: m, headers: headers, overrides: overrides)
}

// MARK: - Categorizer

print("— Categorizer")
eq(cat(msg(from: "ivan.petrov@severlab.ru", name: "Иван Петров", subject: "Макеты к среде")), .people, "человек из компании → люди")
eq(cat(msg(from: "john@acme.com", name: "John Smith", subject: "Lunch tomorrow?")), .people, "english person → people")
eq(cat(msg(from: "friend@gmail.com", subject: "Код ревью PR 1234")), .people, "«код» + 4 цифры не считается OTP")

eq(cat(msg(from: "notifications@github.com", subject: "[org/repo] Fix build (#42)"),
       ["List-Id": "org/repo <repo.org.github.com>", "List-Unsubscribe": "<mailto:x@github.com>"]),
   .notifications, "GitHub с List-Id → уведомления, не рассылки")
eq(cat(msg(from: "jira@company.atlassian.net", subject: "[JIRA] PRJ-12 назначена вам"), ["Precedence": "bulk"]),
   .notifications, "Atlassian + Precedence bulk → уведомления")
eq(cat(msg(from: "gitlab@gitlab.corp.local", subject: "Pipeline failed")), .notifications, "self-hosted gitlab → уведомления")
eq(cat(msg(from: "jira@jira.severlab.ru", subject: "Задача обновлена")), .notifications, "метка jira в домене → уведомления")
eq(cat(msg(from: "no-reply@gosuslugi.ru", name: "Госуслуги", subject: "Статус заявления")), .notifications, "Госуслуги → уведомления")
eq(cat(msg(from: "info@sberbank.ru", subject: "Списание по карте")), .notifications, "банк → уведомления")
eq(cat(msg(from: "tickets@rzd.ru", subject: "Ваш билет")), .notifications, "РЖД → уведомления")
eq(cat(msg(from: "id@yandex.ru", subject: "Код подтверждения: 482 913")), .notifications, "код подтверждения → уведомления")
eq(cat(msg(from: "account@service.io", subject: "Your verification code")), .notifications, "verification code → notifications")
eq(cat(msg(from: "team@app.io", subject: "Code 55123 for login")), .notifications, "code + 5 digits → notifications")
eq(cat(msg(from: "team@app.io", subject: "Your OTP")), .notifications, "OTP token → notifications")
var coded = msg(from: "someone@startup.io", subject: "Вход")
coded.oneTimeCode = "123456"
eq(cat(coded), .notifications, "oneTimeCode → уведомления")
eq(cat(msg(from: "security@startup.io", subject: "Сброс пароля"), ["List-Unsubscribe": "<https://x>"]),
   .notifications, "сброс пароля важнее List-Unsubscribe")
eq(cat(msg(from: "anna@startup.io", subject: "Автоответ: отпуск"), ["Auto-Submitted": "auto-replied"]),
   .notifications, "Auto-Submitted → уведомления")
eq(cat(msg(from: "anna@startup.io", subject: "Re: план"), ["auto-submitted": "no"]), .people, "Auto-Submitted: no → люди")
eq(cat(msg(from: "noreply@startup.io", subject: "Ваш заказ оформлен")), .notifications, "noreply → уведомления")
eq(cat(msg(from: "github-noreply@startup.io", subject: "x")), .notifications, "*-noreply → уведомления")
eq(cat(msg(from: "MAILER-DAEMON@mx.startup.io", subject: "Undelivered Mail")), .notifications, "mailer-daemon (регистр) → уведомления")
eq(cat(msg(from: "robot@startup.io", subject: "Отчёт")), .notifications, "robot@ → уведомления")
eq(cat(msg(from: "info@startup.io", subject: "Изменения в сервисе")), .notifications, "info@ → уведомления")
eq(cat(msg(from: "team@startup.io", name: "Startup (no-reply)", subject: "Hi")), .notifications, "no-reply в имени → уведомления")

eq(cat(msg(from: "hello@startup.io", subject: "Весенняя распродажа"), ["List-Unsubscribe": "<mailto:u@startup.io>"]),
   .newsletters, "List-Unsubscribe → рассылки")
eq(cat(msg(from: "hello@startup.io", subject: "Weekly"), ["LIST-ID": "<weekly.startup.io>"]), .newsletters, "List-Id (регистр имени) → рассылки")
eq(cat(msg(from: "hello@startup.io", subject: "Weekly"), ["Precedence": "Bulk"]), .newsletters, "Precedence: Bulk → рассылки")
eq(cat(msg(from: "noreply@ozon.ru", subject: "Скидки недели"), ["List-Unsubscribe": "<https://ozon.ru/u>"]),
   .newsletters, "noreply + List-Unsubscribe → рассылки")
var withField = msg(from: "hello@startup.io", subject: "Новости")
withField.listUnsubscribe = "https://startup.io/unsub"
eq(cat(withField), .newsletters, "Message.listUnsubscribe → рассылки")
eq(cat(msg(from: "news@vc.ru", subject: "Главное за неделю")), .newsletters, "news@ → рассылки")
eq(cat(msg(from: "digest@medium.com", subject: "Daily Digest")), .newsletters, "digest@ → newsletters")
eq(cat(msg(from: "anna@substack.com", subject: "New post")), .newsletters, "substack → newsletters")
eq(cat(msg(from: "shop@news.brand.ru", subject: "Новинки")), .newsletters, "поддомен news. → рассылки")
eq(cat(msg(from: "anna@brand.ru", subject: "x"), ["X-Campaign-ID": "42"]), .newsletters, "X-Campaign → рассылки")

let overrides = [
    CategoryOverride(key: "ivan@severlab.ru", category: .newsletters),
    CategoryOverride(key: "@digest.ru", category: .people),
    CategoryOverride(key: "boss@digest.ru", category: .notifications),
    CategoryOverride(key: "@example.org", category: .newsletters),
]
eq(cat(msg(from: "Ivan@Severlab.ru"), [:], overrides), .newsletters, "поправка по точному адресу (регистр)")
eq(cat(msg(from: "news@digest.ru"), ["List-Unsubscribe": "<x>"], overrides), .people, "поправка по домену важнее заголовков")
eq(cat(msg(from: "boss@digest.ru"), [:], overrides), .notifications, "точный адрес важнее домена")
eq(cat(msg(from: "a@mail.example.org"), [:], overrides), .newsletters, "поправка родительского домена")
eq(Categorizer.overrideCategory(for: "a@org", overrides: [CategoryOverride(key: "@org", category: .newsletters)]),
   .newsletters, "домен из одной метки совпадает только точно")
eq(Categorizer.overrideCategory(for: "a@b.example.org", overrides: [CategoryOverride(key: "@org", category: .newsletters)]),
   nil, "родитель короче двух меток не проверяется")
eq(Categorizer.domain(of: " <Anna@Volkova.Studio> "), "volkova.studio", "domain(of:) нормализует")

// MARK: - RuleEngine

print("— RuleEngine")
func rule(name: String = "r", account: UUID? = nil, all: Bool = true, _ conds: [MailRule.Condition],
          _ actions: [MailRule.Action], stop: Bool = false, enabled: Bool = true) -> MailRule {
    MailRule(name: name, isEnabled: enabled, accountID: account, matchAll: all, conditions: conds, actions: actions, stopProcessing: stop)
}
func c(_ f: MailRule.Field, _ m: MailRule.Match, _ v: String) -> MailRule.Condition { .init(field: f, match: m, value: v) }

let base = msg(from: "Ivan@Severlab.ru", name: "Иван Ёлкин", subject: "СЧЁТ за сентябрь", body: "Оплатите до пятницы")

do {
    let (m, notify) = RuleEngine.apply([], to: base)
    eq(m, base, "без правил письмо не меняется")
    check(notify, "без правил: уведомлять")
}
do {
    let r = rule([c(.subject, .contains, "счет")], [.flag])
    check(RuleEngine.apply([r], to: base).0.isFlagged, "кириллица без регистра и ё=е: «счет» ⊂ «СЧЁТ»")
    let r2 = rule([c(.from, .contains, "ёлкин")], [.markRead])
    check(RuleEngine.apply([r2], to: base).0.isRead, "имя отправителя, кириллица")
    let r3 = rule([c(.from, .equals, "ivan@severlab.ru")], [.markRead])
    check(RuleEngine.apply([r3], to: base).0.isRead, "equals по e-mail без регистра")
    let r4 = rule([c(.from, .endsWith, "@severlab.ru")], [.markRead])
    check(RuleEngine.apply([r4], to: base).0.isRead, "endsWith домен")
    let r5 = rule([c(.subject, .startsWith, "счёт")], [.markRead])
    check(RuleEngine.apply([r5], to: base).0.isRead, "startsWith")
    let r6 = rule([c(.body, .notContains, "пятниц")], [.markRead])
    check(!RuleEngine.apply([r6], to: base).0.isRead, "notContains не срабатывает при совпадении")
    let r7 = rule([c(.to, .contains, "me@severlab")], [.markRead])
    check(RuleEngine.apply([r7], to: base).0.isRead, "поле «Кому»")
    let r8 = rule([c(.anyAddress, .contains, "severlab.ru")], [.flag])
    check(RuleEngine.apply([r8], to: base).0.isFlagged, "любой адрес")
    let r9 = rule([c(.from, .notContains, "severlab")], [.flag])
    check(!RuleEngine.apply([r9], to: base).0.isFlagged, "notContains по адресу: ни один вариант не должен содержать")
    let english = msg(from: "Billing@Stripe.com", subject: "INVOICE #7")
    let r10 = rule([c(.subject, .contains, "invoice")], [.flag])
    check(RuleEngine.apply([r10], to: english).0.isFlagged, "английский без регистра")
}
do {
    let all = rule(all: true, [c(.subject, .contains, "счёт"), c(.body, .contains, "нет такого")], [.flag])
    check(!RuleEngine.apply([all], to: base).0.isFlagged, "matchAll: одно условие не выполнено → нет")
    let any = rule(all: false, [c(.subject, .contains, "счёт"), c(.body, .contains, "нет такого")], [.flag])
    check(RuleEngine.apply([any], to: base).0.isFlagged, "matchAny: хватает одного")
    let empty = rule([c(.subject, .contains, "  ")], [.flag])
    check(!RuleEngine.apply([empty], to: base).0.isFlagged, "правило без непустых условий не срабатывает")
    let mixed = rule(all: true, [c(.subject, .contains, "счёт"), c(.body, .contains, "")], [.flag])
    check(RuleEngine.apply([mixed], to: base).0.isFlagged, "пустое условие игнорируется")
    let disabled = rule([c(.subject, .contains, "счёт")], [.flag], enabled: false)
    check(!RuleEngine.apply([disabled], to: base).0.isFlagged, "выключенное правило пропускается")
}
do {
    let forB = rule(account: accB, [c(.subject, .contains, "счёт")], [.flag])
    check(!RuleEngine.apply([forB], to: base).0.isFlagged, "правило другого ящика не срабатывает")
    let forA = rule(account: accA, [c(.subject, .contains, "счёт")], [.flag])
    check(RuleEngine.apply([forA], to: base).0.isFlagged, "правило своего ящика срабатывает")
}
do {
    let first = rule(name: "1", [c(.subject, .contains, "счёт")], [.setCategory(.notifications)], stop: true)
    let second = rule(name: "2", [c(.subject, .contains, "счёт")], [.flag])
    let (m, _) = RuleEngine.apply([first, second], to: base)
    check(m.category == .notifications && !m.isFlagged, "stopProcessing останавливает следующие правила")
    let (m2, _) = RuleEngine.apply([rule(name: "1", [c(.subject, .contains, "счёт")], [.setCategory(.notifications)]), second], to: base)
    check(m2.category == .notifications && m2.isFlagged, "без stopProcessing применяются оба")
    let noMatchStop = rule(name: "0", [c(.subject, .contains, "zzz")], [.markRead], stop: true)
    check(RuleEngine.apply([noMatchStop, second], to: base).0.isFlagged, "stop несработавшего правила не мешает")
}
do {
    let hit = [c(.subject, .contains, "счёт")]
    let (moved, n1) = RuleEngine.apply([rule(hit, [.moveTo(.archive)])], to: base)
    check(moved.role == .archive && !n1, "moveTo(.archive), по умолчанию без уведомления вне «Входящих»")
    let (read, n2) = RuleEngine.apply([rule(hit, [.markRead])], to: base)
    check(read.isRead && !n2, "markRead, прочитанное не уведомляет")
    let (flagged, n3) = RuleEngine.apply([rule(hit, [.flag])], to: base)
    check(flagged.isFlagged && n3, "flag, уведомление по умолчанию")
    let (news, n4) = RuleEngine.apply([rule(hit, [.setCategory(.newsletters)])], to: base)
    check(news.category == .newsletters && !n4, "setCategory(.newsletters) → без уведомления")
    let (snoozed, n5) = RuleEngine.apply([rule(hit, [.snooze(hours: 5)])], to: base, now: t0)
    check(snoozed.role == .snoozed && snoozed.snoozedUntil == t0.addingTimeInterval(5 * 3600) && snoozed.isRead && !n5,
          "snooze(5) → .snoozed до now+5ч")
    let (zero, _) = RuleEngine.apply([rule(hit, [.snooze(hours: 0)])], to: base, now: t0)
    check(zero.role == .inbox && zero.snoozedUntil == nil, "snooze(0) игнорируется")
    var wasSnoozed = base
    wasSnoozed.role = .snoozed
    wasSnoozed.snoozedUntil = t0
    let (back, _) = RuleEngine.apply([rule(hit, [.moveTo(.inbox)])], to: wasSnoozed)
    check(back.role == .inbox && back.snoozedUntil == nil, "moveTo снимает snoozedUntil")
    let (_, off) = RuleEngine.apply([rule(hit, [.notify(false)])], to: base)
    check(!off, "notify(false)")
    let (_, on) = RuleEngine.apply([rule(hit, [.setCategory(.newsletters), .notify(true)])], to: base)
    check(on, "явный notify(true) важнее рассылки")
    let (_, last) = RuleEngine.apply([rule(hit, [.notify(true)]), rule(hit, [.notify(false)])], to: base)
    check(!last, "последний notify побеждает")
    let newsletter = msg(from: "news@vc.ru", category: .newsletters)
    check(!RuleEngine.apply([], to: newsletter).notify, "рассылка по умолчанию без уведомления")
}
do {
    let r = rule([c(.from, .contains, "github"), c(.subject, .contains, "PR")], [.moveTo(.archive), .snooze(hours: 48)], stop: true)
    eq(r.summary, "От содержит «github» и Тема содержит «PR» → в «Архив», отложить на 2 дня · стоп", "summary правила")
    eq(MailRule.Action.hoursText(3), "3 часа", "hoursText 3")
    eq(MailRule.Action.hoursText(21), "21 час", "hoursText 21")
    eq(MailRule.Action.Kind.allCases.map { $0.defaultAction.kind }, MailRule.Action.Kind.allCases, "Kind ↔ defaultAction")
}

// MARK: - FollowUp

print("— FollowUp")
do {
    let day: TimeInterval = 86_400
    var s1 = msg("s1", from: "me@severlab.ru", thread: "T1", role: .sent, date: t0)
    s1.followUpAt = t0 + 3 * day
    var s2 = msg("s2", from: "me@severlab.ru", thread: "T2", role: .sent, date: t0)
    s2.followUpAt = t0 + 3 * day
    let reply2 = msg("r2", from: "client@acme.com", thread: "T2", role: .inbox, date: t0 + day)
    var s3 = msg("s3", from: "me@severlab.ru", thread: "T3", role: .sent, date: t0)
    s3.followUpAt = t0 + 10 * day                                   // ещё рано
    var s4 = msg("s4", from: "me@severlab.ru", thread: "T4", role: .sent, date: t0 + day)
    s4.followUpAt = t0 + 2 * day
    let older4 = msg("o4", from: "client@acme.com", thread: "T4", role: .inbox, date: t0)   // старее исходящего
    let mine4 = msg("m4", from: "ME@severlab.ru", thread: "T4", role: .inbox, date: t0 + 1.5 * day) // своё же
    let draft4 = msg("d4", from: "client@acme.com", thread: "T4", role: .drafts, date: t0 + 1.5 * day)
    let s5 = msg("s5", from: "me@severlab.ru", thread: "T5", role: .sent, date: t0)        // без followUpAt
    var s6 = msg("s6", from: "me@severlab.ru", thread: "T6", role: .sent, date: t0)
    s6.followUpAt = t0 + day
    let alias6 = msg("a6", from: "design@severlab.ru", thread: "T6", role: .inbox, date: t0 + 0.5 * day)
    let otherThread = msg("x", from: "client@acme.com", thread: "T1-other", role: .inbox, date: t0 + day)
    let all = [s1, s2, reply2, s3, s4, older4, mine4, draft4, s5, s6, alias6, otherThread]
    let now = t0 + 5 * day

    eq(FollowUp.due(all, now: now).map(\.id), ["s4", "s1"], "due: подошёл срок и нет ответа (сортировка по сроку)")
    eq(FollowUp.due(all, now: now, myAddresses: ["design@severlab.ru"]).map(\.id), ["s6", "s4", "s1"],
       "due: письмо с моего алиаса — не ответ")
    eq(FollowUp.due(all, now: t0 + 2 * day).map(\.id), ["s4"], "due: followUpAt == now включается")
    eq(FollowUp.resolved(all), ["s2", "s6"], "resolved: ответ пришёл")
    eq(FollowUp.resolved(all, myAddresses: ["design@severlab.ru"]), ["s2"], "resolved с учётом алиасов")
    let later = FollowUp.reminderDate(after: t0, days: 3, calendar: Calendar(identifier: .gregorian))
    check(abs(later.timeIntervalSince(t0) - 3 * day) < 2 * 3600, "reminderDate +3 дня")
}

// MARK: - AutomationStore

print("— AutomationStore")
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unimail-autotest-\(UUID().uuidString)")

MainActor.assumeIsolated {
    let url = dir.appendingPathComponent("automation.json")
    let store = AutomationStore(fileURL: url)
    eq(store.templates.map(\.name), ["Спасибо, получил", "Перезвоню позже", "Отправлю завтра"], "первый запуск: шаблоны по умолчанию")
    eq(store.followUpDays, 3, "followUpDays по умолчанию 3")
    check(store.rules.isEmpty && store.categoryOverrides.isEmpty, "первый запуск: правил и поправок нет")
    check(!FileManager.default.fileExists(atPath: url.path), "файл не пишется до save()")

    store.templates.append(MailTemplate(name: "Ёж", subject: "Тема", body: "Тело\nстрока 2"))
    store.rules = [rule(name: "Счета", account: accA, all: false, [c(.subject, .contains, "счёт")],
                        [.moveTo(.archive), .markRead, .flag, .setCategory(.notifications), .snooze(hours: 24), .notify(false)],
                        stop: true)]
    store.followUpDays = 5
    check(store.save(), "save() успешен")

    let reloaded = AutomationStore(fileURL: url)
    eq(reloaded.templates, store.templates, "round-trip шаблонов")
    eq(reloaded.rules, store.rules, "round-trip правил со всеми действиями")
    eq(reloaded.followUpDays, 5, "round-trip followUpDays")

    // learnCategory
    store.learnCategory(for: Address(name: "Иван", email: "Ivan@Shop.ru"), category: .newsletters)
    eq(store.categoryOverrides, [CategoryOverride(key: "ivan@shop.ru", category: .newsletters)], "одна поправка — только адрес")
    store.learnCategory(for: Address(name: nil, email: "ivan@shop.ru"), category: .newsletters)
    eq(store.categoryOverrides.count, 1, "повтор того же адреса не дублирует и не учит домен")
    store.learnCategory(for: Address(name: nil, email: "petr@shop.ru"), category: .people)
    check(!store.categoryOverrides.contains { $0.key == "@shop.ru" }, "разные категории — домен не учится")
    store.learnCategory(for: Address(name: nil, email: "sale@shop.ru"), category: .newsletters)
    check(store.categoryOverrides.contains(CategoryOverride(key: "@shop.ru", category: .newsletters)),
          "два адреса домена в одну категорию → @shop.ru")
    eq(Categorizer.category(for: msg(from: "new@shop.ru"), headers: [:], overrides: store.categoryOverrides), .newsletters,
       "выученный домен применяется к новому адресу")
    eq(Categorizer.category(for: msg(from: "petr@shop.ru"), headers: [:], overrides: store.categoryOverrides), .people,
       "точная поправка важнее выученного домена")
    store.learnCategory(for: Address(name: nil, email: "a@gmail.com"), category: .newsletters)
    store.learnCategory(for: Address(name: nil, email: "b@gmail.com"), category: .newsletters)
    check(!store.categoryOverrides.contains { $0.key == "@gmail.com" }, "публичный домен не выучивается")
    store.learnCategory(for: Address(name: nil, email: "a@gmail.com"), category: .people)
    eq(store.categoryOverrides.filter { $0.key == "a@gmail.com" }.map(\.category), [.people], "повторная поправка заменяет категорию")

    let persisted = AutomationStore(fileURL: url)
    eq(persisted.categoryOverrides, store.categoryOverrides, "learnCategory сохраняет сразу")
    store.removeOverride("@SHOP.ru")
    check(!store.categoryOverrides.contains { $0.key == "@shop.ru" }, "removeOverride по ключу без регистра")
    eq(AutomationStore(fileURL: url).categoryOverrides.count, store.categoryOverrides.count, "removeOverride сохраняет")

    // process = категория + правила
    let (processed, notify) = store.process(msg(from: "news@vc.ru", subject: "Главное"), headers: [:], now: t0)
    check(processed.category == .newsletters && !notify, "process: категоризация и уведомление")
    let (billed, _) = store.process(msg(from: "client@acme.com", subject: "Счёт №5"), now: t0)
    check(billed.role == .snoozed && billed.isFlagged && billed.category == .notifications, "process: правила после категории")
    check(abs(store.followUpDate(after: t0).timeIntervalSince(t0) - 5 * 86_400) < 2 * 3600, "followUpDate учитывает followUpDays")

    // Удаление всех шаблонов переживает перезапуск.
    store.templates.removeAll()
    store.save()
    check(AutomationStore(fileURL: url).templates.isEmpty, "пустой список шаблонов не заменяется умолчаниями")

    // Терпимое чтение.
    let partial = dir.appendingPathComponent("partial.json")
    try? #"{"rules":[{"broken":true},{"id":"7C5E2C5E-8E0D-4B8C-9A55-1C1B2F3C4D5E","name":"ok","isEnabled":true,"matchAll":true,"conditions":[],"actions":[{"markRead":{}}],"stopProcessing":false}],"followUpDays":999}"#
        .data(using: .utf8)!.write(to: partial)
    let tolerant = AutomationStore(fileURL: partial)
    eq(tolerant.rules.map(\.name), ["ok"], "битое правило пропускается, остальные читаются")
    eq(tolerant.templates.count, 3, "нет ключа templates → шаблоны по умолчанию")
    eq(tolerant.followUpDays, 30, "followUpDays зажимается в 1...30")

    let corrupt = dir.appendingPathComponent("corrupt.json")
    try? "{ not json".data(using: .utf8)!.write(to: corrupt)
    let recovered = AutomationStore(fileURL: corrupt)
    eq(recovered.templates.count, 3, "нечитаемый файл → значения по умолчанию")
    let backups = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("automation.corrupt-") }
    eq(backups.count, 1, "нечитаемый файл сохранён в резервную копию")
}

try? FileManager.default.removeItem(at: dir)
print("\nИтого: \(passed) PASS, \(failed) FAIL")
exit(failed == 0 ? 0 : 1)
