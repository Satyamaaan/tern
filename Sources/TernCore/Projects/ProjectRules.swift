import Foundation
import GRDB

/// Keeps rule-based project membership (`thread_project` rows with source `.rule`) in step with
/// `project_rule`. A thread joins a project when any of the project's rules matches, unless the user
/// took it out by hand (`ProjectExclusion`). Manual rows are never touched; an AI row for a project a
/// rule now matches becomes a rule row.
public enum ProjectRules {
    public struct Changes: Hashable, Sendable {
        public var added = 0
        public var removed = 0

        public init(added: Int = 0, removed: Int = 0) {
            self.added = added
            self.removed = removed
        }
    }

    /// Re-evaluates every project's rules for these threads. Sync calls it for the threads it touched.
    @discardableResult
    public static func apply(_ db: Database, keys: some Collection<ThreadKey>) throws -> Changes {
        guard !keys.isEmpty else { return Changes() }
        let rules = try CompiledRules.load(db, projectId: nil, scope: Array(keys))
        var changes = Changes()
        for chunk in Array(keys).chunked(by: 400) {
            changes.merge(try evaluate(db, chunk, rules: rules, projectId: nil))
        }
        return changes
    }

    /// Re-evaluates one project (or every project when nil) against all threads, after its rules change.
    @discardableResult
    public static func recomputeAll(_ db: Database, projectId: String? = nil) throws -> Changes {
        let rules = try CompiledRules.load(db, projectId: projectId, scope: nil)
        let keys = try Row.fetchAll(db, sql: "SELECT accountId, id FROM thread")
            .map { ThreadKey(accountId: $0[0], threadId: $0[1]) }
        var changes = Changes()
        for chunk in keys.chunked(by: 400) {
            changes.merge(try evaluate(db, chunk, rules: rules, projectId: projectId))
        }
        return changes
    }

    /// Whether two rule lists match the same threads: the same fields and values, in any order and with
    /// repeats ignored, since a thread joins when any rule matches. A save that keeps the rules (a new name,
    /// icon or colour) needs no `recomputeAll`.
    public static func sameRules(_ lhs: [ProjectRule], _ rhs: [ProjectRule]) -> Bool {
        func normalized(_ rules: [ProjectRule]) -> Set<[String]> {
            Set(rules.map { [$0.field.rawValue, $0.value.trimmingCharacters(in: .whitespacesAndNewlines)] })
        }
        return normalized(lhs) == normalized(rhs)
    }

    /// The projects whose rules match one thread.
    public static func matchingProjects(_ db: Database, key: ThreadKey) throws -> Set<String> {
        let rules = try CompiledRules.load(db, projectId: nil, scope: [key])
        let facts = try ThreadFacts.load(db, [key], needsMessages: rules.needsMessages)
        return facts[key].map { rules.projects(matching: $0) } ?? []
    }

    /// The threads among `keys` that one of the project's rules matches.
    static func keysMatching(_ db: Database, _ keys: [ThreadKey], projectId: String) throws -> Set<ThreadKey> {
        let rules = try CompiledRules.load(db, projectId: projectId, scope: keys)
        guard !rules.checks.isEmpty else { return [] }
        var matched = Set<ThreadKey>()
        for chunk in keys.chunked(by: 400) {
            for (key, thread) in try ThreadFacts.load(db, chunk, needsMessages: rules.needsMessages)
            where rules.projects(matching: thread).contains(projectId) {
                matched.insert(key)
            }
        }
        return matched
    }

    // MARK: Evaluation

