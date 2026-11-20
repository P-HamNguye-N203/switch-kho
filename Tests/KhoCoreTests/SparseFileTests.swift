import Darwin
import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct SparseFileTests {
    @Test func sparseFileSegmentsAndDigest() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let sparse = sb.root.appendingPathComponent("sparse.bin")
        try SparseFixture.make(sparse)

        #expect(try SparseFile.allocatedBytes(sparse) < 8 * SparseFixture.mib)
        let (segments, digest) = try ContentDigest.segmentsAndDigest(sparse)
        #expect(segments.count >= 2)
        #expect(try ContentDigest.segmentsAndDigest(sparse).digest == digest)

        // A dense file with the same logical content hashes the same over the sparse segments.
        let dense = sb.root.appendingPathComponent("dense.bin")
        let fd = open(dense.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        let zero = [UInt8](repeating: 0, count: 8 * SparseFixture.mib)
        for _ in 0..<128 {
            let n = zero.withUnsafeBytes { write(fd, $0.baseAddress, zero.count) }
            #expect(n == zero.count)
        }
        let ab = [UInt8](repeating: 0xAB, count: SparseFixture.mib)
        for offset in [0, 512 * SparseFixture.mib] {
            let n = ab.withUnsafeBytes { pwrite(fd, $0.baseAddress, ab.count, off_t(offset)) }
            #expect(n == ab.count)
        }
        close(fd)
        #expect(try ContentDigest.digest(dense, segments: segments) == digest)
    }

    @Test func emptyFileHasNoSegments() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let empty = sb.root.appendingPathComponent("empty")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let (segments, _) = try ContentDigest.segmentsAndDigest(empty)
        #expect(segments.isEmpty)
    }
}
