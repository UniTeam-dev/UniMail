import Foundation

/// Провайдер с правдоподобными тестовыми письмами. Нужен, чтобы разрабатывать
/// и показывать интерфейс до подключения настоящих серверов.
/// Состояния не хранит: номер «поколения» зашит в курсор синхронизации.
struct DemoProvider: MailProvider {
    let account: Account
    var accountID: UUID { account.id }

    init(account: Account) {
        self.account = account
    }

    func sync(cursor: String?) async throws -> SyncResult {
        try await Task.sleep(for: .milliseconds(Int.random(in: 250...700)))

        guard let cursor, let generation = Int(cursor.dropFirst(4)) else {
            return SyncResult(upserted: seed(), deletedIDs: [], cursor: "gen:1")
        }
        // На каждом обновлении с шансом 50% приходит новое письмо — видно анимацию вставки.
        var fresh: [Message] = []
        if Bool.random() {
            fresh.append(incoming(generation: generation))
        }
        return SyncResult(upserted: fresh, deletedIDs: [], cursor: "gen:\(generation + 1)")
    }

    func apply(_ action: MailAction) async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    func send(_ message: OutgoingMessage) async throws -> Message {
        try await Task.sleep(for: .milliseconds(600))
        let id = "\(accountID)-sent-\(UUID().uuidString)"
        return Message(
            id: id,
            accountID: accountID,
            threadID: message.threadID ?? id,
            role: .sent,
            from: Address(name: account.displayName, email: message.fromAddress),
            to: message.to,
            cc: message.cc,
            subject: message.subject,
            body: message.body,
            date: .now,
            isRead: true
        )
    }

    // MARK: - Генерация

    /// Набор писем: 0 — рабочий, 1 — личный, 2 — iCloud.
    private var set: Int {
        let email = account.email.lowercased()
        if email.contains("icloud") || email.contains("me.com") { return 2 }
        if email.contains("gmail") || email.contains("mail.ru") || email.contains("yandex") { return 1 }
        return 0
    }

    private func incoming(generation: Int) -> Message {
        let senders = [
            Address(name: "Анна Смирнова", email: "anna@studio.design"),
            Address(name: "GitHub", email: "noreply@github.com"),
            Address(name: "Дмитрий Орлов", email: "d.orlov@partner.ru"),
        ]
        let subjects = [
            "Короткий вопрос по макетам",
            "[UniMail] New pull request #\(40 + generation)",
            "Созвон перенесли на 16:00",
        ]
        let index = generation % senders.count
        let id = "\(accountID)-new-\(generation)"
        return Message(
            id: id, accountID: accountID, threadID: id, role: .inbox,
            from: senders[index], to: [me],
            subject: subjects[index],
            body: "Это новое письмо, пришедшее при обновлении. Оно появляется в списке с анимацией.\n\nОбновление №\(generation).",
            date: .now, isRead: false,
            category: index == 1 ? .notifications : .people
        )
    }

    private var me: Address { Address(name: account.displayName, email: account.email) }

    private struct Template {
        var from: Address
        var subject: String
        var body: String
        var hoursAgo: Double
        var read = false
        var flagged = false
        var role: MailboxRole = .inbox
        var thread: String? = nil
        var category: InboxCategory = .people
        var attachments: [Attachment] = []
        var html: String? = nil
        var invite = false
        var snoozeHours: Double? = nil
    }

    private func seed() -> [Message] {
        let templates: [Template]
        switch set {
        case 0: templates = workTemplates
        case 1: templates = personalTemplates
        default: templates = cloudTemplates
        }
        return templates.enumerated().map { index, t in
            let id = "\(accountID)-\(index)"
            let isOutgoing = t.role == .sent || t.role == .drafts
            return Message(
                id: id,
                accountID: accountID,
                threadID: t.thread.map { "\(accountID)-t-\($0)" } ?? id,
                role: t.role,
                from: isOutgoing ? me : t.from,
                to: isOutgoing ? [t.from] : [me],
                subject: t.subject,
                body: t.body,
                htmlBody: t.html,
                date: Date.now.addingTimeInterval(-t.hoursAgo * 3600),
                isRead: t.read || isOutgoing,
                isFlagged: t.flagged,
                attachments: t.attachments,
                category: t.category,
                snoozedUntil: t.snoozeHours.map { Date.now.addingTimeInterval($0 * 3600) },
                hasInvite: t.invite
            )
        }
    }

