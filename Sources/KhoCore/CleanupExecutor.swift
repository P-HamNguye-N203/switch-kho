import Foundation

public struct CleanupOutcome: Sendable {
    public let freedBytes: Int64
    public let removed: [URL]
    public let failed: [(URL, String)]
    public let commandOutput: String?
}

/// Executes one cleanup candidate after re-checking app state and every path's policy.
public enum CleanupExecutor {
    public static func execute(
        _ c: CleanupCandidate, policy: PathPolicy, ledger: Ledger,
        isRunning: @Sendable (URL) -> Bool,
        trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        freeSpace: @Sendable () -> Int64 = { VolumeService.info(for: URL(fileURLWithPath: "/"))?.availableForImportant ?? 0 }
    ) async throws -> CleanupOutcome {
        try await checkRequirement(c.requirement, isRunning: isRunning)
        let before = freeSpace()
        var removed: [URL] = []
        var failed: [(URL, String)] = []
        var output: String?
        var reported: Int64?

        switch c.method {
        case .paths(let urls, let deletion):
            // Check every path first so a bad entry stops the whole group before anything is touched.
            for url in urls {
                try policy.check(url, purpose: purpose(for: url, policy: policy))
                // Permanent deletion has no holding area behind it, so the shape must also be a cache.
                if deletion == .permanent && !isPermanentlyDeletable(url, home: policy.home) {
                    throw KhoError.blocked(url.path)
                }
            }
            for url in urls {
                // App state can change while earlier items are deleted.
                try await checkRequirement(c.requirement, isRunning: isRunning)
                do {
                    switch deletion {
                    case .permanent: try FileOps.removeTree(url)
                    case .trash: try trash(url)
                    }
                    removed.append(url)
                } catch {
                    failed.append((url, error.localizedDescription))
                }
            }
        case .command(let exe, let args, _):
            let result = try await CommandRunner.run(exe, args, timeout: 600)
            output = result.output
            guard result.exitCode == 0 else {
                ledger.log(action: "cleanup", path: c.id, detail: "exit \(result.exitCode)", ok: false)
                throw KhoError.io("\(exe.lastPathComponent) thoát mã \(result.exitCode): \(result.output.suffix(400))")
            }
            if c.id == "docker-prune" { reported = reclaimedBytes(result.output) }
        }

        let freed = reported ?? max(0, freeSpace() - before)
        ledger.log(action: "cleanup", path: c.id,
                   detail: "\(ByteFormat.string(freed)); \(removed.count) mục; \(failed.count) lỗi", ok: failed.isEmpty)
        return CleanupOutcome(freedBytes: freed, removed: removed, failed: failed, commandOutput: output)
    }

    static func checkRequirement(_ r: AppStateRequirement, isRunning: (URL) -> Bool) async throws {
        switch r {
        case .commandSucceeds(let exe, let args, let hint):
            let result = try? await CommandRunner.run(exe, args, timeout: 20)
            if result?.exitCode != 0 { throw KhoError.io(hint) }
        case .none: break
        case .mustBeQuit(let app):
            if isRunning(app) { throw KhoError.appRunning(app.deletingPathExtension().lastPathComponent) }
        case .mustBeRunning(let app):
            if !isRunning(app) { throw KhoError.io("Hãy mở \(app.deletingPathExtension().lastPathComponent) trước") }
        }
    }

    /// Only cache-shaped locations may be deleted without a holding area: inside
    /// ~/Library/Caches, a package cache, Xcode DerivedData, ~/Library/pnpm/store, the Trash,
    /// or a cache folder (or something inside one) under ~/Library/Application Support.
    public static func isPermanentlyDeletable(_ url: URL, home: URL) -> Bool {
        let library = home.appendingPathComponent("Library")
        let parent = url.deletingLastPathComponent()
        func strictlyUnder(_ base: URL) -> Bool { FileOps.isUnder(url, base) && !FileOps.same(url, base) }
        if strictlyUnder(library.appendingPathComponent("Caches")) { return true }
        if strictlyUnder(library.appendingPathComponent("Developer/Xcode/DerivedData")) { return true }
        if strictlyUnder(library.appendingPathComponent("pnpm/store")) || FileOps.same(url, library.appendingPathComponent("pnpm/store")) {
            return true
        }
        if FileOps.same(parent, home.appendingPathComponent(".Trash")) { return true }
        if PathPolicy.packageCacheDirs.contains(where: { FileOps.same(parent, home.appendingPathComponent($0)) }) {
            return true
        }
        let support = library.appendingPathComponent("Application Support")
        if strictlyUnder(support) {
            // At least <App>/<cache>: never a top-level folder of Application Support.
            let depth = FileOps.components(url.path).count - FileOps.components(support.path).count
            guard depth >= 2 else { return false }
            let names = CleanupCatalog.cacheFolderNames
            return names.contains(url.lastPathComponent) || names.contains(parent.lastPathComponent)
        }
        return false
    }

    /// Purpose used for the policy check, chosen only from where the path is.
    static func purpose(for url: URL, policy: PathPolicy) -> PathPurpose {
        let home = policy.home
        let parent = url.deletingLastPathComponent()
        if FileOps.same(parent, home.appendingPathComponent(".Trash")) { return .trashContents }
        if FileOps.isUnder(url, home.appendingPathComponent("Library")) { return .appData }
        if PathPolicy.packageCacheDirs.contains(where: { FileOps.same(parent, home.appendingPathComponent($0)) }) {
            return .packageCache
        }
        return .personal
    }

    /// Parses Docker's "Total reclaimed space: 1.23GB" (decimal units).
    public static func reclaimedBytes(_ output: String) -> Int64? {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("Total reclaimed space") }),
              let value = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
        else { return nil }
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where value.hasSuffix(suffix) {
            guard let n = Double(value.dropLast(suffix.count)) else { return nil }
            return Int64(n * factor)
        }
        return nil
    }
}
