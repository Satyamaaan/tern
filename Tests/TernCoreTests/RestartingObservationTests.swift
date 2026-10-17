import Foundation
import GRDB
import Testing
@testable import TernCore

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func update(_ change: (inout T) -> Void) { lock.withLock { change(&value) } }
}

private struct Flaky: Error {}

@MainActor
@Test func observationsComeBackAfterAnError() async throws {
    let database = try AppDatabase.inMemory()
    let failuresLeft = Box(2)
    let errors = Box(0)
    let values = Box<[Int]>([])
    let observation = ValueObservation.tracking { db -> Int in
        var fail = false
        failuresLeft.update { left in
            fail = left > 0
            left -= 1
        }
        if fail { throw Flaky() }
        return try Account.fetchCount(db)
    }
    let cancellable = observation.startRestarting(
        in: database.reader, scheduling: .async(onQueue: .main),
        onError: { _ in errors.update { $0 += 1 } }, onChange: { value in values.update { $0.append(value) } })

    let deadline = Date().addingTimeInterval(5)
    while values.get().isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(errors.get() == 2, "each failure is reported")
    #expect(values.get() == [0], "and the observation starts again until it delivers")

    try await database.writer.write { db in try Account(email: "a@example.com").insert(db) }
    while values.get().count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(values.get() == [0, 1], "the restarted observation keeps tracking changes")
    cancellable.cancel()
}

@Test func restartDelaysBackOffAndStayBounded() {
    #expect(ObservationRestarts.delay(afterFailures: 0) == 0.25)
    #expect(ObservationRestarts.delay(afterFailures: 1) == 0.5)
    #expect(ObservationRestarts.delay(afterFailures: 3) == 2)
    #expect(ObservationRestarts.delay(afterFailures: 40) == 30)
}
