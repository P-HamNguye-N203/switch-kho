import DiskArbitration
import Foundation

public struct VolumeInfo: Sendable, Hashable, Identifiable {
    public var id: String { uuid ?? url.path }
    public let url: URL
    public let name: String
    public let uuid: String?
    public let total: Int64
    /// Free space as `df` reports it.
    public let available: Int64
    /// Free space including purgeable data macOS can reclaim on demand.
    public let availableForImportant: Int64
    public let isInternal: Bool
    public let isRoot: Bool
    public let isDiskImage: Bool
    /// Localised format description, e.g. "APFS".
    public let format: String?

    public init(url: URL, name: String, uuid: String?, total: Int64, available: Int64,
                availableForImportant: Int64, isInternal: Bool, isRoot: Bool, isDiskImage: Bool,
                format: String?) {
        self.url = url
        self.name = name
        self.uuid = uuid
        self.total = total
        self.available = available
        self.availableForImportant = availableForImportant
        self.isInternal = isInternal
        self.isRoot = isRoot
        self.isDiskImage = isDiskImage
        self.format = format
    }

    public var used: Int64 { max(0, total - available) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    public var isAPFS: Bool { format?.localizedCaseInsensitiveContains("APFS") == true }
}

public enum VolumeService {
    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey,
        .volumeLocalizedFormatDescriptionKey,
    ]

    /// The startup disk plus real external drives: no internal secondary volumes, no disk
    /// images, nothing without a UUID, nothing outside /Volumes.
    public static func filterUserVolumes(_ all: [VolumeInfo]) -> [VolumeInfo] {
        all.filter { v in
            v.isRoot || (!v.isInternal && v.uuid != nil && !v.isDiskImage && v.url.path.hasPrefix("/Volumes/"))
        }
    }

    public static func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return filterUserVolumes(urls.compactMap(info(for:)))
    }

    public static func info(for url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let isRoot = v.volumeIsRootFileSystem ?? false
        return VolumeInfo(
            url: url, name: v.volumeName ?? url.lastPathComponent, uuid: v.volumeUUIDString,
            total: Int64(v.volumeTotalCapacity ?? 0), available: Int64(v.volumeAvailableCapacity ?? 0),
            availableForImportant: v.volumeAvailableCapacityForImportantUsage ?? 0,
            isInternal: v.volumeIsInternal ?? isRoot, isRoot: isRoot, isDiskImage: isDiskImage(url),
            format: v.volumeLocalizedFormatDescription)
    }

    static func isDiskImage(_ url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let desc = DADiskCopyDescription(disk) as? [CFString: Any]
        else { return false }
        let model = (desc[kDADiskDescriptionDeviceModelKey] as? String)?.trimmingCharacters(in: .whitespaces)
        return model == "Disk Image"
    }

    /// nil when `tmutil` cannot be run or its output is not understood.
    public static func hasTimeMachineDestination() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["destinationinfo"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("No destinations configured") { return false }
        return text.contains("Name") || text.contains("Kind") ? true : nil
    }
}
