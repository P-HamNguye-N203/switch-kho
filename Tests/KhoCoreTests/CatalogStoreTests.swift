import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct CatalogStoreTests {
    func item(_ rel: String, dir: Bool = false) -> CatalogItem {
        CatalogItem(relPath: rel, name: (rel as NSString).lastPathComponent, size: dir ? 0 : 100,
                    isDirectory: dir, modified: Date())
    }

    @Test func searchIgnoresAccents() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let store = try CatalogStore(path: sb.root.appendingPathComponent("db/catalog.sqlite"))
        try store.replaceCatalog(volumeUUID: "K", volumeName: "Kho", items: [item("Docs/Hoá đơn T3-2024.pdf"), item("Docs/khac.txt")])
        #expect(try store.search("hoa don").map(\.item.name) == ["Hoá đơn T3-2024.pdf"])
        #expect(try store.search("hoá").map(\.item.name) == ["Hoá đơn T3-2024.pdf"])
        #expect(try store.search("pdf").count == 1)
        #expect(try store.search("   ").isEmpty)
        #expect(try store.search("\"").isEmpty)
    }

    @Test func removeTakesChildrenToo() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let store = try CatalogStore(path: sb.root.appendingPathComponent("db/catalog.sqlite"))
        try store.replaceCatalog(volumeUUID: "K", volumeName: "Kho", items: [
            item("A", dir: true), item("A/x.txt"), item("A/b", dir: true), item("A/b/y.txt"), item("AB/z.txt"), item("A_1.txt"),
        ])
        try store.remove(volumeUUID: "K", relPathPrefix: "A")
        #expect(try store.count(volumeUUID: "K") == 2)
        #expect(try store.search("y").isEmpty)
        #expect(try store.search("z").count == 1)
    }

    @Test func replaceTwiceDoesNotDuplicate() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let store = try CatalogStore(path: sb.root.appendingPathComponent("db/catalog.sqlite"))
        let items = (0..<12_000).map { item("f/\($0).bin") }
        try store.replaceCatalog(volumeUUID: "K", volumeName: "Kho", items: items)
        try store.replaceCatalog(volumeUUID: "K", volumeName: "Kho", items: items)
        #expect(try store.count(volumeUUID: "K") == 12_000)
        #expect(try store.search("11999").count == 1)
        #expect(try store.indexedVolume(uuid: "K")?.files == 12_000)
    }

    @Test func cancelledReplaceStillRestoresTriggers() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let store = try CatalogStore(path: sb.root.appendingPathComponent("db/catalog.sqlite"))
        let calls = Locked(0)
        #expect(throws: CancellationError.self) {
            try store.replaceCatalog(volumeUUID: "K", volumeName: "Kho", items: (0..<12_000).map { item("f/\($0).bin") },
                                     isCancelled: { calls.withLock { $0 += 1; return $0 > 1 } })
        }
        try store.upsert(volumeUUID: "K", items: [item("Sau/moi-them.txt")])
        #expect(try store.search("moi").count == 1)
    }

    @Test func catalogLivesApartFromTheLedger() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let ledger = try Ledger(path: sb.dbPath)
        let before = try ledger.db.scalarInt("PRAGMA user_version")
        let store = try CatalogStore(path: sb.root.appendingPathComponent("db/catalog.sqlite"))
        try store.replaceCatalog(volumeUUID: "K", volumeName: "Kho", items: [item("a.txt")])
        #expect(try ledger.db.scalarInt("PRAGMA user_version") == before)
        #expect(sb.dbPath != sb.root.appendingPathComponent("db/catalog.sqlite"))
    }
}

@Suite struct CatalogIndexerTests {
    @Test func scansEveryItemRelativeToTheKho() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let root = sb.root.appendingPathComponent("idx")
        // 3 folders × (1 subfolder + 8 files) + 3 folders = 30 items.
        for d in 0..<3 {
            for f in 0..<8 {
                try sb.makeFile(root.appendingPathComponent("d\(d)/s/f\(f).bin"), bytes: 10, seed: UInt8(f))
            }
        }
        try sb.makeFile(root.appendingPathComponent(".DS_Store"), bytes: 10, seed: 1)
        try sb.makeFile(root.appendingPathComponent("d0/.switchkho-partial-x/y"), bytes: 10, seed: 1)
        let items = try CatalogIndexer.scan(khoRoot: root)
        #expect(items.count == 30)
        #expect(items.contains { $0.relPath == "d1/s/f3.bin" && !$0.isDirectory && $0.size == 10 })
        #expect(items.contains { $0.relPath == "d2" && $0.isDirectory })
        #expect(!items.contains { $0.relPath.hasPrefix("/") || $0.name == ".DS_Store" || $0.relPath.contains("partial") })
        let sub = CatalogIndexer.scanSubtree(root: root.appendingPathComponent("d0"), khoRoot: root)
        #expect(sub.count == 10)
    }
}