    private var workTemplates: [Template] {
        let lead = Address(name: "Марина Ковалёва", email: "m.kovaleva@company.ru")
        let dev = Address(name: "Алексей Петров", email: "a.petrov@company.ru")
        let client = Address(name: "Ольга Власова", email: "o.vlasova@retail-group.ru")
        return [
            Template(from: lead, subject: "Планирование спринта 42",
                     body: "Коллеги, привет!\n\nВ четверг в 11:00 планируем спринт 42. До встречи, пожалуйста, оцените задачи в бэклоге и отметьте блокеры.\n\nПриглашение во вложении.\n\nМарина",
                     hoursAgo: 0.4, flagged: true, invite: true),
            Template(from: dev, subject: "Re: Интеграция с 1С — обмен документами",
                     body: "Выгрузка контрагентов прошла, но на документах реализации падает сопоставление НДС. Прикладываю лог. Посмотришь?",
                     hoursAgo: 1.2, thread: "1c",
                     attachments: [Attachment(filename: "exchange-log.txt", size: 48_213, mimeType: "text/plain")]),
            Template(from: dev, subject: "Интеграция с 1С — обмен документами",
                     body: "Запустил первую выгрузку в тестовую базу. Отпишусь по результатам.",
                     hoursAgo: 5, read: true, thread: "1c"),
            Template(from: client, subject: "Договор и спецификация на 4 квартал",
                     body: "Добрый день!\n\nНаправляю проект договора и спецификацию. Просим согласовать до пятницы. Если будут правки — пришлите в режиме рецензирования.\n\nС уважением,\nОльга Власова",
                     hoursAgo: 3,
                     attachments: [
                        Attachment(filename: "Договор_Q4.pdf", size: 1_240_000, mimeType: "application/pdf"),
                        Attachment(filename: "Спецификация.xlsx", size: 88_400, mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
                     ]),
            Template(from: Address(name: "Jira", email: "jira@company.atlassian.net"),
                     subject: "[BS4OSC-218] Статус изменён на «В ревью»",
                     body: "Алексей Петров перевёл задачу BS4OSC-218 «Генерация электронного договора» в статус «В ревью».",
                     hoursAgo: 6, category: .notifications),
            Template(from: Address(name: "Habr Weekly", email: "digest@habr.com"),
                     subject: "Лучшее за неделю: Swift 6 concurrency на практике",
                     body: "Подборка лучших статей недели.",
                     hoursAgo: 20, read: true, category: .newsletters,
                     html: Self.newsletterHTML),
            Template(from: lead, subject: "Ревью архитектуры шлюза",
                     body: "Вернёмся к этому после релиза.",
                     hoursAgo: 30, read: true, role: .snoozed, snoozeHours: 18),
            Template(from: client, subject: "Re: Спецификация Q3",
                     body: "Ольга, добрый день! Спецификацию согласовали, подписанный экземпляр во вложении.",
                     hoursAgo: 50, role: .sent),
            Template(from: dev, subject: "Черновик: регламент релизов",
                     body: "1. Заморозка ветки за два дня\n2. Регресс\n3. …",
                     hoursAgo: 70, role: .drafts),
            Template(from: Address(name: "HR", email: "hr@company.ru"),
                     subject: "Корпоратив 18 октября",
                     body: "Регистрация открыта до 10 октября.",
                     hoursAgo: 90, read: true, role: .archive, category: .notifications),
        ]
    }

    private var personalTemplates: [Template] {
        let friend = Address(name: "Саша Никитин", email: "sasha.nikitin@gmail.com")
        return [
            Template(from: friend, subject: "Поездка на выходные 🚗",
                     body: "Ну что, в субботу выезжаем в 9? Я возьму палатку, с тебя горелка и карта маршрута.",
                     hoursAgo: 0.8, thread: "trip"),
            Template(from: Address(name: "Aeroflot", email: "noreply@aeroflot.ru"),
                     subject: "Ваш электронный билет SU 1402",
                     body: "Москва (SVO) → Сочи (AER), 12 октября, 08:35. Номер бронирования: KX7P2Q.",
                     hoursAgo: 2, flagged: true, category: .notifications,
                     attachments: [Attachment(filename: "e-ticket.pdf", size: 312_000, mimeType: "application/pdf")]),
            Template(from: Address(name: "Госуслуги", email: "no-reply@gosuslugi.ru"),
                     subject: "Код подтверждения: 482 913",
                     body: "Никому не сообщайте код 482 913. Он действует 5 минут.",
                     hoursAgo: 4, category: .notifications),
            Template(from: Address(name: "Ozon", email: "news@ozon.ru"),
                     subject: "Распродажа осени: скидки до 70%",
                     body: "Только до воскресенья.",
                     hoursAgo: 9, category: .newsletters, html: Self.promoHTML),
            Template(from: friend, subject: "Re: Поездка на выходные 🚗",
                     body: "Горелку возьму, маршрут скину вечером.",
                     hoursAgo: 12, role: .sent, thread: "trip"),
            Template(from: Address(name: "Мама", email: "mama@mail.ru"),
                     subject: "Фото с дачи",
                     body: "Смотри, какие яблоки в этом году! Приезжайте на выходных.",
                     hoursAgo: 26, read: true,
                     attachments: [
                        Attachment(filename: "IMG_2041.jpg", size: 2_400_000, mimeType: "image/jpeg"),
                        Attachment(filename: "IMG_2042.jpg", size: 2_100_000, mimeType: "image/jpeg"),
                     ]),
            Template(from: Address(name: "Steam", email: "noreply@steampowered.com"),
                     subject: "Предмет из вашего списка желаемого со скидкой",
                     body: "GregTech: New Horizons Soundtrack — скидка 40%.",
                     hoursAgo: 48, read: true, category: .newsletters),
        ]
    }

    private var cloudTemplates: [Template] {
        return [
            Template(from: Address(name: "Apple", email: "no_reply@email.apple.com"),
                     subject: "Ваш чек от Apple",
                     body: "iCloud+ 200 ГБ — 149 ₽. Спасибо за покупку.",
                     hoursAgo: 7, category: .notifications),
            Template(from: Address(name: "Ирина Лебедева", email: "irina.lebedeva@icloud.com"),
                     subject: "Фотоальбом с дня рождения",
                     body: "Выложила общий альбом, добавь свои фото, пожалуйста 🙂",
                     hoursAgo: 15),
            Template(from: Address(name: "Ландшафт-Про", email: "info@landshaft-pro.ru"),
                     subject: "Смета на благоустройство участка",
                     body: "Направляем смету: дренаж, отмостка, газон. Выезд замерщика — по согласованию.",
                     hoursAgo: 40, read: true, flagged: true,
                     attachments: [Attachment(filename: "Смета.pdf", size: 540_000, mimeType: "application/pdf")]),
        ]
    }

    private static let newsletterHTML = """
    <div style="font-family:-apple-system,Helvetica;max-width:560px;margin:auto">
      <h2 style="margin:0 0 8px">Лучшее за неделю</h2>
      <p style="color:#666">Подборка статей, которые обсуждали больше всего.</p>
      <img src="https://tracker.example.com/open.gif?u=123" width="1" height="1">
      <img src="https://cdn.example.com/banner.png" style="width:100%;border-radius:12px">
      <ol>
        <li><b>Swift 6 concurrency на практике</b> — как мигрировать без боли</li>
        <li><b>SQLite FTS5</b> — поиск по миллиону писем за 20 мс</li>
        <li><b>SwiftUI анимации</b> — matchedGeometryEffect без магии</li>
      </ol>
      <p><a href="https://habr.com">Читать на Хабре</a></p>
    </div>
    """

    private static let promoHTML = """
    <div style="font-family:-apple-system,Helvetica;text-align:center">
      <img src="https://pixel.ozon.example/track?id=9" width="1" height="1">
      <img src="https://cdn.ozon.example/sale.jpg" style="width:100%">
      <h1 style="color:#005bff">−70%</h1>
      <p>Осенняя распродажа до воскресенья.</p>
    </div>
    """
}
