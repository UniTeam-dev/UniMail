# UniMail — архитектура модулей

Все модули лежат в одном SwiftPM-таргете `UniMail` (macOS 14, Swift 5 language mode). Всё под `Core/Mail`, `Core/Store/Database`, `Core/Automation` не зависит от AppKit/SwiftUI и проверяется на Linux (swiftc 6.0.3) тестовыми программами из `Tests/LinuxChecks/`.

## Общие типы (уже есть)
- `Core/Models/Message.swift` — `Message`, `Address`, `Attachment`, `MailboxRole`, `InboxCategory`, `Invite`, `OutgoingMessage`, `plural()`.
- `Core/Models/Account.swift` — `Account`, `ServerSettings`, `ConnectionSecurity`, `ProviderKind`, `AccountTint`.
- `Core/Models/Automation.swift` — `MailTemplate`, `MailRule`, `CategoryOverride`.
- `Core/Mail/Transport.swift` — `MailTransport`, `MailTransportError`, `LineReader`, `ScriptedTransport` (для тестов).

## Core/Mail/IMAP — IMAP-клиент
```swift
struct IMAPFolder: Sendable, Hashable { var name: String; var delimiter: String?; var attributes: Set<String>; var role: MailboxRole? }
struct IMAPSelectInfo: Sendable { var uidValidity: UInt32; var uidNext: UInt32?; var exists: Int; var highestModSeq: UInt64? }
struct IMAPEnvelope: Sendable { var date: Date?; var subject: String?; var from: [Address]; var to: [Address]; var cc: [Address]; var replyTo: [Address]; var messageID: String?; var inReplyTo: String? }
struct IMAPMessageSummary: Sendable {
    var uid: UInt32; var flags: Set<String>; var internalDate: Date?; var size: Int?; var modSeq: UInt64?
    var envelope: IMAPEnvelope
    var gmailThreadID: UInt64?; var gmailLabels: [String]
    var headers: [String: String]      // lowercased: references, list-unsubscribe, list-unsubscribe-post, content-type
    var hasAttachments: Bool           // multipart/mixed или есть Content-Disposition: attachment
    var preview: String?               // первые ~200 символов текста, если запрошены
}
struct IMAPFlagUpdate: Sendable { var uid: UInt32; var flags: Set<String>; var modSeq: UInt64? }
enum IMAPError: LocalizedError { case no(String), bad(String), unexpected(String), authenticationFailed(String) }

actor IMAPClient {
    init(transport: MailTransport)
    func connect() async throws                       // читает приветствие
    var capabilities: Set<String> { get }             // заполняется после connect/login
    func refreshCapabilities() async throws -> Set<String>
    func startTLS() async throws                      // STARTTLS + transport.startTLS()
    func login(username: String, password: String) async throws
    func enableCondStore() async throws               // ENABLE CONDSTORE / QRESYNC, если есть
    func listFolders() async throws -> [IMAPFolder]   // LIST "" "*" (+ SPECIAL-USE)
    func select(_ folder: String, readOnly: Bool) async throws -> IMAPSelectInfo
    func uidSearch(_ criteria: String) async throws -> [UInt32]     // "ALL", "SINCE 1-Sep-2026", "TEXT \"x\"", "X-GM-RAW \"...\""
    func fetchSummaries(uids: [UInt32]) async throws -> [IMAPMessageSummary]
    func fetchFlags(changedSince modSeq: UInt64) async throws -> [IMAPFlagUpdate]
    func fetchFlags(uids: [UInt32]) async throws -> [IMAPFlagUpdate]
    func fetchMessage(uid: UInt32) async throws -> Data             // BODY.PEEK[] целиком
    func fetchPart(uid: UInt32, section: String) async throws -> Data
    func store(uids: [UInt32], flags: [String], add: Bool) async throws
    func move(uids: [UInt32], to folder: String) async throws        // MOVE или COPY + \Deleted + UID EXPUNGE
    func copy(uids: [UInt32], to folder: String) async throws
    func expunge(uids: [UInt32]) async throws
    func append(folder: String, message: Data, flags: [String], date: Date?) async throws -> UInt32?  // APPENDUID
    func idle(timeout: TimeInterval) async throws -> Bool            // true — пришли изменения (EXISTS/EXPUNGE/FETCH)
    func noop() async throws
    func logout() async
}
```
Имена папок — в modified UTF-7 на проводе; наружу — обычный Unicode (`IMAPUTF7.encode/decode`).

