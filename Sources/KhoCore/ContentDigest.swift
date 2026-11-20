import CryptoKit
import Darwin
import Foundation

/// SHA-256 over a file's data regions. Source and destination are hashed with the *same*
/// segment list, so a destination with a different hole layout still produces the same
/// digest when its logical content is identical (holes read back as zeros).
public enum ContentDigest {
    static let chunk = 8 * 1024 * 1024

    public static func digest(_ url: URL, segments: [Segment]) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw KhoError.io("Không mở được \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunk)
        for seg in segments {
            withUnsafeBytes(of: UInt64(seg.offset).littleEndian) { hasher.update(bufferPointer: $0) }
            withUnsafeBytes(of: UInt64(seg.length).littleEndian) { hasher.update(bufferPointer: $0) }
            var done: Int64 = 0
            while done < seg.length {
                let want = Int(min(Int64(chunk), seg.length - done))
                let got = buffer.withUnsafeMutableBytes { raw in
                    pread(fd, raw.baseAddress, want, off_t(seg.offset + done))
                }
                if got < 0 {
                    throw KhoError.io("Lỗi đọc \(url.path): \(String(cString: strerror(errno)))")
                }
                if got == 0 { throw KhoError.verifyFailed(url.lastPathComponent) }
                buffer.withUnsafeBytes { raw in
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<got]))
                }
                done += Int64(got)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func segmentsAndDigest(_ url: URL) throws -> (segments: [Segment], digest: String) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw KhoError.io("Không mở được \(url.path): \(String(cString: strerror(errno)))")
        }
        var st = stat()
        fstat(fd, &st)
        let segments = SparseFile.dataSegments(fd, length: Int64(st.st_size))
        close(fd)
        return (segments, try digest(url, segments: segments))
    }
}
