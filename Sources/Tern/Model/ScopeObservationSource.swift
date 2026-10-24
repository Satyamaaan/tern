import Foundation
import GRDB
import TernCore

/// Counts and labels follow scope changes without starting another concurrent observation.
final class ScopeObservationSource: @unchecked Sendable {
    struct Request: Equatable, Sendable {
        var accountId: String?
        var generation = 0

        func fetchCounts(_ db: Database) throws -> Counts {
            Counts(request: self, counts: try MailStore.fetchScopeCounts(db, accountId: accountId))
        }

        func fetchLabels(_ db: Database) throws -> Labels {
            guard let accountId else { return Labels(request: self, labels: []) }
            let labels = try MailLabel
                .filter(Column("accountId") == accountId && Column("type") == "user" && Column("hidden") == false)
                .order(Column("name"))
                .fetchAll(db)
            return Labels(request: self, labels: labels)
        }
    }

    struct Counts: Equatable, Sendable {
        var request: Request
        var counts: ScopeCounts
    }

    struct Labels: Equatable, Sendable {
        var request: Request
        var labels: [MailLabel]
    }

    private let lock = NSLock()
    private var request = Request()

    var current: Request { lock.withLock { request } }

    func set(accountId: String?) -> Request {
        lock.withLock {
            request = Request(accountId: accountId, generation: request.generation + 1)
            return request
        }
    }

    static let countsRegions: [any DatabaseRegionConvertible] = [
        Table<Row>("thread_label").select(Column("accountId"), Column("threadId"), Column("labelId"), Column("gmailTab")),
        Table<Row>("thread_ai").select(Column("accountId"), Column("threadId"), Column("category"), Column("needsReply")),
        Table<Row>("snooze"),
        Table<Row>("draft").select(Column("accountId"), Column("gmailMessageId"), Column("state")),
        Table<Row>("message").select(Column("accountId"), Column("id"), Column("isDraft")),
        Table<Row>("thread_project").select(Column("accountId"), Column("threadId"), Column("projectId")),
        Table<Row>("setting"),
        Table<Row>("commitment").select(Column("accountId"), Column("threadId"), Column("state"), Column("surfaced"), Column("direction"), Column("confidence")),
    ]

    static let labelsRegions: [any DatabaseRegionConvertible] = [Table<Row>("label")]
}
