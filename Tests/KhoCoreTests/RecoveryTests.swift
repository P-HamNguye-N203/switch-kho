import Darwin
import Foundation
import Testing
@testable import KhoCore

/// Every state is built by hand through the ledger and the file system, as a crash would leave it.
@Suite(.serialized) struct RecoveryTests {
    /// Creates an operation with its items and copies them to the Kho, leaving it in `copying`.
    func copied(_ fx: ServiceFixture, _ originals: [URL], symlink: Bool = false,
                kind: OperationKind = .personal, bundleID: String? = nil) throws -> Int64 {
        let op = try fx.ledger.createOperation(kind: kind, title: "t", bundleID: bundleID, khoUUID: ServiceFixture.khoUUID)
        for (i, o) in originals.enumerated() {
            let item = try fx.ledger.addItem(opID: op, idx: i, originalPath: o.path, purpose: .personal,
                                             origIno: FileOps.inode(o), leftSymlink: symlink)
            let dst = fx.sb.layout.archiveURL(forOriginal: o)
            let report = try fx.service.copier.copy(from: o, to: dst, progress: { _ in }, isCancelled: { false })
            try fx.ledger.updateItem(item, khoRelPath: .some(fx.rel(o)), allocated: report.allocatedBytes,
                                     filesJSON: OffloadService.encodeFiles(report.files))
        }
        return op
    }

    func hold(_ fx: ServiceFixture, _ op: Int64, item index: Int, symlink: Bool = false) throws {
        let o = try #require(try fx.ledger.operation(op))
        let item = try fx.ledger.items(op)[index]
        let slot = fx.service.holding.slotURL(opUID: o.uid, index: item.idx, original: item.originalURL)
        try fx.ledger.updateItem(item.id, holdingPath: .some(slot.path))
        try fx.service.holding.hold(item.originalURL, to: slot)
        if symlink {
            try fx.service.makeOurSymlink(at: item.originalURL, relPath: item.khoRelPath!, layout: fx.sb.layout)
            try fx.ledger.updateItem(item.id, symlinkCreated: true)
        }
    }

