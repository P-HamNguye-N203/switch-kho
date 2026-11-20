import Darwin
import Foundation

public enum LiveStatus: Sendable, Equatable {
    case ok
    case khoMissing
    /// A real file or folder sits where our link should be (made while the Kho was away).
    case symlinkReplaced(URL)
    case symlinkMissing(URL)
    case targetMissing(URL)
}

public enum LiveIntegrity {
    /// One status per item, in the given order. `khoTarget` is the target through the Kho link.
    public static func check(items: [(original: URL, khoTarget: URL)], khoMounted: Bool) -> [LiveStatus] {
        items.map { item in
            // Same URL whether or not the ledger's path resolved as a folder.
            let original = URL(fileURLWithPath: item.original.path, isDirectory: false)
            if !FileOps.exists(original) { return .symlinkMissing(original) }
            if !FileOps.isSymlink(original) { return .symlinkReplaced(original) }
            if !khoMounted { return .khoMissing }
            // Follows the link: the target must exist on the mounted Kho.
            if !FileManager.default.fileExists(atPath: item.khoTarget.path) { return .targetMissing(item.khoTarget) }
            return .ok
        }
    }

    /// Items of live operations that still need guarding.
    public static func items(of op: Operation, ledger: Ledger, layout: KhoLayout) -> [(original: URL, khoTarget: URL)] {
        ((try? ledger.items(op.id)) ?? []).compactMap { item in
            guard item.role == .normal, !item.restored, !item.released, item.stage != .swapped,
                  let rel = item.khoRelPath,
                  let target = try? layout.symlinkTarget(relative: rel) else { return nil }
            return (item.originalURL, target)
        }
    }

    /// Our links are locked so apps cannot replace them; put the lock back if it was removed.
    public static func relockIfNeeded(_ original: URL) {
        guard FileOps.isSymlink(original) else { return }
        if FileOps.flags(original) & UInt32(UF_IMMUTABLE) == 0 {
            _ = lchflags(original.path, FileOps.flags(original) | UInt32(UF_IMMUTABLE))
        }
    }

    /// Worst status first, for a one-line summary per app.
    public static func summary(_ statuses: [LiveStatus]) -> LiveStatus {
        func rank(_ s: LiveStatus) -> Int {
            switch s {
            case .ok: 0
            case .khoMissing: 1
            case .symlinkMissing: 2
            case .symlinkReplaced: 3
            case .targetMissing: 4
            }
        }
        return statuses.max { rank($0) < rank($1) } ?? .ok
    }
}
