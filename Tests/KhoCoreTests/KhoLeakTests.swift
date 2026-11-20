import Foundation
import Testing
@testable import KhoCore

/// The Kho never keeps copies the ledger does not know about, even after a crash or a
/// failed delete.
@Suite(.serialized) struct KhoLeakTests {
    @Test func khoPathIsRecordedBeforeCopying() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let seen = Locked<[String?]>([])
        let ledger = fx.ledger
        fx.afterCopy.withLock { $0 = { _ in
            let rel = (try? ledger.operations().first.flatMap { try ledger.items($0.id).first?.khoRelPath }) ?? nil
            seen.withLock { $0.append(rel) }
        } }
        try fx.offload([fx.request(dir)])
        let recorded = seen.withLock { $0 }
        #expect(!recorded.isEmpty)
        #expect(recorded.allSatisfy { $0 == fx.rel(dir) })
    }

    /// Crash after the copier's final rename but before the ledger learned the copy finished.
    @Test func recoveryRemovesCopyLeftByCrashAfterRename() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let rel = fx.rel(dir)
        let opID = try fx.ledger.createOperation(kind: .personal, title: "t", bundleID: nil, khoUUID: ServiceFixture.khoUUID)
        let itemID = try fx.ledger.addItem(opID: opID, idx: 0, originalPath: dir.path, purpose: .personal,
                                           origIno: FileOps.inode(dir))
        try fx.ledger.updateItem(itemID, khoRelPath: .some(rel))
        let onKho = try fx.sb.layout.absoluteURL(relative: rel)
        try fx.sb.makeFile(onKho.appendingPathComponent("sub/f0.bin"), bytes: 4000, seed: 0)

        _ = fx.service.recover()
        #expect(!FileOps.exists(onKho))
        #expect(try fx.ledger.operation(opID)?.state == .failed)
        #expect(FileOps.exists(dir))
    }

    @Test func failedKhoDeleteIsRetriedUntilItSucceeds() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let rel = fx.rel(dir)
        fx.afterCopy.withLock { $0 = { _ in } }
        // Make the copy fail after it lands, then make deleting it fail too.
        fx.corrupt.withLock { $0.insert("f0.bin") }
        let parent = try fx.sb.layout.absoluteURL(relative: rel).deletingLastPathComponent()
        let ledger = fx.ledger
        fx.afterCopy.withLock { $0 = { _ in
            // Lock the parent once the destination exists so removal fails with EACCES.
            if let ops = try? ledger.operations(), !ops.isEmpty { chmod(parent.path, 0o555) }
        } }
        #expect(throws: KhoError.self) { try fx.offload([fx.request(dir)]) }
        // Partial copy is gone (renamed never happened); simulate the leftover final copy instead.
        chmod(parent.path, 0o755)
        let onKho = try fx.sb.layout.absoluteURL(relative: rel)
        try fx.sb.makeFile(onKho.appendingPathComponent("x"), bytes: 10, seed: 1)
        chmod(parent.path, 0o555)
        let op = try #require(try fx.ledger.operations().first)
        fx.service.failCopying(op, error: "again")
        #expect(FileOps.exists(onKho))
        #expect(try fx.ledger.pendingCleanup(khoUUID: ServiceFixture.khoUUID).map(\.khoRelPath).contains(rel))

        fx.service.drainPendingCleanup()
        #expect(try fx.ledger.pendingCleanup(khoUUID: ServiceFixture.khoUUID).map(\.khoRelPath).contains(rel))

        chmod(parent.path, 0o755)
        fx.service.drainPendingCleanup()
        #expect(!FileOps.exists(onKho))
        #expect(try fx.ledger.pendingCleanup(khoUUID: ServiceFixture.khoUUID).isEmpty)
    }

    @Test func occupiedDestinationIsNeverDeleted() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let rel = fx.rel(dir)
        let onKho = try fx.sb.layout.absoluteURL(relative: rel)
        // Something else appears at the destination while we copy.
        fx.afterCopy.withLock { $0 = { _ in
            if !FileOps.exists(onKho) { try? fx.sb.makeFile(onKho.appendingPathComponent("theirs"), bytes: 10, seed: 9) }
        } }
        #expect(throws: KhoError.self) { try fx.offload([fx.request(dir)]) }
        #expect(FileOps.exists(onKho.appendingPathComponent("theirs")))
        #expect(FileOps.exists(dir))
    }
}
