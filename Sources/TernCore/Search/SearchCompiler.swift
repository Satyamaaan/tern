import Foundation
import GRDB

public enum SearchSort: Sendable {
    /// Most recently active thread first.
    case newest
    /// Best bm25 match first (subject counts most, then sender, recipients, snippet and body), later-stored
    /// messages first among equals. A query whose words match over 20,000 messages (`the`, `th`) has nothing to
    /// rank by and is returned newest first.
    case relevance
}

public struct SearchOptions: Sendable {
    /// Restrict to one account (nil: every account).
    public var accountId: String?
    public var limit: Int
    public var sort: SearchSort
    /// What `older_than:` / `newer_than:` count back from.
    public var now: Date
    /// Where `before:` / `after:` days start.
    public var timeZone: TimeZone

    public init(accountId: String? = nil, limit: Int = 100, sort: SearchSort = .newest, now: Date = Date(), timeZone: TimeZone = .current) {
        self.accountId = accountId
        self.limit = limit
        self.sort = sort
        self.now = now
        self.timeZone = timeZone
    }
}

/// A query reduced to what the executor needs. Message-level SQL refers to the message as `m`, thread-level
/// SQL to the thread as `t`.
struct CompiledSearch {
    enum Driver {
        /// Walk `thread_label` for this label id, newest first.
        case label(String)
        /// A small set of candidate threads (`SELECT … AS a, … AS i`, distinct), then sorted.
        case set(SQLFragment)
    }

    /// FTS5 MATCH expression for the words, with its negations.
    var fts: String?
    var messageConds: [SQLFragment] = []
    var threadConds: [SQLFragment] = []
    var drivers: [Driver] = []
    var lastDateMin: Double?
    var lastDateMax: Double?
    var accountIds: [String]?
    /// Marks free-text terms in a message body excerpt.
    var bodyHighlighter: SearchHighlighter
    /// Marks free-text terms and `subject:` values in a subject.
    var subjectHighlighter: SearchHighlighter
    /// First word of each positive text term, lowercased ASCII: where to excerpt a body from.
    var bodyTerms: [String] = []
    /// Microseconds to test one message against every full-text expression the query probes with (the planner
    /// avoids per-message tests when this is high).
    var probeCost = 0.0

    var hasMessageConditions: Bool { fts != nil || !messageConds.isEmpty }

    var isImpossible: Bool {
        messageConds.contains(where: \.isNever) || threadConds.contains(where: \.isNever) || accountIds?.isEmpty == true
    }
}

/// Resolves label, project and account names against the database while compiling.
final class SearchCompiler {
    private let db: Database
    private let options: SearchOptions
    private var accountsCache: [Account]?
    private var labelsCache: [(accountId: String, id: String, name: String)]?
    private var projectsCache: [(id: String, name: String)]?
    private var messageProbeCost = 0.0

    init(_ db: Database, options: SearchOptions) {
        self.db = db
        self.options = options
    }

    // MARK: Entry