## Core/Mail/MIME, SMTP, ICS
```swift
struct MIMEHeaders: Sendable { subscript(_ name: String) -> String? { get }; func all(_ name: String) -> [String] }
struct ParsedAttachment: Sendable { var filename: String; var mimeType: String; var data: Data; var contentID: String?; var isInline: Bool; var partID: String }
struct ParsedMessage: Sendable {
    var headers: MIMEHeaders
    var subject: String; var from: [Address]; var to: [Address]; var cc: [Address]; var replyTo: [Address]
    var date: Date?; var messageID: String?; var inReplyTo: String?; var references: [String]
    var listUnsubscribe: String?; var listUnsubscribePost: Bool
    var textBody: String?; var htmlBody: String?
    var attachments: [ParsedAttachment]
    var calendar: String?          // сырой text/calendar
}
enum MIMEParser { static func parse(_ data: Data) -> ParsedMessage; static func parseAddressList(_ s: String) -> [Address] }
enum RFC2047 { static func decode(_ s: String) -> String; static func encode(_ s: String) -> String }
enum TextEncodings { static func decode(_ data: Data, charset: String?) -> String }  // utf-8, cp1251, koi8-r, latin1…

struct OutgoingAttachment: Sendable { var filename: String; var mimeType: String; var data: Data }
struct OutgoingMIME: Sendable {
    var from: Address; var to: [Address]; var cc: [Address]; var bcc: [Address]
    var subject: String; var textBody: String; var htmlBody: String?
    var attachments: [OutgoingAttachment]
    var messageID: String; var inReplyTo: String?; var references: [String]; var date: Date
    var extraHeaders: [(String, String)]
    var calendar: (method: String, ics: String)?
}
enum MIMEBuilder { static func build(_ m: OutgoingMIME) -> Data; static func makeMessageID(domain: String) -> String }

actor SMTPClient {
    init(transport: MailTransport, heloName: String = "unimail.local")
    func connect() async throws                    // 220
    func ehlo() async throws -> Set<String>
    func startTLS() async throws                   // STARTTLS, transport.startTLS(), повторный EHLO
    func authenticate(username: String, password: String) async throws   // PLAIN или LOGIN
    func send(from: String, recipients: [String], data: Data) async throws  // MAIL/RCPT/DATA c dot-stuffing
    func quit() async
}
enum SMTPError: LocalizedError { case rejected(code: Int, message: String), authenticationFailed(String), unexpected(String) }

struct ICSEvent: Sendable, Hashable { var uid: String; var summary: String; var start: Date; var end: Date; var allDay: Bool; var location: String?; var organizer: Address?; var attendees: [Address]; var sequence: Int; var method: String? }
enum ICSParser { static func parse(_ text: String) -> [ICSEvent] }
enum ICSPartStat: String { case accepted = "ACCEPTED", tentative = "TENTATIVE", declined = "DECLINED" }
enum ICSBuilder { static func reply(to event: ICSEvent, attendee: Address, status: ICSPartStat) -> String }
```

## Core/Store/Database — SQLite (системный SQLite3, без зависимостей)
```swift
struct FolderSyncState: Codable, Sendable { var accountID: UUID; var folder: String; var uidValidity: UInt32; var highestModSeq: UInt64?; var lastUID: UInt32 }
struct PendingActionRecord: Codable, Sendable, Identifiable { var id: UUID; var accountID: UUID; var kind: String; var payload: Data; var createdAt: Date; var attempts: Int }
struct StoredBody: Sendable { var text: String?; var html: String? }

final class MailDatabase: @unchecked Sendable {   // потокобезопасен (serial queue)
    init(url: URL) throws                          // создаёт схему, WAL
    static func inMemory() throws -> MailDatabase
    func upsert(_ messages: [Message]) throws
    func delete(ids: [String]) throws
    func deleteAccount(_ accountID: UUID) throws
    func allMessages() throws -> [Message]
    func message(id: String) throws -> Message?
    func search(_ query: String, accountID: UUID?, limit: Int) throws -> [String]   // FTS5, ранжировано
    func setBody(_ body: StoredBody, for id: String) throws                        // + обновляет FTS
    func body(for id: String) throws -> StoredBody?
    func syncState(accountID: UUID, folder: String) throws -> FolderSyncState?
    func setSyncState(_ state: FolderSyncState) throws
    func enqueue(_ action: PendingActionRecord) throws
    func pendingActions(accountID: UUID?) throws -> [PendingActionRecord]
    func removeAction(id: UUID) throws
    func updateAction(_ action: PendingActionRecord) throws
}
```

