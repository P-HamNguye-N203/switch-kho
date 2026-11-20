import Darwin
import Foundation

public enum OperationKind: String, Sendable, Codable { case personal, appCold, appLive }

public enum OperationState: String, Sendable, Codable, CaseIterable {
    case copying, moving, holding, committing, undoing, restoring, committed, restored, undone, failed

    public static let terminal: Set<OperationState> = [.restored, .undone, .failed]
    public static let finished: Set<OperationState> = [.committed, .restored, .undone, .failed]
}

public enum ItemRole: String, Sendable, Codable { case normal, setAside }
public enum ItemStage: String, Sendable, Codable { case copied, swapped }

/// Name that does not collide with `Foundation.Operation` in app code.
public typealias LedgerOperation = Operation

public struct Operation: Sendable, Hashable {
    public let id: Int64
    public let uid: String
    public let kind: OperationKind
    public let title: String?
    public let bundleID: String?
    public let khoUUID: String
    public let state: OperationState
    public let createdAt: Date
    public let holdingUntil: Date?
    public let finishedAt: Date?
    public let error: String?
    public let needsReview: Bool
}

public struct OperationItem: Sendable, Hashable {
    public let id: Int64
    public let opID: Int64
    public let idx: Int
    public let originalPath: String
    public let purpose: PathPurpose
    public let role: ItemRole
    public let origIno: UInt64?
    public let khoRelPath: String?
    public let holdingPath: String?
    public let leftSymlink: Bool
    public let symlinkCreated: Bool
    public let released: Bool
    public let restored: Bool
    public let stage: ItemStage?
    public let stagePath: String?
    public let restoredPath: String?
    public let allocated: Int64?
    public let filesJSON: String?

    public var originalURL: URL { URL(fileURLWithPath: originalPath) }

    public func files() -> [CopiedFile] { decodedFiles() ?? [] }

    /// nil when the file list is missing or unreadable (callers that guard deletions must
    /// treat that as a failure, not as "no files").
    public func decodedFiles() -> [CopiedFile]? {
        guard let filesJSON, let data = filesJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([CopiedFile].self, from: data)
    }
}

public struct PendingCleanup: Sendable, Equatable {
    public let id: Int64
    public let khoUUID: String
    public let khoRelPath: String
}

public struct ActivityEntry: Sendable, Equatable {
    public let at: Date
    public let action: String
    public let path: String?
    public let detail: String?
    public let ok: Bool
}

/// Durable operation ledger with a strict state machine and `user_version` migrations.
///
/// `@unchecked Sendable` is sound: the only state is the `SQLiteDatabase`, which serialises
/// every access behind its own lock; `Ledger` keeps no mutable state of its own.
public final class Ledger: @unchecked Sendable {
    public static let latestVersion: Int64 = 1
    public let path: URL
    let db: SQLiteDatabase

