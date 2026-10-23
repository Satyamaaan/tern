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
    #expect(database.liveLongLivedObservationCount == 1, "Retries reuse the same subscription budget")

    try await database.writer.write { db in try Account(email: "a@example.com").insert(db) }
    while values.get().count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(values.get() == [0, 1], "the restarted observation keeps tracking changes")
    cancellable.cancel()
    #expect(database.liveLongLivedObservationCount == 0)
}

@Test func restartDelaysBackOffAndStayBounded() {
    #expect(ObservationRestarts.delay(afterFailures: 0) == 0.25)
    #expect(ObservationRestarts.delay(afterFailures: 1) == 0.5)
    #expect(ObservationRestarts.delay(afterFailures: 3) == 2)
    #expect(ObservationRestarts.delay(afterFailures: 40) == 30)
}

@MainActor
@Test func liveObservationCountTracksCancellationAndRelease() throws {
    let database = try AppDatabase.inMemory()
    let other = try AppDatabase.inMemory()
    let observation = ValueObservation.tracking { db in try Account.fetchCount(db) }
    var subscriptions = (0..<AppDatabase.longLivedObservations).map { _ in
        observation.startRestarting(in: database.reader, scheduling: .immediate,
                                    onError: { Issue.record($0) }, onChange: { _ in })
    }
    #expect(database.liveLongLivedObservationCount == AppDatabase.longLivedObservations)
    #expect(other.liveLongLivedObservationCount == 0)
    subscriptions[0].cancel()
    subscriptions[0].cancel()
    #expect(database.liveLongLivedObservationCount == AppDatabase.longLivedObservations - 1)
    subscriptions.removeAll()
    #expect(database.liveLongLivedObservationCount == 0)
    let token = database.trackLongLivedObservation()
    #expect(database.liveLongLivedObservationCount == 1)
    token.cancel()
    #expect(database.liveLongLivedObservationCount == 0)
}
