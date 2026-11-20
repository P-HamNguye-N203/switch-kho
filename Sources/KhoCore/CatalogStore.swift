import Foundation

public struct CatalogItem: Sendable, Equatable {
    public let relPath: String
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    public let modified: Date?

    public init(relPath: String, name: String, size: Int64, isDirectory: Bool, modified: Date?) {
        self.relPath = relPath
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.modified = modified
    }
}

public struct CatalogEntry: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let volumeUUID: String
    public let item: CatalogItem
}

public struct IndexedVolume: Sendable, Equatable {
    public let uuid: String
    public let name: String
    public let lastIndexed: Date
    public let files: Int64
    public let bytes: Int64
}

/// Searchable index of everything on the Kho, kept in its own database so writing a
/// million rows never holds the ledger's lock. It can always be rebuilt, so it is not
/// backed up.
/// `@unchecked Sendable`: every access goes through `SQLiteDatabase`, which serialises
/// calls with its own lock.
public final class CatalogStore: @unchecked Sendable {
    let db: SQLiteDatabase
    static let batch = 5_000

    static let triggers = """
        CREATE TRIGGER IF NOT EXISTS catalog_ai AFTER INSERT ON catalog BEGIN
          INSERT INTO catalog_fts(rowid, search) VALUES (new.id, new.search);
        END;
        CREATE TRIGGER IF NOT EXISTS catalog_ad AFTER DELETE ON catalog BEGIN
          INSERT INTO catalog_fts(catalog_fts, rowid, search) VALUES ('delete', old.id, old.search);
        END;
        CREATE TRIGGER IF NOT EXISTS catalog_au AFTER UPDATE ON catalog BEGIN
          INSERT INTO catalog_fts(catalog_fts, rowid, search) VALUES ('delete', old.id, old.search);
          INSERT INTO catalog_fts(rowid, search) VALUES (new.id, new.search);
        END;
        """

