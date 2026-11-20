import Foundation
import Testing
@testable import KhoCore

extension TestSandbox {
    /// A non-runnable app bundle with an Info.plist, read through AppCatalog.
    func makeAppBundle(_ name: String, _ bundleID: String, electron: Bool = false) throws -> InstalledApp {
        let url = applications.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if electron {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                withIntermediateDirectories: true)
        }
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleExecutable": name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return try #require(AppCatalog.read(url))
    }

    func setModified(_ url: URL, daysAgo: Double, now: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)],
                                              ofItemAtPath: url.path)
    }
}

@Suite(.serialized) struct CleanupCatalogTests {
    static let modules = "node_modules"

    @Test func discoversOnlySafeGroups() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let now = Date()
        let alpha = try sb.makeAppBundle("Alpha", "test.alpha")
        let elec = try sb.makeAppBundle("Elec", "test.elec", electron: true)
        #expect(elec.isElectron)
        let caches = sb.home.appendingPathComponent("Library/Caches")
        for name in ["com.apple.x", "CloudKit", "test.alpha.ShipIt", "test.alpha", "Mystery"] {
            try sb.makeFile(caches.appendingPathComponent("\(name)/f"), bytes: 4096, seed: 1)
        }
        try sb.makeFile(sb.home.appendingPathComponent("Library/Application Support/Elec/Cache/f"), bytes: 4096, seed: 2)
        try sb.makeFile(sb.home.appendingPathComponent("Library/Application Support/Elec/Settings.json"), bytes: 10, seed: 3)

        let downloads = sb.home.appendingPathComponent("Downloads")
        try sb.makeFile(downloads.appendingPathComponent("old.dmg"), bytes: 100, seed: 4)
        try sb.makeFile(downloads.appendingPathComponent("new.dmg"), bytes: 100, seed: 5)
        try sb.setModified(downloads.appendingPathComponent("old.dmg"), daysAgo: 40, now: now)

        let docs = sb.home.appendingPathComponent("Documents")
        for p in ["p1", "p2"] {
            try sb.makeFile(docs.appendingPathComponent("\(p)/\(Self.modules)/m/index.js"), bytes: 10, seed: 6)
            try sb.makeFile(docs.appendingPathComponent("\(p)/package.json"), bytes: 10, seed: 7)
        }
        try sb.setModified(docs.appendingPathComponent("p1/package.json"), daysAgo: 90, now: now)

        let map = AppDataMapper.map(home: sb.home, apps: [alpha, elec], overrides: [:])
        // Test files all carry today's "date added", so usage comes from the modification date here.
        let found = CleanupCatalog.discover(
            home: sb.home, appDataMap: map, now: now, applicationsDir: sb.applications,
            usageDate: { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate },
            toolExists: { _ in false })
        let ids = Set(found.map(\.id))
        let allPaths = found.flatMap(\.paths).map(\.lastPathComponent)

        #expect(!allPaths.contains("com.apple.x"))
        #expect(!allPaths.contains("CloudKit"))
        #expect(!allPaths.contains("test.alpha.ShipIt"))

        let user = try #require(found.first { $0.id == "user-caches:test.alpha" })
        #expect(user.requirement == .mustBeQuit(appURL: alpha.url))
        #expect(user.paths.map(\.lastPathComponent) == ["test.alpha"])
        #expect(!user.manualOnly)

        let mystery = try #require(found.first { $0.id == "user-caches-unknown:Mystery" })
        #expect(mystery.manualOnly)
        #expect(mystery.requirement == .none)

        let electron = try #require(found.first { $0.id == "electron:test.elec" })
        #expect(electron.requirement == .mustBeQuit(appURL: elec.url))
        #expect(electron.paths.map(\.lastPathComponent) == ["f"])
        #expect(electron.paths.allSatisfy { $0.path.contains("/Cache/") })

        let installers = try #require(found.first { $0.id == "old-installers" })
        #expect(installers.paths.map(\.lastPathComponent) == ["old.dmg"])
        #expect(installers.method == .paths(installers.paths, .trash))

        let modules = try #require(found.first { $0.id == "node-modules" })
        #expect(modules.paths.map { $0.deletingLastPathComponent().lastPathComponent } == ["p1"])

