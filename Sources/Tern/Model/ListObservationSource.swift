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

    /// The union of columns read by every ListSource, including local drafts and Due.
    static let regions: [any DatabaseRegionConvertible] = [
        Table<Row>("thread"),
        Table<Row>("thread_label").select(Column("accountId"), Column("threadId"), Column("labelId"), Column("lastDate"), Column("gmailTab")),
        Table<Row>("thread_ai").select(Column("accountId"), Column("threadId"), Column("category"), Column("needsReply"), Column("priority"), Column("summary")),
        Table<Row>("thread_summary").select(Column("accountId"), Column("threadId"), Column("messageCount"), Column("lastDate"), Column("line")),
        Table<Row>("thread_project").select(Column("accountId"), Column("threadId"), Column("projectId")),
        Table<Row>("snooze"),
        Table<Row>("message").select(Column("accountId"), Column("id"), Column("threadId"), Column("isDraft"), Column("isFromMe"), Column("searchRecipients")),
        Table<Row>("account").select(Column("id"), Column("email")),
        // Drafts and Due select whole records, so these regions must stay broad.
        Table<Row>("draft"), Table<Row>("setting"), Table<Row>("commitment"),
    ]
}
