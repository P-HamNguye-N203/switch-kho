import Darwin
import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct LiveRelocatorTests {
    struct Setup {
        let fx: ServiceFixture
        let support: URL
        let installed: InstalledApp

        func footprint() throws -> AppFootprint {
            try #require(AppDataMapper.map(home: fx.sb.home, apps: [installed], overrides: [:]).footprints.first)
        }

        func relocate() throws -> Int64 {
            let fp = try footprint()
            return try LiveRelocator.relocate(fp, folders: LiveRelocator.eligibleFolders(fp), service: fx.service,
                                              ledger: fx.ledger, layout: fx.sb.layout, home: fx.sb.home,
                                              isRunning: { _ in false })
        }
    }

    func setUp() throws -> Setup {
        let fx = try ServiceFixture()
        let installed = try fx.sb.makeAppBundle("Fake", "test.fake")
        let support = fx.sb.home.appendingPathComponent("Library/Application Support/Fake")
        try fx.sb.makeFile(support.appendingPathComponent("data.db"), bytes: 32 << 10, seed: 4)
        return Setup(fx: fx, support: support, installed: installed)
    }

    @Test func relocateLeavesLockedLinkThroughKhoLink() throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let before = try Data(contentsOf: s.support.appendingPathComponent("data.db"))
        _ = try s.relocate()
        #expect(FileOps.isSymlink(s.support))
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: s.support.path)
        #expect(target == s.fx.sb.khoLink.appendingPathComponent("Live/test.fake/Library/Application Support/Fake").path)
        #expect(try Data(contentsOf: s.support.appendingPathComponent("data.db")) == before)
        #expect(FileOps.flags(s.support) & UInt32(UF_IMMUTABLE) != 0)
        #expect(unlink(s.support.path) != 0)
        #expect(FileOps.isSymlink(s.support))
    }

    @Test func bringBackWhileHoldingKeepsNewFiles() throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let opID = try s.relocate()
        try Data("mới".utf8).write(to: s.support.appendingPathComponent("new.txt"))
        try LiveRelocator.bringBack(opID: opID, service: s.fx.service, ledger: s.fx.ledger)
        #expect(!FileOps.isSymlink(s.support))
        #expect(FileOps.exists(s.support.appendingPathComponent("data.db")))
        #expect(FileOps.exists(s.support.appendingPathComponent("new.txt")))
    }

    @Test func bringBackAfterCommitLeavesNothingOnKho() throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let opID = try s.relocate()
        s.fx.advance(days: 8)
        #expect(s.fx.service.commitDue() == [opID])
        try LiveRelocator.bringBack(opID: opID, service: s.fx.service, ledger: s.fx.ledger)
        #expect(!FileOps.isSymlink(s.support))
        #expect(FileOps.exists(s.support.appendingPathComponent("data.db")))
        #expect(!FileOps.exists(s.fx.sb.layout.liveRoot(bundleID: "test.fake").appendingPathComponent("Library")))
    }

    @Test func bringBackWhileRunningChangesNothing() throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let opID = try s.relocate()
        s.fx.running.withLock { $0 = true }
        #expect(throws: KhoError.appRunning("Fake")) {
            try LiveRelocator.bringBack(opID: opID, service: s.fx.service, ledger: s.fx.ledger)
        }
        #expect(FileOps.isSymlink(s.support))
        #expect(FileOps.exists(s.fx.sb.layout.liveRoot(bundleID: "test.fake")))
    }

    @Test func bringBackRefusesARealFolderInPlaceOfTheLink() throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let opID = try s.relocate()
        _ = lchflags(s.support.path, 0)
        #expect(unlink(s.support.path) == 0)
        try s.fx.sb.makeFile(s.support.appendingPathComponent("made-while-away.txt"), bytes: 10, seed: 1)
        #expect(throws: KhoError.self) {
            try LiveRelocator.bringBack(opID: opID, service: s.fx.service, ledger: s.fx.ledger)
        }
        #expect(FileOps.exists(s.support.appendingPathComponent("made-while-away.txt")))
        #expect(try s.fx.ledger.operation(opID)?.state == .holding)
    }

    @Test func vmImagesAndOtherAreasAreRefused() throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        // A 1 GiB sparse disk image: detected by its logical size, takes no space.
        let disk = s.support.appendingPathComponent("vm_bundles/disk.raw")
        try s.fx.sb.makeFile(disk, bytes: 10, seed: 2)
        let h = try FileHandle(forWritingTo: disk)
        try h.truncate(atOffset: 1 << 30)
        try h.close()
        let e = LiveRelocator.eligibility(for: try s.footprint(), isRunning: false, ledger: s.fx.ledger)
        #expect(e.blockers.contains { $0.hasPrefix("Có ảnh đĩa máy ảo") })
        #expect(throws: KhoError.self) { _ = try s.relocate() }
        #expect(!FileOps.isSymlink(s.support))

        let container = s.fx.sb.home.appendingPathComponent("Library/Containers/test.other")
        try s.fx.sb.makeFile(container.appendingPathComponent("Data/x"), bytes: 10, seed: 3)
        let other = try s.fx.sb.makeAppBundle("Other", "test.other")
        let fp = try #require(AppDataMapper.map(home: s.fx.sb.home, apps: [other], overrides: [:]).footprints.first)
        #expect(LiveRelocator.eligibility(for: fp, isRunning: false, ledger: s.fx.ledger).blockers
                .contains("Chỉ hỗ trợ dữ liệu trong Application Support"))
        #expect(LiveRelocator.requests(for: fp, folders: fp.folders, home: s.fx.sb.home, layout: s.fx.sb.layout).isEmpty)
    }
}

