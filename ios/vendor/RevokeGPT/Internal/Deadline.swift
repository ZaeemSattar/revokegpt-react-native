import Foundation

/// A total deadline for one call (plan: 10 s default, 1 to 60 s). Wall-clock `Date` based: the
/// iOS 15 target has no `ContinuousClock`, and the monotonic alternatives (`systemUptime`,
/// `mach_absolute_time`) are required-reason boot-time APIs (R§5, ruling C3). A wall-clock jump
/// can shorten or lengthen a deadline once, and a long PoW (32 bits x 256) is not bounded by its
/// own work. So `Deadline` is only the cheap in-loop check; `race` is the hard bound: every network
/// call and the PoW run under it, against `Task.sleep(nanoseconds:)`, which is monotonic and uses
/// no boot-time API.
struct Deadline: Sendable, Equatable {
    let date: Date

    init(after seconds: TimeInterval, from now: Date = Date()) {
        date = now.addingTimeInterval(seconds)
    }

    var isExpired: Bool { Date() >= date }
}

/// The deadline passed before the raced operation finished.
struct DeadlineExceeded: Error, Equatable {}

extension Deadline {
    /// Seconds left (negative once expired), by the wall clock.
    var remaining: TimeInterval { date.timeIntervalSinceNow }

    /// Runs `operation` against a monotonic timer, the time left now slept with
    /// `Task.sleep(nanoseconds:)` (no boot-time API, unaffected by later wall-clock changes), and
    /// returns as soon as either finishes: the operation's result, or `DeadlineExceeded`. The
    /// loser is cancelled and **abandoned, never awaited**, so an operation that ignores
    /// cancellation (an App Attest or DeviceCheck call in flight) cannot stretch the bound: its
    /// late result is dropped. Cancelling the calling task ends the race at once with
    /// `CancellationError`. An expired deadline throws `DeadlineExceeded` before the operation
    /// starts.
    func race<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let seconds = remaining
        guard seconds > 0 else { throw DeadlineExceeded() }
        // A caller already cancelled starts nothing (no request goes out).
        try Task.checkCancellation()
        let nanoseconds = UInt64(min(seconds, 86_400) * 1_000_000_000)
        let gate = RaceGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
                let work = Task {
                    let result: Result<T, any Error>
                    do {
                        result = .success(try await operation())
                    } catch {
                        result = .failure(error)
                    }
                    await gate.finish(result)
                }
                let timer = Task {
                    guard (try? await Task.sleep(nanoseconds: nanoseconds)) != nil else { return }
                    await gate.finish(.failure(DeadlineExceeded()))
                }
                Task { await gate.start(c, tasks: [work, timer]) }
            }
        } onCancel: {
            Task { await gate.finish(.failure(CancellationError())) }
        }
    }
}

/// Resumes a race's continuation exactly once, with the first result, and then cancels both
/// sides. `start` and `finish` can arrive in either order. The winning result (it can be a
/// token) is held only until it is handed over, never while the abandoned loser runs on.
private actor RaceGate<T: Sendable> {
    private var continuation: CheckedContinuation<T, any Error>?
    /// A result that arrived before `start`, held until `start` hands it over.
    private var early: Result<T, any Error>?
    private var done = false
    private var tasks: [Task<Void, Never>] = []

    func start(_ c: CheckedContinuation<T, any Error>, tasks: [Task<Void, Never>]) {
        self.tasks = tasks
        if let early {
            self.early = nil
            c.resume(with: early)
            cancelAll()
        } else {
            continuation = c
        }
    }

    func finish(_ r: Result<T, any Error>) {
        guard !done else { return }
        done = true
        guard let c = continuation else {
            early = r
            return
        }
        continuation = nil
        c.resume(with: r)
        cancelAll()
    }


    private func cancelAll() {
        for t in tasks { t.cancel() }
        tasks = []
    }
}
