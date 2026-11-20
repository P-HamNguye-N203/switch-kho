import Darwin
import Foundation
@testable import KhoCore

enum SparseFixture {
    static let mib = 1 << 20

    /// 1 GiB file with 1 MiB of data at offset 0 and 1 MiB at offset 512 MiB.
    static func make(_ url: URL) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw KhoError.io("open failed") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(1 << 30)) == 0 else { throw KhoError.io("ftruncate failed") }
        let chunk = [UInt8](repeating: 0xAB, count: mib)
        for offset in [0, 512 * mib] {
            let n = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress, mib, off_t(offset)) }
            guard n == mib else { throw KhoError.io("pwrite failed") }
        }
    }
}
