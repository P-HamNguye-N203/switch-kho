import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Sendable {
    case int(Int64), double(Double), text(String), null
}

/// Minimal thread-safe SQLite wrapper.
///
/// `@unchecked Sendable` is sound here: the only mutable state is the connection handle,
/// and every access to it happens while holding `lock` (recursive, so `transaction`
/// bodies can call the other methods).
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            sqlite3_close(handle)
            handle = nil
            throw KhoError.io("Không mở được cơ sở dữ liệu: \(message)")
        }
        sqlite3_busy_timeout(handle, 5000)
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        }
    }

    deinit { sqlite3_close(handle) }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        sqlite3_close(handle)
        handle = nil
    }

    /// Rows changed by the most recent INSERT/UPDATE/DELETE on this connection.
    public func changes() -> Int {
        lock.lock(); defer { lock.unlock() }
        return Int(sqlite3_changes(handle))
    }

    /// Runs an UPDATE/DELETE and returns the number of rows it changed, atomically with
    /// respect to other callers.
    public func runChanges(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try run(sql, params)
        return Int(sqlite3_changes(handle))
    }

    public func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int64? {
        try query(sql, params) { $0.isNull(0) ? nil : $0.int(0) }.first ?? nil
    }

    public func scalarText(_ sql: String, _ params: [SQLValue] = []) throws -> String? {
        try query(sql, params) { $0.isNull(0) ? nil : $0.text(0) }.first ?? nil
    }

    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw KhoError.io("SQLite: \(message)")
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
        return sqlite3_last_insert_rowid(handle)
    }

    public func query<T>(_ sql: String, _ params: [SQLValue] = [], _ map: (Row) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(map(Row(stmt: stmt)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw lastError()
            }
        }
        return out
    }

    /// Runs `body` inside a transaction; rolls back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Prepared statement reused for bulk inserts.
    public func withStatement(_ sql: String, _ body: (Statement) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, [])
        defer { sqlite3_finalize(stmt) }
        try body(Statement(stmt: stmt, db: self))
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        bind(stmt, params)
        return stmt
    }

    fileprivate func bind(_ stmt: OpaquePointer?, _ params: [SQLValue]) {
        for (i, value) in params.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    fileprivate func lastError() -> KhoError {
        KhoError.io("SQLite: \(String(cString: sqlite3_errmsg(handle)))")
    }

    public struct Row {
        let stmt: OpaquePointer?
        public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        public func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        public func optInt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
        public func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
        public func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
    }

    public struct Statement {
        let stmt: OpaquePointer?
        let db: SQLiteDatabase
        public func run(_ params: [SQLValue]) throws {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            db.bind(stmt, params)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw db.lastError() }
        }
    }
}
