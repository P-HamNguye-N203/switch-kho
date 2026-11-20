import Darwin
import Foundation

/// A data (non-hole) region of a file.
public struct Segment: Codable, Sendable, Equatable {
    public let offset: Int64
    public let length: Int64

    public init(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
    }
}

public enum SparseFile {
    /// Bytes actually allocated on disk (`st_blocks * 512`), without following symlinks.
    public static func allocatedBytes(_ url: URL) throws -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw KhoError.io("Không đọc được \(url.path): \(String(cString: strerror(errno)))")
        }
        return Int64(st.st_blocks) * 512
    }

    /// True when APFS/HFS transparent compression is used (allocated size is meaningless then).
    public static func isCompressed(_ url: URL) -> Bool {
        FileOps.flags(url) & UInt32(UF_COMPRESSED) != 0
    }

    /// Data regions found with `SEEK_DATA`/`SEEK_HOLE`. When the volume does not support
    /// hole detection the whole file is reported as one region, which is still correct.
    public static func dataSegments(_ fd: Int32, length: Int64) -> [Segment] {
        guard length > 0 else { return [] }
        var result: [Segment] = []
        var pos: off_t = 0
        while pos < length {
            let dataStart = lseek(fd, pos, SEEK_DATA)
            if dataStart < 0 {
                if errno == ENXIO { break }
                return [Segment(offset: 0, length: length)]
            }
            var holeStart = lseek(fd, dataStart, SEEK_HOLE)
            if holeStart < 0 || holeStart > length { holeStart = off_t(length) }
            if holeStart > dataStart {
                result.append(Segment(offset: Int64(dataStart), length: Int64(holeStart - dataStart)))
            }
            pos = holeStart
            if holeStart <= dataStart { break }
        }
        return result
    }
}
