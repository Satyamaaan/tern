import Foundation
import GRDB

/// Validated model evidence. Validation lives at the AI boundary; merging lives with ledger writes.
public struct LedgerExtraction: Sendable {
    public var direction: LedgerDirection
    public var counterparty: String
    public var counterpartyName: String = ""
    public var deliverable: String
    public var sourceMessageId: String
    public var quote: String
    public var sourceDate: Date
    public var dueAt: Date?
    public var dueText: String?
    public var confidence: Int
    public var existingId: Int64?

    public init(direction: LedgerDirection, counterparty: String, deliverable: String, sourceMessageId: String,
                quote: String, sourceDate: Date, dueAt: Date?, dueText: String?, confidence: Int, existingId: Int64?) {
        self.direction = direction; self.counterparty = counterparty; self.deliverable = deliverable
        self.sourceMessageId = sourceMessageId; self.quote = quote; self.sourceDate = sourceDate
        self.dueAt = dueAt; self.dueText = dueText; self.confidence = confidence; self.existingId = existingId
    }
}

extension Ledger {
    private static let stopwords: Set<String> = ["a", "an", "the", "to", "of", "for", "by", "my", "your", "me", "you", "i", "please", "will", "can", "could", "and", "in", "on"]
    public static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(stopwords)
    }

    /// Refines existing items without undoing a user's decision or reopening a completed item.
    public static func applyExtraction(_ db: Database, key: ThreadKey, items: [LedgerExtraction],
                                       messageCount: Int, promptVersion: Int, origin: String, now: Date = Date()) throws {
        let settings = try LedgerSettings.load(db)
        for value in items.sorted(by: { ($0.sourceDate, $0.sourceMessageId) < ($1.sourceDate, $1.sourceMessageId) }) {
            let rows = try Commitment.filter(Column("accountId") == key.accountId && Column("threadId") == key.threadId).fetchAll(db)
            let words = tokens(value.deliverable)
            let ordered = value.deliverable.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
            let fingerprint = "\(value.direction.rawValue)|\(value.counterparty.lowercased())|\(ordered.isEmpty ? value.deliverable : ordered)|\(value.sourceMessageId)"
            func overlap(_ row: Commitment) -> Bool {
                let a = row.sourceQuote.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let b = value.quote.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return !a.isEmpty && !b.isEmpty && (a.contains(b) || b.contains(a))
            }
            func sharesEvidence(_ row: Commitment) -> Bool {
                if overlap(row) { return true }
                func phrases(_ text: String) -> Set<String> {
                    let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
                        .map(String.init).filter { !stopwords.contains($0) }
                    guard words.count >= 3 else { return [] }
                    return Set((0...(words.count - 3)).map { words[$0..<($0 + 3)].joined(separator: " ") })
                }
                return !phrases(row.sourceQuote).intersection(phrases(value.quote)).isEmpty
            }
            let candidates = rows.filter { row in
                row.direction == value.direction && row.counterpartyEmail.lowercased() == value.counterparty.lowercased()
            }
            let existing = candidates.first { $0.state != .open && $0.sourceMessageId == value.sourceMessageId && overlap($0) }
                ?? candidates.filter { row in
                    guard row.state == .open else { return false }
                    if let id = value.existingId { return row.id == id }
                    if row.fingerprint == fingerprint { return true }
                    if row.sourceMessageId == value.sourceMessageId && row.kind == "reply" { return true }
                    let other = tokens(row.deliverable)
                    return (row.sourceMessageId == value.sourceMessageId || sharesEvidence(row)) &&
                        Double(words.intersection(other).count) / Double(max(1, words.union(other).count)) >= 0.67
                }.max { left, right in
                    func score(_ row: Commitment) -> Double {
                        if row.id == value.existingId { return 3 }
                        let other = tokens(row.deliverable)
                        return Double(words.intersection(other).count) / Double(max(1, words.union(other).count))
                    }
                    return score(left) < score(right)
                }
            let contact = try String.fetchOne(db, sql: "SELECT name FROM contact WHERE id=?", arguments: [value.counterparty.lowercased()]) ?? ""
            let name = !value.counterpartyName.isEmpty ? value.counterpartyName : !contact.isEmpty ? contact : value.counterparty
            let deliverable = value.deliverable.prefix(1).uppercased() + value.deliverable.dropFirst()
            let surface = value.direction == .iOwe || value.dueAt != nil ? value.sourceDate : value.sourceDate.addingTimeInterval(Double(settings.waitingDays) * 86_400)
            if var item = existing {
                guard !rows.contains(where: { $0.id != item.id && $0.fingerprint == fingerprint }) else { continue }
                guard item.state == .open, item.stateSource != "user", item.direction == value.direction,
                      item.counterpartyEmail.lowercased() == value.counterparty.lowercased() else { continue }
                if let due = value.dueAt, item.dueAt != due, let old = item.dueAt {
                    item.resolutionNote = "Previous due date: \(old.formatted(.iso8601.year().month().day()))"
                }
                if item.counterpartyName.isEmpty { item.counterpartyName = name }
                item.kind = "deliverable"; item.deliverable = deliverable
                item.dueAt = value.dueAt ?? item.dueAt; item.dueText = value.dueText ?? item.dueText; item.origin = origin
                item.stateSource = "ai"; item.confidence = max(item.confidence, value.confidence)
                if value.sourceDate < item.sourceDate {
                    item.sourceMessageId = value.sourceMessageId; item.sourceDate = value.sourceDate; item.sourceQuote = value.quote
                }
                if let hintAt = item.hintAt, hintAt <= value.sourceDate {
                    item.hintMessageId = nil; item.hintAt = nil
                }
                item.surfaceAt = item.direction == .iOwe || item.dueAt != nil ? item.sourceDate : item.sourceDate.addingTimeInterval(Double(settings.waitingDays) * 86_400)
                item.surfaced = item.surfaceAt <= now; item.updatedAt = now
                item.fingerprint = fingerprint
                try item.update(db)
            } else {
                let item = Commitment(id: nil, accountId: key.accountId, threadId: key.threadId, direction: value.direction,
                    kind: "deliverable", counterpartyEmail: value.counterparty.lowercased(), counterpartyName: name,
                    deliverable: deliverable, dueAt: value.dueAt, dueText: value.dueText, sourceMessageId: value.sourceMessageId,
                    sourceQuote: value.quote, sourceDate: value.sourceDate, origin: origin, confidence: value.confidence,
                    state: .open, stateSource: "ai", resolvedMessageId: nil, resolvedAt: nil, resolutionNote: nil,
                    hintMessageId: nil, hintAt: nil, checkedCount: 0, surfaceAt: surface, surfaced: surface <= now,
                    fingerprint: fingerprint, createdAt: now, updatedAt: now)
                try item.insert(db)
            }
        }
        try recordScan(db, key: key, messageCount: messageCount, promptVersion: promptVersion, origin: origin, now: now)
        try refreshHints(db, keys: [key], now: now)
    }

    /// Stores validated resolution evidence for later confirmation. It never changes the item's state.
    public static func applyResolutionHint(_ db: Database, id: Int64, messageId: String?, at date: Date?,
                                           note: String?, newDueAt: Date?, now: Date) throws {
        guard var item = try Commitment.fetchOne(db, key: id), item.state == .open, item.stateSource != "user" else { return }
        if messageId != nil, let due = newDueAt, item.dueAt != due {
            if let old = item.dueAt { item.resolutionNote = "Previous due date: \(old.formatted(.iso8601.year().month().day()))" }
            item.dueAt = due
        }
        if let messageId, let date {
            item.hintMessageId = messageId; item.hintAt = date
            if let note, !(item.resolutionNote ?? "").components(separatedBy: "\n").contains(note) { item.resolutionNote = [item.resolutionNote, note].compactMap { $0 }.joined(separator: "\n") }
        }
        item.updatedAt = now
        try item.update(db)
    }

    /// Records exactly the message version inspected by a scan or skipped by the cue filter.
    public static func recordScan(_ db: Database, key: ThreadKey, messageCount: Int, promptVersion: Int, origin: String, now: Date) throws {
        try LedgerScan(accountId: key.accountId, threadId: key.threadId, messageCount: messageCount,
                       scannedAt: now, origin: origin, promptVersion: promptVersion).upsert(db)
    }

    /// A later reply is evidence to review, never proof that a deliverable arrived.
    static func refreshHints(_ db: Database, keys: some Collection<ThreadKey>, now: Date) throws {
        guard !keys.isEmpty, try LedgerSettings.load(db).enabled else { return }
        let pairs = keys.map { _ in "(?,?)" }.joined(separator: ",")
        let arguments = StatementArguments(keys.flatMap { [$0.accountId, $0.threadId] })
        let items = try Commitment.fetchAll(db, sql: """
            SELECT * FROM commitment WHERE (accountId,threadId) IN (VALUES \(pairs))
              AND origin!='rule' AND state='open' AND stateSource!='user' AND hintMessageId IS NULL
            """, arguments: arguments)
        for item in items {
            let key = ThreadKey(accountId: item.accountId, threadId: item.threadId)
            let person = item.counterpartyEmail.lowercased()
            let reply = try Row.fetchOne(db, sql: """
                SELECT id,date FROM message
                WHERE accountId=? AND threadId=? AND date>? AND isDraft=0
                  AND ((?='waitingOn' AND isFromMe=0 AND lower(fromEmail)=?)
                    OR (?='iOwe' AND isFromMe=1 AND EXISTS (
                      SELECT 1 FROM json_each(message.toList) r WHERE lower(json_extract(r.value,'$.email'))=?
                      UNION ALL SELECT 1 FROM json_each(message.ccList) r WHERE lower(json_extract(r.value,'$.email'))=?)))
                ORDER BY date,id LIMIT 1
                """, arguments: [key.accountId, key.threadId, item.sourceDate.timeIntervalSince1970,
                    item.direction.rawValue, person, item.direction.rawValue, person, person])
            if let reply {
                let id: String = reply["id"]
                let date: Double = reply["date"]
                try db.execute(sql: "UPDATE commitment SET hintMessageId=?,hintAt=?,updatedAt=? WHERE id=?",
                    arguments: [id, date, now.timeIntervalSince1970, item.id])
            }
        }
    }
}
