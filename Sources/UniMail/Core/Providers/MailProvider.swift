import Foundation

/// Действие над письмами, которое провайдер должен повторить на сервере.
/// Codable — чтобы класть в журнал офлайн-действий и повторять после восстановления связи.
enum MailAction: Sendable, Equatable, Codable {
    case markRead(ids: [String], read: Bool)
    case flag(ids: [String], flagged: Bool)
    case move(ids: [String], to: MailboxRole)
    case deletePermanently(ids: [String])
    case snooze(ids: [String], until: Date)
    /// В свою папку (ключ `MailFolder.id`).
    case moveToFolder(ids: [String], folder: String)

    var ids: [String] {
        switch self {
        case .markRead(let ids, _), .flag(let ids, _), .move(let ids, _),
             .deletePermanently(let ids), .snooze(let ids, _), .moveToFolder(let ids, _):
            return ids
        }
    }

    /// То же действие для другого набора писем.
    func withIDs(_ ids: [String]) -> MailAction {
        switch self {
        case .markRead(_, let read): .markRead(ids: ids, read: read)
        case .flag(_, let flagged): .flag(ids: ids, flagged: flagged)
        case .move(_, let role): .move(ids: ids, to: role)
        case .deletePermanently: .deletePermanently(ids: ids)
        case .snooze(_, let until): .snooze(ids: ids, until: until)
        case .moveToFolder(_, let folder): .moveToFolder(ids: ids, folder: folder)
        }
    }
}

/// Результат инкрементальной синхронизации.
struct SyncResult: Sendable {
    var upserted: [Message]
    var deletedIDs: [String]
    /// Непрозрачный курсор (для демо). IMAP хранит состояние папок в базе.
    var cursor: String?
    /// Сырые заголовки новых писем (List-Id, Precedence, Auto-Submitted…) — для категоризатора и правил.
    var headers: [String: [String: String]] = [:]
    /// Свои папки ящика (nil — провайдер папок не отдаёт).
    var folders: [MailFolder]?
}

/// Правило на сервере (Exchange): работает там само, в UniMail только показываем.
struct ServerRule: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isEnabled: Bool
    /// «Если …» и «то …» простым текстом.
    var conditions: [String]
    var actions: [String]
}

/// Полное содержимое письма после скачивания тела.
struct MessageContent: Sendable {
    var text: String?
    var html: String?
    var attachments: [Attachment]
    var invite: Invite?
    var listUnsubscribe: String?
    var listUnsubscribePost: Bool
    var references: [String]
    var inReplyTo: String?
    var messageID: String?
}

enum MailProviderError: LocalizedError {
    case notImplemented(ProviderKind)
    case authenticationFailed
    case network(String)
    case missingServerSettings
    case missingPassword
    case notFound
    /// Сервер отказал во входе: его ответ и подсказка, где включить доступ.
    case loginRejected(server: String, details: String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let kind):
            "Для «\(kind.title)» не заданы настройки сервера."
        case .authenticationFailed:
            "Не удалось войти. Проверьте логин и пароль."
        case .network(let details):
            "Не удаётся подключиться: \(details). Проверьте адрес сервера, порт и защиту — или что этот протокол включён на сервере."
        case .missingServerSettings:
            "Не заданы серверы IMAP и SMTP."
        case .missingPassword:
            "Нет пароля в Связке ключей — введите его заново в настройках аккаунта."
        case .notFound:
            "Письмо не найдено на сервере."
        case let .loginRejected(server, details):
            "\(server) не принял логин или пароль (ответ сервера: «\(details)»). " + Self.loginHint(for: server)
        }
    }
}

