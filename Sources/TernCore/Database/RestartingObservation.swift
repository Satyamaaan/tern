import Foundation
import GRDB

extension ValueObservation where Reducer: ValueReducer {
    /// Like `start(in:scheduling:onError:onChange:)`, but an error doesn't end it. GRDB stops an
    /// observation the first time a read fails (busy, interrupted, a schema change mid-read), which
    /// would leave a list or count frozen; this reports the error, then starts the observation again
    /// on the main queue after 0.25 s, doubling up to 30 s while it keeps failing. A delivered value
    /// resets the delay. Start it on the main thread; cancelling stops the retries too.
    @preconcurrency public func startRestarting(
        in reader: any DatabaseReader,
        scheduling scheduler: some ValueObservationScheduler,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable {
        let restarts = ObservationRestarts()
        let observation = self
        restarts.begin = { [weak restarts] in
            observation.start(
                in: reader, scheduling: scheduler,
                onError: { error in
                    onError(error)
                    restarts?.failed()
                },
                onChange: { value in
                    restarts?.delivered()
                    onChange(value)
                })
        }
        restarts.restart()
        return AnyDatabaseCancellable { restarts.cancel() }
    }

    /// `startRestarting` for main-actor callers, like GRDB's main-actor `start`.
    @preconcurrency @MainActor public func startRestarting(
        in reader: any DatabaseReader,
        scheduling scheduler: some ValueObservationMainActorScheduler = .mainActor,
        onError: @escaping @MainActor (Error) -> Void,
        onChange: @escaping @MainActor (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable {
        let regularScheduler: some ValueObservationScheduler = scheduler
        return startRestarting(
            in: reader, scheduling: regularScheduler,
            onError: { error in MainActor.assumeIsolated { onError(error) } },
            onChange: { value in MainActor.assumeIsolated { onChange(value) } })
    }
}

/// The running observation of a `startRestarting` call, and its retry delay.
final class ObservationRestarts: @unchecked Sendable {
    static let firstDelay = 0.25
    static let maxDelay = 30.0

    var begin: (() -> AnyDatabaseCancellable)?
    private let lock = NSLock()
    private var current: AnyDatabaseCancellable?
    private var failures = 0
    private var cancelled = false

    func restart() {
        guard let begin else { return }
        let started = begin()
        lock.lock()
        defer { lock.unlock() }
        if cancelled { started.cancel() } else { current = started }
    }

    func failed() {
        lock.lock()
        let delay = Self.delay(afterFailures: failures)
        failures += 1
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.restart()
        }
    }

    func delivered() {
        lock.lock()
        failures = 0
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = current
        current = nil
        begin = nil
        lock.unlock()
        running?.cancel()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    static func delay(afterFailures failures: Int) -> Double {
        min(maxDelay, firstDelay * pow(2, Double(min(failures, 16))))
    }
}
