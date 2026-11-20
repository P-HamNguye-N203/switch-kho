import Foundation
import Testing
@testable import KhoCore

@Suite struct LedgerTests {
    @Test func readSettingsIsReadOnly() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        #expect(try Ledger.readSettings(path: sb.dbPath, keys: ["kho.uuid"]).isEmpty)
        let ledger = try Ledger(path: sb.dbPath)
        try ledger.setSetting("kho.uuid", "U")
        try ledger.setSetting("kho.token", "T")
        try ledger.setSetting("other", "x")
        let before = try ledger.db.scalarInt("PRAGMA user_version")
        let got = try Ledger.readSettings(path: sb.dbPath, keys: ["kho.uuid", "kho.token", "missing"])
        #expect(got == ["kho.uuid": "U", "kho.token": "T"])
        #expect(try ledger.db.scalarInt("PRAGMA user_version") == before)
        try ledger.setSetting("kho.uuid", "V")
        #expect(try Ledger.readSettings(path: sb.dbPath, keys: ["kho.uuid"])["kho.uuid"] == "V")
    }

    func backups(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(".ledger-backup.tmp-") }
    }

    @Test func createReadTransition() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let l = try Ledger(path: sb.dbPath)
        let id = try l.createOperation(kind: .personal, title: "t", bundleID: nil, khoUUID: "K")
        #expect(try l.operation(id)?.state == .copying)
        #expect(try l.transition(id, from: [.copying], to: .moving))
        #expect(try !l.transition(id, from: [.copying], to: .holding))
        #expect(try l.operation(id)?.state == .moving)
        let until = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(try l.transition(id, from: [.moving], to: .holding, holdingUntil: until))
        let op = try #require(try l.operation(id))
        #expect(op.state == .holding && op.holdingUntil == until)
        let id2 = try l.createOperation(kind: .appCold, title: nil, bundleID: "b", khoUUID: "K")
        #expect(try l.operation(id2)?.uid != op.uid)
        #expect(try l.transition(id2, from: [.copying], to: .failed, error: "x"))
        #expect(try l.operation(id2)?.finishedAt != nil)
    }

    @Test func checkConstraintRejectsUnknownState() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let l = try Ledger(path: sb.dbPath)
        #expect(throws: KhoError.self) {
            try l.db.run("INSERT INTO operations(uid, kind, kho_uuid, state) VALUES('u','personal','K','weird')")
        }
    }

    @Test func reopenKeepsDataAndBackupOnlyOnMigration() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let bak = URL(fileURLWithPath: sb.dbPath.path + ".bak")
        // An old database at user_version 0 with one table gets backed up before migrating.
        let old = try SQLiteDatabase(path: sb.dbPath.path)
        try old.execute("CREATE TABLE legacy(x INTEGER); INSERT INTO legacy VALUES(1);")
        old.close()
        var l = try Ledger(path: sb.dbPath)
        #expect(FileManager.default.fileExists(atPath: bak.path))
        _ = try l.createOperation(kind: .personal, title: nil, bundleID: nil, khoUUID: "K")
        l.close()
        try FileManager.default.removeItem(at: bak)
        l = try Ledger(path: sb.dbPath)
        #expect(try l.operationCount() == 1)
        #expect(!FileManager.default.fileExists(atPath: bak.path))
    }

    @Test func settingsItemsAndOverlap() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let l = try Ledger(path: sb.dbPath)
        try l.setSetting("rule.a", "1")
        try l.setSetting("rule.b", "2")
        try l.setSetting("other", "3")
        #expect(try l.settings(withPrefix: "rule.") == ["rule.a": "1", "rule.b": "2"])
        try l.removeSetting("rule.a")
        #expect(try l.setting("rule.a") == nil)

        let op = try l.createOperation(kind: .personal, title: nil, bundleID: nil, khoUUID: "K")
        let item = try l.addItem(opID: op, idx: 0, originalPath: "/Users/u/Documents/Dự án", purpose: .personal,
                                 origIno: 42)
        try l.updateItem(item, khoRelPath: "SwitchKho/Archive/Users/u/Documents/Dự án", stage: .some(.copied))
        let found = try #require(try l.item(khoRelPath: "SwitchKho/Archive/Users/u/Documents/Dự án"))
        #expect(found.0.id == op && found.1.id == item && found.1.origIno == 42 && found.1.stage == .copied)
        try l.updateItem(item, stage: .some(nil))
        #expect(try l.item(id: item)?.stage == nil)

        #expect(try l.activeItems(overlapping: "/Users/u/Documents").count == 1)
        #expect(try l.activeItems(overlapping: "/Users/u/documents/dự án/sub/x").count == 1)
        #expect(try l.activeItems(overlapping: "/Users/u/Documents/Dự án 2").isEmpty)
        try l.transition(op, from: [.copying], to: .failed)
        #expect(try l.activeItems(overlapping: "/Users/u/Documents").isEmpty)
    }

    @Test func backupAndRefuseShrink() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let l = try Ledger(path: sb.dbPath)
        _ = try l.createOperation(kind: .personal, title: nil, bundleID: nil, khoUUID: "K")
        _ = try l.createOperation(kind: .personal, title: nil, bundleID: nil, khoUUID: "K")
        let target = sb.kho.appendingPathComponent("SwitchKho/ledger-backup.sqlite")
        try l.backup(to: target)
        #expect(try Ledger.countOperations(target) == 2)
        #expect(backups(target.deletingLastPathComponent()).isEmpty)

        let emptyPath = sb.root.appendingPathComponent("db/empty.sqlite")
        let empty = try Ledger(path: emptyPath)
        #expect(throws: KhoError.self) { try empty.backup(to: target) }
        #expect(try Ledger.countOperations(target) == 2)
        #expect(backups(target.deletingLastPathComponent()).isEmpty)
    }

    @Test func restoreFromBackupFlagsOpenOperations() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = try Ledger(path: sb.root.appendingPathComponent("db/src.sqlite"))
        let held = try src.createOperation(kind: .personal, title: nil, bundleID: nil, khoUUID: "K")
        try src.transition(held, from: [.copying], to: .holding)
        let done = try src.createOperation(kind: .personal, title: nil, bundleID: nil, khoUUID: "K")
        try src.transition(done, from: [.copying], to: .committed)
        let backup = sb.kho.appendingPathComponent("SwitchKho/ledger-backup.sqlite")
        try src.backup(to: backup)

        let empty = try Ledger(path: sb.dbPath)
        empty.close()
        try Data("junk wal".utf8).write(to: URL(fileURLWithPath: sb.dbPath.path + "-wal"))
        try Ledger.restoreFromBackup(backup, to: sb.dbPath)

        let l = try Ledger(path: sb.dbPath)
        #expect(try l.operationCount() == 2)
        #expect(try l.operation(held)?.needsReview == true)
        #expect(try l.operation(done)?.needsReview == false)
        l.close()
        #expect(throws: KhoError.self) { try Ledger.restoreFromBackup(backup, to: sb.dbPath) }
    }
}