## Core/Automation
```swift
@MainActor @Observable final class AutomationStore {
    static let shared: AutomationStore
    var templates: [MailTemplate]; var rules: [MailRule]; var categoryOverrides: [CategoryOverride]
    var followUpDays: Int                           // по умолчанию 3
    func save()
    func learnCategory(for address: Address, category: InboxCategory)  // «переместить отправителя в категорию»
}
enum RuleEngine { static func apply(_ rules: [MailRule], to message: Message) -> (Message, notify: Bool) }
enum Categorizer { static func category(for m: Message, headers: [String: String], overrides: [CategoryOverride]) -> InboxCategory }
enum FollowUp { static func due(_ messages: [Message], now: Date) -> [Message] }   // исходящие с followUpAt < now без ответа в треде
```

## Сервисы macOS (Core/Services, UI)
- `CalendarService` (EventKit): доступ, события дня/недели, добавление встречи из `Invite`.
- `NotificationService`: разрешение, уведомление о новых письмах с действиями «Архив», «Прочитано», «Ответить».
- Строка меню (`MenuBarExtra`), бейдж Dock, автозапуск (`SMAppService.mainApp`).
- `UnsubscribeService`: RFC 8058 one-click (POST) или mailto.
- `ExportService`: PDF треда, печать, сохранение .eml.
- `AIService`: сводка треда и черновик ответа через Anthropic API по ключу пользователя из Keychain.

## Core/Providers — IMAPProvider
```swift
actor IMAPProvider: MailProvider {
    init(account: Account, database: MailDatabase, transportFactory: @escaping TransportFactory,
         password: @escaping @Sendable () -> String?, cacheDirectory: URL)
}
typealias TransportFactory = @Sendable (host, port, implicitTLS, readTimeout) async throws -> MailTransport
```
- Id письма: `"<accountID>|<папка>|<uidvalidity>|<uid>"`; копия отправленного до синхронизации — `"<accountID>|local-sent|<Message-ID>"`.
- Треды: Gmail — `"<accountID>-g<X-GM-THRID>"`, остальные — `"<accountID>-m<первый References / In-Reply-To / Message-ID>"`; MailStore дополнительно приклеивает письмо к треду известного родителя.
- Синхронизация папок по ролям (SPECIAL-USE): новые UID после `lastUID`, удалённые — сверкой диапазона, флаги — `CHANGEDSINCE` или последние 800 UID. Первая загрузка — 30 дней, не больше 400 писем.
- Команды идут по одному соединению под `AsyncMutex`; IDLE — на втором соединении (`waitForChanges`).
- Тело: `BODY.PEEK[]` → `MIMEParser` → вложения в `~/Library/Caches/UniMail/attachments`, встроенные картинки — data:-URI, text/calendar → `Invite`.
- «Отложить» — только локально. Gmail сам кладёт копию в «Отправленные», остальным — `APPEND`.

## Core/Store — MailStore
- При запуске читает письма настоящих ящиков из базы; демо-ящики живут только в памяти.
- `merge`: для известных писем сервер обновляет флаги, а локальные поля (роль, snooze, категория, напоминание, скачанное тело) сохраняются; новые входящие проходят `AutomationStore.process` (категория + правила, действия правил уходят на сервер).
- `markDirty` → запись в базу пачкой через 0,7 с на отдельной очереди; в строке письма — только превью, тело — в `bodies` (для FTS).
- Журнал: неудачное из-за сети действие → `pending_actions`, повтор в начале `refresh`.
- Запланированные письма — `scheduled.json` рядом с базой.

## Проверки на Linux
`scripts/linux-checks.sh` собирает и запускает `Tests/LinuxChecks/*`: IMAP, MIME/SMTP/ICS, Database, Automation, RichText, Provider (фейковые серверы из `Provider/FakeServers.swift`), Store (MailStore целиком, заглушки SwiftUI/Keychain/EventKit в `Store/Stubs.swift`).