        #expect(!ids.contains("docker-prune") && !ids.contains("homebrew"))
    }

    @Test func packageCachesListChildrenWhereTheFolderMustStay() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        try sb.makeFile(sb.home.appendingPathComponent(".Trash/old"), bytes: 4096, seed: 3)
        try sb.makeFile(sb.home.appendingPathComponent("Library/Caches/ms-playwright/c"), bytes: 4096, seed: 4)
        try sb.makeFile(sb.home.appendingPathComponent(".npm/_cacache/content-v2/x"), bytes: 4096, seed: 1)
        try sb.makeFile(sb.home.appendingPathComponent("Library/Caches/Yarn/y"), bytes: 4096, seed: 2)
        let found = CleanupCatalog.discover(home: sb.home, appDataMap: AppDataMap(footprints: [], unassigned: []),
                                            applicationsDir: sb.applications, toolExists: { _ in false })
        let npm = try #require(found.first { $0.id == "package-caches:npm" })
        #expect(npm.paths.map(\.lastPathComponent) == ["content-v2"])
        let yarn = try #require(found.first { $0.id == "package-caches:yarn" })
        #expect(yarn.paths.map(\.lastPathComponent) == ["Yarn"])
        #expect(try #require(found.first { $0.id == "trash" }).manualOnly)
        // ms-playwright is offered once, by its package recipe, not again as an unknown cache.
        #expect(found.filter { $0.paths.contains { $0.lastPathComponent == "ms-playwright" } }.map(\.id)
                == ["package-caches:ms-playwright"])
        // Every listed path passes the policy the executor will apply.
        for c in found {
            for url in c.paths {
                #expect(throws: Never.self) {
                    try sb.policy.check(url, purpose: CleanupExecutor.purpose(for: url, policy: sb.policy))
                }
                if case .paths(_, .permanent) = c.method {
                    #expect(CleanupExecutor.isPermanentlyDeletable(url, home: sb.home))
                }
            }
        }
    }

    @Test func emptyFoldersAreNotOffered() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        try FileManager.default.createDirectory(at: sb.home.appendingPathComponent("Library/Caches/Yarn/v6"),
                                                withIntermediateDirectories: true)
        let found = CleanupCatalog.discover(home: sb.home, appDataMap: AppDataMap(footprints: [], unassigned: []),
                                            applicationsDir: sb.applications, toolExists: { _ in false })
        #expect(!found.contains { $0.id == "package-caches:yarn" })
    }

    @Test func dockerCandidatesNeedDockerRunning() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let found = CleanupCatalog.discover(home: sb.home, appDataMap: AppDataMap(footprints: [], unassigned: []),
                                            applicationsDir: sb.applications,
                                            toolExists: { $0 == "/usr/local/bin/docker" })
        let prune = try #require(found.first { $0.id == "docker-prune" })
        #expect(prune.requirement == .commandSucceeds(executable: URL(fileURLWithPath: "/usr/local/bin/docker"),
                                                      args: ["info"], hint: "Hãy mở Docker (hoặc OrbStack, Colima) trước"))
        #expect(prune.warning?.contains("container đang dừng") == true)
        #expect(prune.manualOnly)
        #expect(found.contains { $0.id == "docker-builder" })
    }
}

/// Read-only discovery on the real home folder; deletes nothing. Run with SWITCHKHO_REAL_SCAN=1.
@Suite struct RealCleanupDiscoveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHKHO_REAL_SCAN"] == "1"))
    func findsTheExpectedGroupsOnThisMac() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let map = AppDataMapper.map(home: home, apps: AppCatalog.scan(), overrides: [:])
        let found = CleanupCatalog.discover(home: home, appDataMap: map)
        for c in found.sorted(by: { $0.estimatedBytes > $1.estimatedBytes }) {
            print("CLEANUP \(c.id)\t\(ByteFormat.string(c.estimatedBytes))\t\(c.paths.count) paths")
        }
        let total = found.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        print("CLEANUP TOTAL \(ByteFormat.string(total))")
        let ids = Set(found.map(\.id))
        #expect(ids.contains("package-caches:ms-playwright"))
        // Present exactly when the Yarn cache holds data (it was emptied on this Mac on 2026-11-20).
        let yarnBytes = DirectoryScanner.size(of: home.appendingPathComponent("Library/Caches/Yarn"))
        #expect(ids.contains("package-caches:yarn") == (yarnBytes > 0))
        #expect(ids.contains("chrome"))
        #expect(ids.contains("docker-prune"))
        #expect(total >= 5_000_000_000)
        // Nothing Apple-owned is ever offered.
        #expect(!found.flatMap(\.paths).contains { CleanupCatalog.isExcludedCacheName($0.lastPathComponent)
            && $0.deletingLastPathComponent().lastPathComponent == "Caches" })
    }
}

/// Read-only space budget on the real home folder; prints Markdown. Run with SWITCHKHO_REAL_SCAN=1.
@Suite struct RealSpaceBudgetTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHKHO_REAL_SCAN"] == "1"))
    func printsBudget() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let map = AppDataMapper.map(home: home, apps: AppCatalog.scan(), overrides: [:])
        let caches = map.unassigned.filter(\.area.isCache).reduce(Int64(0)) { $0 + $1.allocated }
        let pkg = PathPolicy.packageCacheDirs.reduce(Int64(0)) { $0 + DirectoryScanner.size(of: home.appendingPathComponent($1)) }
        let scan = try DirectoryScanner().scan(home, progress: { _ in }, isCancelled: { false })
        let stale = DirectoryScanner.staleFiles(in: scan, days: 180, minSize: 10 << 20).reduce(Int64(0)) { $0 + $1.size }
        let lines = SpaceBudget.estimate(map: map, caches: caches, personalStale: stale, packageCache: pkg)
        print("BUDGET-BEGIN")
        print(SpaceBudget.markdown(lines))
        print("BUDGET-END")
        for fp in map.footprints.sorted(by: { $0.total > $1.total }).prefix(15) {
            print("APP \(fp.app.name)\t\(ByteFormat.string(fp.total))\tvm=\(fp.hasVMImage)\tlast=\(fp.app.lastUsed.map { FileUsage.daysSince($0.date) ?? -1 } ?? -1)d")
        }
    }
}
