import Foundation
import GRDB

/// The current reader request, shared by navigation and GRDB's fetch queue.
final class DetailObservationSource: @unchecked Sendable {
    struct Request: Equatable, Sendable {
        var key: ThreadKey?
        var generation = 0

        func fetch(_ db: Database) throws -> Value {
            Value(request: self, detail: try key.flatMap { try MailStore.fetchThreadDetail(db, $0) })
        }
    }

    struct Value: Equatable, Sendable {
        var request: Request
        var detail: ThreadDetail?
    }

    private let lock = NSLock()
    private var request = Request()

    var current: Request { lock.withLock { request } }

    func set(_ key: ThreadKey?) -> Request {
        lock.withLock {
            request = Request(key: key, generation: request.generation + 1)
            return request
        }
    }

    // Detail selects whole records, including message bodies and Gmail drafts. Only the join
    // table reads a subset of columns. Fixed regions must cover branches absent on the first fetch.
    static let regions: [any DatabaseRegionConvertible] = [
        Table<Row>("thread"), Table<Row>("message"), Table<Row>("attachment"),
        Table<Row>("thread_ai"), Table<Row>("project"), Table<Row>("snooze"),
        Table<Row>("setting"), Table<Row>("commitment"),
        Table<Row>("thread_project").select(Column("accountId"), Column("threadId"), Column("projectId")),
    ]
}
