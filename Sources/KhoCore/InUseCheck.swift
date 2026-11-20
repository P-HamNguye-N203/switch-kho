import Darwin
import Foundation
import Synchronization

/// Never offload something being worked on: recently changed, or open in another process.
public enum InUseCheck {
    public static let recentlyChanged = "Vừa được sửa"
    public static let openElsewhere = "Đang được mở bởi tiến trình khác"
    public static let notChecked = "Không kiểm tra được file có đang mở không"
    static let recentWindow: TimeInterval = 600
    static let maxEntries = 50_000

    public static func reason(_ url: URL, now: Date = Date()) -> String? {
        if let newest = newestModification(url), now.timeIntervalSince(newest) < recentWindow {
            return recentlyChanged
        }
        var st = stat()
        if lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG {
            switch openCheck(url) {
            case .open: return openElsewhere
            case .unknown: return notChecked
            case .closed: return nil
            }
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

    enum OpenState: Equatable { case open, closed, unknown }

    /// `lsof -t` prints the PIDs holding the file. Synchronous on purpose (it runs inside
    /// offload checks). Output is drained without blocking, so the timeout really applies;
    /// a tool that cannot start or does not finish in time gives `unknown`, never "closed".
    static func openCheck(_ url: URL, tool: URL = URL(fileURLWithPath: "/usr/sbin/lsof"),
                          arguments: [String]? = nil, timeout: TimeInterval = 5) -> OpenState {
        let p = Process()
        p.executableURL = tool
        p.arguments = arguments ?? ["-t", "--", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let output = Mutex(Data())
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { output.withLock { $0.append(chunk) } }
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .unknown
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(pid, SIGKILL) }
            p.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            return .unknown
        }
        // Collect what is still buffered after exit.
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let all = output.withLock { $0 } + rest
        return String(decoding: all, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .closed : .open
    }
}
