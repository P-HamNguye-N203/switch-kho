import Foundation
import Synchronization

public enum JobState: Sendable, Equatable {
    case queued, running, done, failed(String), cancelled
}

public struct JobSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let fraction: Double
    public let detail: String
    public let state: JobState
    public let cancellable: Bool
}

/// Progress and cancellation shared between a running job and the queue.
final class JobControl: Sendable {
    struct Values { var fraction = 0.0; var detail = ""; var cancelled = false; var lastPublish = 0.0 }
    let values = Mutex(Values())
    let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
}

/// Handed to every job body. Safe to call from synchronous code such as copy callbacks.
public struct JobContext: Sendable {
    public let id: UUID
    let control: JobControl

    /// Publishes at most about ten times a second; copy callbacks fire far more often.
    public func report(fraction: Double, detail: String) {
        let now = Date().timeIntervalSinceReferenceDate
        let publish = control.values.withLock { v -> Bool in
            v.fraction = max(0, min(1, fraction))
            v.detail = detail
            guard now - v.lastPublish >= 0.1 || fraction >= 1 else { return false }
            v.lastPublish = now
            return true
        }
        if publish { control.onChange() }
    }

    public var isCancelled: Bool { control.values.withLock { $0.cancelled } }
}

/// Resumes a continuation at most once, whichever path gets there first.
final class OnceResume<T: Sendable>: Sendable {
    let continuation: Mutex<CheckedContinuation<T, Error>?>
    init(_ c: CheckedContinuation<T, Error>) { continuation = Mutex(c) }
    func resume(_ result: Result<T, Error>) {
        continuation.withLock { c in
            c?.resume(with: result)
            c = nil
        }
    }
}

/// Runs heavy and state-changing work one job at a time, with progress, safe cancellation
/// and a suspend switch used while a Kho is being ejected.
public actor JobQueue {
    @TaskLocal static var insideJob = false

    struct Record {
        let id: UUID
        let title: String
        let cancellable: Bool
        var state: JobState
        let control: JobControl
        let work: @Sendable (JobContext) async throws -> Void
        let dropped: (@Sendable (Error) -> Void)?
    }

    var records: [Record] = []
    var suspended = false
    var observers: [UUID: AsyncStream<[JobSnapshot]>.Continuation] = [:]
    static let keepFinished = 20

    public init() {}

    // MARK: Public API

    @discardableResult
    public func enqueue(title: String, cancellable: Bool = false,
                        work: @escaping @Sendable (JobContext) async throws -> Void) -> UUID {
        add(title: title, cancellable: cancellable, work: work, dropped: nil)
    }

    public func run<T: Sendable>(title: String, cancellable: Bool = false,
                                 work: @escaping @Sendable (JobContext) async throws -> T) async throws -> T {
        if Self.insideJob { throw KhoError.invalidState("Gọi lồng trong hàng đợi") }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            let once = OnceResume(c)
            add(title: title, cancellable: cancellable, work: { ctx in
                do {
                    once.resume(.success(try await work(ctx)))
                } catch {
                    once.resume(.failure(error))
                    throw error
                }
            }, dropped: { once.resume(.failure($0)) })
        }
    }

    public func cancel(id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        switch records[i].state {
        case .queued:
            records[i].state = .cancelled
            records[i].dropped?(CancellationError())
            publish()
        case .running where records[i].cancellable:
            records[i].control.values.withLock { $0.cancelled = true }
            publish()
        default:
            break
        }
    }

    /// Cancels the running job if it allows it. Returns whether a cancel was requested.
    public func cancelRunningIfCancellable() -> Bool {
        guard let r = records.first(where: { $0.state == .running }), r.cancellable else { return false }
        cancel(id: r.id)
        return true
    }

    public var updates: AsyncStream<[JobSnapshot]> {
        let (stream, continuation) = AsyncStream<[JobSnapshot]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        observers[key] = continuation
        continuation.yield(snapshots())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(key) }
        }
        return stream
    }

    public var isBusy: Bool { records.contains { $0.state == .running || $0.state == .queued } }

    public var snapshot: [JobSnapshot] { snapshots() }

    public func suspend() {
        suspended = true
    }

    public func resume() {
        suspended = false
        pump()
    }

    /// True once no job is running; false when `timeout` passes first.
    public func waitUntilIdle(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while records.contains(where: { $0.state == .running }) {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: Internals

    func removeObserver(_ key: UUID) { observers[key] = nil }

    private func add(title: String, cancellable: Bool,
                     work: @escaping @Sendable (JobContext) async throws -> Void,
                     dropped: (@Sendable (Error) -> Void)?) -> UUID {
        let id = UUID()
        let control = JobControl(onChange: { [weak self] in
            Task { await self?.publish() }
        })
        records.append(Record(id: id, title: title, cancellable: cancellable, state: .queued,
                              control: control, work: work, dropped: dropped))
        publish()
        pump()
        return id
    }

    private func pump() {
        guard !suspended, !records.contains(where: { $0.state == .running }),
              let i = records.firstIndex(where: { $0.state == .queued })
        else { return }
        records[i].state = .running
        let record = records[i]
        publish()
        Task {
            let ctx = JobContext(id: record.id, control: record.control)
            var outcome: JobState = .done
            do {
                try await Self.$insideJob.withValue(true) { try await record.work(ctx) }
            } catch {
                outcome = (error is CancellationError || ctx.isCancelled)
                    ? .cancelled : .failed(error.localizedDescription)
            }
            await self.finish(record.id, outcome)
        }
    }

    private func finish(_ id: UUID, _ state: JobState) {
        if let i = records.firstIndex(where: { $0.id == id }) {
            records[i].state = state
            if state == .done { records[i].control.values.withLock { $0.fraction = 1 } }
        }
        let finished = records.filter { $0.state != .queued && $0.state != .running }
        if finished.count > Self.keepFinished {
            let drop = Set(finished.prefix(finished.count - Self.keepFinished).map(\.id))
            records.removeAll { drop.contains($0.id) }
        }
        publish()
        pump()
    }

    private func snapshots() -> [JobSnapshot] {
        records.map { r in
            let v = r.control.values.withLock { $0 }
            return JobSnapshot(id: r.id, title: r.title, fraction: v.fraction, detail: v.detail,
                               state: r.state, cancellable: r.cancellable)
        }
    }

    func publish() {
        let snap = snapshots()
        for c in observers.values { c.yield(snap) }
    }
}