    public init(path: URL) throws {
        self.path = path
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: path.path)
        db = try SQLiteDatabase(path: path.path)
        let version = try db.scalarInt("PRAGMA user_version") ?? 0
        if version < Self.latestVersion {
            if existed {
                try backup(to: URL(fileURLWithPath: path.path + ".bak"), allowShrink: true)
            }
            try migrate(from: version)
        }
    }

    public func close() { db.close() }

    private func migrate(from version: Int64) throws {
        if version < 1 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE operations(
                  id INTEGER PRIMARY KEY,
                  uid TEXT NOT NULL UNIQUE,
                  kind TEXT NOT NULL CHECK(kind IN ('personal','appCold','appLive')),
                  title TEXT, bundle_id TEXT,
                  kho_uuid TEXT NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('copying','moving','holding','committing','undoing','restoring','committed','restored','undone','failed')),
                  created_at REAL, holding_until REAL, finished_at REAL, error TEXT,
                  needs_review INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE operation_items(
                  id INTEGER PRIMARY KEY,
                  op_id INTEGER NOT NULL REFERENCES operations(id),
                  idx INTEGER NOT NULL,
                  original_path TEXT NOT NULL,
                  purpose TEXT NOT NULL,
                  role TEXT NOT NULL DEFAULT 'normal' CHECK(role IN ('normal','setAside')),
                  orig_ino INTEGER, kho_rel_path TEXT, holding_path TEXT,
                  left_symlink INTEGER NOT NULL DEFAULT 0,
                  symlink_created INTEGER NOT NULL DEFAULT 0,
                  released INTEGER NOT NULL DEFAULT 0,
                  restored INTEGER NOT NULL DEFAULT 0,
                  stage TEXT CHECK(stage IS NULL OR stage IN ('copied','swapped')),
                  stage_path TEXT, restored_path TEXT, allocated INTEGER, files_json TEXT);
                CREATE INDEX idx_items_kho ON operation_items(kho_rel_path);
                CREATE INDEX idx_items_original ON operation_items(original_path);
                CREATE TABLE pending_cleanup(id INTEGER PRIMARY KEY, kho_uuid TEXT NOT NULL,
                  kho_rel_path TEXT NOT NULL, created_at REAL);
                CREATE TABLE partials(path TEXT PRIMARY KEY, created_at REAL);
                CREATE TABLE activity(id INTEGER PRIMARY KEY, at REAL, action TEXT, path TEXT,
                  detail TEXT, ok INTEGER);
                CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT);
                PRAGMA user_version = 1;
                """)
            }
        }
    }

    static func now() -> Double { Date().timeIntervalSince1970 }

    // MARK: Operations

    static let opColumns = """
        id, uid, kind, title, bundle_id, kho_uuid, state, created_at, holding_until,
        finished_at, error, needs_review
        """

    static func mapOperation(_ r: SQLiteDatabase.Row) -> Operation {
        Operation(
            id: r.int(0), uid: r.text(1), kind: OperationKind(rawValue: r.text(2)) ?? .personal,
            title: r.optText(3), bundleID: r.optText(4), khoUUID: r.text(5),
            state: OperationState(rawValue: r.text(6)) ?? .failed,
            createdAt: Date(timeIntervalSince1970: r.double(7)),
            holdingUntil: r.optDouble(8).map(Date.init(timeIntervalSince1970:)),
            finishedAt: r.optDouble(9).map(Date.init(timeIntervalSince1970:)),
            error: r.optText(10), needsReview: r.int(11) != 0)
    }

    public func createOperation(kind: OperationKind, title: String?, bundleID: String?,
                                khoUUID: String) throws -> Int64 {
        try db.run(
            "INSERT INTO operations(uid, kind, title, bundle_id, kho_uuid, state, created_at) VALUES(?,?,?,?,?,'copying',?)",
            [.text(UUID().uuidString), .text(kind.rawValue), title.map(SQLValue.text) ?? .null,
             bundleID.map(SQLValue.text) ?? .null, .text(khoUUID), .double(Self.now())])
    }

    /// Compare-and-set state change in a single UPDATE. Returns false (and changes nothing)
    /// when the current state is not in `from`.
    @discardableResult
    public func transition(_ opID: Int64, from: Set<OperationState>, to: OperationState,
                           error: String? = nil, holdingUntil: Date? = nil) throws -> Bool {
        guard !from.isEmpty else { return false }
        let placeholders = Array(repeating: "?", count: from.count).joined(separator: ",")
        let finished = OperationState.finished.contains(to)
        let sql = """
            UPDATE operations SET state=?, error=?, holding_until=COALESCE(?, holding_until),
              finished_at=CASE WHEN ? THEN ? ELSE finished_at END
            WHERE id=? AND state IN (\(placeholders))
            """
        var params: [SQLValue] = [
            .text(to.rawValue), error.map(SQLValue.text) ?? .null,
            holdingUntil.map { .double($0.timeIntervalSince1970) } ?? .null,
            .int(finished ? 1 : 0), .double(Self.now()), .int(opID),
        ]
        params += from.map { .text($0.rawValue) }
        return try db.runChanges(sql, params) == 1
    }

    public func setHoldingUntil(_ opID: Int64, _ date: Date) throws {
        try db.run("UPDATE operations SET holding_until=? WHERE id=?",
                   [.double(date.timeIntervalSince1970), .int(opID)])
    }

    public func setNeedsReview(_ opID: Int64, _ value: Bool) throws {
        try db.run("UPDATE operations SET needs_review=? WHERE id=?", [.int(value ? 1 : 0), .int(opID)])
    }

    public func setError(_ opID: Int64, _ error: String?) throws {
        try db.run("UPDATE operations SET error=? WHERE id=?", [error.map(SQLValue.text) ?? .null, .int(opID)])
    }

    public func operation(_ id: Int64) throws -> Operation? {
        try db.query("SELECT \(Self.opColumns) FROM operations WHERE id=?", [.int(id)], Self.mapOperation).first
    }

    public func operations(states: Set<OperationState>? = nil) throws -> [Operation] {
        guard let states else {
            return try db.query("SELECT \(Self.opColumns) FROM operations ORDER BY id", [], Self.mapOperation)
        }
        guard !states.isEmpty else { return [] }
        let ph = Array(repeating: "?", count: states.count).joined(separator: ",")
        return try db.query("SELECT \(Self.opColumns) FROM operations WHERE state IN (\(ph)) ORDER BY id",
                            states.map { .text($0.rawValue) }, Self.mapOperation)
    }

    public func operationCount() throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM operations") ?? 0)
    }

    // MARK: Items

    static let itemColumns = """
        id, op_id, idx, original_path, purpose, role, orig_ino, kho_rel_path, holding_path,
        left_symlink, symlink_created, released, restored, stage, stage_path, restored_path,
        allocated, files_json
        """

    static func mapItem(_ r: SQLiteDatabase.Row, offset o: Int32 = 0) -> OperationItem {
        OperationItem(
            id: r.int(o), opID: r.int(o + 1), idx: Int(r.int(o + 2)), originalPath: r.text(o + 3),
            purpose: PathPurpose(rawValue: r.text(o + 4)) ?? .personal,
            role: ItemRole(rawValue: r.text(o + 5)) ?? .normal,
            origIno: r.optInt(o + 6).map { UInt64(bitPattern: $0) },
            khoRelPath: r.optText(o + 7), holdingPath: r.optText(o + 8),
            leftSymlink: r.int(o + 9) != 0, symlinkCreated: r.int(o + 10) != 0,
            released: r.int(o + 11) != 0, restored: r.int(o + 12) != 0,
            stage: r.optText(o + 13).flatMap(ItemStage.init(rawValue:)),
            stagePath: r.optText(o + 14), restoredPath: r.optText(o + 15),
            allocated: r.optInt(o + 16), filesJSON: r.optText(o + 17))
    }

    @discardableResult
    public func addItem(opID: Int64, idx: Int, originalPath: String, purpose: PathPurpose,
                        role: ItemRole = .normal, origIno: UInt64? = nil,
                        leftSymlink: Bool = false) throws -> Int64 {
        try db.run(
            "INSERT INTO operation_items(op_id, idx, original_path, purpose, role, orig_ino, left_symlink) VALUES(?,?,?,?,?,?,?)",
            [.int(opID), .int(Int64(idx)), .text(originalPath), .text(purpose.rawValue), .text(role.rawValue),
             origIno.map { .int(Int64(bitPattern: $0)) } ?? .null, .int(leftSymlink ? 1 : 0)])
    }

    /// Writes only the columns that are passed. For the double-optional columns, `.some(nil)`
    /// clears the value.
    public func updateItem(
        _ id: Int64, origIno: UInt64?? = nil, khoRelPath: String?? = nil, holdingPath: String?? = nil,
        symlinkCreated: Bool? = nil, released: Bool? = nil, restored: Bool? = nil,
        stage: ItemStage?? = nil, stagePath: String?? = nil, restoredPath: String?? = nil,
        allocated: Int64? = nil, filesJSON: String? = nil
    ) throws {
        var sets: [String] = []
        var params: [SQLValue] = []
        func text(_ col: String, _ v: String??) {
            guard let v else { return }
            sets.append("\(col)=?")
            params.append(v.map(SQLValue.text) ?? .null)
        }
        func flag(_ col: String, _ v: Bool?) {
            guard let v else { return }
            sets.append("\(col)=?")
            params.append(.int(v ? 1 : 0))
        }
        if let origIno {
            sets.append("orig_ino=?")
            params.append(origIno.map { .int(Int64(bitPattern: $0)) } ?? .null)
        }
        text("kho_rel_path", khoRelPath)
        text("holding_path", holdingPath)
        flag("symlink_created", symlinkCreated)
        flag("released", released)
        flag("restored", restored)
        if let stage {
            sets.append("stage=?")
            params.append(stage.map { .text($0.rawValue) } ?? .null)
        }
        text("stage_path", stagePath)
        text("restored_path", restoredPath)
        if let allocated {
            sets.append("allocated=?")
            params.append(.int(allocated))
        }
        if let filesJSON {
            sets.append("files_json=?")
            params.append(.text(filesJSON))
        }
        guard !sets.isEmpty else { return }
        params.append(.int(id))
        try db.run("UPDATE operation_items SET \(sets.joined(separator: ", ")) WHERE id=?", params)
    }

    public func items(_ opID: Int64) throws -> [OperationItem] {
        try db.query("SELECT \(Self.itemColumns) FROM operation_items WHERE op_id=? ORDER BY idx, id",
                     [.int(opID)]) { Self.mapItem($0) }
    }

    public func item(id: Int64) throws -> OperationItem? {
        try db.query("SELECT \(Self.itemColumns) FROM operation_items WHERE id=?", [.int(id)]) {
            Self.mapItem($0)
        }.first
    }

    static var joinedColumns: String {
        let op = opColumns.split(separator: ",").map { "o." + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let it = itemColumns.split(separator: ",").map { "i." + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (op + it).joined(separator: ", ")
    }

    static func mapPair(_ r: SQLiteDatabase.Row) -> (Operation, OperationItem) {
        (mapOperation(r), mapItem(r, offset: 12))
    }

    public func item(khoRelPath: String) throws -> (Operation, OperationItem)? {
        try db.query("""
            SELECT \(Self.joinedColumns) FROM operation_items i JOIN operations o ON o.id = i.op_id
            WHERE i.kho_rel_path=? ORDER BY o.id DESC LIMIT 1
            """, [.text(khoRelPath)], Self.mapPair).first
    }

    /// Items of live operations (not restored/undone/failed) whose original path is an
    /// ancestor, a descendant or the same as `path` (component-wise, case-insensitive).
    public func activeItems(overlapping path: String) throws -> [(Operation, OperationItem)] {
        let all = try db.query("""
            SELECT \(Self.joinedColumns) FROM operation_items i JOIN operations o ON o.id = i.op_id
            WHERE o.state NOT IN ('restored','undone','failed')
            """, [], Self.mapPair)
        let target = URL(fileURLWithPath: path)
        return all.filter { _, item in
            let u = URL(fileURLWithPath: item.originalPath)
            return FileOps.isUnder(u, target) || FileOps.isUnder(target, u)
        }
    }

    // MARK: Cleanup bookkeeping

    public func addPendingCleanup(khoUUID: String, khoRelPath: String) throws {
        try db.run("INSERT INTO pending_cleanup(kho_uuid, kho_rel_path, created_at) VALUES(?,?,?)",
                   [.text(khoUUID), .text(khoRelPath), .double(Self.now())])
    }

    public func pendingCleanup(khoUUID: String) throws -> [PendingCleanup] {
        try db.query("SELECT id, kho_uuid, kho_rel_path FROM pending_cleanup WHERE kho_uuid=? ORDER BY id",
                     [.text(khoUUID)]) { PendingCleanup(id: $0.int(0), khoUUID: $0.text(1), khoRelPath: $0.text(2)) }
    }

    public func removePendingCleanup(_ id: Int64) throws {
        try db.run("DELETE FROM pending_cleanup WHERE id=?", [.int(id)])
    }

    public func removePendingCleanup(khoUUID: String, khoRelPath: String) throws {
        try db.run("DELETE FROM pending_cleanup WHERE kho_uuid=? AND kho_rel_path=?",
                   [.text(khoUUID), .text(khoRelPath)])
    }

    public func addPartial(_ path: String) throws {
        try db.run("INSERT OR REPLACE INTO partials(path, created_at) VALUES(?,?)",
                   [.text(path), .double(Self.now())])
    }

    public func removePartial(_ path: String) throws {
        try db.run("DELETE FROM partials WHERE path=?", [.text(path)])
    }

    public func partials() throws -> [String] {
        try db.query("SELECT path FROM partials ORDER BY created_at", []) { $0.text(0) }
    }

    // MARK: Activity and settings

    public func log(action: String, path: String?, detail: String?, ok: Bool) {
        _ = try? db.run("INSERT INTO activity(at, action, path, detail, ok) VALUES(?,?,?,?,?)",
                        [.double(Self.now()), .text(action), path.map(SQLValue.text) ?? .null,
                         detail.map(SQLValue.text) ?? .null, .int(ok ? 1 : 0)])
    }

    public func recentActivity(limit: Int) throws -> [ActivityEntry] {
        try db.query("SELECT at, action, path, detail, ok FROM activity ORDER BY id DESC LIMIT ?",
                     [.int(Int64(limit))]) {
            ActivityEntry(at: Date(timeIntervalSince1970: $0.double(0)), action: $0.text(1),
                          path: $0.optText(2), detail: $0.optText(3), ok: $0.int(4) != 0)
        }
    }

    public func setting(_ key: String) throws -> String? {
        try db.scalarText("SELECT value FROM settings WHERE key=?", [.text(key)])
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try db.run("INSERT OR REPLACE INTO settings(key, value) VALUES(?,?)", [.text(key), .text(value)])
    }

    public func removeSetting(_ key: String) throws {
        try db.run("DELETE FROM settings WHERE key=?", [.text(key)])
    }

    public func settings(withPrefix prefix: String) throws -> [String: String] {
        let rows = try db.query("SELECT key, value FROM settings WHERE substr(key, 1, ?) = ?",
                                [.int(Int64(prefix.utf8.count)), .text(prefix)]) { ($0.text(0), $0.text(1)) }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Backup and restore

    static func fullSync(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_FULLFSYNC)
        Darwin.close(fd)
    }

    static func integrityOK(_ url: URL) -> Bool {
        guard let db = try? SQLiteDatabase(path: url.path, readOnly: true) else { return false }
        defer { db.close() }
        return (try? db.scalarText("PRAGMA integrity_check")) == "ok"
    }

    static func countOperations(_ url: URL) throws -> Int {
        let db = try SQLiteDatabase(path: url.path, readOnly: true)
        defer { db.close() }
        let hasTable = try db.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='operations'") ?? 0
        guard hasTable > 0 else { return 0 }
        return Int(try db.scalarInt("SELECT COUNT(*) FROM operations") ?? 0)
    }

    /// Writes a consistent copy to `url` safely for removable drives: temp file, integrity
    /// check, full fsync, atomic rename. Refuses to replace a backup that holds more
    /// operations than this ledger unless `allowShrink`.
    public func backup(to url: URL, allowShrink: Bool = false) throws {
        if !allowShrink, FileManager.default.fileExists(atPath: url.path) {
            let existing = try Self.countOperations(url)
            let mine = (try? operationCount()) ?? 0
            if existing > mine {
                throw KhoError.invalidState("Bản sao lưu trên Kho có nhiều thao tác hơn sổ cái trong máy")
            }
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".ledger-backup.tmp-\(UUID().uuidString)")
        do {
            try db.execute("PRAGMA synchronous=FULL")
            try db.run("VACUUM INTO ?", [.text(tmp.path)])
            guard Self.integrityOK(tmp) else { throw KhoError.verifyFailed(tmp.lastPathComponent) }
            Self.fullSync(tmp)
            guard rename(tmp.path, url.path) == 0 else {
                throw KhoError.io("Không ghi được bản sao lưu: \(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Reads a few settings without opening the ledger for writing (another Switch Kho may be
    /// running). Missing file or keys give an empty or partial result.
    public static func readSettings(path: URL, keys: [String]) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: path.path), !keys.isEmpty else { return [:] }
        let db = try SQLiteDatabase(path: path.path, readOnly: true)
        defer { db.close() }
        let ph = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let rows = try db.query("SELECT key, value FROM settings WHERE key IN (\(ph))", keys.map { .text($0) }) {
            ($0.text(0), $0.text(1))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    /// Replaces an empty ledger at `path` with `backup`. Callers must have closed every
    /// connection to `path`. Unfinished operations are flagged for review because the
    /// backup may be older than reality.
    public static func restoreFromBackup(_ backup: URL, to path: URL) throws {
        guard integrityOK(backup) else { throw KhoError.verifyFailed(backup.lastPathComponent) }
        if FileManager.default.fileExists(atPath: path.path), try countOperations(path) > 0 {
            throw KhoError.invalidState("Sổ cái trong máy đã có dữ liệu, không ghi đè")
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path.path + suffix)
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: backup, to: path)
        fullSync(path)
        let ledger = try Ledger(path: path)
        defer { ledger.close() }
        let open = OperationState.allCases.filter { !OperationState.finished.contains($0) }
        let ph = Array(repeating: "?", count: open.count).joined(separator: ",")
        try ledger.db.run("UPDATE operations SET needs_review=1 WHERE state IN (\(ph))",
                          open.map { .text($0.rawValue) })
        ledger.log(action: "Khôi phục sổ cái từ Kho", path: backup.path, detail: nil, ok: true)
    }
}