extension MailProviderError {
    /// Где у почтового сервиса включается вход для почтовых программ.
    static func loginHint(for server: String) -> String {
        let host = server.lowercased()
        if host.hasPrefix("exchange") {
            return "Exchange: логин — как при входе в Windows: ДОМЕН\\имя_входа (имя входа бывает не таким, как в адресе почты, — уточните у ИТ) или UPN вида имя@домен. Пароль — доменный. Повторных попыток не будет, пока вы не введёте пароль заново — чтобы учётка не заблокировалась."
        }
        if host.contains("yandex") {
            return "Яндекс: в Почте откройте «Все настройки → Почтовые программы», включите доступ по IMAP и «Портальный пароль», затем создайте пароль приложения для почты (id.yandex.ru → Безопасность → Пароли приложений) и введите его вместо обычного пароля."
        }
        if host.contains("gmail") || host.contains("google") {
            return "Gmail: нужен пароль приложения из 16 букв (myaccount.google.com/apppasswords), он появляется после включения двухэтапной аутентификации. Обычный пароль Google не подойдёт."
        }
        if host.contains("mail.ru") {
            return "Mail.ru: создайте «Пароль для внешнего приложения» (Настройки → Безопасность) и введите его."
        }
        if host.contains("me.com") || host.contains("icloud") {
            return "iCloud: нужен пароль приложения (account.apple.com → Вход и безопасность → Пароли приложений)."
        }
        return "Проверьте логин (иногда это полный адрес, иногда только имя) и пароль; у многих сервисов нужен отдельный пароль приложения."
    }
}

/// Контракт, который реализует каждый источник почты: IMAP (Gmail, iCloud, Exchange, любой), демо.
/// UI с провайдерами напрямую не общается — только через MailStore.
protocol MailProvider: Sendable {
    var accountID: UUID { get }

    /// Инкрементальная синхронизация от курсора (nil — первая загрузка).
    func sync(cursor: String?) async throws -> SyncResult

    /// Повторить действие на сервере. Вызывается из очереди действий после окна «Отменить».
    func apply(_ action: MailAction) async throws

    /// Отправить письмо. Возвращает копию для папки «Отправленные».
    func send(_ message: OutgoingMessage) async throws -> Message

    /// Скачать тело письма (текст, HTML, вложения, приглашение).
    func fetchContent(for message: Message) async throws -> MessageContent

    /// Исходник письма (.eml).
    func rawSource(for message: Message) async throws -> Data

    /// Поиск на сервере по письмам, которых нет локально.
    func serverSearch(_ query: String) async throws -> [Message]

    /// Синхронизировать одну свою папку (при открытии и пока она открыта).
    func syncFolder(_ key: String) async throws -> SyncResult

    /// Правила на сервере (Exchange). У IMAP — пусто.
    func serverRules() async throws -> [ServerRule]

    /// Календарь ящика на сервере (Exchange). У IMAP нет — встречи берутся из Календаря macOS.
    var hasServerCalendar: Bool { get }

    /// Встречи за период (без участников и описания — они в `calendarEventDetails`).
    func calendarEvents(from start: Date, to end: Date) async throws -> [CalendarEvent]

    /// Встреча целиком: участники, описание.
    func calendarEventDetails(_ event: CalendarEvent) async throws -> CalendarEvent

    /// Создать (`remoteID == nil`) или изменить встречу. Возвращает id на сервере.
    func saveEvent(_ draft: EventDraft) async throws -> String

    /// Удалить свою встречу (участникам уйдёт отмена).
    func deleteEvent(remoteID: String) async throws

    /// Ответить на приглашение из календаря.
    func respondToEvent(remoteID: String, response: EventResponse, comment: String?) async throws

    /// Найти на сервере встречу, известную по Календарю macOS (тема и время). nil — не нашлась.
    func locateEvent(title: String, start: Date, end: Date) async throws -> CalendarEvent?

    /// Ответить на приглашение из письма силами сервера. false — не умеет, ответ уйдёт письмом (iCalendar REPLY).
    func respondToInvite(messageID: String, response: EventResponse) async throws -> Bool

    /// Ждать изменений на сервере (IMAP IDLE). true — что-то пришло, пора синхронизироваться.
    func waitForChanges(timeout: TimeInterval) async throws -> Bool

    /// Проверить вход (для мастера добавления ящика).
    func verifyLogin() async throws

    /// Закрыть соединения.
    func disconnect() async
}

