import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct CleanupExecutorTests {
    func ledger(_ sb: TestSandbox) throws -> Ledger { try Ledger(path: sb.dbPath) }

    func candidate(_ urls: [URL], _ deletion: CleanupDeletion = .permanent,
                   _ requirement: AppStateRequirement = .none) -> CleanupCandidate {
        CleanupCandidate(id: "t", title: "t", detail: "", method: .paths(urls, deletion),
                         requirement: requirement, estimatedBytes: 0)
    }

    @Test func permanentlyRemovesFolders() async throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let a = sb.home.appendingPathComponent("Library/Caches/a"), b = sb.home.appendingPathComponent("Library/Caches/b")
        try sb.makeFile(a.appendingPathComponent("f"), bytes: 4096, seed: 1)
        try sb.makeFile(b.appendingPathComponent("f"), bytes: 4096, seed: 2)
        let out = try await CleanupExecutor.execute(candidate([a, b]), policy: sb.policy, ledger: try ledger(sb),
                                                    isRunning: { _ in false }, freeSpace: { 0 })
        #expect(!FileOps.exists(a) && !FileOps.exists(b))
        #expect(out.removed.count == 2 && out.failed.isEmpty)
    }

    @Test func movesToTrashThroughClosure() async throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let file = sb.home.appendingPathComponent("Downloads/old.dmg")
        try sb.makeFile(file, bytes: 100, seed: 1)
        try sb.makeFile(sb.home.appendingPathComponent("Downloads/new.dmg"), bytes: 8192, seed: 2)
        let trashDir = sb.root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        _ = try await CleanupExecutor.execute(
            candidate([file], .trash), policy: sb.policy, ledger: try ledger(sb), isRunning: { _ in false },
            trash: { try FileManager.default.moveItem(at: $0, to: trashDir.appendingPathComponent($0.lastPathComponent)) },
            freeSpace: { 0 })
        #expect(FileOps.exists(trashDir.appendingPathComponent("old.dmg")))
        let out = try await CleanupExecutor.execute(
            candidate([sb.home.appendingPathComponent("Downloads/new.dmg")], .trash), policy: sb.policy,
            ledger: try ledger(sb), isRunning: { _ in false }, trash: { try FileOps.removeTree($0) }, freeSpace: { 0 })
        // Moving to Trash frees nothing yet, but the report says how much was taken away.
        #expect(out.freedBytes > 0)
        #expect(!FileOps.exists(file))
    }

    @Test func refusesWhileAppRuns() async throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let app = try sb.makeRunnableFakeApp(name: "Runner", bundleID: "test.runner")
        let target = sb.home.appendingPathComponent("Library/Caches/test.runner")
        try sb.makeFile(target.appendingPathComponent("f"), bytes: 10, seed: 1)
        let p = try sb.launch(app.appendingPathComponent("Contents/MacOS/Runner"))
        defer { sb.stop(p) }
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: KhoError.appRunning("Runner")) {
            _ = try await CleanupExecutor.execute(self.candidate([target], .permanent, .mustBeQuit(appURL: app)),
                                                  policy: sb.policy, ledger: try self.ledger(sb),
                                                  isRunning: { RunningProcesses.isRunning(appURL: $0) }, freeSpace: { 0 })
        }
        #expect(FileOps.exists(target))
    }

    @Test func mustBeRunningRefusesWhenQuit() async throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let c = CleanupCandidate(id: "docker-prune", title: "", detail: "",
                                 method: .command(executable: URL(fileURLWithPath: "/bin/echo"), args: [], previewArgs: nil),
                                 requirement: .mustBeRunning(appURL: URL(fileURLWithPath: "/Applications/Docker.app")),
                                 estimatedBytes: 0)
        await #expect(throws: KhoError.io("Hãy mở Docker trước")) {
            _ = try await CleanupExecutor.execute(c, policy: sb.policy, ledger: try self.ledger(sb),
                                                  isRunning: { _ in false }, freeSpace: { 0 })
        }
    }

    @Test func commandRequirementMustSucceed() async throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let c = CleanupCandidate(id: "docker-builder", title: "", detail: "",
                                 method: .command(executable: URL(fileURLWithPath: "/bin/echo"), args: ["ok"], previewArgs: nil),
                                 requirement: .commandSucceeds(executable: URL(fileURLWithPath: "/usr/bin/false"),
                                                               args: [], hint: "Hãy mở Docker trước"),
                                 estimatedBytes: 0)
        await #expect(throws: KhoError.io("Hãy mở Docker trước")) {
            _ = try await CleanupExecutor.execute(c, policy: sb.policy, ledger: try self.ledger(sb),
                                                  isRunning: { _ in false }, freeSpace: { 0 })
        }
        let ok = CleanupCandidate(id: "x", title: "", detail: "", method: c.method,
                                  requirement: .commandSucceeds(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                                                args: [], hint: ""), estimatedBytes: 0)
        let out = try await CleanupExecutor.execute(ok, policy: sb.policy, ledger: try ledger(sb),
                                                    isRunning: { _ in false }, freeSpace: { 0 })
        #expect(out.commandOutput?.contains("ok") == true)
    }

    @Test func permanentDeleteOnlyForCacheShapedPaths() async throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let support = sb.home.appendingPathComponent("Library/Application Support")
        let appData = support.appendingPathComponent("Google")
        try sb.makeFile(appData.appendingPathComponent("Chrome/Default/Bookmarks"), bytes: 10, seed: 1)
        // Allowed by PathPolicy as app data, but not a cache: permanent delete must refuse.
        #expect(throws: Never.self) { try sb.policy.check(appData, purpose: .appData) }
        await #expect(throws: KhoError.blocked(appData.path)) {
            _ = try await CleanupExecutor.execute(self.candidate([appData]), policy: sb.policy,
                                                  ledger: try self.ledger(sb), isRunning: { _ in false }, freeSpace: { 0 })
        }
        #expect(FileOps.exists(appData))
        let topLevelCache = support.appendingPathComponent("Cache")
        #expect(!CleanupExecutor.isPermanentlyDeletable(topLevelCache, home: sb.home))
        #expect(CleanupExecutor.isPermanentlyDeletable(support.appendingPathComponent("Elec/Cache"), home: sb.home))
        #expect(CleanupExecutor.isPermanentlyDeletable(support.appendingPathComponent("Elec/Cache/f"), home: sb.home))
        #expect(!CleanupExecutor.isPermanentlyDeletable(sb.home.appendingPathComponent("Documents/x"), home: sb.home))
        #expect(!CleanupExecutor.isPermanentlyDeletable(sb.home.appendingPathComponent("Library/Caches"), home: sb.home))
    }

    @Test func trashContentsAndPackageCacheRules() async throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let l = try ledger(sb)
        let trashItem = sb.home.appendingPathComponent(".Trash/x")
        try sb.makeFile(trashItem, bytes: 10, seed: 1)
        _ = try await CleanupExecutor.execute(candidate([trashItem]), policy: sb.policy, ledger: l,
                                              isRunning: { _ in false }, freeSpace: { 0 })
        #expect(!FileOps.exists(trashItem))
        let trash = sb.home.appendingPathComponent(".Trash")
        await #expect(throws: KhoError.blocked(trash.path)) {
            _ = try await CleanupExecutor.execute(self.candidate([trash]),
                                                  policy: sb.policy, ledger: l, isRunning: { _ in false }, freeSpace: { 0 })
        }
        #expect(FileOps.exists(trash))

        let content = sb.home.appendingPathComponent(".npm/_cacache/content-v2")
        try sb.makeFile(content.appendingPathComponent("y"), bytes: 10, seed: 2)
        _ = try await CleanupExecutor.execute(candidate([content]), policy: sb.policy, ledger: l,
                                              isRunning: { _ in false }, freeSpace: { 0 })
        #expect(!FileOps.exists(content))
        let cacache = sb.home.appendingPathComponent(".npm/_cacache")
        await #expect(throws: KhoError.blocked(cacache.path)) {
            _ = try await CleanupExecutor.execute(self.candidate([cacache]), policy: sb.policy, ledger: l,
                                                  isRunning: { _ in false }, freeSpace: { 0 })
        }
        #expect(FileOps.exists(cacache))
    }

    @Test func blockedPathStopsTheWholeGroup() async throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let ok = sb.home.appendingPathComponent("Library/Caches/ok")
        try sb.makeFile(ok.appendingPathComponent("f"), bytes: 10, seed: 1)
        let library = sb.home.appendingPathComponent("Library")
        await #expect(throws: KhoError.blocked(library.path)) {
            _ = try await CleanupExecutor.execute(self.candidate([ok, library]), policy: sb.policy,
                                                  ledger: try self.ledger(sb), isRunning: { _ in false }, freeSpace: { 0 })
        }
        #expect(FileOps.exists(ok))
        #expect(FileOps.exists(library))
    }

    @Test func parsesDockerReclaimedSpace() {
        #expect(CleanupExecutor.reclaimedBytes("Deleted...\nTotal reclaimed space: 1.5GB\n") == 1_500_000_000)
        #expect(CleanupExecutor.reclaimedBytes("Total reclaimed space: 0B") == 0)
        #expect(CleanupExecutor.reclaimedBytes("Total reclaimed space: 12.3kB") == 12_300)
        #expect(CleanupExecutor.reclaimedBytes("nothing") == nil)
    }
}
