import CryptoKit
import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct AppArchiverTests {
    struct Setup {
        let fx: ServiceFixture
        let app: URL
        let container: URL
        let support: URL
        var exe: URL { app.appendingPathComponent("Contents/MacOS/Fake") }

        func footprint() throws -> AppFootprint {
            let installed = try #require(AppCatalog.read(app))
            let map = AppDataMapper.map(home: fx.sb.home, apps: [installed], overrides: [:])
            return try #require(map.footprints.first)
        }

        func archive(otherApps: [InstalledApp] = []) async throws -> Int64 {
            try await AppArchiver.archive(try footprint(), service: fx.service, ledger: fx.ledger, layout: fx.sb.layout,
                                          home: fx.sb.home, otherApps: otherApps,
                                          isRunning: { RunningProcesses.isRunning(appURL: $0.url) })
        }
    }

    func setUp() throws -> Setup {
        let fx = try ServiceFixture()
        let app = try fx.sb.makeRunnableFakeApp(name: "Fake", bundleID: "test.fake")
        let lib = fx.sb.home.appendingPathComponent("Library")
        let container = lib.appendingPathComponent("Containers/test.fake")
        let support = lib.appendingPathComponent("Application Support/Fake")
        try fx.sb.makeFile(container.appendingPathComponent("Data/x.bin"), bytes: 1 << 20, seed: 7)
        try fx.sb.makeFile(support.appendingPathComponent("db.sqlite"), bytes: 64 << 10, seed: 8)
        return Setup(fx: fx, app: app, container: container, support: support)
    }

    func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func archiveMovesBundleAndDataToKho() async throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let opID = try await s.archive()
        for url in [s.app, s.container, s.support] { #expect(!FileOps.exists(url)) }
        let items = try s.fx.ledger.items(opID)
        #expect(items.count == 3)
        #expect(items[0].khoRelPath == "SwitchKho/Apps/test.fake/bundle/Fake.app")
        #expect(items.contains { $0.khoRelPath == "SwitchKho/Apps/test.fake/data/Library/Containers/test.fake" })
        for item in items {
            #expect(FileOps.exists(try s.fx.sb.layout.absoluteURL(relative: try #require(item.khoRelPath))))
            #expect(FileOps.exists(URL(fileURLWithPath: try #require(item.holdingPath))))
        }
        #expect(try s.fx.ledger.operation(opID)?.state == .holding)
    }

    @Test func undoPutsEverythingBack() async throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let x = try sha(s.container.appendingPathComponent("Data/x.bin"))
        let opID = try await s.archive()
        _ = try await AppArchiver.restore(opID: opID, service: s.fx.service, ledger: s.fx.ledger)
        for url in [s.app, s.container, s.support] { #expect(FileOps.exists(url)) }
        #expect(try sha(s.container.appendingPathComponent("Data/x.bin")) == x)
        #expect(try s.fx.ledger.operation(opID)?.state == .undone)
    }

    @Test func commitThenRestoreFromKho() async throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let x = try sha(s.container.appendingPathComponent("Data/x.bin"))
        let opID = try await s.archive()
        s.fx.advance(days: 8)
        #expect(s.fx.service.commitDue() == [opID])
        let result = try await AppArchiver.restore(opID: opID, service: s.fx.service, ledger: s.fx.ledger)
        #expect(!result.signatureBroken)
        for url in [s.app, s.container, s.support] { #expect(FileOps.exists(url)) }
        #expect(try sha(s.container.appendingPathComponent("Data/x.bin")) == x)
        #expect(FileManager.default.isExecutableFile(atPath: s.exe.path))
        #expect(try s.fx.ledger.operation(opID)?.state == .restored)
    }

    @Test func runningAppIsBlockedWithoutOperation() async throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let p = try s.fx.sb.launch(s.exe)
        defer { s.fx.sb.stop(p) }
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: KhoError.self) { _ = try await s.archive() }
        #expect(try s.fx.ledger.operationCount() == 0)
        #expect(FileOps.exists(s.app))
    }

    @Test func appOpenedDuringCopyFailsAndKeepsOriginals() async throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let launched = Locked<Process?>(nil)
        let exe = s.exe, sb = s.fx.sb
        s.fx.afterCopy.withLock { $0 = { _ in
            launched.withLock { p in if p == nil { p = try? sb.launch(exe) } }
        } }
        defer { sb.stop(launched.withLock { $0 }) }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: KhoError.appRunning("Fake")) { _ = try await s.archive() }
        let op = try #require(try s.fx.ledger.operations().first)
        #expect(op.state == .failed)
        for url in [s.app, s.container, s.support] { #expect(FileOps.exists(url)) }
    }

    @Test func dataOwnedByAnotherOperationIsBlocked() async throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let fp = try s.footprint()
        let other = try s.fx.offload([s.fx.request(s.support, purpose: .appData)])
        let e = AppArchiver.eligibility(for: fp, isRunning: false, ledger: s.fx.ledger, home: s.fx.sb.home)
        #expect(e.blockers.contains("Dữ liệu đang thuộc thao tác #\(other) (ví dụ đang chạy từ Kho)"))
        await #expect(throws: KhoError.self) {
            _ = try await AppArchiver.archive(fp, service: s.fx.service, ledger: s.fx.ledger, layout: s.fx.sb.layout,
                                              home: s.fx.sb.home, isRunning: { _ in false })
        }
    }

    @Test func appStoreAppIsBlocked() async throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        try s.fx.sb.makeFile(s.app.appendingPathComponent("Contents/_MASReceipt/receipt"), bytes: 10, seed: 1)
        let e = AppArchiver.eligibility(for: try s.footprint(), isRunning: false, ledger: s.fx.ledger, home: s.fx.sb.home)
        #expect(e.blockers.contains("Ứng dụng từ App Store — cập nhật sẽ hỏng"))
        await #expect(throws: KhoError.self) { _ = try await s.archive() }
        #expect(try s.fx.ledger.operationCount() == 0)
    }

    @Test func holdFailureAfterBundleMovedRollsEverythingBack() async throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        s.fx.failHoldFor.withLock { $0 = "Fake" }   // Application Support/Fake, after Fake.app moved
        await #expect(throws: KhoError.self) { _ = try await s.archive() }
        for url in [s.app, s.container, s.support] { #expect(FileOps.exists(url)) }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: s.fx.sb.applications.path)
        #expect(siblings == ["Fake.app"])
        let op = try #require(try s.fx.ledger.operations().first)
        #expect(op.state == .failed)
        let apps = s.fx.sb.layout.apps
        let left = (try? FileManager.default.subpathsOfDirectory(atPath: apps.path))?.filter { !$0.isEmpty } ?? []
        #expect(left.isEmpty, "\(left)")
    }

    @Test func lockedBundleIsRefused() async throws {
        let s = try setUp()
        defer {
            chflags(s.app.path, 0)
            s.fx.cleanup()
        }
        #expect(chflags(s.app.path, UInt32(UF_IMMUTABLE)) == 0)
        await #expect(throws: KhoError.notDeletable("Mục đang bị khoá (Locked)")) { _ = try await s.archive() }
        #expect(try s.fx.ledger.operationCount() == 0)
    }

    @Test func undoWhileRunningIsRefused() async throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let opID = try await s.archive()
        s.fx.running.withLock { $0 = true }
        await #expect(throws: KhoError.appRunning("Fake")) {
            _ = try await AppArchiver.restore(opID: opID, service: s.fx.service, ledger: s.fx.ledger)
        }
        #expect(!FileOps.exists(s.app))
        #expect(try s.fx.ledger.operation(opID)?.state == .holding)
    }

    @Test func appManagementRefusalExplainsThePermission() async throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        s.fx.holdError.withLock { $0 = .notPermitted(s.app.path) }
        s.fx.failHoldFor.withLock { $0 = "Fake.app" }
        await #expect(throws: KhoError.io(AppArchiver.appManagementHint)) { _ = try await s.archive() }
        #expect(FileOps.exists(s.app))
        #expect(try s.fx.ledger.operations().first?.state == .failed)
    }

    @Test func restoreRefusesWhenTheAppWasReinstalled() async throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let opID = try await s.archive()
        s.fx.advance(days: 8)
        #expect(s.fx.service.commitDue() == [opID])
        // The user installed the app again meanwhile.
        let reinstalled = try s.fx.sb.makeRunnableFakeApp(name: "Fake", bundleID: "test.fake")
        await #expect(throws: KhoError.self) {
            _ = try await AppArchiver.restore(opID: opID, service: s.fx.service, ledger: s.fx.ledger)
        }
        #expect(try s.fx.ledger.operation(opID)?.state == .committed)
        #expect(FileOps.exists(reinstalled))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: s.fx.sb.applications.path)
        #expect(siblings == ["Fake.app"])
    }

    @Test func warnsAboutContainersAndLaunchAgents() throws {
        let s = try setUp()
        defer { s.fx.cleanup() }
        let agent: [String: Any] = ["Label": "test.fake.helper",
                                    "ProgramArguments": [s.exe.path, "--background"]]
        let agents = s.fx.sb.home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("test.fake.helper.plist"))
        let e = AppArchiver.eligibility(for: try s.footprint(), isRunning: false, ledger: s.fx.ledger, home: s.fx.sb.home)
        #expect(e.allowed)
        #expect(e.warnings.contains { $0.contains("Containers") })
        #expect(e.warnings.contains { $0.hasPrefix("test.fake.helper.plist") })
    }

    @Test func sharedGroupContainerIsBlocked() throws {
        let owner = InstalledApp(url: URL(fileURLWithPath: "/Applications/Word.app"), bundleID: "com.microsoft.Word",
                                 name: "Word", executableName: "Word")
        let excel = InstalledApp(url: URL(fileURLWithPath: "/Applications/Excel.app"), bundleID: "com.microsoft.Excel",
                                 name: "Excel", executableName: "Excel")
        #expect(AppArchiver.sharedGroupContainer("UBF8T346G9.com.microsoft", owner: owner, others: [owner, excel])?.name == "Excel")
        #expect(AppArchiver.sharedGroupContainer("UBF8T346G9.com.microsoft.Word", owner: owner, others: [owner, excel]) == nil)
    }
}

