import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` из C-заголовка не импортируется в Swift (это макрос с приведением типа),
/// поэтому объявляем вручную: SQLite копирует переданные байты сразу при bind.
/// `private` — чтобы не конфликтовать с таким же именем в других файлах таргета.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Ошибка SQLite: код результата, текст от движка и SQL, на котором упали.
struct MailDatabaseError: Error, CustomStringConvertible, Sendable {
    var code: Int32
    var message: String
    var sql: String?

    var description: String {
        if let sql { return "SQLite error \(code): \(message) — \(sql)" }
        return "SQLite error \(code): \(message)"
    }

    /// Ошибки уровня нашей логики, а не движка (например, база от более новой версии приложения).
    static func logic(_ message: String) -> MailDatabaseError {
        MailDatabaseError(code: SQLITE_ERROR, message: message, sql: nil)
    }
}

/// Значение для привязки к параметру запроса.
enum SQLValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func optionalText(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
    static func optionalInteger(_ value: Int64?) -> SQLValue { value.map { .integer($0) } ?? .null }
}

/// Подготовленный запрос. Не потокобезопасен — используется только внутри очереди `MailDatabase`.
final class DatabaseStatement {
    let handle: OpaquePointer
    let sql: String
    private let db: OpaquePointer

    init(db: OpaquePointer, sql: String) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let message = String(cString: sqlite3_errmsg(db))
            if let stmt { sqlite3_finalize(stmt) }
            throw MailDatabaseError(code: rc, message: message, sql: sql)
        }
        self.db = db
        self.handle = stmt
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    /// Сбросить курсор и привязки, чтобы переиспользовать запрос из кэша.
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            try bind(value, at: Int32(offset + 1))
        }
    }

    func bind(_ value: SQLValue, at index: Int32) throws {
        let rc: Int32
        switch value {
        case .null:
            rc = sqlite3_bind_null(handle, index)
        case .integer(let v):
            rc = sqlite3_bind_int64(handle, index, v)
        case .real(let v):
            rc = sqlite3_bind_double(handle, index, v)
        case .text(let v):
            rc = sqlite3_bind_text(handle, index, v, -1, SQLITE_TRANSIENT)
        case .blob(let data):
            if data.isEmpty {
                rc = sqlite3_bind_zeroblob(handle, index, 0)
            } else {
                rc = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(handle, index, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                }
            }
        }
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    /// Шаг выполнения: `true` — есть строка, `false` — запрос завершён.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error(rc)
        }
    }

    // MARK: Чтение колонок

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }

    func optionalInt64(_ column: Int32) -> Int64? { isNull(column) ? nil : int64(column) }

    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }

    func text(_ column: Int32) -> String? {
        guard let ptr = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: ptr)
    }

    func blob(_ column: Int32) -> Data? {
        if isNull(column) { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let ptr = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: ptr, count: count)
    }

    private func error(_ rc: Int32) -> MailDatabaseError {
        MailDatabaseError(code: rc, message: String(cString: sqlite3_errmsg(db)), sql: sql)
    }
}

/// Тонкая обёртка над соединением SQLite с кэшем подготовленных запросов.
/// Не потокобезопасна: `MailDatabase` вызывает её только из своей последовательной очереди.
final class DatabaseConnection {
    private(set) var handle: OpaquePointer?
    let path: String
    private var cache: [String: DatabaseStatement] = [:]
    private var transactionDepth = 0

    init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let db { sqlite3_close_v2(db) }
            throw MailDatabaseError(code: rc, message: message, sql: nil)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
    }

    deinit { close() }

    /// Финализирует все запросы из кэша и закрывает соединение. Повторный вызов безопасен.
    func close() {
        cache.removeAll()          // deinit каждого DatabaseStatement вызывает sqlite3_finalize
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private func db() throws -> OpaquePointer {
        guard let handle else { throw MailDatabaseError.logic("database is closed") }
        return handle
    }

    /// Выполнить один или несколько SQL-операторов без параметров (схема, PRAGMA).
    func execute(_ sql: String) throws {
        let db = try db()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw MailDatabaseError(code: rc, message: message, sql: sql)
        }
    }

    func setBusyTimeout(milliseconds: Int32) throws {
        let rc = sqlite3_busy_timeout(try db(), milliseconds)
        guard rc == SQLITE_OK else { throw MailDatabaseError(code: rc, message: "busy_timeout", sql: nil) }
    }

    /// Подготовленный запрос из кэша (или новый). Перед возвратом сброшен.
    func prepare(_ sql: String) throws -> DatabaseStatement {
        if let cached = cache[sql] {
            cached.reset()
            return cached
        }
        let statement = try DatabaseStatement(db: try db(), sql: sql)
        cache[sql] = statement
        return statement
    }

    /// Выполнить изменяющий запрос. Возвращает число затронутых строк.
    @discardableResult
    func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql)
        defer { statement.reset() }
        try statement.bind(values)
        while try statement.step() {}
        return Int(sqlite3_changes(try db()))
    }

    /// Выполнить выборку и преобразовать каждую строку.
    func query<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (DatabaseStatement) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { statement.reset() }
        try statement.bind(values)
        var rows: [T] = []
        while try statement.step() {
            rows.append(try map(statement))
        }
        return rows
    }

    /// Первая строка выборки или nil.
    func queryFirst<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (DatabaseStatement) throws -> T) throws -> T? {
        let statement = try prepare(sql)
        defer { statement.reset() }
        try statement.bind(values)
        guard try statement.step() else { return nil }
        return try map(statement)
    }

    /// Целочисленная PRAGMA (например, user_version).
    func pragmaInt(_ name: String) throws -> Int {
        Int(try queryFirst("PRAGMA \(name)") { $0.int64(0) } ?? 0)
    }

    /// Транзакция: BEGIN IMMEDIATE … COMMIT, при ошибке — ROLLBACK.
    /// Вложенные вызовы выполняются внутри внешней транзакции (через SAVEPOINT).
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let depth = transactionDepth
        let savepoint = "sp\(depth)"
        try execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        do {
            let result = try body()
            transactionDepth -= 1
            try execute(depth == 0 ? "COMMIT" : "RELEASE \(savepoint)")
            return result
        } catch {
            transactionDepth = depth
            if depth == 0 {
                try? execute("ROLLBACK")
            } else {
                try? execute("ROLLBACK TO \(savepoint)")
                try? execute("RELEASE \(savepoint)")
            }
            throw error
        }
    }
}
