import Foundation
import GRDB

/// Counts subscriptions per reader, including ones outside `startRestarting`.
extension AppDatabase {
    /// Retain this token for a value-observation subscription's lifetime; cancel it when the subscription ends.
    public func trackLongLivedObservation() -> AnyDatabaseCancellable {
        LongLivedObservationCounts.track(in: reader)
    }
}

/// Reader identities are removed when their last subscription ends. The lock protects background starts and stops.
final class LongLivedObservationCounts: @unchecked Sendable {
    private static let shared = LongLivedObservationCounts()
    private let lock = NSLock()
    private var counts: [ObjectIdentifier: Int] = [:]

    static func count(in reader: any DatabaseReader) -> Int {
        shared.lock.withLock { shared.counts[ObjectIdentifier(reader), default: 0] }
    }

    static func track(in reader: any DatabaseReader) -> AnyDatabaseCancellable {
        let id = ObjectIdentifier(reader)
        shared.lock.withLock { shared.counts[id, default: 0] += 1 }
        return AnyDatabaseCancellable {
            shared.lock.withLock {
                let remaining = shared.counts[id, default: 0] - 1
                shared.counts[id] = remaining > 0 ? remaining : nil
            }
        }
    }
}
