import Foundation
import GRDB

/// Validated model evidence. Validation lives at the AI boundary; merging lives with ledger writes.
public struct LedgerExtraction: Sendable {
    public var direction: LedgerDirection
    public var counterparty: String
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
    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(stopwords)
    }

    /// Refines existing items without undoing a user's decision or reopening a completed item.
    public static func applyExtraction(_ db: Database, key: ThreadKey, items: [LedgerExtraction],
                                       messageCount: Int, promptVersion: Int, origin: String, now: Date = Date()) throws {
        let settings = try LedgerSettings.load(db)
        for value in items {
            let rows = try Commitment.filter(Column("accountId") == key.accountId && Column("threadId") == key.threadId).fetchAll(db)
            let words = tokens(value.deliverable)
            let fingerprint = "\(value.direction.rawValue)|\(value.counterparty.lowercased())|" + words.sorted().prefix(6).joined(separator: " ")
            let existing = rows.first { row in
                if let id = value.existingId { return row.id == id }
                guard row.direction == value.direction, row.counterpartyEmail.lowercased() == value.counterparty.lowercased() else { return false }
                if row.fingerprint == fingerprint { return true }
                if row.sourceMessageId == value.sourceMessageId && (row.kind == "reply" || row.sourceQuote.lowercased() == value.quote.lowercased()) { return true }
                let other = tokens(row.deliverable)
                return Double(words.intersection(other).count) / Double(max(1, words.union(other).count)) >= 0.5
            }
            let surface = value.direction == .iOwe || value.dueAt != nil ? value.sourceDate : value.sourceDate.addingTimeInterval(Double(settings.waitingDays) * 86_400)
            if var item = existing {
                guard !rows.contains(where: { $0.id != item.id && $0.fingerprint == fingerprint }) else { continue }
                guard item.state == .open, item.stateSource != "user", item.direction == value.direction,
                      item.counterpartyEmail.lowercased() == value.counterparty.lowercased() else { continue }
                if item.dueAt != value.dueAt, let old = item.dueAt {
                    item.resolutionNote = "Previous due date: \(old.formatted(.iso8601.year().month().day()))"
                }
                item.kind = "deliverable"; item.deliverable = value.deliverable
                item.dueAt = value.dueAt; item.dueText = value.dueText; item.origin = origin
                item.stateSource = "ai"; item.confidence = value.confidence
                item.sourceMessageId = value.sourceMessageId; item.sourceDate = value.sourceDate; item.sourceQuote = value.quote
                if let hintAt = item.hintAt, hintAt <= value.sourceDate {
                    item.hintMessageId = nil; item.hintAt = nil
                }
                item.surfaceAt = surface; item.surfaced = surface <= now; item.updatedAt = now
                item.fingerprint = fingerprint
                try item.update(db)
            } else {
                let name = try String.fetchOne(db, sql: "SELECT name FROM contact WHERE id=?", arguments: [value.counterparty.lowercased()]) ?? ""
                let item = Commitment(id: nil, accountId: key.accountId, threadId: key.threadId, direction: value.direction,
                    kind: "deliverable", counterpartyEmail: value.counterparty.lowercased(), counterpartyName: name,
                    deliverable: value.deliverable, dueAt: value.dueAt, dueText: value.dueText, sourceMessageId: value.sourceMessageId,
                    sourceQuote: value.quote, sourceDate: value.sourceDate, origin: origin, confidence: value.confidence,
                    state: .open, stateSource: "ai", resolvedMessageId: nil, resolvedAt: nil, resolutionNote: nil,
                    hintMessageId: nil, hintAt: nil, checkedCount: 0, surfaceAt: surface, surfaced: surface <= now,
                    fingerprint: fingerprint, createdAt: now, updatedAt: now)
                try item.insert(db, onConflict: .ignore)
            }
        }
        try recordScan(db, key: key, messageCount: messageCount, promptVersion: promptVersion, origin: origin, now: now)
        try refreshHints(db, keys: [key], now: now)
    }

    /// Stores validated resolution evidence for later confirmation. It never changes the item's state.
    public static func applyResolutionHint(_ db: Database, id: Int64, messageId: String?, at date: Date?,
                                           note: String?, newDueAt: Date?, now: Date) throws {
        guard var item = try Commitment.fetchOne(db, key: id), item.state == .open, item.stateSource != "user" else { return }
        if let due = newDueAt, item.dueAt != due {
            if let old = item.dueAt { item.resolutionNote = "Previous due date: \(old.formatted(.iso8601.year().month().day()))" }
            item.dueAt = due
        }
        if let messageId, let date {
            item.hintMessageId = messageId; item.hintAt = date
            if let note { item.resolutionNote = [item.resolutionNote, note].compactMap { $0 }.joined(separator: "\n") }
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
        guard !keys.isEmpty else { return }
        let pairs = keys.map { _ in "(?,?)" }.joined(separator: ",")
        let arguments = StatementArguments(keys.flatMap { [$0.accountId, $0.threadId] })
        let items = try Commitment.fetchAll(db, sql: """
            SELECT * FROM commitment WHERE (accountId,threadId) IN (VALUES \(pairs))
              AND origin!='rule' AND state='open' AND stateSource!='user' AND hintMessageId IS NULL
            """, arguments: arguments)
        for item in items {
            let key = ThreadKey(accountId: item.accountId, threadId: item.threadId)
            let messages = try MailMessage.filter(Column("accountId") == key.accountId && Column("threadId") == key.threadId
                && Column("date") > item.sourceDate.timeIntervalSince1970 && Column("isDraft") == false).order(Column("date"), Column("id")).fetchAll(db)
            if let reply = messages.first(where: { message in
                if item.direction == .waitingOn { return !message.isFromMe && message.fromEmail.lowercased() == item.counterpartyEmail.lowercased() }
                return message.isFromMe && (message.toList + message.ccList).contains { $0.email.lowercased() == item.counterpartyEmail.lowercased() }
            }) {
                try db.execute(sql: "UPDATE commitment SET hintMessageId=?,hintAt=?,updatedAt=? WHERE id=?",
                    arguments: [reply.id, reply.date.timeIntervalSince1970, now.timeIntervalSince1970, item.id])
            }
        }
    }
}
