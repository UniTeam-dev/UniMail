import Foundation

/// Провайдер с тестовыми письмами из макета (Анна Волкова: Работа, Личное, Студия).
/// Нужен, чтобы разрабатывать и показывать интерфейс до подключения настоящих серверов.
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
        // На каждом третьем обновлении приходит новое письмо — видно анимацию вставки.
        var fresh: [Message] = []
        if generation % 3 == 0 {
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
            from: me,
            to: message.to,
            cc: message.cc,
            subject: message.subject,
            body: message.body,
            date: .now,
            isRead: true
        )
    }

    // MARK: - Набор писем

    private enum DataSet { case work, home, studio }

    private var dataSet: DataSet {
        let email = account.email.lowercased()
        if email.contains("icloud") || email.contains("me.com") || email.contains("gmail") { return .home }
        if email.contains("studio") || email.contains("fastmail") { return .studio }
        return .work
    }

    private var me: Address {
        Address(name: account.senderName ?? "Анна Волкова", email: account.email)
    }

    private func incoming(generation: Int) -> Message {
        let senders = [
            Address(name: "Ирина Ким", email: "i.kim@severlab.ru"),
            Address(name: "Трекер задач", email: "tracker@severlab.ru"),
            Address(name: "Сергей Лебедев", email: "s.lebedev@severlab.ru"),
        ]
        let subjects = ["Короткий вопрос по токенам", "[DS-\(220 + generation)] Новый комментарий", "Стенд обновлён"]
        let index = generation % senders.count
        let id = "\(accountID)-new-\(generation)"
        return Message(
            id: id, accountID: accountID, threadID: id, role: .inbox,
            from: senders[index], to: [me],
            subject: subjects[index],
            body: "Это новое письмо, пришедшее при обновлении. Оно въезжает в список сверху.\n\nОбновление №\(generation).",
            date: .now, isRead: false,
            category: index == 1 ? .notifications : .people
        )
    }

    /// Дата «n дней назад в hh:mm»; будущее время сегодняшнего дня сдвигается в прошлое.
    private func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        let date = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        if daysAgo == 0 && date > .now {
            return Date.now.addingTimeInterval(-Double((24 - hour) * 60 + minute) * 7)
        }
        return date
    }

    /// Ближайший четверг в указанный час.
    private func nextWeekday(_ weekday: Int, hour: Int) -> Date {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = hour
        return cal.nextDate(after: .now, matching: comps, matchingPolicy: .nextTime) ?? .now
    }

    private struct T {
        var thread: String
        var from: Address
        var to: [Address]? = nil
        var cc: [Address] = []
        var subject: String
        var body: String
        var date: Date
        var read = false
        var flagged = false
        var role: MailboxRole = .inbox
        var category: InboxCategory = .people
        var attachments: [Attachment] = []
        var html: String? = nil
        var invite: Invite? = nil
        var code: String? = nil
        var snoozedUntil: Date? = nil
        var scheduledAt: Date? = nil
    }

    private func pdf(_ name: String, _ size: Int) -> Attachment {
        Attachment(filename: name, size: size, mimeType: "application/pdf")
    }

    private func file(_ name: String, _ size: Int) -> Attachment {
        Attachment(filename: name, size: size, mimeType: "application/octet-stream")
    }

    private func seed() -> [Message] {
        let items: [T]
        switch dataSet {
        case .work: items = work
        case .home: items = home
        case .studio: items = studio
        }
        return items.enumerated().map { index, t in
            let outgoing = t.from.email == account.email
            var m = Message(
                id: "\(accountID)-\(index)",
                accountID: accountID,
                threadID: "\(accountID)-t-\(t.thread)",
                role: t.role,
                from: t.from,
                to: t.to ?? [me],
                cc: t.cc,
                subject: t.subject,
                body: t.body,
                htmlBody: t.html,
                date: t.date,
                isRead: t.read || outgoing,
                isFlagged: t.flagged,
                attachments: t.attachments,
                category: t.category,
                snoozedUntil: t.snoozedUntil,
                scheduledAt: t.scheduledAt
            )
            m.invite = t.invite
            m.oneTimeCode = t.code
            return m
        }
    }

    // MARK: Работа

    private var work: [T] {
        let misha = Address(name: "Михаил Орлов", email: "m.orlov@severlab.ru")
        let irina = Address(name: "Ирина Ким", email: "i.kim@severlab.ru")
        let olga = Address(name: "Ольга Белова", email: "o.belova@severlab.ru")
        let sergey = Address(name: "Сергей Лебедев", email: "s.lebedev@severlab.ru")
        let tracker = Address(name: "Трекер задач", email: "tracker@severlab.ru")
        let meetingStart = nextWeekday(5, hour: 15)
        return [
            T(thread: "onboarding", from: me, to: [misha],
              subject: "Правки по макету онбординга",
              body: "Михаил, привет!\n\nСкидываю вторую итерацию онбординга, посмотри, пожалуйста, до завтра.",
              date: at(1, 18, 10), role: .sent),
            T(thread: "onboarding", from: misha,
              subject: "Правки по макету онбординга",
              body: "Анна, привет!\n\nПосмотрел вторую итерацию. В целом очень хорошо: стало заметно спокойнее, и переход между шагами наконец читается.\n\nДва замечания. На шаге выбора аккаунта я бы убрал лишний экран и сразу показывал сетку провайдеров. И давай проверим ошибку входа в тёмной теме — сейчас оранжевый почти теряется.\n\nКомментарии оставил прямо в файле, PDF — для тех, у кого нет доступа.\n\nСпасибо! Миша",
              date: at(0, 12, 24),
              attachments: [pdf("Комментарии_онбординг_v2.pdf", 2_400_000), file("onboarding-flow.fig", 18_100_000)]),
            T(thread: "ds-review", from: irina,
              cc: [misha, Address(name: "Ольга Белова", email: "o.belova@severlab.ru"),
                   Address(name: "Сергей Лебедев", email: "s.lebedev@severlab.ru"),
                   Address(name: "Даша Ли", email: "d.li@severlab.ru")],
              subject: "Приглашение: ревью дизайн-системы",
              body: "Коллеги, привет!\n\nПредлагаю в четверг пройтись по дизайн-системе UniMail: токены обеих тем, типографика, строки списка в трёх плотностях. Возьмите свои вопросы — соберём их в один документ.\n\nИрина",
              date: at(0, 11, 2),
              invite: Invite(title: "Ревью дизайн-системы UniMail", start: meetingStart,
                             end: meetingStart.addingTimeInterval(3600),
                             location: "Переговорная «Нева» · видеозвонок по ссылке в приглашении")),
            T(thread: "ds-214", from: tracker,
              subject: "[DS-214] Вам назначена задача «Тёмная тема для списка»",
              body: "Ольга Белова назначила вас исполнителем. Срок — 2 октября, приоритет высокий.\n\nХорошего дня!",
              date: at(1, 16, 30), category: .notifications),
            T(thread: "budget", from: olga, subject: "Бюджет на Q4",
              body: "Анна, пришли, пожалуйста, оценку исследования на Q4 до среды.", date: at(4, 10, 5), read: true),
            T(thread: "budget", from: me, to: [olga], subject: "Re: Бюджет на Q4",
              body: "Ольга, оценка во вложении. На исследование нужно чуть больше, чем в прошлом квартале.",
              date: at(3, 17, 40), role: .sent),
            T(thread: "budget", from: olga, subject: "Re: Бюджет на Q4",
              body: "Спасибо! Отнесу финансам.", date: at(2, 9, 12), read: true),
            T(thread: "budget", from: olga, subject: "Re: Бюджет на Q4",
              body: "Согласовала с финансами: на исследование закладываем чуть больше, на подрядчиков — как в прошлом квартале.",
              date: at(1, 15, 20), read: true, flagged: true),
            T(thread: "stand", from: sergey, subject: "Доступ к тестовому стенду",
              body: "Выдал доступ к стенду, логин прежний. Если будут ошибки синхронизации — пиши сразу мне.",
              date: at(3, 14, 0), read: true),
            T(thread: "budget-draft", from: me, to: [olga], subject: "Re: Бюджет на Q4",
              body: "Ольга, спасибо! Тогда закладываю исследование в план спринта…", date: at(0, 9, 40), role: .drafts),
            T(thread: "report", from: me, to: [olga], subject: "Отчёт за сентябрь",
              body: "Ольга, отчёт за сентябрь во вложении.", date: at(0, 9, 0), role: .scheduled,
              scheduledAt: Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: .now)),
            T(thread: "conf", from: misha, subject: "Идеи для доклада на конференции",
              body: "Давай после релиза обсудим, о чём рассказать.", date: at(5, 11, 0), read: true,
              role: .snoozed, snoozedUntil: at(-2, 9, 0)),
            T(thread: "corp", from: Address(name: "HR", email: "hr@severlab.ru"), subject: "Корпоратив 18 октября",
              body: "Регистрация открыта до 10 октября.", date: at(6, 12, 0), read: true, role: .archive,
              category: .notifications),
        ]
    }

    // MARK: Личное

    private var home: [T] {
        let mom = Address(name: "Мама", email: "galina.v@mail.ru")
        return [
            T(thread: "code", from: Address(name: "Облако Север", email: "no-reply@oblako-sever.ru"),
              subject: "Код для входа: 482 913",
              body: "Здравствуйте!\n\nКто-то входит в ваш аккаунт с нового устройства: MacBook Pro, Москва. Если это вы, введите код выше.\n\nЕсли вы не запрашивали вход, проигнорируйте письмо и смените пароль.",
              date: at(0, 10, 47), category: .notifications, code: "482 913"),
            T(thread: "polosa", from: Address(name: "Полоса", email: "digest@polosa.media"),
              subject: "Выпуск №42: вариативные шрифты в интерфейсах",
              body: "Как одна гарнитура заменяет целое семейство начертаний, почему это экономит трафик и что с этим делать дизайнерам.",
              date: at(0, 9, 15), category: .newsletters, html: Self.polosaHTML),
            T(thread: "dacha", from: mom, subject: "Фотографии с дачи",
              body: "Анечка, как ты там? Позвони, как будет минутка.", date: at(1, 20, 41), read: true),
            T(thread: "dacha", from: mom, subject: "Фотографии с дачи",
              body: "Анечка, отправляю фотографии, как обещала. Яблок в этом году столько, что не знаем, куда девать!\n\nПриезжайте в выходные, папа уже договорился насчёт бани.",
              date: at(1, 21, 5), read: true,
              attachments: [file("IMG_2041.heic", 3_100_000), file("IMG_2044.heic", 2_800_000)]),
            T(thread: "train", from: Address(name: "Ласточка · Билеты", email: "tickets@lastochka.example"),
              subject: "Ваш маршрут Москва — Казань",
              body: "Поезд №712, отправление 10 октября в 07:05. Электронная регистрация пройдена.\n\nХорошего пути!",
              date: at(3, 8, 20), read: true, category: .notifications,
              attachments: [pdf("Билет_712.pdf", 96_000)]),
            T(thread: "pool", from: Address(name: "Бассейн «Волна»", email: "info@volna.example"),
              subject: "Абонемент заканчивается", body: "Продлите абонемент до конца недели со скидкой 10%.",
              date: at(2, 12, 0), read: true, role: .snoozed, category: .notifications, snoozedUntil: at(-4, 9, 0)),
            T(thread: "spam1", from: Address(name: "Выигрыш", email: "win@lucky.example"),
              subject: "Вы выиграли iPhone!", body: "Заберите приз по ссылке.", date: at(1, 3, 0), role: .spam),
            T(thread: "spam2", from: Address(name: "Кредит онлайн", email: "credit@fast.example"),
              subject: "Одобрено 500 000 ₽", body: "Без справок.", date: at(2, 4, 0), role: .spam),
        ]
    }

    // MARK: Студия

    private var studio: [T] {
        let daniil = Address(name: "Даниил Смирнов", email: "d.smirnov@bureau.ru")
        return [
            T(thread: "invoice", from: me, to: [daniil], subject: "Счёт за сентябрь и акт",
              body: "Даниил, пришлите, пожалуйста, счёт за сентябрь, когда будет готов.", date: at(4, 14, 2), role: .sent),
            T(thread: "invoice", from: daniil, subject: "Счёт за сентябрь и акт",
              body: "Да, конечно, пришлю в начале недели вместе с актом.", date: at(3, 10, 15), read: true),
            T(thread: "invoice", from: daniil, subject: "Счёт за сентябрь и акт",
              body: "Анна, добрый день!\n\nПрикладываю счёт и акт выполненных работ за сентябрь. Оплатить нужно до 5 октября, реквизиты те же, что и в прошлый раз.\n\nДаниил",
              date: at(0, 9, 3), read: true, flagged: true,
              attachments: [pdf("Счёт_0927.pdf", 184_000), pdf("Акт_сентябрь.pdf", 212_000)]),
            T(thread: "digest", from: Address(name: "Дизайн-дайджест", email: "digest@design-digest.example"),
              subject: "Десять лучших интерфейсов сентября",
              body: "Разбираем почтовые клиенты, календари и одну очень смелую навигацию.",
              date: at(3, 7, 30), read: true, category: .newsletters),
            T(thread: "paid", from: me, to: [daniil], subject: "Счёт оплачен",
              body: "Даниил, счёт оплачен, платёжка во вложении.", date: at(0, 8, 50), role: .scheduled,
              scheduledAt: Calendar.current.date(bySettingHour: 18, minute: 40, second: 0, of: .now)),
            T(thread: "bakery", from: Address(name: "Пекарня на Литейном", email: "hello@bakery.example"),
              subject: "Бриф: сайт для пекарни", body: "Анна, возвращаемся к брифу после праздников.",
              date: at(6, 16, 0), read: true, role: .snoozed, snoozedUntil: at(-6, 8, 0)),
            T(thread: "spam3", from: Address(name: "SEO Pro", email: "seo@promo.example"),
              subject: "Выведем сайт в ТОП", body: "Гарантия результата.", date: at(1, 5, 0), role: .spam),
            T(thread: "spam4", from: Address(name: "Лиды", email: "leads@promo.example"),
              subject: "База клиентов", body: "Скидка 90%.", date: at(2, 6, 0), role: .spam),
        ]
    }

    /// Рассылка «Полоса»: одна картинка-обложка, один трекинг-пиксель, одна картинка в подвале.
    static let polosaHTML = """
    <div style="font-family:Georgia,'Times New Roman',serif;color:#1A1A1A">
      <div style="padding:22px 32px 16px;display:flex;justify-content:space-between;align-items:baseline;border-bottom:1px solid #EEE">
        <div style="font-family:-apple-system,'Helvetica Neue',sans-serif;font-weight:800;letter-spacing:0.28em;font-size:14px">ПОЛОСА</div>
        <div style="font-family:-apple-system,'Helvetica Neue',sans-serif;font-size:11px;color:#777">Выпуск №42 · 29 сентября</div>
      </div>
      <img src="https://tracker.polosa.example/open.gif?u=123" width="1" height="1">
      <div style="margin:20px 32px 0"><img src="https://cdn.polosa.example/cover-42.jpg" style="width:100%;height:180px;object-fit:cover;border-radius:6px"></div>
      <div style="padding:20px 32px 26px">
        <div style="font-size:24px;line-height:1.2;font-weight:700;letter-spacing:-0.01em">Один файл вместо двенадцати: вариативные шрифты в интерфейсах</div>
        <p style="font-size:15px;line-height:1.6;color:#333;margin:12px 0 0">Как одна гарнитура заменяет целое семейство начертаний, почему это экономит трафик и что с этим делать дизайнерам интерфейсов. Разбираем на примерах почтовых клиентов и новостных приложений.</p>
        <a href="https://polosa.media/42" style="display:inline-block;margin-top:18px;padding:10px 18px;border-radius:6px;background:#1A1A1A;color:#fff;font-family:-apple-system,sans-serif;font-size:13px;font-weight:600;text-decoration:none">Читать выпуск</a>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:18px;margin-top:24px;padding-top:18px;border-top:1px solid #EEE">
          <div><div style="font-family:-apple-system,sans-serif;font-size:10.5px;font-weight:700;letter-spacing:0.08em;color:#999">ТАКЖЕ В ВЫПУСКЕ</div><div style="font-size:15px;font-weight:700;margin-top:6px;line-height:1.3">Почему кириллица ломает вёрстку заголовков</div></div>
          <div><div style="font-family:-apple-system,sans-serif;font-size:10.5px;font-weight:700;letter-spacing:0.08em;color:#999">ИНСТРУМЕНТЫ</div><div style="font-size:15px;font-weight:700;margin-top:6px;line-height:1.3">Пять утилит для проверки контраста</div></div>
        </div>
        <img src="https://cdn.polosa.example/footer-logo.png" style="height:18px;margin-top:20px">
        <div style="font-family:-apple-system,sans-serif;font-size:11px;color:#999;margin-top:24px;line-height:1.5">Вы получили это письмо, потому что подписались на «Полосу». <a href="https://polosa.media/unsubscribe" style="color:#999">Отписаться</a></div>
      </div>
    </div>
    """
}
