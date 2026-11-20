import Darwin
import Foundation
import Synchronization
import Testing
@testable import KhoCore

@Suite(.serialized) struct VerifiedCopierTests {
    func partials(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(".switchkho-partial-") }
    }

    func copier(afterFileCopied: (@Sendable (URL) -> Void)? = nil) -> VerifiedCopier {
        VerifiedCopier(capacityProvider: { _ in Int64(1) << 40 }, afterFileCopied: afterFileCopied)
    }

    func copy(_ c: VerifiedCopier, _ src: URL, _ dst: URL,
              isCancelled: @escaping @Sendable () -> Bool = { false },
              progress: @escaping @Sendable (CopyProgress) -> Void = { _ in }) throws -> CopyReport {
        try c.copy(from: src, to: dst, progress: progress, isCancelled: isCancelled)
    }

    func makeTree(_ sb: TestSandbox) throws -> URL {
        let src = sb.home.appendingPathComponent("Documents/Dự án")
        var n = 0
        for a in 0..<2 {
            for b in 0..<2 {
                for f in 0..<5 {
                    let p = src.appendingPathComponent("a\(a)/b\(b)/tệp \(f).txt")
                    try sb.makeFile(p, bytes: 1000 + n * 37, seed: UInt8(n))
                    n += 1
                }
            }
        }
        return src
    }

    @Test func nestedTreeCopiedAndVerified() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = try makeTree(sb)
        let dst = sb.kho.appendingPathComponent("SwitchKho/Archive/x")
        let report = try copy(copier(), src, dst)
        #expect(report.files.count == 20)
        for f in report.files {
            let d = try ContentDigest.digest(dst.appendingPathComponent(f.relPath), segments: f.segments)
            #expect(d == f.digest)
        }
        #expect(partials(dst.deletingLastPathComponent()).isEmpty)
    }

    @Test func tagsDatesAndSymlinksPreserved() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = sb.home.appendingPathComponent("Documents/tagged")
        let file = src.appendingPathComponent("f.txt")
        try sb.makeFile(file, bytes: 100, seed: 1)
        let tag = Data("bplist00\u{a1}\u{01}_\u{10}\u{03}Red\u{08}\u{0a}\0\0\0\0\0\0\u{01}\u{01}\0\0\0\0\0\0\0\u{02}\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\u{0e}".utf8)
        let rc = tag.withUnsafeBytes {
            setxattr(file.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, tag.count, 0, 0)
        }
        #expect(rc == 0)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("link").path,
                                                   withDestinationPath: "f.txt")
        let dst = sb.kho.appendingPathComponent("SwitchKho/Archive/tagged")
        _ = try copy(copier(), src, dst)

        let copied = dst.appendingPathComponent("f.txt")
        let size = getxattr(copied.path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0)
        #expect(size == tag.count)
        let mdate = try FileManager.default.attributesOfItem(atPath: copied.path)[.modificationDate] as? Date
        #expect(mdate == old)
        #expect(FileOps.isSymlink(dst.appendingPathComponent("link")))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("link").path) == "f.txt")
    }

    @Test func sparseFileStaysSparse() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = sb.home.appendingPathComponent("Downloads/sparse.img")
        try SparseFixture.make(src)
        let dst = sb.kho.appendingPathComponent("SwitchKho/Archive/sparse.img")
        _ = try copy(copier(), src, dst)
        #expect(try SparseFile.allocatedBytes(dst) < 8 * SparseFixture.mib)
    }

    @Test func corruptedCopyFailsVerification() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = try makeTree(sb)
        let before = try ContentDigest.segmentsAndDigest(src.appendingPathComponent("a0/b0/tệp 0.txt")).digest
        let c = copier(afterFileCopied: { url in
            if let h = try? FileHandle(forWritingTo: url) {
                try? h.seek(toOffset: 3)
                h.write(Data([0xFF]))
                try? h.close()
            }
        })
        let dst = sb.kho.appendingPathComponent("SwitchKho/Archive/x")
        #expect(throws: KhoError.self) { try copy(c, src, dst) }
        #expect(partials(dst.deletingLastPathComponent()).isEmpty)
        #expect(!FileOps.exists(dst))
        #expect(try ContentDigest.segmentsAndDigest(src.appendingPathComponent("a0/b0/tệp 0.txt")).digest == before)
    }

    @Test func cancelAfterFirstProgress() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = try makeTree(sb)
        let seen = Mutex(false)
        let dst = sb.kho.appendingPathComponent("SwitchKho/Archive/x")
        #expect(throws: CancellationError.self) {
            try copy(copier(), src, dst, isCancelled: { seen.withLock { $0 } },
                     progress: { _ in seen.withLock { $0 = true } })
        }
        #expect(partials(dst.deletingLastPathComponent()).isEmpty)
        #expect(!FileOps.exists(dst))
    }

    @Test func insufficientSpace() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = try makeTree(sb)
        let c = VerifiedCopier(capacityProvider: { _ in 0 })
        #expect {
            try copy(c, src, sb.kho.appendingPathComponent("SwitchKho/Archive/x"))
        } throws: { error in
            if case KhoError.insufficientSpace = error { return true }
            return false
        }
    }

    @Test func changedSourceDetected() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = try makeTree(sb)
        let report = try copy(copier(), src, sb.kho.appendingPathComponent("SwitchKho/Archive/x"))
        #expect(VerifiedCopier.changedSource(report.files, under: src) == nil)
        let target = src.appendingPathComponent("a1/b0/tệp 2.txt")
        try Data("đã sửa".utf8).write(to: target)
        #expect(VerifiedCopier.changedSource(report.files, under: src) == "a1/b0/tệp 2.txt")
    }

    @Test func lockedSourceCopiesUnlocked() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let src = try makeTree(sb)
        let locked = src.appendingPathComponent("a0/b1/tệp 1.txt")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        let dst = sb.kho.appendingPathComponent("SwitchKho/Archive/x")
        _ = try copy(copier(), src, dst)
        #expect(FileOps.flags(dst.appendingPathComponent("a0/b1/tệp 1.txt")) & UInt32(UF_IMMUTABLE) == 0)

        let c = copier(afterFileCopied: { url in
            if url.lastPathComponent == "tệp 3.txt", let h = try? FileHandle(forWritingTo: url) {
                h.write(Data([0x00, 0x01]))
                try? h.close()
            }
        })
        let dst2 = sb.kho.appendingPathComponent("SwitchKho/Archive/y")
        #expect(throws: KhoError.self) { try copy(c, src, dst2) }
        #expect(partials(dst2.deletingLastPathComponent()).isEmpty)
        _ = chflags(locked.path, 0)
    }
}
