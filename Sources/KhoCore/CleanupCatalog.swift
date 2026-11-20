import Foundation

/// Discovers cleanable groups that actually exist on this Mac. Only uses folders the
/// app map already assigned to an app (allowlist); never guesses at Apple service caches.
public enum CleanupCatalog {
    public static let appleServiceCaches: Set<String> = [
        "CloudKit", "familycircled", "FamilyCircle", "GeoServices", "GameKit", "icloudmailagent",
        "askpermissiond", "Animoji", "EnergyKit",
    ]
    static let electronCacheDirs = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "Service Worker/CacheStorage",
    ]
    static let chromeProfileCacheDirs = ["Code Cache", "GPUCache", "Service Worker/CacheStorage"]
    /// Last path components that mark a regenerable cache folder inside Application Support.
    public static let cacheFolderNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "CacheStorage",
    ]
    /// ~/Library/Caches folders handled by the package-cache recipe.
    static let packageCacheNames: Set<String> = ["ms-playwright", "Yarn", "pip"]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "zip", "xip"]
    static let projectRoots = ["Documents", "Developer", "Projects", "Code"]

    /// Names in `~/Library/Caches` that must never be offered.
    public static func isExcludedCacheName(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || name.hasSuffix(".ShipIt") || name == "SwitchKho"
            || appleServiceCaches.contains(name)
    }

    public static func discover(
        home: URL, appDataMap: AppDataMap, now: Date = Date(),
        applicationsDir: URL = URL(fileURLWithPath: "/Applications"),
        usageDate: (URL) -> Date? = { FileUsage.effective($0)?.date },
        toolExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [CleanupCandidate] {
        var out: [CleanupCandidate] = []
        let fm = FileManager.default
        let library = home.appendingPathComponent("Library")
        let caches = library.appendingPathComponent("Caches")

        func existing(_ urls: [URL]) -> [URL] { urls.filter { FileOps.exists($0) } }
        func children(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent != ".DS_Store" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func size(_ urls: [URL]) -> Int64 { urls.reduce(0) { $0 + DirectoryScanner.size(of: $1) } }
        func app(_ bundleID: String) -> InstalledApp? {
            appDataMap.footprints.first { $0.app.bundleID == bundleID }?.app
        }
        func add(_ id: String, _ title: String, _ detail: String, _ urls: [URL], _ deletion: CleanupDeletion,
                 _ requirement: AppStateRequirement, warning: String? = nil, manualOnly: Bool = false) {
            guard !urls.isEmpty else { return }
            let bytes = size(urls)
            guard bytes > 0 else { return }
            out.append(CleanupCandidate(id: id, title: title, detail: detail, method: .paths(urls, deletion),
                                        requirement: requirement, estimatedBytes: bytes, warning: warning,
                                        manualOnly: manualOnly))
        }

        // 1. Xcode DerivedData.
        let derived = library.appendingPathComponent("Developer/Xcode/DerivedData")
        let xcode = applicationsDir.appendingPathComponent("Xcode.app")
        add("xcode-derived-data", "Xcode DerivedData", "Bản build trung gian, Xcode tạo lại khi cần",
            children(derived), .permanent, FileOps.exists(xcode) ? .mustBeQuit(appURL: xcode) : .none)

        // 2. ~/Library/Caches: only folders the map assigned to an app.
        for fp in appDataMap.footprints {
            let urls = fp.folders.filter {
                $0.area == .caches && FileOps.same($0.url.deletingLastPathComponent(), caches)
                    && !isExcludedCacheName($0.url.lastPathComponent)
            }.map(\.url)
            add("user-caches:\(fp.app.bundleID)", "Cache của \(fp.app.name)", "Trong ~/Library/Caches",
                existing(urls), .permanent, .mustBeQuit(appURL: fp.app.url))
        }
        for folder in appDataMap.unassigned where folder.area == .caches
            && FileOps.same(folder.url.deletingLastPathComponent(), caches)
            && !isExcludedCacheName(folder.url.lastPathComponent)
            && !packageCacheNames.contains(folder.url.lastPathComponent) {
            let name = folder.url.lastPathComponent
            add("user-caches-unknown:\(name)", "Cache không rõ app: \(name)", "Trong ~/Library/Caches",
                existing([folder.url]), .permanent, .none,
                warning: "Không rõ app nào dùng thư mục này", manualOnly: true)
        }

        // 3. Electron apps.
        for fp in appDataMap.footprints where fp.app.isElectron {
            let dataDirs = fp.folders.filter { $0.area == .applicationSupport }.map(\.url)
            let urls = dataDirs.flatMap { dir in electronCacheDirs.map { dir.appendingPathComponent($0) } }
            add("electron:\(fp.app.bundleID)", "Cache Electron của \(fp.app.name)", "Cache, Code Cache, GPUCache…",
                existing(urls).flatMap(children), .permanent, .mustBeQuit(appURL: fp.app.url))
        }

        // 4. Chrome.
        let chromeData = library.appendingPathComponent("Application Support/Google/Chrome")
        var chromeURLs: [URL] = []
        for profile in children(chromeData) where FileOps.isDirectory(profile) {
            chromeURLs += existing(chromeProfileCacheDirs.map { profile.appendingPathComponent($0) })
        }
        chromeURLs += existing([caches.appendingPathComponent("Google/Chrome")])
        let chromeApp = app("com.google.Chrome")?.url ?? applicationsDir.appendingPathComponent("Google Chrome.app")
        add("chrome", "Cache Google Chrome", "Code Cache, GPUCache, Service Worker của mọi hồ sơ",
            chromeURLs, .permanent, .mustBeQuit(appURL: chromeApp))

        // 5. Package manager caches. Folders like ~/.npm/_cacache are emptied, not removed.
        let packageDirs: [(String, URL, Bool, String?)] = [
            ("ms-playwright", caches.appendingPathComponent("ms-playwright"), false,
             "Playwright sẽ tải lại trình duyệt khi cần"),
            ("yarn", caches.appendingPathComponent("Yarn"), false, nil),
            ("npm", home.appendingPathComponent(".npm/_cacache"), true, nil),
            ("pnpm", library.appendingPathComponent("pnpm/store"), false, nil),
            ("pip-library", caches.appendingPathComponent("pip"), false, nil),
            ("huggingface", home.appendingPathComponent(".cache/huggingface"), true,
             "Mô hình Hugging Face sẽ phải tải lại"),
            ("pip", home.appendingPathComponent(".cache/pip"), true, nil),
            ("uv", home.appendingPathComponent(".cache/uv"), true, nil),
            ("pnpm-cache", home.appendingPathComponent(".cache/pnpm"), true, nil),
        ]
        for (key, dir, emptyOnly, warning) in packageDirs where FileOps.exists(dir) {
            add("package-caches:\(key)", "Cache gói: \(dir.lastPathComponent)",
                dir.path.replacingOccurrences(of: home.path, with: "~"),
                emptyOnly ? children(dir) : [dir], .permanent, .none, warning: warning)
        }

        // 6. Homebrew.
        let brew = "/opt/homebrew/bin/brew"
        if toolExists(brew) {
            out.append(CleanupCandidate(
                id: "homebrew", title: "Homebrew cleanup", detail: "Bản tải về và phiên bản cũ của Homebrew",
                method: .command(executable: URL(fileURLWithPath: brew), args: ["cleanup", "--prune=all", "-s"],
                                 previewArgs: ["cleanup", "--prune=all", "-s", "-n"]),
                requirement: .none, estimatedBytes: 0))
        }

        // 7. Docker.
        if let docker = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"].first(where: toolExists) {
            let exe = URL(fileURLWithPath: docker)
            let daemon = AppStateRequirement.commandSucceeds(executable: exe, args: ["info"],
                                                             hint: "Hãy mở Docker (hoặc OrbStack, Colima) trước")
            out.append(CleanupCandidate(
                id: "docker-prune", title: "Docker system prune",
                detail: "Container đã dừng, mạng không dùng, image treo, build cache",
                method: .command(executable: exe, args: ["system", "prune", "-f"],
                                 previewArgs: ["ps", "-a", "--filter", "status=exited", "--format",
                                               "{{.Names}}\t{{.Image}}\t{{.Status}}"]),
                requirement: daemon, estimatedBytes: 0,
                warning: "Xoá mọi container đang dừng tại lúc chạy lệnh, cùng dữ liệu bên trong chúng. Volume có tên được giữ lại.",
                manualOnly: true))
            out.append(CleanupCandidate(
                id: "docker-builder", title: "Docker build cache", detail: "docker builder prune",
                method: .command(executable: exe, args: ["builder", "prune", "-f"], previewArgs: ["builder", "du"]),
                requirement: daemon, estimatedBytes: 0))
        }

        // 8. Old installers in Downloads.
        let downloads = home.appendingPathComponent("Downloads")
        let oldInstallers = children(downloads).filter { url in
            guard installerExtensions.contains(url.pathExtension.lowercased()),
                  let used = usageDate(url) else { return false }
            return now.timeIntervalSince(used) > 30 * 86_400
        }
        add("old-installers", "File cài đặt cũ", "dmg, pkg, zip, xip trong Tải về, không dùng hơn 30 ngày",
            oldInstallers, .trash, .none)

        // 9. node_modules of projects untouched for 60 days.
        var modules: [URL] = []
        for root in projectRoots.map({ home.appendingPathComponent($0) }) where FileOps.exists(root) {
            findNodeModules(root, depth: 0, now: now, into: &modules)
        }
        add("node-modules", "node_modules của dự án cũ", "Dự án không sửa hơn 60 ngày; chạy lại npm install khi cần",
            modules, .trash, .none)

        // 10. Trash.
        add("trash", "Thùng rác", "Các mục trong ~/.Trash", children(home.appendingPathComponent(".Trash")),
            .permanent, .none, warning: "Xoá vĩnh viễn", manualOnly: true)

        return out
    }

    /// Depth-limited search that never descends into a `node_modules`, a symlink or another device.
    static func findNodeModules(_ dir: URL, depth: Int, now: Date, into out: inout [URL]) {
        guard depth <= 6 else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])) ?? []
        if let modules = entries.first(where: { $0.lastPathComponent == "node_modules" }), FileOps.isDirectory(modules) {
            let newest = entries.filter { $0.lastPathComponent != "node_modules" }
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max() ?? .distantPast
            if now.timeIntervalSince(newest) > 60 * 86_400 { out.append(modules) }
        }
        for entry in entries where entry.lastPathComponent != "node_modules" && !entry.lastPathComponent.hasPrefix(".") {
            let v = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard v?.isDirectory == true, v?.isSymbolicLink != true, FileOps.sameDevice(entry, dir) else { continue }
            findNodeModules(entry, depth: depth + 1, now: now, into: &out)
        }
    }
}
