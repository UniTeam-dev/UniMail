import Foundation

/// Локальная база писем на системном SQLite.
///
/// Потокобезопасна: все обращения к соединению идут через собственную последовательную
/// очередь (`queue.sync`), поэтому методы синхронные и их можно вызывать с любого потока
/// (из UI — только быстрые, пакетную запись лучше делать из фоновой задачи).
///
/// Источник истины для письма — JSON `Message` в колонке `data`; остальные колонки
/// (`account_id`, `role`, `date`…) — денормализованные ключи для индексов.
/// Полнотекстовый индекс `messages_fts` (FTS5) обновляется вместе с письмами и телами;
/// его rowid — стабильная колонка `messages.doc` (rowid обычной таблицы может смениться после VACUUM).
///
/// Методы не реентерабельны: не вызывайте `MailDatabase` из замыканий, выполняемых внутри неё.
final class MailDatabase: @unchecked Sendable {
    /// Путь к файлу базы (nil для базы в памяти).
    let url: URL?

    private let queue = DispatchQueue(label: "app.unimail.MailDatabase", qos: .userInitiated)
    private let db: DatabaseConnection
    /// Следующий свободный `doc` (rowid в FTS). Меняется только внутри очереди.
    private var nextDoc: Int64 = 1

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    // MARK: Открытие

