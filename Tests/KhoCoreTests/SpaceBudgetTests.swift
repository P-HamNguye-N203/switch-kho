import Foundation
import Testing
@testable import KhoCore

@Suite struct SpaceBudgetTests {
    func app(_ id: String, root: Bool = false) -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/\(id).app"), bundleID: id, name: id,
                     executableName: id, ownerIsRoot: root)
    }

    @Test func routesRespectVMImagesAndRootOwnership() {
        let gb: Int64 = 1 << 30
        let support = URL(fileURLWithPath: "/Users/u/Library/Application Support")
        let map = AppDataMap(footprints: [
            AppFootprint(app: app("vm"), bundleAllocated: gb, folders: [
                AppDataFolder(url: support.appendingPathComponent("vm"), area: .applicationSupport,
                              allocated: 10 * gb, hasVMImage: true)]),
            AppFootprint(app: app("rooted", root: true), bundleAllocated: gb, folders: [
                AppDataFolder(url: support.appendingPathComponent("rooted"), area: .applicationSupport,
                              allocated: 2 * gb, hasVMImage: false)]),
        ], unassigned: [])
        let lines = SpaceBudget.estimate(map: map, caches: gb, personalStale: gb)
        #expect(!lines.contains { $0.source == "vm" && $0.route == SpaceBudget.runFromKho })
        #expect(!lines.contains { $0.source == "rooted" && $0.route == SpaceBudget.coldArchive })
        #expect(lines.contains { $0.source == "rooted" && $0.route == SpaceBudget.runFromKho })
        #expect(SpaceBudget.markdown(lines).contains("| vm |"))
    }
}
