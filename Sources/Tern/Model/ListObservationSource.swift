import Foundation
import GRDB
import TernCore

/// One observation follows every list. Changing its request never starts another WAL snapshot.
final class ListObservationSource: @unchecked Sendable {
    struct Request: Equatable, Sendable {
        var source: ListSource
        var limit: Int
        var keepingPlace = false
        var generation = 0

        func fetch(_ db: Database) throws -> Rows {
            let signpost = Timing.begin("list")
            defer { Timing.end(signpost) }
            return Rows(request: self, rows: try source.fetch(db, limit: limit))
        }
    }

    struct Rows: Equatable, Sendable {
        var request: Request
        var rows: [ThreadRow]
    }

    // The observation fetches on GRDB's queues; navigation replaces the request on main.
    private let lock = NSLock()
    private var request: Request

    init(source: ListSource, limit: Int) {
        request = Request(source: source, limit: limit)
    }

    var current: Request { lock.withLock { request } }

    func set(source: ListSource, limit: Int, keepingPlace: Bool) -> Request {
        lock.withLock {
            request = Request(source: source, limit: limit, keepingPlace: keepingPlace, generation: request.generation + 1)
            return request
        }
    }

    /// The union of tables read by every ListSource, including local drafts and Due.
    static let regions: [any DatabaseRegionConvertible] = [
        "thread", "thread_label", "thread_ai", "thread_summary", "thread_project", "snooze",
        "message", "account", "draft", "setting", "commitment",
    ].map { Table<Row>($0) }
}