    /// Открывает (или создаёт) базу в файле: WAL, внешние ключи, миграция схемы.
    convenience init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(path: url.path, url: url)
    }

    /// База в памяти — для тестов и превью.
    static func inMemory() throws -> MailDatabase {
        try MailDatabase(path: ":memory:", url: nil)
    }

    private init(path: String, url: URL?) throws {
        self.url = url
        db = try DatabaseConnection(path: path)
        try db.setBusyTimeout(milliseconds: 5_000)
        try db.execute("PRAGMA foreign_keys = ON")
        if url != nil {
            // Для :memory: журнал всегда «memory», WAL там не нужен.
            try db.execute("PRAGMA journal_mode = WAL")
            try db.execute("PRAGMA synchronous = NORMAL")
        }
        try MailDatabase.migrate(db)
        nextDoc = (try db.queryFirst("SELECT COALESCE(MAX(doc), 0) + 1 FROM messages") { $0.int64(0) }) ?? 1
    }

    deinit {
        db.close()
    }

    // MARK: Письма

    /// Вставить или обновить письма одной транзакцией (10 000 писем — доли секунды).
    /// Обновление сохраняет скачанное тело (`bodies`) и пересобирает строку FTS.
    func upsert(_ messages: [Message]) throws {
        guard !messages.isEmpty else { return }
        try queue.sync {
            try db.transaction {
                for message in messages { try upsertLocked(message) }
            }
        }
    }

    /// Удалить письма по id (вместе с телами и строками FTS). Неизвестные id игнорируются.
    func delete(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try db.transaction {
                for id in ids {
                    guard let doc = try docLocked(for: id) else { continue }
                    try db.run("DELETE FROM messages_fts WHERE rowid = ?", [.integer(doc)])
                    try db.run("DELETE FROM messages WHERE id = ?", [.text(id)])   // bodies — ON DELETE CASCADE
                }
            }
        }
    }

    /// Удалить всё, что относится к аккаунту: письма, тела, FTS, состояние синхронизации, очередь действий.
    func deleteAccount(_ accountID: UUID) throws {
        let key = SQLValue.text(accountID.uuidString)
        try queue.sync {
            try db.transaction {
                try db.run("DELETE FROM messages_fts WHERE rowid IN (SELECT doc FROM messages WHERE account_id = ?)", [key])
                try db.run("DELETE FROM bodies WHERE id IN (SELECT id FROM messages WHERE account_id = ?)", [key])
                try db.run("DELETE FROM messages WHERE account_id = ?", [key])
                try db.run("DELETE FROM sync_state WHERE account_id = ?", [key])
                try db.run("DELETE FROM pending_actions WHERE account_id = ?", [key])
            }
        }
    }

    /// Все письма, новые сверху. Строки, которые не удалось декодировать, пропускаются.
    func allMessages() throws -> [Message] {
        try queue.sync {
            let blobs = try db.query("SELECT data FROM messages ORDER BY date DESC, id") { $0.blob(0) }
            return blobs.compactMap { data in data.flatMap { try? decoder.decode(Message.self, from: $0) } }
        }
    }

    /// Письмо по id; nil, если его нет или строку не удалось декодировать.
    func message(id: String) throws -> Message? {
        try queue.sync {
            guard let data = try db.queryFirst("SELECT data FROM messages WHERE id = ?", [.text(id)], { $0.blob(0) }),
                  let data else { return nil }
            return try? decoder.decode(Message.self, from: data)
        }
    }

    // MARK: Поиск

    /// Полнотекстовый поиск (FTS5): id писем, лучшие совпадения первыми (bm25).
    ///
    /// Ввод пользователя безопасен: он превращается в набор квотированных префиксных термов
    /// (см. `MailFTS.matchExpression`). Поддерживаются `from:`, `subject:`, `to:` и `"точная фраза"`.
    /// `limit <= 0` — без ограничения.
    func search(_ query: String, accountID: UUID?, limit: Int) throws -> [String] {
        guard let expression = MailFTS.matchExpression(for: query) else { return [] }
        // Веса колонок bm25: id (неиндексируемая), subject, sender, recipients, body.
        var sql = """
        SELECT m.id FROM messages_fts
        JOIN messages m ON m.doc = messages_fts.rowid
        WHERE messages_fts MATCH ?
        """
        var values: [SQLValue] = [.text(expression)]
        if let accountID {
            sql += " AND m.account_id = ?"
            values.append(.text(accountID.uuidString))
        }
        sql += " ORDER BY bm25(messages_fts, 0.0, 10.0, 5.0, 3.0, 1.0), m.date DESC LIMIT ?"
        values.append(.integer(limit > 0 ? Int64(limit) : -1))
        return try queue.sync {
            try db.query(sql, values) { $0.text(0) ?? "" }
        }
    }

    // MARK: Тела писем

    /// Сохранить скачанное тело и обновить текст в FTS (HTML без текстовой части очищается от тегов).
    /// Бросает ошибку внешнего ключа, если письма с таким id нет.
    func setBody(_ body: StoredBody, for id: String) throws {
        try queue.sync {
            try db.transaction {
                try db.run("""
                    INSERT INTO bodies (id, text, html) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET text = excluded.text, html = excluded.html
                    """, [.text(id), .optionalText(body.text), .optionalText(body.html)])
                guard let row = try db.queryFirst("SELECT doc, data FROM messages WHERE id = ?", [.text(id)], {
                    ($0.int64(0), $0.blob(1))
                }) else { return }
                let message = row.1.flatMap { try? decoder.decode(Message.self, from: $0) }
                let text = MailDatabase.ftsBody(message: message, stored: body)
                try db.run("UPDATE messages_fts SET body = ? WHERE rowid = ?", [.text(text), .integer(row.0)])
            }
        }
    }

    func body(for id: String) throws -> StoredBody? {
        try queue.sync { try bodyLocked(for: id) }
    }

    // MARK: Состояние синхронизации

    func syncState(accountID: UUID, folder: String) throws -> FolderSyncState? {
        try queue.sync {
            try db.queryFirst("""
                SELECT uid_validity, highest_modseq, last_uid FROM sync_state
                WHERE account_id = ? AND folder = ?
                """, [.text(accountID.uuidString), .text(folder)]) { row in
                FolderSyncState(
                    accountID: accountID,
                    folder: folder,
                    uidValidity: UInt32(truncatingIfNeeded: row.int64(0)),
                    highestModSeq: row.optionalInt64(1).map { UInt64(bitPattern: $0) },
                    lastUID: UInt32(truncatingIfNeeded: row.int64(2)))
            }
        }
    }

    func setSyncState(_ state: FolderSyncState) throws {
        try queue.sync {
            _ = try db.run("""
                INSERT INTO sync_state (account_id, folder, uid_validity, highest_modseq, last_uid)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(account_id, folder) DO UPDATE SET
                    uid_validity = excluded.uid_validity,
                    highest_modseq = excluded.highest_modseq,
                    last_uid = excluded.last_uid
                """, [
                    .text(state.accountID.uuidString),
                    .text(state.folder),
                    .integer(Int64(state.uidValidity)),
                    .optionalInteger(state.highestModSeq.map { Int64(bitPattern: $0) }),
                    .integer(Int64(state.lastUID)),
                ])
        }
    }

    // MARK: Очередь отложенных действий

    /// Добавить действие в очередь. Повторный вызов с тем же id перезаписывает запись.
    func enqueue(_ action: PendingActionRecord) throws {
        try queue.sync {
            _ = try db.run("""
                INSERT INTO pending_actions (id, account_id, kind, payload, created_at, attempts)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    account_id = excluded.account_id, kind = excluded.kind, payload = excluded.payload,
                    created_at = excluded.created_at, attempts = excluded.attempts
                """, MailDatabase.values(for: action))
        }
    }

    /// Действия в порядке постановки в очередь (для аккаунта или все при nil).
    func pendingActions(accountID: UUID?) throws -> [PendingActionRecord] {
        let columns = "SELECT id, account_id, kind, payload, created_at, attempts FROM pending_actions"
        let order = " ORDER BY created_at, rowid"
        return try queue.sync {
            let map: (DatabaseStatement) throws -> PendingActionRecord? = { row in
                guard let id = row.text(0).flatMap(UUID.init(uuidString:)),
                      let account = row.text(1).flatMap(UUID.init(uuidString:)) else { return nil }
                return PendingActionRecord(
                    id: id, accountID: account, kind: row.text(2) ?? "",
                    payload: row.blob(3) ?? Data(),
                    createdAt: Date(timeIntervalSince1970: row.double(4)),
                    attempts: Int(row.int64(5)))
            }
            if let accountID {
                return try db.query(columns + " WHERE account_id = ?" + order, [.text(accountID.uuidString)], map).compactMap { $0 }
            }
            return try db.query(columns + order, [], map).compactMap { $0 }
        }
    }

    func removeAction(id: UUID) throws {
        try queue.sync {
            _ = try db.run("DELETE FROM pending_actions WHERE id = ?", [.text(id.uuidString)])
        }
    }

    /// Обновить действие (обычно `attempts` после неудачной попытки). Если записи нет — ничего не делает.
    func updateAction(_ action: PendingActionRecord) throws {
        var values = MailDatabase.values(for: action)
        values.append(values.removeFirst())   // id — в конец, для WHERE
        try queue.sync {
            _ = try db.run("""
                UPDATE pending_actions SET account_id = ?, kind = ?, payload = ?, created_at = ?, attempts = ?
                WHERE id = ?
                """, values)
        }
    }

    // MARK: Внутреннее (вызывается только внутри очереди)

    /// UID писем папки на сервере: id → uid (для сверки при синхронизации IMAP).
    func folderUIDs(accountID: UUID, folder: String) throws -> [String: UInt32] {
        try queue.sync {
            let rows = try db.query(
                "SELECT id, uid FROM messages WHERE account_id = ? AND folder = ? AND uid IS NOT NULL AND instr(id, ?) > 0",
                [.text(accountID.uuidString), .text(folder), .text("|\(folder)|")]
            ) { stmt -> (String, UInt32) in
                (stmt.text(0) ?? "", UInt32(truncatingIfNeeded: stmt.int64(1)))
            }
            return Dictionary(rows, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Письма одной папки аккаунта (EWS: сверка с сервером без UID).
    func messages(accountID: UUID, folder: String) throws -> [Message] {
        try queue.sync {
            let rows = try db.query("SELECT data FROM messages WHERE account_id = ? AND folder = ? AND instr(id, ?) > 0",
                                    [.text(accountID.uuidString), .text(folder), .text("|\(folder)|")]) { $0.blob(0) }
            return rows.compactMap { $0.flatMap { try? decoder.decode(Message.self, from: $0) } }
        }
    }

    /// Письма, перенесённые в папку локально (id ещё из старой папки): при синхронизации папки
    /// их заменяют настоящие копии с сервера.
    func movedIn(accountID: UUID, folder: String) throws -> [String] {
        try queue.sync {
            try db.query("SELECT id FROM messages WHERE account_id = ? AND folder = ? AND instr(id, ?) = 0",
                         [.text(accountID.uuidString), .text(folder), .text("|\(folder)|")]) { $0.text(0) ?? "" }
        }
    }

    /// Письма по списку id (для обновления флагов после синхронизации).
    func messages(ids: [String]) throws -> [Message] {
        guard !ids.isEmpty else { return [] }
        return try queue.sync {
            var result: [Message] = []
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try db.query("SELECT data FROM messages WHERE id IN (\(placeholders))",
                                        chunk.map { SQLValue.text($0) }) { $0.blob(0) }
                result += rows.compactMap { $0.flatMap { try? decoder.decode(Message.self, from: $0) } }
            }
            return result
        }
    }

    private func docLocked(for id: String) throws -> Int64? {
        try db.queryFirst("SELECT doc FROM messages WHERE id = ?", [.text(id)]) { $0.int64(0) }
    }

    private func bodyLocked(for id: String) throws -> StoredBody? {
        try db.queryFirst("SELECT text, html FROM bodies WHERE id = ?", [.text(id)]) {
            StoredBody(text: $0.text(0), html: $0.text(1))
        }
    }

    private func upsertLocked(_ message: Message) throws {
        let existing = try docLocked(for: message.id)
        let doc: Int64
        if let existing {
            doc = existing
        } else {
            doc = nextDoc
            nextDoc += 1
        }
        let data = try encoder.encode(message)
        try db.run("""
            INSERT INTO messages (id, doc, account_id, thread_id, role, folder, uid, date, is_read, data)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                account_id = excluded.account_id, thread_id = excluded.thread_id, role = excluded.role,
                folder = excluded.folder, uid = excluded.uid, date = excluded.date,
                is_read = excluded.is_read, data = excluded.data
            """, [
                .text(message.id),
                .integer(doc),
                .text(message.accountID.uuidString),
                .text(message.threadID),
                .text(message.role.rawValue),
                .optionalText(message.folder),
                .optionalInteger(message.uid.map { Int64($0) }),
                .real(message.date.timeIntervalSince1970),
                .integer(message.isRead ? 1 : 0),
                .blob(data),
            ])

        // Тело из bodies может существовать только у уже сохранённого письма.
        let stored = existing != nil ? try bodyLocked(for: message.id) : nil
        if existing != nil {
            try db.run("DELETE FROM messages_fts WHERE rowid = ?", [.integer(doc)])
        }
        try db.run("""
            INSERT INTO messages_fts (rowid, id, subject, sender, recipients, body) VALUES (?, ?, ?, ?, ?, ?)
            """, [
                .integer(doc),
                .text(message.id),
                .text(message.subject),
                .text(MailDatabase.addressText([message.from])),
                .text(MailDatabase.addressText(message.to + message.cc)),
                .text(MailDatabase.ftsBody(message: message, stored: stored)),
            ])
    }

    /// «Имя email» через пробел — токенизатор разобьёт email на части (ivan, example, com).
    static func addressText(_ addresses: [Address]) -> String {
        addresses.map { [$0.name ?? "", $0.email].filter { !$0.isEmpty }.joined(separator: " ") }
            .joined(separator: " ")
    }

    /// Текст для колонки body: превью/тело из `Message` плюс скачанное тело.
    /// HTML без текстовой части очищается от тегов.
    static func ftsBody(message: Message?, stored: StoredBody?) -> String {
        var parts: [String] = []
        if let message {
            if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(message.body)
            } else if let html = message.htmlBody, !html.isEmpty {
                parts.append(MailFTS.plainText(fromHTML: html))
            }
        }
        if let stored {
            if let text = stored.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if text != message?.body { parts.append(text) }
            } else if let html = stored.html, !html.isEmpty {
                parts.append(MailFTS.plainText(fromHTML: html))
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func values(for action: PendingActionRecord) -> [SQLValue] {
        [
            .text(action.id.uuidString),
            .text(action.accountID.uuidString),
            .text(action.kind),
            .blob(action.payload),
            .real(action.createdAt.timeIntervalSince1970),
            .integer(Int64(action.attempts)),
        ]
    }
}