@Suite(.serialized) struct LiveRelocatorEdgeTests {
    /// An undo that stopped after the first of two folders: the folder already back is a real
    /// folder now, which must not block finishing the job.
    @Test func interruptedUndoWithTwoFoldersCanFinish() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let support = fx.sb.home.appendingPathComponent("Library/Application Support")
        let a = support.appendingPathComponent("FakeA"), b = support.appendingPathComponent("FakeB")
        try fx.sb.makeFile(a.appendingPathComponent("a.db"), bytes: 4096, seed: 1)
        try fx.sb.makeFile(b.appendingPathComponent("b.db"), bytes: 4096, seed: 2)
        let root = "SwitchKho/Live/test.fake/Library/Application Support"
        let opID = try fx.offload([
            OffloadRequest(original: a, khoRelPath: "\(root)/FakeA", purpose: .appData, leaveSymlink: true),
            OffloadRequest(original: b, khoRelPath: "\(root)/FakeB", purpose: .appData, leaveSymlink: true),
        ], kind: .appLive, bundleID: "test.fake")
        // Stop the undo once the first folder is back as a real folder.
        #expect(throws: CancellationError.self) {
            try fx.service.undo(opID: opID, isCancelled: { !FileOps.isSymlink(a) })
        }
        #expect(!FileOps.isSymlink(a) && FileOps.exists(a.appendingPathComponent("a.db")))
        #expect(FileOps.isSymlink(b))
        let op = try #require(try fx.ledger.operation(opID))
        let statuses = LiveIntegrity.check(items: LiveIntegrity.items(of: op, ledger: fx.ledger, layout: fx.sb.layout),
                                           khoMounted: true)
        #expect(statuses == [.ok])
        try LiveRelocator.bringBack(opID: opID, service: fx.service, ledger: fx.ledger)
        #expect(!FileOps.isSymlink(b) && FileOps.exists(b.appendingPathComponent("b.db")))
        #expect(try fx.ledger.operation(opID)?.state == .undone)
    }

    /// A copy kept from while the Kho was away comes back beside the live link, never over it.
    @Test func restoredSetAsideLandsBesideTheLink() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let support = fx.sb.home.appendingPathComponent("Library/Application Support/Fake")
        try fx.sb.makeFile(support.appendingPathComponent("data.db"), bytes: 4096, seed: 1)
        let liveID = try fx.offload([OffloadRequest(original: support,
                                                    khoRelPath: "SwitchKho/Live/test.fake/Library/Application Support/Fake",
                                                    purpose: .appData, leaveSymlink: true)],
                                    kind: .appLive, bundleID: "test.fake")
        _ = lchflags(support.path, 0)
        unlink(support.path)
        try fx.sb.makeFile(support.appendingPathComponent("away.txt"), bytes: 10, seed: 2)
        let asideID = try fx.service.setAside(liveOpID: liveID, folder: support)
        #expect(FileOps.isSymlink(support))
        fx.advance(days: 8)
        #expect(Set(fx.service.commitDue()) == [liveID, asideID])
        try LiveRelocator.bringBack(opID: asideID, service: fx.service, ledger: fx.ledger)
        #expect(FileOps.isSymlink(support))
        let beside = support.deletingLastPathComponent().appendingPathComponent("Fake (bản khi Kho vắng)")
        #expect(FileOps.exists(beside.appendingPathComponent("away.txt")))
        #expect(try fx.ledger.operation(asideID)?.state == .restored)
        #expect(try fx.ledger.operation(liveID)?.state == .committed)
    }
}
