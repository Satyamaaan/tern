import Foundation

/// Limits how many model CLIs run at once across the app; later calls wait in order. Background calls
/// (triage) may hold at most `backgroundLimit` slots, so an on-demand call (a summary, a draft) always
/// finds one, and waiting on-demand calls go before waiting background ones.
public actor CLIGate {
    /// Four CLI calls at a time: up to three background triage batches plus one for on-demand features.
    public static let shared = CLIGate(limit: 4, backgroundLimit: 3)

    public let limit: Int
    public let backgroundLimit: Int
    private var running = 0
    private var runningBackground = 0
    private var waiters: [(id: UUID, background: Bool, continuation: CheckedContinuation<Void, Error>)] = []

    /// `backgroundLimit` defaults to `limit`; it is clamped to `1...limit`.
    public init(limit: Int, backgroundLimit: Int? = nil) {
        self.limit = max(1, limit)
        self.backgroundLimit = min(self.limit, max(1, backgroundLimit ?? limit))
    }

    /// Runs `body` once a slot is free. A cancelled waiter leaves the queue without running, also when a slot
    /// reached it before its cancellation did.
    public nonisolated func withSlot<T: Sendable>(background: Bool = false, _ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire(background: background)
        if Task.isCancelled {
            await release(background: background)
            throw CancellationError()
        }
        do {
            let value = try await body()
            await release(background: background)
            return value
        } catch {
            await release(background: background)
            throw error
        }
    }

    private func acquire(background: Bool) async throws {
        try Task.checkCancellation()
        // Background calls queue behind anyone waiting; on-demand calls only behind other on-demand calls.
        let queuedAhead = background ? !waiters.isEmpty : waiters.contains { !$0.background }
        if !queuedAhead, canStart(background: background) {
            take(background: background)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, background, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func canStart(background: Bool) -> Bool {
        running < limit && (!background || runningBackground < backgroundLimit)
    }

    private func take(background: Bool) {
        running += 1
        if background { runningBackground += 1 }
    }

    private func release(background: Bool) {
        running -= 1
        if background { runningBackground -= 1 }
        // Free slots pass to waiting on-demand calls first, then to background calls, each in order.
        while let index = waiters.firstIndex(where: { !$0.background && canStart(background: false) })
                ?? waiters.firstIndex(where: { $0.background && canStart(background: true) }) {
            let waiter = waiters.remove(at: index)
            take(background: waiter.background)
            waiter.continuation.resume()
        }
    }

    /// Calls holding a slot and calls waiting for one.
    var occupancy: (running: Int, waiting: Int) { (running, waiters.count) }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
