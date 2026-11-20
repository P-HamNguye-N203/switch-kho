import Darwin
import Foundation
import Testing
@testable import KhoCore

@Suite struct FileUsageTests {
    func writeLastUsed(_ file: URL, _ date: Date) {
        let sec = Int64(date.timeIntervalSince1970)
        var buf = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { buf[i] = UInt8(truncatingIfNeeded: sec >> (8 * Int64(i))) }
        #expect(setxattr(file.path, "com.apple.lastuseddate#PS", &buf, 16, 0, XATTR_NOFOLLOW) == 0)
    }

    @Test func decodesLastUsedXattr() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let file = sb.home.appendingPathComponent("Downloads/a.dmg")
        try sb.makeFile(file, bytes: 10, seed: 1)
        let used = Date(timeIntervalSince1970: floor(Date().addingTimeInterval(-400 * 86_400).timeIntervalSince1970))
        writeLastUsed(file, used)
        #expect(FileUsage.lastUsedXattr(file) == used)
    }

    /// A freshly created file's "date added" is now, so the last-used value has to be the
    /// newest of the candidates for it to win.
    @Test func effectivePicksNewestWithSource() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let file = sb.home.appendingPathComponent("Downloads/b.dmg")
        try sb.makeFile(file, bytes: 10, seed: 1)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-500 * 86_400)],
                                              ofItemAtPath: file.path)
        let used = Date(timeIntervalSince1970: floor(Date().addingTimeInterval(3600).timeIntervalSince1970))
        writeLastUsed(file, used)
        let e = try #require(FileUsage.effective(file))
        #expect(e.source == .lastUsedXattr)
        #expect(e.date == used)
    }
}
