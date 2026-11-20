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

    @Test func defaultCopierHandlesMissingDestinationFolders() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = sb.home.appendingPathComponent("Documents/a.bin")
        try sb.makeFile(src, bytes: 5000, seed: 1)
        let dst = sb.layout.apps.appendingPathComponent("x/y/z/a.bin")
        _ = try VerifiedCopier().copy(from: src, to: dst, progress: { _ in }, isCancelled: { false })
        #expect(FileOps.exists(dst))
    }

    @Test func capacityIsMeasuredAtNearestExistingFolder() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = sb.home.appendingPathComponent("Documents/a.bin")
        try sb.makeFile(src, bytes: 5000, seed: 1)
        let asked = Locked<[URL]>([])
        let copier = VerifiedCopier(capacityProvider: { url in asked.withLock { $0.append(url) }; return 1 << 40 })
        _ = try copier.copy(from: src, to: sb.layout.apps.appendingPathComponent("x/y/a.bin"),
                            progress: { _ in }, isCancelled: { false })
        #expect(asked.withLock { $0 }.map(\.standardizedFileURL.path) == [sb.layout.base.standardizedFileURL.path])
        try FileManager.default.createDirectory(at: sb.layout.apps, withIntermediateDirectories: true)
        asked.withLock { $0 = [] }
        _ = try copier.copy(from: src, to: sb.layout.apps.appendingPathComponent("b.bin"),
                            progress: { _ in }, isCancelled: { false })
        #expect(asked.withLock { $0 }.map(\.standardizedFileURL.path) == [sb.layout.apps.standardizedFileURL.path])
    }

    @Test func unpluggedKhoStopsBeforeTheNextItem() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let a = try fx.makeFolder("A", files: 1), b = try fx.makeFolder("B", files: 1)
        // Item A copies completely; then the Kho "goes away" (identity file gone) before B.
        let identity = fx.sb.layout.identityFile
        fx.afterCopy.withLock { $0 = { _ in try? FileManager.default.removeItem(at: identity) } }
        #expect(throws: KhoError.khoOffline) { try fx.offload([fx.request(a), fx.request(b)]) }
        #expect(FileOps.exists(a) && FileOps.exists(b))
        let op = try #require(try fx.ledger.operations().first)
        #expect(op.state == .failed)
        let items = try fx.ledger.items(op.id)
        #expect(items[1].khoRelPath == nil)
        #expect(!FileOps.exists(try fx.sb.layout.absoluteURL(relative: fx.rel(a))))
        #expect(!FileOps.exists(try fx.sb.layout.absoluteURL(relative: fx.rel(b))))
    }

    @Test func partialLeftByUnpluggedKhoIsRemovedOnNextMount() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A", files: 2)
        let base = fx.sb.layout.base, gone = fx.sb.root.appendingPathComponent("unplugged")
        // Unplug mid-copy: the partial stays on the (now absent) Kho.
        fx.afterCopy.withLock { $0 = { _ in
            if FileOps.exists(base) { try? FileManager.default.moveItem(at: base, to: gone) }
        } }
        fx.khoMounted.withLock { $0 = true }
        #expect(throws: (any Error).self) { try fx.offload([fx.request(dir)]) }
        fx.khoMounted.withLock { $0 = false }
        _ = fx.service.recover()   // offline: must not forget anything
        #expect(try fx.ledger.pendingCleanup(khoUUID: ServiceFixture.khoUUID).contains {
            $0.khoRelPath.contains(".switchkho-partial-") })
        try FileManager.default.moveItem(at: gone, to: base)
        fx.khoMounted.withLock { $0 = true }
        _ = fx.service.recover()
        let left = try FileManager.default.subpathsOfDirectory(atPath: base.path)
        #expect(!left.contains { $0.contains(".switchkho-partial-") }, "\(left)")
        #expect(try fx.ledger.pendingCleanup(khoUUID: ServiceFixture.khoUUID).isEmpty)
    }

    @Test func staleCleanupRowNeverDeletesCommittedCopy() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let opID = try fx.offload([fx.request(dir)])
        let rel = try #require(try fx.ledger.items(opID).first?.khoRelPath)
        try fx.ledger.addPendingCleanup(khoUUID: ServiceFixture.khoUUID, khoRelPath: rel)
        fx.service.drainPendingCleanup()
        #expect(FileOps.exists(try fx.sb.layout.absoluteURL(relative: rel)))
        #expect(try fx.ledger.pendingCleanup(khoUUID: ServiceFixture.khoUUID).isEmpty)
    }

    @Test func failedUndoDeleteIsQueued() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let opID = try fx.offload([fx.request(dir)])
        let rel = try #require(try fx.ledger.items(opID).first?.khoRelPath)
        let parent = try fx.sb.layout.absoluteURL(relative: rel).deletingLastPathComponent()
        chmod(parent.path, 0o555)
        defer { chmod(parent.path, 0o755) }
        try fx.service.undo(opID: opID)
        #expect(try fx.ledger.pendingCleanup(khoUUID: ServiceFixture.khoUUID).map(\.khoRelPath) == [rel])
        chmod(parent.path, 0o755)
        fx.service.drainPendingCleanup()
        #expect(!FileOps.exists(try fx.sb.layout.absoluteURL(relative: rel)))
    }

    @Test func partialIsNeverCreatedUnrecorded() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = sb.home.appendingPathComponent("Documents/a.bin")
        try sb.makeFile(src, bytes: 5000, seed: 1)
        let dst = sb.layout.archive.appendingPathComponent("a.bin")
        #expect(throws: KhoError.io("ledger down")) {
            _ = try VerifiedCopier(capacityProvider: { _ in 1 << 40 }).copy(
                from: src, to: dst, onPartialCreated: { _ in throw KhoError.io("ledger down") },
                progress: { _ in }, isCancelled: { false })
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: sb.layout.archive.path)) ?? []
        #expect(left.isEmpty, "\(left)")
    }

    @Test func ourLinksAreKnownWithoutTheKho() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        fx.khoMounted.withLock { $0 = false }
        let ours = fx.sb.khoLink.appendingPathComponent("Archive/x").path
        #expect(fx.service.isOurLinkTarget(ours))
        #expect(!fx.service.isOurLinkTarget(fx.sb.khoLink.path))
        // A link someone else made straight into a SwitchKho tree is not ours.
        #expect(!fx.service.isOurLinkTarget(fx.sb.layout.archive.appendingPathComponent("x").path))
        #expect(!fx.service.isOurLinkTarget("/Volumes/Other/KhoLink/Archive/x"))
        let link = fx.sb.home.appendingPathComponent("Documents/l")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: ours)
        try fx.service.removeOurSymlink(at: link)
        #expect(!FileOps.isSymlink(link))
    }
}