    private static func evaluate(_ db: Database, _ keys: [ThreadKey], rules: CompiledRules, projectId: String?) throws -> Changes {
        let facts = try ThreadFacts.load(db, keys, needsMessages: rules.needsMessages)
        let (values, arguments) = keyValues(keys)
        var sql = "SELECT * FROM thread_project WHERE (accountId, threadId) IN (VALUES \(values))"
        var queryArguments = arguments
        if let projectId {
            sql += " AND projectId = ?"
            _ = queryArguments.append(contentsOf: [projectId])
        }
        var existing: [ThreadKey: [String: ThreadProject.Source]] = [:]
        for link in try ThreadProject.fetchAll(db, sql: sql, arguments: queryArguments) {
            existing[ThreadKey(accountId: link.accountId, threadId: link.threadId), default: [:]][link.projectId] = link.source
        }

        let excluded = try exclusions(db, keys, projectId: projectId)

        var changes = Changes()
        for key in keys {
            guard let thread = facts[key] else { continue }
            let wanted = rules.projects(matching: thread).subtracting(excluded[key] ?? [])
            let current = existing[key] ?? [:]
            for project in wanted {
                switch current[project] {
                case nil:
                    try ThreadProject(accountId: key.accountId, threadId: key.threadId, projectId: project, source: .rule).insert(db)
                    changes.added += 1
                case .ai?:
                    try ThreadProject(accountId: key.accountId, threadId: key.threadId, projectId: project, source: .rule).update(db)
                case .rule?, .manual?:
                    break
                }
            }
            for (project, source) in current where source == .rule && !wanted.contains(project) {
                try db.execute(sql: """
                    DELETE FROM thread_project WHERE accountId = ? AND threadId = ? AND projectId = ?
                    """, arguments: [key.accountId, key.threadId, project])
                changes.removed += 1
            }
        }
        return changes
    }

    static func keyValues(_ keys: [ThreadKey]) -> (String, StatementArguments) {
        var arguments: StatementArguments = []
        for key in keys { _ = arguments.append(contentsOf: [key.accountId, key.threadId]) }
        return (keys.map { _ in "(?, ?)" }.joined(separator: ", "), arguments)
    }
}

extension ProjectRules.Changes {
    fileprivate mutating func merge(_ other: Self) {
        added += other.added
        removed += other.removed
    }
}

/// What rules look at, per thread. Addresses are lowercased.
private struct ThreadFacts {
    var key: ThreadKey
    var subject: String
    var labelIds: Set<String>
    var senders: Set<String> = []
    var recipients: Set<String> = []

