import AppKit
import Foundation

public enum RunningProcesses {
    /// Executable paths of all processes (`ps -axo comm=`).
    public static func executablePaths() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// PID and executable path of every process (`ps -axo pid=,comm=`).
    public static func processes() -> [(pid: Int32, path: String)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let space = t.firstIndex(of: " "), let pid = Int32(t[..<space]) else { return nil }
            return (pid, t[space...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Processes running an executable inside the bundle, helpers included.
    public static func pids(inside appURL: URL) -> [Int32] {
        let prefix = (FileOps.realpath(appURL.path) ?? appURL.path) + "/"
        return processes().filter { p in
            p.path.hasPrefix("/") && ((FileOps.realpath(p.path) ?? p.path).hasPrefix(prefix) || p.path.hasPrefix(prefix))
        }.map(\.pid)
    }

    /// True when any process runs an executable inside the bundle (helpers included).
    public static func isRunning(appURL: URL, paths: [String]? = nil) -> Bool {
        let prefix = (FileOps.realpath(appURL.path) ?? appURL.path) + "/"
        return (paths ?? executablePaths()).contains { path in
            guard path.hasPrefix("/") else { return false }
            let resolved = FileOps.realpath(path) ?? path
            return resolved.hasPrefix(prefix) || path.hasPrefix(prefix)
        }
    }

    public static func isRunning(bundleID: String, appURL: URL?) -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return true }
        if let appURL { return isRunning(appURL: appURL) }
        return false
    }
}
