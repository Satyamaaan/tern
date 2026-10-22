import Foundation
import GRDB

/// Deterministic tracking. Only commitment and ledger_scan are owned by this writer.
public enum Ledger {
    private struct Message {
        var id: String
        var date: Date
        var fromEmail: String
        var subject: String
        var text: String
        var isFromMe: Bool
        var hasList: Bool
        var to: String
        var cc: String

        init(_ row: Row) {
            id = row["id"]; date = Date(timeIntervalSince1970: row["date"])
            fromEmail = row["fromEmail"]; subject = row["subject"]
            let body: String? = row["bodyText"]
            text = body.flatMap { $0.isEmpty ? nil : $0 } ?? row["snippet"]
            isFromMe = row["isFromMe"]; hasList = row["hasList"]
            to = row["toList"]; cc = row["ccList"]
        }

        func recipients() throws -> [Participant] {
            let decoder = JSONDecoder()
            return try decoder.decode([Participant].self, from: Data(to.utf8)) + decoder.decode([Participant].self, from: Data(cc.utf8))
        }
    }
    private static let day = 86_400.0
    private static let askPatterns = [#"\blooking forward to\b"#, #"\battached\b.{0,100}\bfor your review\b"#].map {
        try! NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }
    private static let closer = try! NSRegularExpression(
        pattern: #"^(thanks[!. ]*|thank you[!. ]*|ok(ay)?[!. ]*|sounds good[!. ]*|great[!. ]*|got it[!. ]*)$"#,
        options: [.caseInsensitive])

