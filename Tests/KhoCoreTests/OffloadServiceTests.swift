import Darwin
import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct OffloadServiceTests {
    @Test func offloadFolderIntoHolding() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("Dự án")
        let before = try fx.digest(dir)
        let ino = FileOps.inode(dir)
        let op = try fx.offload([fx.request(dir)])
        let o = try #require(try fx.ledger.operation(op))
        #expect(o.state == .holding && o.holdingUntil != nil)
        let item = try fx.ledger.items(op)[0]
        #expect(item.holdingPath?.contains("/Holding/\(o.uid)/") == true)
        #expect(item.holdingPath?.hasSuffix(".held") == true)
        #expect(item.khoRelPath != nil && item.origIno == ino)
        #expect(!FileOps.exists(dir))
        #expect(try fx.digest(fx.khoCopy(op)) == before)
    }

    @Test func leaveSymlinkPointsThroughKhoLink() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("Ảnh")
        let op = try fx.offload([fx.request(dir, symlink: true)])
        #expect(FileOps.isSymlink(dir))
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: dir.path)
        #expect(target.hasPrefix(fx.sb.khoLink.path + "/"))
        #expect(FileOps.flags(dir) & UInt32(UF_IMMUTABLE) != 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sub/f0.bin").path))
        #expect(try fx.ledger.items(op)[0].symlinkCreated)
    }

    @Test func commitDueAfterHoldPeriod() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let op = try fx.offload([fx.request(try fx.makeFolder("A"))])
        let slotDir = fx.sb.home.appendingPathComponent(
            "Library/Application Support/SwitchKho/Holding/\(try fx.ledger.operation(op)!.uid)")
        #expect(fx.service.commitDue().isEmpty)
        fx.advance(days: 8)
        #expect(fx.service.commitDue() == [op])
        #expect(!FileOps.exists(slotDir))
        #expect(try fx.ledger.operation(op)?.state == .committed)
    }

    @Test func commitDueWaitsForKho() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let op = try fx.offload([fx.request(try fx.makeFolder("A"))])
        let until = try fx.ledger.operation(op)?.holdingUntil
        fx.advance(days: 8)
        fx.khoMounted.withLock { $0 = false }
        #expect(fx.service.commitDue().isEmpty)
        #expect(try fx.ledger.operation(op)?.holdingUntil == until)
        #expect(try fx.ledger.operation(op)?.state == .holding)
        fx.khoMounted.withLock { $0 = true }
        #expect(fx.service.commitDue() == [op])
    }

    @Test func commitDueRefusesWhenKhoCopyChanged() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = fx.sb.home.appendingPathComponent("Downloads/vm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try SparseFixture.make(dir.appendingPathComponent("disk.img"))
        let op = try fx.offload([fx.request(dir)])
        let onKho = try fx.khoCopy(op).appendingPathComponent("disk.img")
        let fd = open(onKho.path, O_WRONLY)
        var b: UInt8 = 0x11
        #expect(pwrite(fd, &b, 1, off_t(512 * SparseFixture.mib + 10)) == 1)
        close(fd)
        fx.advance(days: 8)
        #expect(fx.service.commitDue().isEmpty)
        #expect(try fx.ledger.operation(op)?.state == .holding)
        #expect(try fx.ledger.operation(op)?.error?.isEmpty == false)
        #expect(FileOps.exists(URL(fileURLWithPath: try fx.ledger.items(op)[0].holdingPath!)))
    }

    @Test func needsReviewBlocksCommit() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let op = try fx.offload([fx.request(try fx.makeFolder("A"))])
        try fx.ledger.setNeedsReview(op, true)
        fx.advance(days: 8)
        #expect(fx.service.commitDue().isEmpty)
        #expect(throws: KhoError.self) { try fx.service.commitNow(opID: op) }
    }

    @Test func commitNowAndOffline() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let op = try fx.offload([fx.request(try fx.makeFolder("A"))])
        let op2 = try fx.offload([fx.request(try fx.makeFolder("B"))])
        try fx.service.commitNow(opID: op)
        #expect(try fx.ledger.operation(op)?.state == .committed)
        #expect(!FileOps.exists(URL(fileURLWithPath: try fx.ledger.items(op)[0].holdingPath!)))
        fx.khoMounted.withLock { $0 = false }
        #expect(throws: KhoError.khoOffline) { try fx.service.commitNow(opID: op2) }
    }

    @Test func copyFailureLeavesNoTrace() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let before = try fx.digest(dir)
        fx.corrupt.withLock { $0 = ["f1.bin"] }
        #expect(throws: KhoError.self) { try fx.offload([fx.request(dir)]) }
        #expect(try fx.ledger.operations().first?.state == .failed)
        #expect(try fx.digest(dir) == before)
        #expect(!fx.archiveEntries().contains { $0.hasSuffix("/A") || $0.contains(".switchkho-partial-") })
        #expect(try fx.ledger.partials().isEmpty)
    }

    @Test func existingArchiveGetsNumberedNameAndSurvivesFailure() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let old = fx.sb.layout.archiveURL(forOriginal: dir)
        try fx.sb.makeFile(old.appendingPathComponent("old.txt"), bytes: 10, seed: 1)
        let op = try fx.offload([fx.request(dir)])
        #expect(try fx.khoCopy(op).lastPathComponent == "A (2)")
        try fx.service.undo(opID: op)

        fx.corrupt.withLock { $0 = ["f0.bin"] }
        #expect(throws: KhoError.self) { try fx.offload([fx.request(dir)]) }
        #expect(FileOps.exists(old.appendingPathComponent("old.txt")))
    }

    @Test func sourceChangedDuringCopy() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let target = dir.appendingPathComponent("sub/f2.bin")
        fx.afterCopy.withLock {
            $0 = { url in
                if url.lastPathComponent == "f2.bin" { try? Data("mới".utf8).write(to: target) }
            }
        }
        #expect(throws: KhoError.sourceChanged("sub/f2.bin")) { try fx.offload([fx.request(dir)]) }
        #expect(try fx.ledger.operations().first?.state == .failed)
        #expect(FileOps.exists(target) && !FileOps.isSymlink(dir))
    }

    @Test func blockedPathCreatesNothing() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let blocked = fx.sb.home.appendingPathComponent("Library/Containers/x")
        try fx.sb.makeFile(blocked.appendingPathComponent("f"), bytes: 10, seed: 1)
        #expect(throws: KhoError.blocked(blocked.path)) { try fx.offload([fx.request(blocked)]) }
        #expect(try fx.ledger.operationCount() == 0)
    }

    @Test func parentOfHeldItemIsAlreadyManaged() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("Cha/Con")
        let op = try fx.offload([fx.request(dir)])
        let parent = dir.deletingLastPathComponent()
        try fx.sb.makeFile(parent.appendingPathComponent("x.txt"), bytes: 10, seed: 1)
        #expect(throws: KhoError.alreadyManaged("#\(op)")) { try fx.offload([fx.request(parent)]) }
        #expect(try fx.ledger.operationCount() == 1)
    }

    @Test func lockedItemOrParentIsRefused() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let file = fx.sb.home.appendingPathComponent("Downloads/khoa.txt")
        try fx.sb.makeFile(file, bytes: 10, seed: 1)
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(throws: KhoError.self) { try fx.offload([fx.request(file)]) }
        _ = chflags(file.path, 0)

        let dir = try fx.makeFolder("Khoá cha/Con")
        let parent = dir.deletingLastPathComponent()
        #expect(chflags(parent.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(throws: KhoError.self) { try fx.offload([fx.request(dir)]) }
        _ = chflags(parent.path, 0)
        #expect(try fx.ledger.operationCount() == 0)
    }

    @Test func holdFailureOnSecondRequestRollsBackFirst() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let a = try fx.makeFolder("A")
        let b = try fx.makeFolder("B")
        fx.failHoldFor.withLock { $0 = "B" }
        #expect(throws: KhoError.self) { try fx.offload([fx.request(a, symlink: true), fx.request(b)]) }
        #expect(FileOps.exists(a) && !FileOps.isSymlink(a))
        #expect(!FileOps.exists(a.deletingLastPathComponent().appendingPathComponent("A (khôi phục)")))
        #expect(FileOps.exists(b))
        #expect(try fx.ledger.operations().first?.state == .failed)
        #expect(!fx.archiveEntries().contains { $0.hasSuffix("/A") || $0.hasSuffix("/B") })
    }

    @Test func khoOfflineCreatesNothing() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        fx.khoMounted.withLock { $0 = false }
        #expect(throws: KhoError.khoOffline) { try fx.offload([fx.request(try fx.makeFolder("A"))]) }
        #expect(try fx.ledger.operationCount() == 0)
    }

    @Test func drainRejectsShallowPaths() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        try fx.sb.makeFile(fx.sb.layout.archive.appendingPathComponent("keep/x"), bytes: 10, seed: 1)
        try fx.ledger.addPendingCleanup(khoUUID: ServiceFixture.khoUUID, khoRelPath: "SwitchKho/Archive")
        fx.service.drainPendingCleanup()
        #expect(FileOps.exists(fx.sb.layout.archive.appendingPathComponent("keep/x")))
        #expect(try fx.ledger.pendingCleanup(khoUUID: ServiceFixture.khoUUID).isEmpty)
        #expect(try fx.ledger.recentActivity(limit: 1).first?.ok == false)
    }
}
