import Darwin
import Foundation

public enum LibraryArea: String, CaseIterable, Sendable, Codable {
    case applicationSupport = "Application Support"
    case containers = "Containers"
    case groupContainers = "Group Containers"
    case caches = "Caches"
    case httpStorages = "HTTPStorages"
    case webKit = "WebKit"
    case logs = "Logs"
    case savedState = "Saved Application State"

    /// Areas whose contents are regenerable caches.
    public var isCache: Bool { [.caches, .httpStorages, .webKit, .logs].contains(self) }
}

public struct AppDataFolder: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let area: LibraryArea
    public let allocated: Int64
    public let hasVMImage: Bool

    public init(url: URL, area: LibraryArea, allocated: Int64, hasVMImage: Bool) {
        self.url = url
        self.area = area
        self.allocated = allocated
        self.hasVMImage = hasVMImage
    }
}

public struct AppFootprint: Sendable, Hashable, Identifiable {
    public var id: String { app.id }
    public let app: InstalledApp
    public let bundleAllocated: Int64
    public let folders: [AppDataFolder]

    public init(app: InstalledApp, bundleAllocated: Int64, folders: [AppDataFolder]) {
        self.app = app
        self.bundleAllocated = bundleAllocated
        self.folders = folders
    }

    public var dataAllocated: Int64 { folders.reduce(0) { $0 + $1.allocated } }
    public var total: Int64 { bundleAllocated + dataAllocated }
    public var hasVMImage: Bool { folders.contains(where: \.hasVMImage) }
}

public struct AppDataMap: Sendable {
    public let footprints: [AppFootprint]
    public let unassigned: [AppDataFolder]
    public let unreadable: Int

    public init(footprints: [AppFootprint], unassigned: [AppDataFolder], unreadable: Int = 0) {
        self.footprints = footprints
        self.unassigned = unassigned
        self.unreadable = unreadable
    }
}

public enum AppDataMapper {
    static let vmExtensions: Set<String> = ["raw", "img", "qcow2", "vmdk", "vhdx", "asif", "sparseimage"]
    static let gib: Int64 = 1 << 30

    public struct TreeStats: Sendable {
        public var allocated: Int64 = 0
        public var hasVMImage = false
        public var unreadable = 0
    }

    /// Allocated size (hard links counted once) and whether a VM disk image is inside.
    /// Never descends into another device.
    public static func stats(_ root: URL) -> TreeStats {
        var s = TreeStats()
        var rootSt = stat()
        guard lstat(root.path, &rootSt) == 0 else {
            s.unreadable = 1
            return s
        }
        var seen = Set<UInt64>()
        func visit(_ dir: URL, inVMFolder: Bool) -> Int64 {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
                s.unreadable += 1
                return 0
            }
            var subtotal: Int64 = 0
            for name in names {
                let url = dir.appendingPathComponent(name)
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFDIR {
                    if st.st_dev != rootSt.st_dev { continue }
                    let lower = name.lowercased()
                    let isVMFolder = lower == "vm_bundles" || lower == "vm"
                    let size = visit(url, inVMFolder: inVMFolder || isVMFolder)
                    if isVMFolder && size >= gib { s.hasVMImage = true }
                    if lower.hasSuffix(".sparsebundle") && size >= gib { s.hasVMImage = true }
                    subtotal += size
                } else if kind == S_IFREG {
                    if st.st_nlink > 1 {
                        if seen.contains(UInt64(st.st_ino)) { continue }
                        seen.insert(UInt64(st.st_ino))
                    }
                    let allocated = Int64(st.st_blocks) * 512
                    subtotal += allocated
                    if vmExtensions.contains(url.pathExtension.lowercased()) && Int64(st.st_size) >= gib {
                        s.hasVMImage = true
                    }
                }
            }
            return subtotal
        }
        if (rootSt.st_mode & S_IFMT) == S_IFDIR {
            s.allocated = visit(root, inVMFolder: false)
        } else {
            s.allocated = Int64(rootSt.st_blocks) * 512
        }
        return s
    }

    static func matches(_ folder: String, area: LibraryArea, app: InstalledApp) -> Bool {
        let id = app.bundleID
        switch area {
        case .containers:
            return folder == id
        case .savedState:
            return folder.hasSuffix(".savedState") && String(folder.dropLast(".savedState".count)) == id
        case .groupContainers:
            return folder.hasSuffix(id) || folder.contains("." + id)
        default:
            let names = [id, app.name, app.executableName] + (AppDataHints.byBundleID[id] ?? [])
            return names.contains { $0.caseInsensitiveCompare(folder) == .orderedSame }
        }
    }

    /// Assigns every top-level folder of the `~/Library` areas to an app, or to `unassigned`.
    /// `overrides` maps a folder path to a bundle id chosen by the user.
    public static func map(home: URL, apps: [InstalledApp], overrides: [String: String],
                           extraHints: [String: [String]] = [:]) -> AppDataMap {
        let library = home.appendingPathComponent("Library")
        let ownData = library.appendingPathComponent("Application Support/SwitchKho")
        var byApp: [String: [AppDataFolder]] = [:]
        var unassigned: [AppDataFolder] = []
        var unreadable = 0

        for area in LibraryArea.allCases {
            let base = library.appendingPathComponent(area.rawValue)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
                unreadable += 1
                continue
            }
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = base.appendingPathComponent(name)
                if FileOps.same(url, ownData) || FileOps.isSymlink(url) { continue }
                let st = stats(url)
                unreadable += st.unreadable
                let folder = AppDataFolder(url: url, area: area, allocated: st.allocated, hasVMImage: st.hasVMImage)
                let owner: InstalledApp?
                if let forced = overrides[url.path] {
                    owner = apps.first { $0.bundleID == forced }
                } else {
                    owner = apps.first { app in
                        matches(name, area: area, app: app)
                            || (extraHints[app.bundleID] ?? []).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                    }
                }
                if let owner {
                    byApp[owner.bundleID, default: []].append(folder)
                } else {
                    unassigned.append(folder)
                }
            }
        }

        let footprints = apps.map { app in
            AppFootprint(app: app, bundleAllocated: stats(app.url).allocated,
                         folders: (byApp[app.bundleID] ?? []).sorted { $0.allocated > $1.allocated })
        }.sorted { $0.total > $1.total }
        return AppDataMap(footprints: footprints, unassigned: unassigned.sorted { $0.allocated > $1.allocated },
                          unreadable: unreadable)
    }
}