/// Archive, commit and restore a fake app on the real Kho, writing only below
/// /Volumes/Kho/SwitchKho/_selftest-<UUID> (removed afterwards). Run with SWITCHKHO_REAL_KHO=1.
@Suite(.serialized) struct RealKhoAppArchiverTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHKHO_REAL_KHO"] == "1"))
    func realKhoRoundTrip() async throws {
        let base = URL(fileURLWithPath: "/Volumes/Kho/SwitchKho")
        try #require(FileOps.exists(URL(fileURLWithPath: "/Volumes/Kho")), "Hãy cắm Kho")
        let createdBase = !FileOps.exists(base)
        if createdBase { try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false) }
        let root = base.appendingPathComponent("_selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let sb = try TestSandbox()
        defer {
            try? FileOps.removeTree(root)
            if createdBase { _ = rmdir(base.path) }
            sb.cleanup()
        }
        let layout = KhoLayout(khoRoot: root, linkRoot: sb.khoLink)
        try FileManager.default.createDirectory(at: layout.base, withIntermediateDirectories: true)
        try Data().write(to: layout.identityFile)
        let ledger = try Ledger(path: sb.dbPath)
        let clock = Locked(Date())
        let service = OffloadService(
            ledger: ledger, holding: HoldingArea(root: sb.holding), policy: sb.policy, copier: VerifiedCopier(), linkRoot: sb.khoLink,
            mountedKho: { MountedKho(uuid: "selftest", layout: layout) },
            holdDays: { 7 }, now: { clock.withLock { $0 } }, appRunning: { _ in false })

        let app = try sb.makeRunnableFakeApp(name: "Fake", bundleID: "test.fake")
        let container = sb.home.appendingPathComponent("Library/Containers/test.fake")
        try sb.makeFile(container.appendingPathComponent("Data/x.bin"), bytes: 8 << 20, seed: 3)
        let before = try Data(contentsOf: container.appendingPathComponent("Data/x.bin"))
        let installed = try #require(AppCatalog.read(app))
        let fp = try #require(AppDataMapper.map(home: sb.home, apps: [installed], overrides: [:]).footprints.first)

        let opID = try await AppArchiver.archive(fp, service: service, ledger: ledger, layout: layout, home: sb.home,
                                                 isRunning: { _ in false })
        #expect(!FileOps.exists(app))
        clock.withLock { $0 = $0.addingTimeInterval(8 * 86_400) }
        #expect(service.commitDue() == [opID])
        _ = try await AppArchiver.restore(opID: opID, service: service, ledger: ledger)
        #expect(FileOps.exists(app.appendingPathComponent("Contents/MacOS/Fake")))
        #expect(try Data(contentsOf: container.appendingPathComponent("Data/x.bin")) == before)
        #expect(try ledger.operation(opID)?.state == .restored)
    }
}