    func compile(_ query: SearchQuery) throws -> CompiledSearch? {
        guard let root = query.root else { return nil }
        var compiled = CompiledSearch(
            bodyHighlighter: query.highlighter(text: true, fields: []),
            subjectHighlighter: query.highlighter(text: true, fields: [.subject]))
        var positives: [String] = []
        var negatives: [String] = []
        var accountIds: Set<String>? = options.accountId.map { [$0] }

        for conjunct in root.conjuncts {
            if isThreadLevel(conjunct) {
                compiled.threadConds.append(try threadSQL(conjunct, "t"))
                try noteAccessPaths(of: conjunct, in: &compiled, accountIds: &accountIds)
            } else if let expression = try fts(conjunct) {
                positives.append(expression)
            } else if case .not(let inner) = conjunct, let expression = try fts(inner) {
                negatives.append(expression)
            } else {
                compiled.messageConds.append(try messageSQL(conjunct))
                try noteMessageAccessPaths(of: conjunct, in: &compiled, positives: &positives)
            }
        }

        if positives.isEmpty {
            // A query of only negations has nothing to look up; test each message instead.
            if !negatives.isEmpty { compiled.messageConds.append(probe(Self.anyOf(negatives)).negated) }
        } else {
            compiled.fts = Self.join(positives: positives, negatives: negatives)
        }

        if let accountIds {
            compiled.accountIds = accountIds.sorted()
            let list = SQLFragment.list(accountIds.sorted())
            compiled.threadConds.append(accountIds.isEmpty ? .never : SQLFragment("t.accountId IN \(list.sql)", list.arguments))
            compiled.messageConds.append(accountIds.isEmpty ? .never : SQLFragment("m.accountId IN \(list.sql)", list.arguments))
        }
        compiled.bodyTerms = bodyTerms(of: root)
        compiled.probeCost = (compiled.fts.map(Self.probeCost(of:)) ?? 0) + messageProbeCost
        if !query.includesTrashOrSpam {
            compiled.threadConds.append(SQLFragment("""
                NOT EXISTS (SELECT 1 FROM thread_label hide WHERE hide.accountId = t.accountId \
                AND hide.threadId = t.id AND hide.labelId IN ('TRASH', 'SPAM'))
                """))
        }
        return compiled
    }

    // MARK: Classification

    private func isThreadLevel(_ expr: SearchExpr) -> Bool {
        switch expr {
        case .filter(let filter):
            switch filter {
            case .hasAttachment, .larger, .smaller: false
            default: true
            }
        case .and(let children), .or(let children): children.allSatisfy(isThreadLevel)
        case .not(let child): isThreadLevel(child)
        case .text, .field: false
        }
    }

    /// Notes how a top-level thread-level condition can narrow the search: a label or small table to start
    /// from, a date range, an account.
    private func noteAccessPaths(of expr: SearchExpr, in compiled: inout CompiledSearch, accountIds: inout Set<String>?) throws {
        guard case .filter(let filter) = expr else { return }
        switch filter {
        case .unread: compiled.drivers.append(.label(SystemLabel.unread))
        case .starred: compiled.drivers.append(.label(SystemLabel.starred))
        case .important: compiled.drivers.append(.label(SystemLabel.important))
        case .folder(let folder):
            switch folder {
            case .inbox: compiled.drivers.append(.label(SystemLabel.inbox))
            case .sent: compiled.drivers.append(.label(SystemLabel.sent))
            case .drafts: compiled.drivers.append(.label(SystemLabel.draft))
            case .trash: compiled.drivers.append(.label(SystemLabel.trash))
            case .spam: compiled.drivers.append(.label(SystemLabel.spam))
            case .anywhere: break
            }
        case .label(let name):
            if let id = try labelDriverId(name) { compiled.drivers.append(.label(id)) }
        case .snoozed:
            compiled.drivers.append(.set(SQLFragment("SELECT accountId AS a, threadId AS i FROM snooze")))
        case .needsReply:
            compiled.drivers.append(.set(SQLFragment("SELECT accountId AS a, threadId AS i FROM thread_ai WHERE needsReply = 1")))
        case .category(let category):
            compiled.drivers.append(.set(SQLFragment(
                "SELECT accountId AS a, threadId AS i FROM thread_ai WHERE category = ?", [category.rawValue])))
        case .project(let name):
            let ids = try projectIds(matching: name)
            if !ids.isEmpty {
                let list = SQLFragment.list(ids)
                compiled.drivers.append(.set(SQLFragment(
                    "SELECT DISTINCT accountId AS a, threadId AS i FROM thread_project WHERE projectId IN \(list.sql)", list.arguments)))
            }
        case .before(let day): tighten(&compiled, max: day.startOfDay(in: options.timeZone).timeIntervalSince1970)
        case .after(let day): tighten(&compiled, min: day.startOfDay(in: options.timeZone).timeIntervalSince1970)
        case .olderThan(let duration): tighten(&compiled, max: options.now.timeIntervalSince1970 - duration.seconds)
        case .newerThan(let duration): tighten(&compiled, min: options.now.timeIntervalSince1970 - duration.seconds)
        case .account(let value):
            let ids = Set(try matchingAccountIds(value))
            accountIds = accountIds.map { $0.intersection(ids) } ?? ids
        case .read, .hasAttachment, .larger, .smaller: break
        }
    }