    static func load(_ db: Database, _ keys: [ThreadKey], needsMessages: Bool) throws -> [ThreadKey: ThreadFacts] {
        guard !keys.isEmpty else { return [:] }
        let (values, arguments) = ProjectRules.keyValues(keys)
        var facts: [ThreadKey: ThreadFacts] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT accountId, id, subject, labelIds FROM thread WHERE (accountId, id) IN (VALUES \(values))
            """, arguments: arguments) {
            let labels = (try? JSONDecoder().decode([String].self, from: Data((row["labelIds"] as String).utf8))) ?? []
            let key = ThreadKey(accountId: row["accountId"], threadId: row["id"])
            facts[key] = ThreadFacts(key: key, subject: MailText.fold(row["subject"]), labelIds: Set(labels))
        }
        guard needsMessages else { return facts }
        let decoder = JSONDecoder()
        for row in try Row.fetchAll(db, sql: """
            SELECT accountId, threadId, fromEmail, toList, ccList FROM message
            WHERE (accountId, threadId) IN (VALUES \(values)) AND isDraft = 0
            """, arguments: arguments) {
            let key = ThreadKey(accountId: row["accountId"], threadId: row["threadId"])
            guard facts[key] != nil else { continue }
            facts[key]!.senders.insert((row["fromEmail"] as String).lowercased())
            for column in ["toList", "ccList"] {
                let people = (try? decoder.decode([Participant].self, from: Data((row[column] as String).utf8))) ?? []
                for person in people { facts[key]!.recipients.insert(person.email.lowercased()) }
            }
        }
        return facts
    }
}

/// Rules turned into fast checks, grouped by project.
private struct CompiledRules {
    enum Check {
        case from(String)
        case fromDomain(String)
        case toAddress(String)
        case toDomain(String)
        case subject(String)
        /// Label ids per account that the rule's id-or-name resolves to.
        case label([String: Set<String>])
        case account(Set<String>)
        /// Threads the free-text query matches, computed once per evaluation.
        case query(Set<ThreadKey>)
        case never
    }

    var checks: [(projectId: String, check: Check)] = []

    var needsMessages: Bool {
        checks.contains { item in
            switch item.check {
            case .from, .fromDomain, .toAddress, .toDomain: true
            default: false
            }
        }
    }

    func projects(matching thread: ThreadFacts) -> Set<String> {
        var matched = Set<String>()
        for (projectId, check) in checks where !matched.contains(projectId) {
            if Self.matches(check, thread) { matched.insert(projectId) }
        }
        return matched
    }

    private static func matches(_ check: Check, _ thread: ThreadFacts) -> Bool {
        switch check {
        case .from(let address): thread.senders.contains(address)
        case .fromDomain(let domain): thread.senders.contains { MailText.domain(MailText.domain(of: $0), isWithin: domain) }
        case .toAddress(let address): thread.recipients.contains(address)
        case .toDomain(let domain): thread.recipients.contains { MailText.domain(MailText.domain(of: $0), isWithin: domain) }
        case .subject(let text): thread.subject.contains(text)
        case .label(let ids): !(ids[thread.key.accountId] ?? []).isDisjoint(with: thread.labelIds)
        case .account(let ids): ids.contains(thread.key.accountId)
        case .query(let keys): keys.contains(thread.key)
        case .never: false
        }
    }

    static func load(_ db: Database, projectId: String?, scope: [ThreadKey]?) throws -> CompiledRules {
        var request = ProjectRule.order(Column("id"))
        if let projectId { request = request.filter(Column("projectId") == projectId) }
        let rules = try request.fetchAll(db)
        guard !rules.isEmpty else { return CompiledRules() }
        let accounts = try Account.fetchAll(db)
        let labels = try MailLabel.fetchAll(db)

        var compiled = CompiledRules()
        for rule in rules {
            let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let lower = value.lowercased()
            let check: Check
            switch rule.field {
            case .from:
                check = .from(lower)
            case .fromDomain:
                check = .fromDomain(lower.hasPrefix("@") ? String(lower.dropFirst()) : lower)
            case .to:
                check = lower.contains("@") && !lower.hasPrefix("@")
                    ? .toAddress(lower) : .toDomain(lower.hasPrefix("@") ? String(lower.dropFirst()) : lower)
            case .subjectContains:
                check = .subject(MailText.fold(value))
            case .label:
                var ids: [String: Set<String>] = [:]
                for label in labels where label.id == value || label.name.lowercased() == lower {
                    ids[label.accountId, default: []].insert(label.id)
                }
                check = ids.isEmpty ? .never : .label(ids)
            case .account:
                let matched = accounts.filter {
                    $0.id == lower || $0.email.lowercased() == lower || $0.displayName.lowercased() == lower
                }
                check = matched.isEmpty ? .never : .account(Set(matched.map(\.id)))
            case .query:
                check = .query(try FreeTextQuery.threads(db, matching: value, within: scope))
            }
            compiled.checks.append((rule.projectId, check))
        }
        return compiled
    }
}

/// The `query` rule: every word of the free text appears in some message of the thread (FTS5).
private enum FreeTextQuery {
    static func threads(_ db: Database, matching text: String, within scope: [ThreadKey]?) throws -> Set<ThreadKey> {
        let words = text.split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"" }.joined(separator: " ")
        let base = """
            SELECT DISTINCT m.accountId, m.threadId FROM message_fts f JOIN message m ON m.seq = f.rowid
            WHERE message_fts MATCH ?
            """
        var keys = Set<ThreadKey>()
        guard let scope else {
            for row in try Row.fetchAll(db, sql: base, arguments: [match]) {
                keys.insert(ThreadKey(accountId: row[0], threadId: row[1]))
            }
            return keys
        }
        for chunk in scope.chunked(by: 400) {
            let (values, arguments) = ProjectRules.keyValues(chunk)
            var all: StatementArguments = [match]
            _ = all.append(contentsOf: arguments)
            for row in try Row.fetchAll(db, sql: base + " AND (m.accountId, m.threadId) IN (VALUES \(values))", arguments: all) {
                keys.insert(ThreadKey(accountId: row[0], threadId: row[1]))
            }
        }
        return keys
    }
}

fileprivate extension Array {
    func chunked(by size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
