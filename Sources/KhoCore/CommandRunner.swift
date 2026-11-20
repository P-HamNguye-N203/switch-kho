import Foundation
import Synchronization

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let output: String
}

/// Runs an external tool, collecting stdout and stderr together, with a timeout.
public enum CommandRunner {
    final class Box: Sendable {
        let data = Mutex(Data())
        let timedOut = Mutex(false)
        let eof = Mutex(false)
    }

    /// Timeouts and hard kills run here, not on a global queue: global queues are capped at
    /// the core count, so threads blocked elsewhere could delay a timeout indefinitely.
    static let timerQueue = DispatchQueue(label: "switchkho.command-timeouts")

    public static func run(_ exe: URL, _ args: [String], timeout: TimeInterval) async throws -> CommandResult {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let box = Box()
        // One reader drains the pipe on its own thread (so a chatty tool never blocks on a full
        // pipe) and marks end-of-file only after its last chunk is stored, so nothing is lost.
        let reader = pipe.fileHandleForReading
        Thread.detachNewThread {
            // availableData returns as soon as anything arrives (read(upToCount:) would wait
            // for a full buffer, holding back output while a child keeps the pipe open).
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                box.data.withLock { $0.append(chunk) }
            }
            box.eof.withLock { $0 = true }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { p in c.resume(returning: p.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                try? pipe.fileHandleForWriting.close()   // lets the reader thread finish
                c.resume(throwing: KhoError.io("Không chạy được \(exe.lastPathComponent): \(error.localizedDescription)"))
                return
            }
            timerQueue.asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    box.timedOut.withLock { $0 = true }
                    let pid = process.processIdentifier
                    // A tool that ignores SIGTERM must not hold the job queue forever.
                    timerQueue.asyncAfter(deadline: .now() + 3) {
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                    process.terminate()
                    // pkill waits for its own exit; keep it off the timer queue so it cannot
                    // delay the hard kill above or any other command's timeout.
                    Thread.detachNewThread { killChildren(of: pid) }
                }
            }
        }

        // A child that inherited the pipe can keep it open after the parent exits; wait for
        // end-of-file only briefly and never after a timeout.
        if !box.timedOut.withLock({ $0 }) {
            let deadline = Date().addingTimeInterval(2)
            while !box.eof.withLock({ $0 }) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        if box.timedOut.withLock({ $0 }) { throw KhoError.io("Quá thời gian") }
        let output = String(decoding: box.data.withLock { $0 }, as: UTF8.self)
        return CommandResult(exitCode: status, output: output)
    }

    /// Terminates the direct children of `pid` (e.g. `ruby` under the `brew` script).
    static func killChildren(of pid: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-TERM", "-P", String(pid)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }
}