extension MailProvider {
    func fetchContent(for message: Message) async throws -> MessageContent {
        MessageContent(text: message.body, html: message.htmlBody, attachments: message.attachments,
                       invite: message.invite, listUnsubscribe: message.listUnsubscribe,
                       listUnsubscribePost: message.listUnsubscribePost ?? false,
                       references: message.references ?? [], inReplyTo: message.inReplyToHeader,
                       messageID: message.headerMessageID)
    }

    func rawSource(for message: Message) async throws -> Data { throw MailProviderError.notFound }
    func syncFolder(_ key: String) async throws -> SyncResult { SyncResult(upserted: [], deletedIDs: [], cursor: nil) }
    func serverRules() async throws -> [ServerRule] { [] }

    var hasServerCalendar: Bool { false }
    func calendarEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] { [] }
    func calendarEventDetails(_ event: CalendarEvent) async throws -> CalendarEvent { event }
    func saveEvent(_ draft: EventDraft) async throws -> String { throw MailProviderError.notFound }
    func deleteEvent(remoteID: String) async throws { throw MailProviderError.notFound }
    func respondToEvent(remoteID: String, response: EventResponse, comment: String?) async throws {
        throw MailProviderError.notFound
    }
    func respondToInvite(messageID: String, response: EventResponse) async throws -> Bool { false }
    func locateEvent(title: String, start: Date, end: Date) async throws -> CalendarEvent? { nil }
    func serverSearch(_ query: String) async throws -> [Message] { [] }

    func waitForChanges(timeout: TimeInterval) async throws -> Bool {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return false
    }

    func verifyLogin() async throws {}
    func disconnect() async {}

    /// Настоящий сервер (IMAP), а не демо: поддерживает IDLE и поиск.
    var isLive: Bool { !(self is DemoProvider) && !(self is PendingProvider) }
}

/// Заглушка, если у ящика нет настроек серверов.
struct PendingProvider: MailProvider {
    let accountID: UUID
    let kind: ProviderKind

    func sync(cursor: String?) async throws -> SyncResult {
        throw MailProviderError.missingServerSettings
    }

    func apply(_ action: MailAction) async throws {
        throw MailProviderError.missingServerSettings
    }

    func send(_ message: OutgoingMessage) async throws -> Message {
        throw MailProviderError.missingServerSettings
    }
}

enum ProviderFactory {
    /// Где лежит база писем. Для демо-ящиков база не нужна.
    @MainActor static var database: MailDatabase?

    /// `password` — проверить вход до сохранения пароля в Связке ключей (мастер добавления ящика).
    @MainActor
    static func make(for account: Account, password: String? = nil) -> any MailProvider {
        switch account.kind {
        case .demo:
            return DemoProvider(account: account)
        case .gmail, .outlook, .icloud, .imap:
            #if canImport(Darwin)
            if let exchange = account.exchange, let url = EWSEndpoint.url(for: exchange.server),
               let database = database ?? (try? MailDatabase.inMemory()) {
                let secret = password ?? Keychain.get(account.id.uuidString) ?? ""
                let user = exchange.username.trimmingCharacters(in: .whitespaces).isEmpty ? account.email : exchange.username
                let transport = EWSHTTPTransport(url: url, username: user, password: secret)
                return EWSProvider(account: account, database: database,
                                   post: { try await transport.post($0) },
                                   cacheDirectory: attachmentsDirectory)
            }
            #endif
            guard account.server != nil, let database = database ?? (try? MailDatabase.inMemory()) else {
                return PendingProvider(accountID: account.id, kind: account.kind)
            }
            #if canImport(Darwin)
            let key = account.id.uuidString
            return IMAPProvider(
                account: account,
                database: database,
                transportFactory: StreamTransport.factory,
                password: { password ?? Keychain.get(key) },
                cacheDirectory: attachmentsDirectory
            )
            #else
            return PendingProvider(accountID: account.id, kind: account.kind)
            #endif
        }
    }

    /// Кэш скачанных вложений: ~/Library/Caches/UniMail/attachments.
    static var attachmentsDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("UniMail/attachments", isDirectory: true)
    }

    /// База писем: ~/Library/Application Support/UniMail/mail.sqlite.
    static func openDatabase() -> MailDatabase? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("UniMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try? MailDatabase(url: folder.appendingPathComponent("mail.sqlite"))
    }
}
