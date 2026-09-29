import Foundation

/// Схема базы и миграции. Версия схемы хранится в `PRAGMA user_version`.
///
/// Правила:
/// - каждая миграция выполняется в своей транзакции вместе с установкой `user_version`,
///   поэтому база никогда не остаётся «наполовину обновлённой»;
/// - повторный запуск `migrate` ничего не делает (идемпотентно);
/// - база от более новой версии приложения не открывается (чтобы не испортить её).
extension MailDatabase {
    /// Текущая версия схемы, которую знает этот код.
    static let schemaVersion = 1

    /// Шаги миграции: версия, до которой поднимает шаг, и SQL.
    static let migrations: [(version: Int, sql: String)] = [
        (1, """
        CREATE TABLE IF NOT EXISTS messages (
            id          TEXT PRIMARY KEY NOT NULL,
            doc         INTEGER NOT NULL UNIQUE,   -- стабильный rowid строки в messages_fts
            account_id  TEXT NOT NULL,
            thread_id   TEXT NOT NULL,
            role        TEXT NOT NULL,
            folder      TEXT,
            uid         INTEGER,
            date        REAL NOT NULL,
            is_read     INTEGER NOT NULL DEFAULT 0,
            data        BLOB NOT NULL              -- JSON Message
        );
        CREATE INDEX IF NOT EXISTS idx_messages_account_role_date ON messages(account_id, role, date);
        CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id);
        CREATE INDEX IF NOT EXISTS idx_messages_folder_uid ON messages(account_id, folder, uid);

        CREATE TABLE IF NOT EXISTS bodies (
            id    TEXT PRIMARY KEY NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            text  TEXT,
            html  TEXT
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            id UNINDEXED,
            subject,
            sender,
            recipients,
            body,
            tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE TABLE IF NOT EXISTS sync_state (
            account_id      TEXT NOT NULL,
            folder          TEXT NOT NULL,
            uid_validity    INTEGER NOT NULL,
            highest_modseq  INTEGER,
            last_uid        INTEGER NOT NULL,
            PRIMARY KEY (account_id, folder)
        );

        CREATE TABLE IF NOT EXISTS pending_actions (
            id          TEXT PRIMARY KEY NOT NULL,
            account_id  TEXT NOT NULL,
            kind        TEXT NOT NULL,
            payload     BLOB NOT NULL,
            created_at  REAL NOT NULL,
            attempts    INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_pending_account_created ON pending_actions(account_id, created_at);
        """),
    ]

    /// Привести схему к `schemaVersion`. Вызывается из `init`; безопасно вызывать повторно.
    static func migrate(_ db: DatabaseConnection) throws {
        let current = try db.pragmaInt("user_version")
        guard current <= schemaVersion else {
            throw MailDatabaseError.logic("database schema v\(current) is newer than supported v\(schemaVersion)")
        }
        for step in migrations where step.version > current {
            try db.transaction {
                try db.execute(step.sql)
                try db.execute("PRAGMA user_version = \(step.version)")
            }
        }
    }
}
