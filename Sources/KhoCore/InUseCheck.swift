import Darwin
import Foundation

/// Never offload something being worked on: recently changed, or open in another process.
public enum InUseCheck {
    public static let recentlyChanged = "Vừa được sửa"
    public static let openElsewhere = "Đang được mở bởi tiến trình khác"
    static let recentWindow: TimeInterval = 600
    static let maxEntries = 50_000

    public static func reason(_ url: URL, now: Date = Date()) -> String? {
        if let newest = newestModification(url), now.timeIntervalSince(newest) < recentWindow {
            return recentlyChanged
        }
        var st = stat()
        if lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, isOpen(url) {
            return openElsewhere
        }
        return nil
    }

    /// Newest modification in the tree (at most 50 000 entries, same device only).
    static func newestModification(_ url: URL) -> Date? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        var newest = Double(st.st_mtimespec.tv_sec)
        guard st.st_mode & S_IFMT == S_IFDIR else { return Date(timeIntervalSince1970: newest) }
        let dev = st.st_dev
        var stack = [url], seen = 0
        while let dir = stack.popLast(), seen < maxEntries {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                seen += 1
                let child = dir.appendingPathComponent(name)
                var cs = stat()
                guard lstat(child.path, &cs) == 0 else { continue }
                newest = max(newest, Double(cs.st_mtimespec.tv_sec))
                if cs.st_mode & S_IFMT == S_IFDIR && cs.st_dev == dev { stack.append(child) }
            }
        }
        return Date(timeIntervalSince1970: newest)
    }

    /// `lsof -t` prints the PIDs holding the file. Synchronous on purpose (it runs inside
    /// offload checks); gives up after 5 seconds and then treats the file as in use.
    static func isOpen(_ url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-t", "--", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            return true
        }
        return !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