    @Test func copyingFailsAndCleansKho() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let op = try copied(fx, [dir])
        let onKho = try fx.khoCopy(op)
        _ = fx.service.recover()
        #expect(try fx.ledger.operation(op)?.state == .failed)
        #expect(!FileOps.exists(onKho))
        #expect(FileOps.exists(dir))
    }

    @Test func movingRollsBackHalfHeld() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let a = try fx.makeFolder("A"), b = try fx.makeFolder("B")
        let op = try copied(fx, [a, b])
        try fx.ledger.transition(op, from: [.copying], to: .moving)
        try hold(fx, op, item: 0)
        _ = fx.service.recover()
        #expect(FileOps.exists(a) && FileOps.exists(b))
        #expect(fx.archiveEntries().isEmpty || !fx.archiveEntries().contains { $0.hasSuffix("/A") || $0.hasSuffix("/B") })
        #expect(try fx.ledger.operation(op)?.state == .failed)
    }

    @Test func movingRemovesOurSymlink() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let a = try fx.makeFolder("A")
        let op = try copied(fx, [a], symlink: true)
        try fx.ledger.transition(op, from: [.copying], to: .moving)
        try hold(fx, op, item: 0, symlink: true)
        #expect(FileOps.isSymlink(a))
        _ = fx.service.recover()
        #expect(FileOps.exists(a) && !FileOps.isSymlink(a))
        #expect(FileOps.exists(a.appendingPathComponent("sub/f0.bin")))
    }

    @Test func holdingWithoutDeadlineGetsOne() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let op = try copied(fx, [try fx.makeFolder("A")])
        try fx.ledger.transition(op, from: [.copying], to: .moving)
        try hold(fx, op, item: 0)
        try fx.ledger.transition(op, from: [.moving], to: .holding)
        #expect(try fx.ledger.operation(op)?.holdingUntil == nil)
        _ = fx.service.recover()
        #expect(try fx.ledger.operation(op)?.holdingUntil != nil)
    }

    @Test func committingFinishes() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let op = try copied(fx, [try fx.makeFolder("A")])
        try fx.ledger.transition(op, from: [.copying], to: .moving)
        try hold(fx, op, item: 0)
        try fx.ledger.transition(op, from: [.moving], to: .committing)
        let slotDir = URL(fileURLWithPath: try fx.ledger.items(op)[0].holdingPath!).deletingLastPathComponent()
        _ = fx.service.recover()
        #expect(!FileOps.exists(slotDir))
        #expect(try fx.ledger.operation(op)?.state == .committed)
    }

    @Test func undoingContinues() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let a = try fx.makeFolder("A"), b = try fx.makeFolder("B")
        let op = try fx.offload([fx.request(a), fx.request(b)])
        try fx.ledger.transition(op, from: [.holding], to: .undoing)
        let first = try fx.ledger.items(op)[0]
        try fx.service.holding.release(URL(fileURLWithPath: first.holdingPath!), to: a, expectedIno: first.origIno)
        try fx.ledger.updateItem(first.id, released: true)
        _ = fx.service.recover()
        #expect(FileOps.exists(a) && FileOps.exists(b))
        #expect(try fx.ledger.operation(op)?.state == .undone)
    }

    @Test func undoingWaitsForRunningApp() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let a = try fx.makeFolder("A")
        let op = try fx.offload([fx.request(a)], kind: .appCold, bundleID: "com.x")
        try fx.ledger.transition(op, from: [.holding], to: .undoing)
        fx.running.withLock { $0 = true }
        _ = fx.service.recover()
        #expect(try fx.ledger.operation(op)?.state == .undoing)
        #expect(!FileOps.exists(a))
    }

    @Test func needsReviewIsLeftAlone() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let a = try fx.makeFolder("A")
        let op = try fx.offload([fx.request(a)])
        try fx.ledger.setNeedsReview(op, true)
        fx.khoMounted.withLock { $0 = false }
        fx.advance(days: 30)
        let report = fx.service.recover()
        #expect(report.needsReview == [op])
        #expect(try fx.ledger.operation(op)?.state == .holding)
        #expect(FileOps.exists(URL(fileURLWithPath: try fx.ledger.items(op)[0].holdingPath!)))
    }

    @Test func orphanHoldingFolderIsReportedNotDeleted() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let stray = fx.service.holding.root.appendingPathComponent("UID-LA/0-x.held")
        try fx.sb.makeFile(stray, bytes: 10, seed: 1)
        _ = try fx.offload([fx.request(try fx.makeFolder("A"))])
        let report = fx.service.recover()
        #expect(report.orphanHoldingDirs == ["UID-LA"])
        #expect(FileOps.exists(stray))
    }

    @Test func recordedPartialsAreRemoved() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let partial = fx.sb.home.appendingPathComponent("Documents/.switchkho-partial-\(UUID().uuidString)")
        try fx.sb.makeFile(partial.appendingPathComponent("x"), bytes: 10, seed: 1)
        try fx.ledger.addPartial(partial.path)
        let khoPartial = fx.sb.layout.archive.appendingPathComponent("a/.switchkho-partial-1")
        try fx.sb.makeFile(khoPartial.appendingPathComponent("y"), bytes: 10, seed: 1)
        // Kho partials are recorded by Kho identity when created.
        try fx.ledger.addPendingCleanup(khoUUID: ServiceFixture.khoUUID,
                                        khoRelPath: try #require(fx.sb.layout.relativePath(khoPartial)))
        _ = fx.service.recover()
        #expect(!FileOps.exists(partial))
        #expect(!FileOps.exists(khoPartial))
        #expect(try fx.ledger.partials().isEmpty)
        #expect(try fx.ledger.pendingCleanup(khoUUID: ServiceFixture.khoUUID).isEmpty)
    }

    /// Nothing the ledger does not know about is ever deleted from the Kho.
    @Test func unrecordedKhoPartialIsLeftAlone() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let stray = fx.sb.layout.archive.appendingPathComponent("a/.switchkho-partial-2")
        try fx.sb.makeFile(stray.appendingPathComponent("y"), bytes: 10, seed: 1)
        _ = fx.service.recover()
        #expect(FileOps.exists(stray))
    }
}