    private func tighten(_ compiled: inout CompiledSearch, min: Double? = nil, max: Double? = nil) {
        if let min { compiled.lastDateMin = Swift.max(compiled.lastDateMin ?? min, min) }
        if let max { compiled.lastDateMax = Swift.min(compiled.lastDateMax ?? max, max) }
    }

    private func noteMessageAccessPaths(of expr: SearchExpr, in compiled: inout CompiledSearch, positives: inout [String]) throws {
        switch expr {
        case .filter(.hasAttachment):
            compiled.threadConds.append(SQLFragment("t.hasAttachments = 1"))
        case .filter(.larger(let bytes)):
            compiled.drivers.append(.set(SQLFragment("""
                SELECT DISTINCT accountId AS a, threadId AS i FROM message INDEXED BY message_by_size WHERE sizeEstimate > ?
                """, [bytes])))
        case .field(.filename, let text):
            guard !text.value.isEmpty else { return }
            compiled.drivers.append(.set(SQLFragment("""
                SELECT DISTINCT m.accountId AS a, m.threadId AS i FROM attachment x \
                CROSS JOIN message m ON m.accountId = x.accountId AND m.id = x.messageId \
                WHERE x.filename LIKE ? ESCAPE '\\'
                """, [SearchSQL.containsPattern(text.value)])))
        case .field(.cc, let text), .field(.bcc, let text):
            // The index only knows "recipients"; use it to find candidates, the list column to confirm.
            if let phrase = phrase(text) { positives.append("searchRecipients : \(phrase)") }
        default: break
        }
    }

    // MARK: Full-text expressions

    /// The FTS5 expression for `expr`, if every part of it can be answered by the index.
    func fts(_ expr: SearchExpr) throws -> String? {
        switch expr {
        case .text(let text):
            return phrase(text)
        case .field(let field, let text):
            switch field {
            case .from:
                if Self.isMe(text) { return nil }
                return phrase(text).map { "searchSender : \($0)" }
            case .to:
                if Self.isMe(text) { return nil }
                return phrase(text).map { "searchRecipients : \($0)" }
            case .subject:
                return phrase(text).map { "subject : \($0)" }
            case .cc, .bcc, .filename:
                return nil
            }
        case .filter:
            return nil
        case .and(let children):
            var positives: [String] = []
            var negatives: [String] = []
            for child in children {
                if let expression = try fts(child) {
                    positives.append(expression)
                } else if case .not(let inner) = child, let expression = try fts(inner) {
                    negatives.append(expression)
                } else {
                    return nil
                }
            }
            return positives.isEmpty ? nil : Self.join(positives: positives, negatives: negatives)
        case .or(let children):
            var parts: [String] = []
            for child in children {
                guard let expression = try fts(child) else { return nil }
                parts.append(expression)
            }
            return parts.isEmpty ? nil : Self.anyOf(parts)
        case .not:
            return nil
        }
    }

    /// One quoted FTS5 phrase. Only letters and digits survive tokenizing, so nothing typed can become FTS5
    /// syntax (no operators, column filters, `NEAR`, `*` or quotes).
    func phrase(_ text: SearchText) -> String? {
        let tokens = text.tokens
        guard !tokens.isEmpty else { return nil }
        let quoted = tokens.joined(separator: " ").replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(quoted)\"" + (text.isPrefix ? "*" : "")
    }

