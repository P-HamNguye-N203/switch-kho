import Darwin
import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct UndoRestoreTests {
    func siblings(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []).sorted()
    }

    @Test func undoPutsOriginalBack() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let before = try fx.digest(dir)
        let op = try fx.offload([fx.request(dir)])
        let onKho = try fx.khoCopy(op)
        try fx.service.undo(opID: op)
        #expect(try fx.digest(dir) == before)
        #expect(!FileOps.exists(onKho))
        #expect(try fx.ledger.operation(op)?.state == .undone)
    }

    @Test func undoWhileKhoAwayQueuesCleanup() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let op = try fx.offload([fx.request(dir)])
        let onKho = try fx.khoCopy(op)
        fx.khoMounted.withLock { $0 = false }
        try fx.service.undo(opID: op)
        #expect(FileOps.exists(dir) && !FileOps.isSymlink(dir))
        #expect(try fx.ledger.operation(op)?.state == .undone)
        #expect(try fx.ledger.pendingCleanup(khoUUID: ServiceFixture.khoUUID).count == 1)
        fx.khoMounted.withLock { $0 = true }
        fx.service.drainPendingCleanup()
        #expect(!FileOps.exists(onKho))
        #expect(try fx.ledger.pendingCleanup(khoUUID: ServiceFixture.khoUUID).isEmpty)
    }

    @Test func undoKeepsFilesWrittenThroughSymlink() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let op = try fx.offload([fx.request(dir, symlink: true)])
        try Data("mới".utf8).write(to: dir.appendingPathComponent("moi.txt"))
        try fx.service.undo(opID: op)
        #expect(!FileOps.isSymlink(dir))
        #expect(try String(contentsOf: dir.appendingPathComponent("moi.txt"), encoding: .utf8) == "mới")
        #expect(try fx.ledger.operation(op)?.state == .undone)
        #expect(siblings(dir) == ["A"])
    }

    @Test func undoWithSymlinkNeedsKho() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let op = try fx.offload([fx.request(try fx.makeFolder("A"), symlink: true)])
        fx.khoMounted.withLock { $0 = false }
        #expect(throws: KhoError.khoOffline) { try fx.service.undo(opID: op) }
        #expect(try fx.ledger.operation(op)?.state == .holding)
    }

    @Test func runningAppBlocksUndoAndRestore() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let a = try fx.makeFolder("A")
        let b = try fx.makeFolder("B")
        let held = try fx.offload([fx.request(a)], kind: .appCold, bundleID: "com.x")
        let done = try fx.offload([fx.request(b)], kind: .appCold, bundleID: "com.x")
        try fx.service.commitNow(opID: done)
        fx.running.withLock { $0 = true }
        #expect(throws: KhoError.appRunning("t")) { try fx.service.undo(opID: held) }
        #expect(throws: KhoError.appRunning("t")) { try fx.service.restore(opID: done) }
        #expect(try fx.ledger.operation(held)?.state == .holding)
        #expect(try fx.ledger.operation(done)?.state == .committed)
        #expect(!FileOps.exists(a) && !FileOps.exists(b))
    }

    @Test func undoResumesAfterCrashPastSwap() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let before = try fx.digest(dir)
        let op = try fx.offload([fx.request(dir, symlink: true)])
        // Simulate a crash right after the staged copy was renamed over the symlink.
        let item = try fx.ledger.items(op)[0]
        #expect(try fx.ledger.transition(op, from: [.holding], to: .undoing))
        _ = lchflags(dir.path, 0)
        _ = unlink(dir.path)
        try FileManager.default.copyItem(at: try fx.khoCopy(op), to: dir)
        try fx.ledger.updateItem(item.id, stage: .some(.swapped), stagePath: .some(dir.path + ".gone"),
                                 restoredPath: .some(dir.path))
        try fx.service.undo(opID: op)
        #expect(try fx.digest(dir) == before)
        #expect(siblings(dir) == ["A"])
        #expect(try fx.ledger.operation(op)?.state == .undone)
    }

    @Test func undoFailureReturnsToHolding() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("P/Q")
        let op = try fx.offload([fx.request(dir)])
        try FileManager.default.removeItem(at: dir.deletingLastPathComponent())
        #expect(throws: KhoError.self) { try fx.service.undo(opID: op) }
        let o = try #require(try fx.ledger.operation(op))
        #expect(o.state == .holding && o.error?.isEmpty == false)
        #expect(FileOps.exists(URL(fileURLWithPath: try fx.ledger.items(op)[0].holdingPath!)))
    }

    @Test func restoreAfterCommit() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let before = try fx.digest(dir)
        let op = try fx.offload([fx.request(dir)])
        try fx.service.commitNow(opID: op)
        try fx.service.restore(opID: op)
        #expect(try fx.digest(dir) == before)
        #expect(try fx.ledger.operation(op)?.state == .restored)
        #expect(fx.archiveEntries().isEmpty)

        let dir2 = try fx.makeFolder("B")
        let op2 = try fx.offload([fx.request(dir2)])
        try fx.service.commitNow(opID: op2)
        try Data("x".utf8).write(to: try fx.khoCopy(op2).appendingPathComponent("sub/f0.bin"))
        #expect(throws: KhoError.self) { try fx.service.restore(opID: op2) }
        #expect(try fx.ledger.operation(op2)?.state == .committed)
    }

    @Test func restoreReplacesSymlinkWithFolder() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let before = try fx.digest(dir)
        let op = try fx.offload([fx.request(dir, symlink: true)])
        try fx.service.commitNow(opID: op)
        try fx.service.restore(opID: op)
        #expect(!FileOps.isSymlink(dir))
        #expect(try fx.digest(dir) == before)
        #expect(siblings(dir) == ["A"])
    }

    @Test func restoreResumesWithoutRecopying() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let a = try fx.makeFolder("A")
        let b = fx.sb.home.appendingPathComponent("Documents/B")
        try fx.sb.makeFile(b.appendingPathComponent("g.bin"), bytes: 3000, seed: 7)
        let op = try fx.offload([fx.request(a), fx.request(b)])
        try fx.service.commitNow(opID: op)
        fx.corrupt.withLock { $0 = ["g.bin"] }
        #expect(throws: KhoError.self) { try fx.service.restore(opID: op) }
        #expect(try fx.ledger.operation(op)?.state == .committed)
        #expect(try fx.ledger.items(op)[0].restored)
        fx.corrupt.withLock { $0 = [] }
        try fx.service.restore(opID: op)
        #expect(try fx.ledger.operation(op)?.state == .restored)
        #expect(siblings(a) == ["A", "B"])
    }

    @Test func setAsideKeepsFolderMadeWhileKhoAway() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let data = fx.sb.home.appendingPathComponent("Library/Application Support/com.x/Data")
        try fx.sb.makeFile(data.appendingPathComponent("db.sqlite"), bytes: 5000, seed: 2)
        let live = try fx.offload([OffloadRequest(original: data, khoRelPath: "SwitchKho/Live/com.x/Data",
                                                  purpose: .appData, leaveSymlink: true)],
                                  kind: .appLive, bundleID: "com.x")
        let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: data.path)
        // The app ran while the Kho was away and created a real folder in place of the link.
        _ = lchflags(data.path, 0)
        _ = unlink(data.path)
        try fx.sb.makeFile(data.appendingPathComponent("a.txt"), bytes: 10, seed: 1)
        try fx.sb.makeFile(data.appendingPathComponent("b.txt"), bytes: 20, seed: 2)

        let aside = try fx.service.setAside(liveOpID: live, folder: data)
        let rel = try #require(try fx.ledger.items(aside)[0].khoRelPath)
        #expect(rel.hasPrefix("SwitchKho/Live/com.x/_khi-kho-vang-") && rel.hasSuffix("/Data"))
        let onKho = try fx.sb.layout.absoluteURL(relative: rel)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: onKho.path)) == ["a.txt", "b.txt"])
        #expect(FileOps.isSymlink(data))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: data.path) == linkTarget)
        #expect(FileOps.flags(data) & UInt32(UF_IMMUTABLE) != 0)
        #expect(try fx.ledger.operation(aside)?.state == .holding)

        try fx.service.undo(opID: aside)
        let beside = data.deletingLastPathComponent().appendingPathComponent("Data (bản khi Kho vắng)")
        #expect(FileOps.exists(beside.appendingPathComponent("a.txt")))
        #expect(FileOps.isSymlink(data))
        #expect(try fx.ledger.operation(live)?.state == .holding)
        #expect(try fx.ledger.operation(aside)?.state == .undone)
    }
}
