import Foundation

/// Действие над письмами, которое провайдер должен повторить на сервере.
enum MailAction: Sendable, Equatable {
    case markRead(ids: [String], read: Bool)
    case flag(ids: [String], flagged: Bool)
    case move(ids: [String], to: MailboxRole)
    case deletePermanently(ids: [String])
    case snooze(ids: [String], until: Date)
}

/// Результат инкрементальной синхронизации.
struct SyncResult: Sendable {
    var upserted: [Message]
    var deletedIDs: [String]
    /// Непрозрачный курсор: UIDVALIDITY+MODSEQ для IMAP, historyId для Gmail, deltaLink для Graph.
    var cursor: String?
}

enum MailProviderError: LocalizedError {
    case notImplemented(ProviderKind)
    case authenticationFailed
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let kind):
            "Синхронизация «\(kind.title)» появится на следующих этапах."
        case .authenticationFailed:
            "Не удалось войти. Проверьте логин и пароль."
        case .network(let details):
            "Нет связи с сервером: \(details)"
        }
    }
}

/// Контракт, который реализует каждый источник почты: IMAP, Gmail API, Microsoft Graph, демо.
/// UI с провайдерами напрямую не общается — только через MailStore.
protocol MailProvider: Sendable {
    var accountID: UUID { get }

    /// Инкрементальная синхронизация от курсора (nil — первая загрузка).
    func sync(cursor: String?) async throws -> SyncResult

    /// Повторить действие на сервере. Вызывается из очереди действий после окна «Отменить».
    func apply(_ action: MailAction) async throws

    /// Отправить письмо. Возвращает серверную копию для папки «Отправленные».
    func send(_ message: OutgoingMessage) async throws -> Message
}

/// Заглушка для типов, чья синхронизация ещё не реализована.
struct PendingProvider: MailProvider {
    let accountID: UUID
    let kind: ProviderKind

    func sync(cursor: String?) async throws -> SyncResult {
        throw MailProviderError.notImplemented(kind)
    }

    func apply(_ action: MailAction) async throws {
        throw MailProviderError.notImplemented(kind)
    }

    func send(_ message: OutgoingMessage) async throws -> Message {
        throw MailProviderError.notImplemented(kind)
    }
}

enum ProviderFactory {
    static func make(for account: Account) -> any MailProvider {
        switch account.kind {
        case .demo:
            return DemoProvider(account: account)
        case .gmail, .outlook, .icloud, .imap:
            return PendingProvider(accountID: account.id, kind: account.kind)
        }
    }
}
