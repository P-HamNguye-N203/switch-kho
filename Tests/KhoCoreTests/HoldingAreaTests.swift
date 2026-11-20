import Darwin
import Foundation
import Testing
@testable import KhoCore

@Suite struct HoldingAreaTests {
    func setup() throws -> (TestSandbox, HoldingArea, URL) {
        let sb = try TestSandbox()
        let h = HoldingArea(root: sb.home.appendingPathComponent("Library/Application Support/SwitchKho/Holding"))
        let original = sb.home.appendingPathComponent("Downloads/Bộ cài.dmg")
        try sb.makeFile(original, bytes: 50_000, seed: 3)
        return (sb, h, original)
    }

    @Test func holdAndRelease() throws {
        let (sb, h, original) = try setup()
        defer { sb.cleanup() }
        let before = try ContentDigest.segmentsAndDigest(original).digest
        let slot = h.slotURL(opUID: "U1", index: 0, original: original)
        #expect(slot.lastPathComponent.hasSuffix(".held"))
        try h.hold(original, to: slot)
        #expect(!FileOps.exists(original))
        var st = stat()
        stat(h.root.path, &st)
        #expect(st.st_mode & 0o777 == 0o700)
        #expect(h.pendingBytes() > 0)
        let back = try h.release(slot, to: original, expectedIno: nil)
        #expect(back.path == original.path)
        #expect(try ContentDigest.segmentsAndDigest(original).digest == before)
    }

    @Test func releaseBesideOccupiedDirectoryAndSymlink() throws {
        let (sb, h, original) = try setup()
        defer { sb.cleanup() }
        let ino = FileOps.inode(original)
        let slot = h.slotURL(opUID: "U1", index: 0, original: original)
        try h.hold(original, to: slot)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let back = try h.release(slot, to: original, expectedIno: ino)
        #expect(back.lastPathComponent == "Bộ cài (khôi phục).dmg")
        #expect(try h.release(slot, to: original, expectedIno: ino).path == back.path)

        let other = sb.home.appendingPathComponent("Downloads/khác.txt")
        try sb.makeFile(other, bytes: 10, seed: 1)
        let slot2 = h.slotURL(opUID: "U2", index: 0, original: other)
        try h.hold(other, to: slot2)
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: sb.kho)
        let back2 = try h.release(slot2, to: other, expectedIno: nil)
        #expect(FileOps.isSymlink(other))
        #expect(back2.lastPathComponent == "khác (khôi phục).txt")
    }

    @Test func releaseMissingWithWrongInode() throws {
        let (sb, h, original) = try setup()
        defer { sb.cleanup() }
        let slot = h.slotURL(opUID: "U1", index: 0, original: original)
        try h.hold(original, to: slot)
        try FileOps.removeTree(slot)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        #expect(throws: KhoError.self) { try h.release(slot, to: original, expectedIno: 999_999_999) }
    }

    @Test func lockedOriginalIsRefusedClearly() throws {
        let (sb, h, original) = try setup()
        defer { sb.cleanup() }
        #expect(chflags(original.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(throws: KhoError.notDeletable(original.path)) {
            try h.hold(original, to: h.slotURL(opUID: "U1", index: 0, original: original))
        }
        #expect(FileOps.exists(original))
    }

    @Test func holdNeverOverwritesSlot() throws {
        let (sb, h, original) = try setup()
        defer { sb.cleanup() }
        let slot = h.slotURL(opUID: "U1", index: 0, original: original)
        try sb.makeFile(slot, bytes: 7, seed: 9)
        #expect(throws: KhoError.self) { try h.hold(original, to: slot) }
        #expect(try Data(contentsOf: slot).count == 7)
        #expect(FileOps.exists(original))
    }

    @Test func purgeRemovesLockedFiles() throws {
        let (sb, h, original) = try setup()
        defer { sb.cleanup() }
        let slot = h.slotURL(opUID: "U1", index: 0, original: original)
        try h.hold(original, to: slot)
        #expect(chflags(slot.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(h.slotDirectories() == ["U1"])
        try h.purge(opUID: "U1")
        #expect(!FileOps.exists(slot.deletingLastPathComponent()))
        try h.purge(opUID: "U1")
    }
}
