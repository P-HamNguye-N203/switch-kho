import Foundation
import Testing
@testable import KhoCore

@Suite struct CommandRunnerTests {
    @Test func capturesOutputAndExitCode() async throws {
        let r = try await CommandRunner.run(URL(fileURLWithPath: "/bin/echo"), ["hi"], timeout: 5)
        #expect(r.exitCode == 0)
        #expect(r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
        let f = try await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/false"), [], timeout: 5)
        #expect(f.exitCode == 1)
    }

    @Test func mergesStderr() async throws {
        let r = try await CommandRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err >&2"], timeout: 5)
        #expect(r.output.contains("out") && r.output.contains("err"))
    }

    @Test func childHoldingThePipeDoesNotHang() async throws {
        let start = Date()
        await #expect(throws: KhoError.io("Quá thời gian")) {
            _ = try await CommandRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 30 & wait"], timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 2.5)
        // Parent exits at once but a background child keeps the pipe open.
        let quick = Date()
        let r = try await CommandRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo done; sleep 30 &"], timeout: 10)
        #expect(r.output.contains("done"))
        #expect(Date().timeIntervalSince(quick) < 4)
    }

    @Test func toolIgnoringTermIsKilled() async throws {
        let start = Date()
        await #expect(throws: KhoError.io("Quá thời gian")) {
            _ = try await CommandRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                            ["-c", "trap '' TERM; while :; do sleep 1; done"], timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test func timesOut() async throws {
        let start = Date()
        await #expect(throws: KhoError.io("Quá thời gian")) {
            _ = try await CommandRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 4)
    }
}
