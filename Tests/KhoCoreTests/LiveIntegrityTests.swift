import Darwin
import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct LiveIntegrityTests {
    func live() throws -> (ServiceFixture, URL, Int64) {
        let fx = try ServiceFixture()
        let support = fx.sb.home.appendingPathComponent("Library/Application Support/Fake")
        try fx.sb.makeFile(support.appendingPathComponent("data.db"), bytes: 4096, seed: 4)
        let rel = "SwitchKho/Live/test.fake/Library/Application Support/Fake"
        let opID = try fx.offload([OffloadRequest(original: support, khoRelPath: rel, purpose: .appData, leaveSymlink: true)],
                                  kind: .appLive, bundleID: "test.fake")
        return (fx, support, opID)
    }

    func status(_ fx: ServiceFixture, _ opID: Int64, mounted: Bool = true) throws -> LiveStatus {
        let op = try #require(try fx.ledger.operation(opID))
        return try #require(LiveIntegrity.check(items: LiveIntegrity.items(of: op, ledger: fx.ledger, layout: fx.sb.layout),
                                                khoMounted: mounted).first)
    }

    @Test func okWhenLinkAndTargetExist() throws {
        let (fx, _, opID) = try live()
        defer { fx.cleanup() }
        #expect(try status(fx, opID) == .ok)
    }

    @Test func khoMissingWhenUnmounted() throws {
        let (fx, _, opID) = try live()
        defer { fx.cleanup() }
        #expect(try status(fx, opID, mounted: false) == .khoMissing)
    }

    @Test func symlinkMissing() throws {
        let (fx, support, opID) = try live()
        defer { fx.cleanup() }
        _ = lchflags(support.path, 0)
        unlink(support.path)
        #expect(try status(fx, opID) == .symlinkMissing(support))
    }

    @Test func symlinkReplaced() throws {
        let (fx, support, opID) = try live()
        defer { fx.cleanup() }
        _ = lchflags(support.path, 0)
        unlink(support.path)
        try fx.sb.makeFile(support.appendingPathComponent("new"), bytes: 10, seed: 1)
        let st = try status(fx, opID)
        #expect(st == .symlinkReplaced(support), "\(st)")
    }

    @Test func targetMissing() throws {
        let (fx, _, opID) = try live()
        defer { fx.cleanup() }
        let onKho = fx.sb.layout.liveRoot(bundleID: "test.fake")
        try FileOps.removeTree(onKho)
        if case .targetMissing = try status(fx, opID) {} else { Issue.record("expected targetMissing") }
    }

    @Test func relockPutsTheFlagBack() throws {
        let (fx, support, _) = try live()
        defer { fx.cleanup() }
        _ = lchflags(support.path, 0)
        #expect(FileOps.flags(support) & UInt32(UF_IMMUTABLE) == 0)
        LiveIntegrity.relockIfNeeded(support)
        #expect(FileOps.flags(support) & UInt32(UF_IMMUTABLE) != 0)
    }

    @Test func relinkRecreatesALockedLink() throws {
        let (fx, support, opID) = try live()
        defer { fx.cleanup() }
        _ = lchflags(support.path, 0)
        unlink(support.path)
        let item = try #require(try fx.ledger.items(opID).first)
        try fx.service.relink(opID: opID, itemID: item.id)
        #expect(FileOps.isSymlink(support))
        #expect(FileOps.flags(support) & UInt32(UF_IMMUTABLE) != 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: support.path)
                .hasPrefix(fx.sb.khoLink.path + "/"))
        #expect(try status(fx, opID) == .ok)
    }

    @Test func relinkRefusesARealFolder() throws {
        let (fx, support, opID) = try live()
        defer { fx.cleanup() }
        _ = lchflags(support.path, 0)
        unlink(support.path)
        try fx.sb.makeFile(support.appendingPathComponent("mine"), bytes: 10, seed: 1)
        let item = try #require(try fx.ledger.items(opID).first)
        #expect(throws: KhoError.destinationOccupied(support.path)) {
            try fx.service.relink(opID: opID, itemID: item.id)
        }
        #expect(FileOps.exists(support.appendingPathComponent("mine")))
        #expect(!FileOps.isSymlink(support))
    }
}
