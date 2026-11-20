import Foundation

/// Keeps the catalog in step with what offloads add to or remove from the Kho.
public enum CatalogSync {
    public static func makeHook(
        store: CatalogStore, queue: JobQueue,
        khoUUID: @escaping @Sendable () -> String?, khoRoot: @escaping @Sendable () -> URL?
    ) -> @Sendable ([String], [String]) -> Void {
        { added, removed in
            guard !added.isEmpty || !removed.isEmpty else { return }
            Task {
                await queue.enqueue(title: "Cập nhật danh mục") { _ in
                    guard let uuid = khoUUID() else { return }
                    for rel in removed { try store.remove(volumeUUID: uuid, relPathPrefix: rel) }
                    if let root = khoRoot() {
                        for rel in added {
                            let items = CatalogIndexer.scanSubtree(root: root.appendingPathComponent(rel), khoRoot: root)
                            try store.upsert(volumeUUID: uuid, items: items)
                        }
                    }
                }
            }
        }
    }
}
