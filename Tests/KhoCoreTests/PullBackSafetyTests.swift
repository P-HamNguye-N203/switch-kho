import Darwin
import Foundation
import Testing
@testable import KhoCore

/// Paths where a retried undo/restore or a damaged ledger row could lose data.
@Suite(.serialized) struct PullBackSafetyTests {
    func liveOp(_ fx: ServiceFixture) throws -> (Int64, URL) {
        let data = fx.sb.home.appendingPathComponent("Library/Application Support/com.x/Data")
        try fx.sb.makeFile(data.appendingPathComponent("db.sqlite"), bytes: 5000, seed: 2)
        let op = try fx.offload([OffloadRequest(original: data, khoRelPath: "SwitchKho/Live/com.x/Data",
                                                purpose: .appData, leaveSymlink: true)],
                                kind: .appLive, bundleID: "com.x")
        return (op, data)
    }

    @Test func retriedRestoreDoesNotReuseStaleStage() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let (op, data) = try liveOp(fx)
        try fx.service.commitNow(opID: op)
        // The app is opened while the copy runs, so the swap is refused and the stage is kept.
        fx.afterCopy.withLock { $0 = { _ in fx.running.withLock { $0 = true } } }
        #expect(throws: KhoError.appRunning("t")) { try fx.service.restore(opID: op) }
        #expect(try fx.ledger.items(op)[0].stage == .copied)
        fx.afterCopy.withLock { $0 = nil }
        // The app keeps writing to the Kho, then quits.
        try Data("ghi sau".utf8).write(to: data.appendingPathComponent("new.txt"))
        fx.running.withLock { $0 = false }
        try fx.service.restore(opID: op)
        #expect(!FileOps.isSymlink(data))
        #expect(try String(contentsOf: data.appendingPathComponent("new.txt"), encoding: .utf8) == "ghi sau")
        #expect(try fx.ledger.operation(op)?.state == .restored)
    }

    @Test func lostStageWithOurSymlinkIsNotTakenAsSwapped() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let before = try fx.digest(dir)
        let op = try fx.offload([fx.request(dir, symlink: true)])
        let item = try fx.ledger.items(op)[0]
        try fx.ledger.transition(op, from: [.holding], to: .undoing)
        try fx.ledger.updateItem(item.id, stage: .some(.copied),
                                 stagePath: .some(dir.deletingLastPathComponent().appendingPathComponent(".switchkho-partial-gone").path),
                                 restoredPath: .some(dir.path))
        try fx.service.undo(opID: op)
        #expect(!FileOps.isSymlink(dir))
        #expect(try fx.digest(dir) == before)
        #expect(try fx.ledger.operation(op)?.state == .undone)
    }

    @Test func unreadableFileListBlocksCommit() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let op = try fx.offload([fx.request(try fx.makeFolder("A"))])
        try fx.ledger.db.run("UPDATE operation_items SET files_json='hỏng' WHERE op_id=?", [.int(op)])
        #expect(throws: KhoError.self) { try fx.service.commitNow(opID: op) }
        #expect(try fx.ledger.operation(op)?.state == .holding)
    }

    @Test func missingKhoCopyOfEmptyFolderBlocksCommit() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let empty = fx.sb.home.appendingPathComponent("Documents/Rỗng")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let op = try fx.offload([fx.request(empty)])
        try FileOps.removeTree(try fx.khoCopy(op))
        fx.advance(days: 8)
        #expect(fx.service.commitDue().isEmpty)
        #expect(try fx.ledger.operation(op)?.state == .holding)
    }
}