    static func anyOf(_ parts: [String]) -> String {
        parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " OR ") + ")"
    }

    static func join(positives: [String], negatives: [String]) -> String {
        var expression = positives.count == 1 ? positives[0] : "(" + positives.joined(separator: " AND ") + ")"
        if !negatives.isEmpty { expression = "(\(expression) NOT \(anyOf(negatives)))" }
        return expression
    }

    private static func isMe(_ text: SearchText) -> Bool {
        !text.isPhrase && text.value.lowercased() == "me"
    }

    private func probe(_ expression: String) -> SQLFragment {
        messageProbeCost += Self.probeCost(of: expression)
        return SearchExecutor.probe(expression)
    }

    /// Microseconds for the index to test one message against `expression` (measured on a 12-segment index):
    /// ~17 per word, and ~230 more for a prefix of four letters or more, which has no prefix index.
    static func probeCost(of expression: String) -> Double {
        var cost = 0.0
        var rest = expression[...]
        // Every phrase is "word word…", optionally followed by *; nothing else in the expression is quoted.
        while let open = rest.firstIndex(of: "\""), let close = rest[rest.index(after: open)...].firstIndex(of: "\"") {
            let words = rest[rest.index(after: open)..<close].split(separator: " ")
            cost += 17 * Double(words.count)
            let next = rest.index(after: close)
            if next < rest.endIndex, rest[next] == "*", (words.last?.count ?? 0) >= 4 { cost += 230 }
            rest = rest[next...]
        }
        return cost
    }

    // MARK: Message-level SQL (alias `m`)

    private func messageSQL(_ expr: SearchExpr) throws -> SQLFragment {
        if let expression = try fts(expr) { return probe(expression) }
        switch expr {
        case .text:
            return .always
        case .field(let field, let text):
            switch field {
            case .from:
                return Self.isMe(text) ? SQLFragment("m.isFromMe = 1") : .always
            case .to:
                guard Self.isMe(text) else { return .always }
                // Any of your own addresses among the recipients; a substring test is cheaper than the index here.
                let tests = try accounts().flatMap { account in
                    ["toList", "ccList", "bccList"].map {
                        SQLFragment("m.\($0) LIKE ? ESCAPE '\\'", [SearchSQL.containsPattern(account.email)])
                    }
                }
                return .any(tests)
            case .cc:
                return SQLFragment("m.ccList LIKE ? ESCAPE '\\'", [SearchSQL.containsPattern(text.value)])
            case .bcc:
                return SQLFragment("m.bccList LIKE ? ESCAPE '\\'", [SearchSQL.containsPattern(text.value)])
            case .filename:
                return SQLFragment("""
                    EXISTS (SELECT 1 FROM attachment x WHERE x.accountId = m.accountId AND x.messageId = m.id \
                    AND x.filename LIKE ? ESCAPE '\\')
                    """, [SearchSQL.containsPattern(text.value)])
            case .subject:
                return .always
            }
        case .filter(let filter):
            switch filter {
            case .hasAttachment: return SQLFragment("m.hasAttachments = 1")
            case .larger(let bytes): return SQLFragment("m.sizeEstimate > ?", [bytes])
            case .smaller(let bytes): return SQLFragment("m.sizeEstimate < ?", [bytes])
            default:
                let inner = try threadPredicate(filter, "tt")
                if inner.isNever || inner.isAlways { return inner }
                return SQLFragment(
                    "EXISTS (SELECT 1 FROM thread tt WHERE tt.accountId = m.accountId AND tt.id = m.threadId AND \(inner.sql))",
                    inner.arguments.map { $0 as any DatabaseValueConvertible })
            }
        case .and(let children):
            return .all(try children.map(messageSQL))
        case .or(let children):
            return .any(try children.map(messageSQL))
        case .not(let child):
            return try messageSQL(child).negated
        }
    }

    // MARK: Thread-level SQL (alias passed in)

    private func threadSQL(_ expr: SearchExpr, _ t: String) throws -> SQLFragment {
        switch expr {
        case .filter(let filter): return try threadPredicate(filter, t)
        case .and(let children): return .all(try children.map { try threadSQL($0, t) })
        case .or(let children): return .any(try children.map { try threadSQL($0, t) })
        case .not(let child): return try threadSQL(child, t).negated
        case .text, .field: return .always
        }
    }

    private func hasLabel(_ t: String, _ id: String) -> SQLFragment {
        SQLFragment("""
            EXISTS (SELECT 1 FROM thread_label x WHERE x.accountId = \(t).accountId AND x.threadId = \(t).id \
            AND x.labelId = ?)
            """, [id])
    }

    private func threadPredicate(_ filter: SearchFilter, _ t: String) throws -> SQLFragment {
        switch filter {
        case .unread: return hasLabel(t, SystemLabel.unread)
        case .read: return hasLabel(t, SystemLabel.unread).negated
        case .starred: return hasLabel(t, SystemLabel.starred)
        case .important: return hasLabel(t, SystemLabel.important)
        case .snoozed:
            return SQLFragment("EXISTS (SELECT 1 FROM snooze sn WHERE sn.accountId = \(t).accountId AND sn.threadId = \(t).id)")
        case .needsReply:
            return SQLFragment("""
                EXISTS (SELECT 1 FROM thread_ai ai WHERE ai.accountId = \(t).accountId AND ai.threadId = \(t).id \
                AND ai.needsReply = 1)
                """)
        case .folder(let folder):
            switch folder {
            case .inbox: return hasLabel(t, SystemLabel.inbox)
            case .sent: return hasLabel(t, SystemLabel.sent)
            case .drafts: return hasLabel(t, SystemLabel.draft)
            case .trash: return hasLabel(t, SystemLabel.trash)
            case .spam: return hasLabel(t, SystemLabel.spam)
            case .anywhere: return .always
            }
        case .label(let name):
            return try labelPredicate(name, t)
        case .before(let day):
            return SQLFragment("\(t).lastDate < ?", [day.startOfDay(in: options.timeZone).timeIntervalSince1970])
        case .after(let day):
            return SQLFragment("\(t).lastDate >= ?", [day.startOfDay(in: options.timeZone).timeIntervalSince1970])
        case .olderThan(let duration):
            return SQLFragment("\(t).lastDate < ?", [options.now.timeIntervalSince1970 - duration.seconds])
        case .newerThan(let duration):
            return SQLFragment("\(t).lastDate >= ?", [options.now.timeIntervalSince1970 - duration.seconds])
        case .category(let category):
            return SQLFragment("""
                EXISTS (SELECT 1 FROM thread_ai ai WHERE ai.accountId = \(t).accountId AND ai.threadId = \(t).id \
                AND ai.category = ?)
                """, [category.rawValue])
        case .project(let name):
            let ids = try projectIds(matching: name)
            guard !ids.isEmpty else { return .never }
            let list = SQLFragment.list(ids)
            return SQLFragment("""
                EXISTS (SELECT 1 FROM thread_project tp WHERE tp.accountId = \(t).accountId AND tp.threadId = \(t).id \
                AND tp.projectId IN \(list.sql))
                """, list.arguments.map { $0 as any DatabaseValueConvertible })
        case .account(let value):
            let ids = try matchingAccountIds(value)
            guard !ids.isEmpty else { return .never }
            let list = SQLFragment.list(ids)
            return SQLFragment("\(t).accountId IN \(list.sql)", list.arguments.map { $0 as any DatabaseValueConvertible })
        case .hasAttachment, .larger, .smaller:
            return .always
        }
    }

    // MARK: Names

    private func accounts() throws -> [Account] {
        if let accountsCache { return accountsCache }
        let loaded = try Account.fetchAll(db)
        accountsCache = loaded
        return loaded
    }

    private func labels() throws -> [(accountId: String, id: String, name: String)] {
        if let labelsCache { return labelsCache }
        let loaded = try Row.fetchAll(db, sql: "SELECT accountId, id, name FROM label").map {
            (accountId: $0["accountId"] as String, id: $0["id"] as String, name: $0["name"] as String)
        }
        labelsCache = loaded
        return loaded
    }

    private func projects() throws -> [(id: String, name: String)] {
        if let projectsCache { return projectsCache }
        let loaded = try Row.fetchAll(db, sql: "SELECT id, name FROM project").map {
            (id: $0["id"] as String, name: $0["name"] as String)
        }
        projectsCache = loaded
        return loaded
    }

    /// Label ids a typed label (id or name, any case) can refer to, per account.
    private func matchingLabels(_ value: String) throws -> [(accountId: String, id: String)] {
        let normalized = SearchSQL.normalizedName(value)
        let lower = value.lowercased()
        return try labels().filter { SearchSQL.normalizedName($0.name) == normalized || $0.id.lowercased() == lower }
            .map { (accountId: $0.accountId, id: $0.id) }
    }

    /// One branch per account, each with the account as a constant, so every branch is a primary-key lookup
    /// in `thread_label (accountId, labelId, threadId)`. Ids that look like the typed text work even with no
    /// label rows (`label:INBOX`); names need the label table, and mean different ids in different accounts.
    private func labelPredicate(_ value: String, _ t: String) throws -> SQLFragment {
        let typedIds = [value, value.uppercased()]
        let byAccount = Dictionary(grouping: try matchingLabels(value), by: \.accountId)
        let branches: [SQLFragment] = try accounts().map { account in
            let ids = Array(Set(typedIds + (byAccount[account.id] ?? []).map(\.id))).sorted()
            let list = SQLFragment.list(ids)
            return SQLFragment("""
                \(t).accountId = ? AND EXISTS (SELECT 1 FROM thread_label x WHERE x.accountId = ? \
                AND x.labelId IN \(list.sql) AND x.threadId = \(t).id)
                """, [account.id, account.id] + list.arguments.map { $0 as any DatabaseValueConvertible })
        }
        return .any(branches)
    }

    /// First word of each positive free-text term that can be found in a body with `instr(lower(…))`.
    private func bodyTerms(of expr: SearchExpr) -> [String] {
        var terms: [String] = []
        func visit(_ expr: SearchExpr) {
            switch expr {
            case .text(let text):
                if let word = text.tokens.first?.lowercased(), word.utf8.allSatisfy({ $0 < 0x80 }), !terms.contains(word) {
                    terms.append(word)
                }
            case .and(let children), .or(let children): children.forEach(visit)
            case .field, .filter, .not: break
            }
        }
        visit(expr)
        return Array(terms.prefix(4))
    }

    /// The single label id to walk when a typed label means the same id in every account.
    private func labelDriverId(_ value: String) throws -> String? {
        let ids = Set(try matchingLabels(value).map(\.id))
        if ids.count == 1 { return ids.first }
        if ids.isEmpty, SystemLabel.all.contains(value.uppercased()) { return value.uppercased() }
        return nil
    }

    private func projectIds(matching value: String) throws -> [String] {
        let normalized = SearchSQL.normalizedName(value)
        guard !normalized.isEmpty else { return [] }
        let all = try projects()
        let exact = all.filter { SearchSQL.normalizedName($0.name) == normalized || $0.id == value }
        if !exact.isEmpty { return exact.map(\.id) }
        return all.filter { SearchSQL.normalizedName($0.name).hasPrefix(normalized) }.map(\.id)
    }

    private func matchingAccountIds(_ value: String) throws -> [String] {
        let lower = value.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return [] }
        let all = try accounts()
        let exact = all.filter { $0.email.lowercased() == lower || $0.displayName.lowercased() == lower || $0.id == lower }
        if !exact.isEmpty { return exact.map(\.id) }
        let prefix = all.filter { $0.email.lowercased().hasPrefix(lower) || $0.displayName.lowercased().hasPrefix(lower) }
        if !prefix.isEmpty { return prefix.map(\.id) }
        return all.filter { $0.email.lowercased().contains(lower) || $0.displayName.lowercased().contains(lower) }.map(\.id)
    }
}
