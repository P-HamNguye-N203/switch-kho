import CoreServices
import Darwin
import Foundation

public enum UsageSource: String, Sendable, Codable { case lastUsedXattr, spotlight, modified, added }

public struct UsageDate: Sendable, Hashable {
    public let date: Date
    public let source: UsageSource

    public init(date: Date, source: UsageSource) {
        self.date = date
        self.source = source
    }
}

public enum FileUsage {
    /// `com.apple.lastuseddate#PS`: a 16-byte timespec written by Launch Services.
    public static func lastUsedXattr(_ url: URL) -> Date? {
        var buf = [UInt8](repeating: 0, count: 16)
        let n = getxattr(url.path, "com.apple.lastuseddate#PS", &buf, 16, 0, XATTR_NOFOLLOW)
        guard n == 16 else { return nil }
        let sec = buf[0..<8].enumerated().reduce(Int64(0)) { $0 | Int64($1.element) << (8 * Int64($1.offset)) }
        let nsec = buf[8..<16].enumerated().reduce(Int64(0)) { $0 | Int64($1.element) << (8 * Int64($1.offset)) }
        guard sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(sec) + Double(nsec) / 1e9)
    }

    public static func spotlightLastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    public static func effective(_ url: URL) -> UsageDate? {
        var candidates: [UsageDate] = []
        if let d = lastUsedXattr(url) {
            candidates.append(UsageDate(date: d, source: .lastUsedXattr))
        } else if let d = spotlightLastUsed(url) {
            candidates.append(UsageDate(date: d, source: .spotlight))
        }
        if let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey]) {
            if let d = v.contentModificationDate { candidates.append(UsageDate(date: d, source: .modified)) }
            if let d = v.addedToDirectoryDate { candidates.append(UsageDate(date: d, source: .added)) }
        }
        return candidates.max { $0.date < $1.date }
    }

    public static func daysSince(_ date: Date?, now: Date = Date()) -> Int? {
        guard let date else { return nil }
        return max(0, Int(now.timeIntervalSince(date) / 86_400))
    }
}