    /// Inspects one indexed message range per touched thread. A nudge preserves the original ask date.
    public static func refresh(_ db: Database, keys: some Collection<ThreadKey>, now: Date = Date()) throws {
        guard !keys.isEmpty else { return }
        let settings = try LedgerSettings.load(db)
        guard settings.enabled else { return }
        let own = Set(try String.fetchAll(db, sql: "SELECT lower(email) FROM account"))
        let preferences = try Setting.fetchAll(db).reduce(into: [String: String]()) { $0[$1.key] = $1.value }
        let messageQuery = try db.cachedStatement(sql: """
            SELECT id,date,fromEmail,subject,bodyText,snippet,isFromMe,listUnsubscribe IS NOT NULL AS hasList,toList,ccList
            FROM message WHERE accountId=? AND threadId=? AND isDraft=0 ORDER BY date,id
            """)
        let threadQuery = try db.cachedStatement(sql: """
            SELECT t.labelIds,ai.category FROM thread t LEFT JOIN thread_ai ai ON ai.accountId=t.accountId AND ai.threadId=t.id
            WHERE t.accountId=? AND t.id=?
            """)
        for key in keys {
            let muteLabel = preferences[MailStore.muteLabelKey(key.accountId)]
            let mutedLabels: [String] = [SystemLabel.trash, SystemLabel.spam, MailStore.pendingMuteLabel] + (muteLabel.map { [$0] } ?? [])
            let messages = try Row.fetchAll(messageQuery, arguments: [key.accountId, key.threadId]).map(Message.init)
            let existingQuery = try db.cachedStatement(sql: "SELECT id,sourceDate FROM commitment WHERE accountId=? AND threadId=? AND origin='rule' AND state='open' AND stateSource!='user'")
            let existing = try Row.fetchAll(existingQuery, arguments: [key.accountId, key.threadId])
            for item in existing {
                let source = Date(timeIntervalSince1970: item["sourceDate"])
                let id: Int64 = item["id"]
                if let reply = messages.first(where: { $0.date > source && isRealReply($0, own: own) }) {
                    try db.execute(sql: "UPDATE commitment SET state='done', stateSource='rule', resolvedMessageId=?, resolvedAt=?, updatedAt=? WHERE id=?",
                                   arguments: [reply.id, reply.date.timeIntervalSince1970, now.timeIntervalSince1970, id])
                }
            }
            let conversation = messages.filter { $0.isFromMe || isRealReply($0, own: own) }
            guard let last = conversation.last, last.isFromMe,
                  last.date <= now, last.date >= now.addingTimeInterval(-45 * day),
                  !messages.contains(where: { $0.hasList }),
                  let thread = try Row.fetchOne(threadQuery, arguments: [key.accountId, key.threadId])
            else { continue }
            let labels = try JSONDecoder().decode([String].self, from: Data((thread["labelIds"] as String).utf8))
            guard !labels.contains(where: { mutedLabels.contains($0) }), labels.contains(SystemLabel.sent) else { continue }
            let category: String? = thread["category"]
            guard category == nil || category == "people" || category == "other" else { continue }
            let run = conversation.suffix(from: conversation.lastIndex(where: { !$0.isFromMe }).map { $0 + 1 } ?? 0)
            guard let ask = run.first, ask.date >= now.addingTimeInterval(-45 * day) else { continue }
            var seen = Set<String>()
            let recipients = try ask.recipients().filter {
                let email = $0.email.lowercased()
                return !own.contains(email) && !email.isEmpty && !RuleClassifier.isAutomated(email) && seen.insert(email).inserted
            }
            guard let person = recipients.first, recipients.count <= 6 else { continue }
            let text = MailText.stripQuoted(ask.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.contains("?") || text.count >= 25,
                  closer.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil,
                  text.contains("?") || RuleClassifier.matches(RuleClassifier.requestPatterns, text) || RuleClassifier.matches(askPatterns, text)
            else { continue }
            let surface = ask.date.addingTimeInterval(Double(settings.waitingDays) * day)
            let name = person.name.isEmpty ? (try String.fetchOne(db, sql: "SELECT name FROM contact WHERE id=?", arguments: [person.email.lowercased()]) ?? "") : person.name
            let insert = try db.cachedStatement(sql: """
                INSERT INTO commitment (accountId,threadId,direction,kind,counterpartyEmail,counterpartyName,deliverable,
                  sourceMessageId,sourceDate,origin,surfaceAt,surfaced,fingerprint,createdAt,updatedAt)
                VALUES (?,?,'waitingOn','reply',?,?,'Reply',?,?,'rule',?,?,?,?,?)
                ON CONFLICT(accountId,threadId,fingerprint) DO NOTHING
                """)
            try insert.execute(arguments: [key.accountId, key.threadId, person.email, name, ask.id, ask.date.timeIntervalSince1970,
                                  surface.timeIntervalSince1970, surface <= now, "rule|" + ask.id, now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
    }

    private static func isRealReply(_ message: Message, own: Set<String>) -> Bool {
        guard !message.isFromMe, !own.contains(message.fromEmail.lowercased()), !RuleClassifier.isAutomated(message.fromEmail.lowercased()) else { return false }
        let subject = message.subject.lowercased()
        return !["automatic reply", "out of office", "out-of-office", "autoreply", "auto-reply"].contains(where: { subject.contains($0) })
    }

    /// Materializes time thresholds so database observations wake without network activity.
    public static func sweep(_ db: Database, now: Date = Date()) throws {
        let stamp = now.timeIntervalSince1970
        try db.execute(sql: """
            UPDATE commitment SET state='stale', updatedAt=? WHERE state='open' AND stateSource!='user' AND (
              (dueAt IS NULL AND sourceDate<?) OR
              NOT EXISTS (SELECT 1 FROM message m WHERE m.accountId=commitment.accountId AND m.id=commitment.sourceMessageId) OR
              EXISTS (SELECT 1 FROM thread_label x WHERE x.accountId=commitment.accountId AND x.threadId=commitment.threadId AND x.labelId IN ('TRASH','SPAM')))
            """, arguments: [stamp, stamp - 45 * day])
        try db.execute(sql: "UPDATE commitment SET surfaced=1, updatedAt=? WHERE state='open' AND surfaced=0 AND surfaceAt<=?", arguments: [stamp, stamp])
    }

    /// Recent sent-only tails are the bounded backfill candidates, including archived conversations.
    public static func waitingCandidates(_ db: Database, now: Date = Date()) throws -> [ThreadKey] {
        try Row.fetchAll(db, sql: """
            SELECT t.accountId,t.id FROM thread t
            LEFT JOIN thread_ai ai ON ai.accountId=t.accountId AND ai.threadId=t.id
            WHERE t.lastDate BETWEEN ? AND ? AND (t.lastInboundDate IS NULL OR t.lastInboundDate<t.lastDate)
              AND EXISTS (SELECT 1 FROM thread_label s WHERE s.accountId=t.accountId AND s.threadId=t.id AND s.labelId='SENT')
              AND (ai.category IS NULL OR ai.category IN ('people','other'))
              AND NOT EXISTS (SELECT 1 FROM thread_label x WHERE x.accountId=t.accountId AND x.threadId=t.id AND x.labelId IN ('TRASH','SPAM'))
            UNION SELECT accountId,threadId FROM commitment WHERE origin='rule' AND state='open' AND stateSource!='user'
            """, arguments: [now.timeIntervalSince1970 - 45 * day, now.timeIntervalSince1970]).map {
                ThreadKey(accountId: $0[0], threadId: $0[1])
            }
    }

    /// Transaction variant for tests and callers already on a writer.
    public static func rebuildWaiting(_ db: Database, now: Date = Date()) throws {
        try refresh(db, keys: waitingCandidates(db, now: now), now: now)
        try sweep(db, now: now)
    }

    /// Background backfill commits every 100 candidates. Run away from the main thread.
    public static func rebuildWaiting(in database: AppDatabase, now: Date = Date(), onlyIfNeeded: Bool = false) throws {
        if onlyIfNeeded, try database.reader.read({ try Setting.fetchOne($0, key: "ledger.backfilled")?.value }) == "1" { return }
        let keys = try database.reader.read { try waitingCandidates($0, now: now) }
        for offset in stride(from: 0, to: keys.count, by: 100) {
            let chunk = Array(keys[offset..<min(offset + 100, keys.count)])
            try database.writer.write { try refresh($0, keys: chunk, now: now) }
        }
        try database.writer.write {
            try sweep($0, now: now)
            try Setting(key: "ledger.backfilled", value: "1").upsert($0)
        }
    }
}
