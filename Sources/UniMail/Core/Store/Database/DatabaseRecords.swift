import Foundation

/// Состояние синхронизации одной папки IMAP (UIDVALIDITY, CONDSTORE MODSEQ, последний UID).
struct FolderSyncState: Codable, Sendable, Hashable {
    var accountID: UUID
    var folder: String
    var uidValidity: UInt32
    var highestModSeq: UInt64?
    var lastUID: UInt32
}

/// Отложенное действие (офлайн-очередь): пометить прочитанным, переместить, отправить…
/// `payload` — произвольные данные действия (обычно JSON), БД их не разбирает.
struct PendingActionRecord: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var accountID: UUID
    var kind: String
    var payload: Data
    var createdAt: Date
    var attempts: Int
}

/// Скачанное тело письма: текстовая и/или HTML-часть.
struct StoredBody: Sendable, Hashable {
    var text: String?
    var html: String?
}
