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
                    guard let uuid = khoUUID(), let root = khoRoot() else { return }
                    // Re-read what is on disk now for every touched path, so the order of
                    // quick successive changes does not matter.
                    for rel in Set(added + removed) {
                        try store.remove(volumeUUID: uuid, relPathPrefix: rel)
                        let items = CatalogIndexer.scanSubtree(root: root.appendingPathComponent(rel), khoRoot: root)
                        if !items.isEmpty { try store.upsert(volumeUUID: uuid, items: items) }
                    }
                }
            }
        }
    }
}
