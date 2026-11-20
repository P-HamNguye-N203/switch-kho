import Foundation
import Testing
@testable import KhoCore

@Suite struct JobQueueTests {
    @Test func jobsRunInOrderWithoutOverlap() async throws {
        let q = JobQueue()
        let log = Locked<[(String, Double, Double)]>([])
        @Sendable func t() -> Double { Date().timeIntervalSinceReferenceDate }
        for name in ["a", "b", "c"] {
            await q.enqueue(title: name) { _ in
                let s = t()
                try await Task.sleep(for: .milliseconds(30))
                log.withLock { $0.append((name, s, t())) }
            }
        }
        let value = try await q.run(title: "d") { _ in 42 }
        #expect(value == 42)
        let entries = log.withLock { $0 }
        #expect(entries.map(\.0) == ["a", "b", "c"])
        for i in 1..<entries.count { #expect(entries[i].1 >= entries[i - 1].2) }
    }

    @Test func cancelCancellableJob() async throws {
        let q = JobQueue()
        let started = Locked(false)
        let id = await q.enqueue(title: "scan", cancellable: true) { ctx in
            started.withLock { $0 = true }
            while !ctx.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        await q.cancel(id: id)
        let next = try await q.run(title: "next") { _ in "ok" }
        #expect(next == "ok")
        #expect(await q.snapshot.first { $0.id == id }?.state == .cancelled)
    }

    @Test func defaultJobIsNotCancellable() async throws {
        let q = JobQueue()
        let started = Locked(false)
        let release = Locked(false)
        await q.enqueue(title: "move") { _ in
            started.withLock { $0 = true }
            while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await q.cancelRunningIfCancellable() == false)
        release.withLock { $0 = true }
        #expect(await q.waitUntilIdle(timeout: .seconds(2)))
        #expect(await q.snapshot.first?.state == .done)
    }

    // A nested call that waited for the outer job would never return; the time limit catches it.
    @Test(.timeLimit(.minutes(1))) func nestedRunThrowsQuickly() async throws {
        let q = JobQueue()
        await #expect(throws: KhoError.invalidState("Gọi lồng trong hàng đợi")) {
            try await q.run(title: "outer") { _ in
                try await q.run(title: "inner") { _ in 1 }
            }
        }
    }

    @Test func suspendHoldsNewJobs() async throws {
        let q = JobQueue()
        await q.suspend()
        let id = await q.enqueue(title: "later") { _ in }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await q.snapshot.first { $0.id == id }?.state == .queued)
        await q.resume()
        #expect(await q.waitUntilIdle(timeout: .seconds(2)))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await q.snapshot.first { $0.id == id }?.state == .done)
    }

    @Test func waitUntilIdleTimesOut() async throws {
        let q = JobQueue()
        let release = Locked(false)
        await q.enqueue(title: "long") { _ in
            while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await q.waitUntilIdle(timeout: .milliseconds(50)) == false)
        release.withLock { $0 = true }
        #expect(await q.waitUntilIdle(timeout: .seconds(2)))
    }
}
