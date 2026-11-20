import Darwin
import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct RealKhoCopyTests {
    static let enabled = ProcessInfo.processInfo.environment["SWITCHKHO_REAL_KHO"] == "1"

    @Test(.enabled(if: RealKhoCopyTests.enabled))
    func realKhoSparseCopy() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = sb.root.appendingPathComponent("sparse.img")
        try SparseFixture.make(src)
        // Leaves the real Kho exactly as it was: a SwitchKho folder created only for this
        // test is removed again afterwards.
        let base = URL(fileURLWithPath: "/Volumes/Kho/SwitchKho")
        let createdBase = !FileOps.exists(base)
        if createdBase { try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false) }
        let dir = base.appendingPathComponent("_selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer {
            try? FileOps.removeTree(dir)
            if createdBase { _ = rmdir(base.path) }
        }
        let dst = dir.appendingPathComponent("sparse.img")
        _ = try VerifiedCopier().copy(from: src, to: dst, progress: { _ in }, isCancelled: { false })
        #expect(try SparseFile.allocatedBytes(dst) < 8 * SparseFixture.mib)
    }
}
