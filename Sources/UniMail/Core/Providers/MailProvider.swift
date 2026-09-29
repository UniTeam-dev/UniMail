import Foundation

/// Действие над письмами, которое провайдер должен повторить на сервере.
/// Codable — чтобы класть в журнал офлайн-действий и повторять после восстановления связи.
enum MailAction: Sendable, Equatable, Codable {
    case markRead(ids: [String], read: Bool)
    case flag(ids: [String], flagged: Bool)
    case move(ids: [String], to: MailboxRole)
    case deletePermanently(ids: [String])
    case snooze(ids: [String], until: Date)

    var ids: [String] {
        switch self {
        case .markRead(let ids, _), .flag(let ids, _), .move(let ids, _),
             .deletePermanently(let ids), .snooze(let ids, _):
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

    var errorDescription: String? {
        switch self {
        case .notImplemented(let kind):
            "Для «\(kind.title)» не заданы настройки сервера."
        case .authenticationFailed:
            "Не удалось войти. Проверьте логин и пароль."
        case .network(let details):
            "Нет связи с сервером: \(details)"
        case .missingServerSettings:
            "Не заданы серверы IMAP и SMTP."
        case .missingPassword:
            "Нет пароля в Связке ключей — введите его заново в настройках аккаунта."
        case .notFound:
            "Письмо не найдено на сервере."
        }
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
