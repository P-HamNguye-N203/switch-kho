import Darwin
import Foundation

public struct RuleCandidate: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let allocated: Int64
    public let usage: UsageDate
    public let isDirectory: Bool
}

public enum RuleEngine {
    static let maxEntries = 50_000

    /// First-level items of the rule's folder that are unused long enough, big enough and of
    /// a matching type, oldest first.
    public static func candidates(
        for rule: OffloadRule, ledger: Ledger, policy: PathPolicy, now: Date = Date(),
        usageDate: (URL) -> UsageDate? = FileUsage.effective
    ) -> [RuleCandidate] {
        let folder = URL(fileURLWithPath: rule.folderPath)
        var folderSt = stat()
        guard lstat(folder.path, &folderSt) == 0 else { return [] }
        let exts = Set(rule.extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .filter { !$0.isEmpty })
        var out: [RuleCandidate] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            let kind = st.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR, st.st_dev == folderSt.st_dev else { continue }
            if !exts.isEmpty && (kind == S_IFDIR || !exts.contains(url.pathExtension.lowercased())) { continue }
            guard (try? policy.check(url, purpose: .personal)) != nil else { continue }
            guard let owners = try? ledger.activeItems(overlapping: url.path), owners.isEmpty else { continue }
            let allocated = kind == S_IFDIR ? DirectoryScanner.size(of: url) : Int64(st.st_blocks) * 512
            guard allocated >= Int64(rule.minSizeMB) << 20 else { continue }
            guard let usage = kind == S_IFDIR ? newestUsage(url, usageDate: usageDate) : usageDate(url) else { continue }
            guard (FileUsage.daysSince(usage.date, now: now) ?? 0) >= rule.minDaysUnused else { continue }
            guard InUseCheck.reason(url, now: now) == nil else { continue }
            out.append(RuleCandidate(url: url, allocated: allocated, usage: usage, isDirectory: kind == S_IFDIR))
        }
        return out.sorted { $0.usage.date < $1.usage.date }
    }

    /// A folder counts as used when anything inside it was. A folder too big to walk fully
    /// (over 50 000 entries) or holding another volume gives nil: never offered, since the
    /// part not seen might be in use.
    static func newestUsage(_ dir: URL, usageDate: (URL) -> UsageDate?) -> UsageDate? {
        var rootSt = stat()
        guard lstat(dir.path, &rootSt) == 0 else { return nil }
        var newest = usageDate(dir)
        var stack = [dir], seen = 0
        while let current = stack.popLast() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? [] {
                seen += 1
                if seen > maxEntries { return nil }
                let child = current.appendingPathComponent(name)
                var st = stat()
                guard lstat(child.path, &st) == 0 else { continue }
                if st.st_mode & S_IFMT == S_IFDIR {
                    if st.st_dev != rootSt.st_dev { return nil }
                    stack.append(child)
                }
                if let u = usageDate(child), u.date > (newest?.date ?? .distantPast) { newest = u }
            }
        }
        return newest
    }

    /// Runs every enabled automatic rule, one personal operation each. Nothing happens
    /// without a mounted Kho.
    public static func runAuto(
        rules: [OffloadRule], khoMounted: Bool, service: OffloadService, ledger: Ledger, policy: PathPolicy,
        layout: KhoLayout?, now: Date = Date(), usageDate: (URL) -> UsageDate? = FileUsage.effective,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> [(rule: String, result: Result<PersonalOffloadResult, Error>)] {
        guard khoMounted, let layout else { return [] }
        var out: [(String, Result<PersonalOffloadResult, Error>)] = []
        for rule in rules where rule.enabled && rule.mode == .auto {
            if isCancelled() { break }
            let urls = candidates(for: rule, ledger: ledger, policy: policy, now: now, usageDate: usageDate).map(\.url)
            guard !urls.isEmpty else { continue }
            out.append((rule.name, Result {
                try PersonalOffload.offload(urls, title: "Quy tắc: \(rule.name)", leaveSymlink: rule.leaveSymlink,
                                            service: service, layout: layout, now: { now }, isCancelled: isCancelled)
            }))
        }
        return out
    }
}
