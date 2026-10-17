import Foundation
import GRDB

/// Threads the user took out of a project by hand. Rules and AI suggestions skip them, so the removal
/// sticks; putting the thread back by hand forgets it. Excluded threads have no `thread_project` row,
/// so every read of project membership ignores them without knowing about this table.
public struct ProjectExclusion: TernRecord, Hashable {
    public static let databaseTableName = "thread_project_exclusion"

    public var accountId: String
    public var threadId: String
    public var projectId: String

    public init(accountId: String, threadId: String, projectId: String) {
        self.accountId = accountId
        self.threadId = threadId
        self.projectId = projectId
    }

    /// Registered as `integrate-1` in `Schema.register`.
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE thread_project_exclusion (
              accountId TEXT NOT NULL,
              threadId TEXT NOT NULL,
              projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
              PRIMARY KEY (accountId, threadId, projectId),
              FOREIGN KEY (accountId, threadId) REFERENCES thread(accountId, id) ON DELETE CASCADE
            );
            CREATE INDEX thread_project_exclusion_by_project ON thread_project_exclusion(projectId);
            """)
    }
}

extension ProjectRules {
    /// Puts threads in a project by hand. Manual assignments survive rule changes and clear an
    /// earlier manual removal.
    public static func assignByHand(_ db: Database, _ keys: [ThreadKey], to projectId: String) throws {
        for key in keys {
            try ThreadProject(accountId: key.accountId, threadId: key.threadId, projectId: projectId, source: .manual).upsert(db)
            _ = try ProjectExclusion.deleteOne(db, key: ["accountId": key.accountId, "threadId": key.threadId, "projectId": projectId])
        }
    }

    /// Takes threads out of a project by hand. When a rule or an AI suggestion put a thread there, or a
    /// rule would match it, the removal is remembered so the next rule run doesn't add it back.
    public static func removeByHand(_ db: Database, _ keys: [ThreadKey], from projectId: String) throws {
        guard !keys.isEmpty else { return }
        let matched = try keysMatching(db, keys, projectId: projectId)
        for key in keys {
            let link = try ThreadProject.fetchOne(db, key: ["accountId": key.accountId, "threadId": key.threadId, "projectId": projectId])
            try link?.delete(db)
            if matched.contains(key) || link.map({ $0.source != .manual }) == true {
                try ProjectExclusion(accountId: key.accountId, threadId: key.threadId, projectId: projectId).upsert(db)
            }
        }
    }

    /// Whether the thread was taken out of the project by hand.
    public static func isExcluded(_ db: Database, _ key: ThreadKey, from projectId: String) throws -> Bool {
        try ProjectExclusion.exists(db, key: ["accountId": key.accountId, "threadId": key.threadId, "projectId": projectId])
    }

    /// Project ids each thread was taken out of by hand (only `projectId` when given).
    static func exclusions(_ db: Database, _ keys: [ThreadKey], projectId: String?) throws -> [ThreadKey: Set<String>] {
        let (values, arguments) = keyValues(keys)
        var sql = "SELECT * FROM thread_project_exclusion WHERE (accountId, threadId) IN (VALUES \(values))"
        var queryArguments = arguments
        if let projectId {
            sql += " AND projectId = ?"
            _ = queryArguments.append(contentsOf: [projectId])
        }
        var result: [ThreadKey: Set<String>] = [:]
        for exclusion in try ProjectExclusion.fetchAll(db, sql: sql, arguments: queryArguments) {
            result[ThreadKey(accountId: exclusion.accountId, threadId: exclusion.threadId), default: []].insert(exclusion.projectId)
        }
        return result
    }
}
