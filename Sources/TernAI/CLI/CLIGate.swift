import Foundation

/// Limits how many model CLIs run at once across the app; later calls wait in order.
public actor CLIGate {
    /// At most two CLI calls at a time, shared by triage and on-demand features.
    public static let shared = CLIGate(limit: 2)

    public let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Runs `body` once a slot is free. A cancelled waiter leaves the queue without running.
    public nonisolated func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // The slot passes straight to the next waiter.
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