    public init(path: URL) throws {
        let existed = FileManager.default.fileExists(atPath: path.path)
        db = try SQLiteDatabase(path: path.path)
        // An index can be rebuilt: trade a little durability for speed.
        try db.execute("PRAGMA synchronous=NORMAL; PRAGMA fullfsync=OFF; PRAGMA checkpoint_fullfsync=OFF;")
        let version = try db.scalarInt("PRAGMA user_version") ?? 0
        if version < 1 {
            if existed && version > 0 {
                let bak = path.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: bak)
                _ = try db.run("VACUUM INTO ?", [.text(bak.path)])
            }
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS catalog(
                      id INTEGER PRIMARY KEY, volume_uuid TEXT NOT NULL, rel_path TEXT NOT NULL, name TEXT NOT NULL,
                      size INTEGER NOT NULL, is_dir INTEGER NOT NULL, modified REAL, search TEXT NOT NULL,
                      UNIQUE(volume_uuid, rel_path));
                    CREATE VIRTUAL TABLE IF NOT EXISTS catalog_fts USING fts5(
                      search, content='catalog', content_rowid='id',
                      tokenize='unicode61 remove_diacritics 2');
                    CREATE TABLE IF NOT EXISTS volumes(
                      uuid TEXT PRIMARY KEY, name TEXT NOT NULL, last_indexed REAL NOT NULL,
                      files INTEGER NOT NULL, bytes INTEGER NOT NULL);
                    \(Self.triggers)
                    PRAGMA user_version = 1;
                    """)
            }
        }
    }

    /// Text the index sees. The tokenizer drops accents, but "đ" is its own letter, so it is
    /// folded to "d" here (and in queries) for "hoa don" to find "Hoá đơn".
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
    }

    static func params(_ uuid: String, _ i: CatalogItem) -> [SQLValue] {
        [.text(uuid), .text(i.relPath), .text(i.name), .int(i.size), .int(i.isDirectory ? 1 : 0),
         i.modified.map { .double($0.timeIntervalSince1970) } ?? .null, .text(fold(i.name + " " + i.relPath))]
    }

    /// Replaces everything known about one volume. Triggers are off during the bulk load and
    /// the text index is rebuilt once at the end; they come back even when cancelled.
    public func replaceCatalog(volumeUUID: String, volumeName: String, items: [CatalogItem],
                               isCancelled: @Sendable () -> Bool = { false }) throws {
        try db.execute("DROP TRIGGER IF EXISTS catalog_ai; DROP TRIGGER IF EXISTS catalog_ad; DROP TRIGGER IF EXISTS catalog_au;")
        defer {
            try? db.execute("INSERT INTO catalog_fts(catalog_fts) VALUES('rebuild');")
            try? db.execute(Self.triggers)
        }
        _ = try db.runChanges("DELETE FROM catalog WHERE volume_uuid=?", [.text(volumeUUID)])
        var start = 0
        while start < items.count {
            if isCancelled() { throw CancellationError() }
            let slice = items[start..<min(start + Self.batch, items.count)]
            try db.transaction {
                try db.withStatement("""
                    INSERT OR REPLACE INTO catalog(volume_uuid, rel_path, name, size, is_dir, modified, search) VALUES(?,?,?,?,?,?,?)
                    """) { stmt in
                    for item in slice { try stmt.run(Self.params(volumeUUID, item)) }
                }
            }
            start += Self.batch
        }
        let files = Int64(items.filter { !$0.isDirectory }.count)
        let bytes = items.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        _ = try db.run("""
            INSERT OR REPLACE INTO volumes(uuid, name, last_indexed, files, bytes) VALUES(?,?,?,?,?)
            """, [.text(volumeUUID), .text(volumeName), .double(Date().timeIntervalSince1970), .int(files), .int(bytes)])
    }

    public func upsert(volumeUUID: String, items: [CatalogItem]) throws {
        try db.transaction {
            try db.withStatement("""
                INSERT INTO catalog(volume_uuid, rel_path, name, size, is_dir, modified, search) VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(volume_uuid, rel_path) DO UPDATE SET
                  name=excluded.name, size=excluded.size, is_dir=excluded.is_dir, modified=excluded.modified,
                  search=excluded.search
                """) { stmt in
                for item in items { try stmt.run(Self.params(volumeUUID, item)) }
            }
        }
    }

    /// Removes `prefix` and everything below it.
    public func remove(volumeUUID: String, relPathPrefix prefix: String) throws {
        let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        _ = try db.runChanges(
            "DELETE FROM catalog WHERE volume_uuid=? AND (rel_path=? OR rel_path LIKE ? ESCAPE '\\')",
            [.text(volumeUUID), .text(prefix), .text(escaped + "/%")])
    }

    /// Every word must match the start of a word in the name or path, accents ignored.
    public func search(_ text: String, limit: Int = 500) throws -> [CatalogEntry] {
        let words = Self.fold(text).split(whereSeparator: { $0.isWhitespace }).map {
            "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        }
        guard !words.isEmpty else { return [] }
        return try db.query("""
            SELECT c.id, c.volume_uuid, c.rel_path, c.name, c.size, c.is_dir, c.modified
            FROM catalog_fts f JOIN catalog c ON c.id = f.rowid
            WHERE catalog_fts MATCH ? ORDER BY rank LIMIT ?
            """, [.text(words.joined(separator: " ")), .int(Int64(limit))]) { r in
            CatalogEntry(id: r.int(0), volumeUUID: r.text(1),
                         item: CatalogItem(relPath: r.text(2), name: r.text(3), size: r.int(4), isDirectory: r.int(5) != 0,
                                           modified: r.optDouble(6).map(Date.init(timeIntervalSince1970:))))
        }
    }

    public func indexedVolume(uuid: String) throws -> IndexedVolume? {
        try db.query("SELECT uuid, name, last_indexed, files, bytes FROM volumes WHERE uuid=?", [.text(uuid)]) { r in
            IndexedVolume(uuid: r.text(0), name: r.text(1), lastIndexed: Date(timeIntervalSince1970: r.double(2)),
                          files: r.int(3), bytes: r.int(4))
        }.first
    }

    public func count(volumeUUID: String) throws -> Int64 {
        try db.scalarInt("SELECT COUNT(*) FROM catalog WHERE volume_uuid=?", [.text(volumeUUID)]) ?? 0
    }
}
