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
            text = row["snippet"]
            isFromMe = row["isFromMe"]; hasList = row["hasList"]
            to = row["toList"]; cc = row["ccList"]
        }

        func recipients() -> [Participant] {
            [to, cc].flatMap { (try? JSONDecoder().decode([Participant].self, from: Data($0.utf8))) ?? [] }
        }
    }
    private static let day = 86_400.0
    private static let links = try! NSRegularExpression(pattern: #"https?://\S+|www\.\S+|[A-Z0-9._%+?\-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    private static let question = try! NSRegularExpression(pattern: #"\?(\s|$)"#)
    private static let requests = try! NSRegularExpression(pattern: #"\b(?:(?:can|could|would|will) you\s+(?:please\s+)?(?:let me know|confirm|send|review|reply|sign|share|approve)|please\s+(?:let me know|confirm|send|review|reply|sign|share)|let me know|attached\b.{0,100}\bfor your review)\b"#, options: [.caseInsensitive, .dotMatchesLineSeparators])

    private static func askText(_ text: String) -> String {
        let stripped = MailText.stripQuoted(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return links.stringByReplacingMatches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: "")
    }

    private static func isDirectQuestion(_ text: String) -> Bool {
        return question.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isAsk(_ text: String) -> Bool {
        guard mayContainAsk(text) else { return false }
        return isAskText(askText(text))
    }

    private static func mayContainAsk(_ text: String) -> Bool {
        text.contains("?") || requests.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func isAskText(_ text: String) -> Bool {
        isDirectQuestion(text) || requests.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Recognises senders that cannot make a personal commitment.
    public static func isAutomation(_ email: String) -> Bool {
        let local = email.lowercased().split(separator: "@").first.map(String.init) ?? ""
        return ["noreply", "no-reply", "no_reply", "do-not-reply", "do_not_reply", "donotreply", "mailer-daemon", "postmaster", "bounce"].contains { local.contains($0) }
    }

    /// Reads metadata first; bodies are fetched only for potential asks in the trailing sent run.
    public static func refresh(_ db: Database, keys: some Collection<ThreadKey>, now: Date = Date()) throws {
        guard !keys.isEmpty else { return }
        try refreshHints(db, keys: keys, now: now)
        let preferences = try Setting.fetchAll(db).reduce(into: [String: String]()) { $0[$1.key] = $1.value }
        let settings = LedgerSettings.load(preferences)
        guard settings.enabled else { return }
        let own = Set(try String.fetchAll(db, sql: "SELECT lower(email) FROM account"))
        let messageQuery = try db.cachedStatement(sql: """
            SELECT id,date,fromEmail,subject,snippet,isFromMe,listUnsubscribe IS NOT NULL AS hasList,toList,ccList
            FROM message WHERE accountId=? AND threadId=? AND isDraft=0 ORDER BY date,id
            """)
        let threadQuery = try db.cachedStatement(sql: """
            SELECT t.labelIds,t.lastDate,t.lastInboundDate,ai.category
            FROM thread t LEFT JOIN thread_ai ai ON ai.accountId=t.accountId AND ai.threadId=t.id
            WHERE t.accountId=? AND t.id=?
            """)
        let existingQuery = try db.cachedStatement(sql: "SELECT * FROM commitment WHERE accountId=? AND threadId=?")
        let bodyQuery = try db.cachedStatement(sql: "SELECT bodyText FROM message WHERE accountId=? AND id=?")
        let insert = try db.cachedStatement(sql: """
            INSERT INTO commitment (accountId,threadId,direction,kind,counterpartyEmail,counterpartyName,deliverable,
              sourceMessageId,sourceDate,origin,surfaceAt,surfaced,fingerprint,createdAt,updatedAt)
            VALUES (?,?,'waitingOn','reply',?,?,'Reply',?,?,'rule',?,?,?,?,?)
            ON CONFLICT(accountId,threadId,fingerprint) DO NOTHING
            """)
        for key in keys {
            guard let thread = try Row.fetchOne(threadQuery, arguments: [key.accountId, key.threadId]) else { continue }
            let allItems = try Commitment.fetchAll(existingQuery, arguments: [key.accountId, key.threadId])
            let existing = allItems.filter { $0.origin == "rule" && $0.state == .open }
            let concreteSources = Set(allItems.filter { $0.kind == "deliverable" }.map(\.sourceMessageId))
            let labels = (try? JSONDecoder().decode([String].self, from: Data((thread["labelIds"] as String).utf8))) ?? []
            let mutedLabels: [String] = [SystemLabel.trash, SystemLabel.spam, MailStore.pendingMuteLabel] + (preferences[MailStore.muteLabelKey(key.accountId)].map { [$0] } ?? [])
            let category: String? = thread["category"]
            let eligible = !labels.contains(where: mutedLabels.contains)
                && (category == nil || category == "people" || category == "other")
            if !eligible {
                try db.execute(sql: "UPDATE commitment SET state='stale',updatedAt=? WHERE accountId=? AND threadId=? AND origin='rule' AND state='open'",
                               arguments: [now.timeIntervalSince1970, key.accountId, key.threadId])
                continue
            }
            let inbound: Double? = thread["lastInboundDate"]
            let lastDate: Double = thread["lastDate"]
            guard labels.contains(SystemLabel.sent), (inbound.map { $0 < lastDate } ?? true) || !existing.isEmpty else { continue }
            let messages = try Row.fetchAll(messageQuery, arguments: [key.accountId, key.threadId]).map(Message.init)
            if messages.contains(where: { $0.hasList }) {
                try db.execute(sql: "UPDATE commitment SET state='stale',updatedAt=? WHERE accountId=? AND threadId=? AND origin='rule' AND state='open'",
                               arguments: [now.timeIntervalSince1970, key.accountId, key.threadId])
                continue
            }
            for item in existing {
                guard let source = messages.first(where: { $0.id == item.sourceMessageId }) else { continue }
                let recipients = Set(source.recipients().map { $0.email.lowercased() }).union([item.counterpartyEmail.lowercased()])
                let after = item.stateSource == "user" ? max(item.sourceDate, item.updatedAt) : item.sourceDate
                if let reply = messages.first(where: { $0.date > after && recipients.contains($0.fromEmail.lowercased()) && isRealReply($0, own: own) }) {
                    try db.execute(sql: "UPDATE commitment SET state='done',stateSource='rule',resolvedMessageId=?,resolvedAt=?,updatedAt=? WHERE id=?",
                                   arguments: [reply.id, reply.date.timeIntervalSince1970, now.timeIntervalSince1970, item.id])
                }
            }
            let conversation = messages.filter { $0.isFromMe || isRealReply($0, own: own) }
            guard let last = conversation.last, last.isFromMe, last.date <= now,
                  last.date >= now.addingTimeInterval(-45 * day) else { continue }
            let run = conversation.suffix(from: conversation.lastIndex(where: { !$0.isFromMe }).map { $0 + 1 } ?? 0)
            for ask in run where ask.date >= now.addingTimeInterval(-45 * day) {
                let body = try String.fetchOne(bodyQuery, arguments: [key.accountId, ask.id])
                let rawText = body.flatMap { $0.isEmpty ? nil : $0 } ?? ask.text
                guard mayContainAsk(rawText) else { continue }
                let text = askText(rawText)
                guard isAskText(text) else { continue }
                // An AI deliverable on this ask replaces the coarse reply tracker.
                if concreteSources.contains(ask.id) { continue }
                let directQuestion = isDirectQuestion(text)
                var seen = Set<String>()
                let recipients = ask.recipients().filter {
                    let email = $0.email.lowercased()
                    return !own.contains(email) && !email.isEmpty && !isAutomation(email)
                        && (!RuleClassifier.isAutomated(email) || (RuleClassifier.roleLocalParts.contains(MailText.localPart(of: email)) && directQuestion)) && seen.insert(email).inserted
                }
                guard let person = recipients.first, recipients.count <= 6 else { continue }
                let surface = ask.date.addingTimeInterval(Double(settings.waitingDays) * day)
                let name = person.name.isEmpty ? (try String.fetchOne(db, sql: "SELECT name FROM contact WHERE id=?", arguments: [person.email.lowercased()]) ?? "") : person.name
                try insert.execute(arguments: [key.accountId, key.threadId, person.email, name, ask.id, ask.date.timeIntervalSince1970,
                                      surface.timeIntervalSince1970, surface <= now, "rule|" + ask.id, now.timeIntervalSince1970, now.timeIntervalSince1970])
                break
            }
        }
    }

    private static func isRealReply(_ message: Message, own: Set<String>) -> Bool {
        guard !message.isFromMe, !own.contains(message.fromEmail.lowercased()), !isAutomation(message.fromEmail) else { return false }
        let subject = message.subject.lowercased()
        return !["automatic reply", "out of office", "out-of-office", "autoreply", "auto-reply"].contains(where: { subject.contains($0) })
    }

    /// Materializes time thresholds so database observations wake without network activity.
    public static func sweep(_ db: Database, now: Date = Date()) throws {
        let stamp = now.timeIntervalSince1970
        try db.execute(sql: """
            UPDATE commitment SET state='stale', updatedAt=? WHERE state='open' AND (
              (stateSource!='user' AND (
                (dueAt IS NULL AND sourceDate<?) OR
                NOT EXISTS (SELECT 1 FROM message m WHERE m.accountId=commitment.accountId AND m.id=commitment.sourceMessageId))) OR
              (origin='rule' AND (
                EXISTS (SELECT 1 FROM thread_label x INDEXED BY thread_label_by_thread WHERE x.accountId=commitment.accountId AND x.threadId=commitment.threadId AND (x.labelId IN ('TRASH','SPAM','TERN_PENDING_MUTED') OR x.labelId=(SELECT value FROM setting WHERE key='mute.label.' || commitment.accountId))) OR
                EXISTS (SELECT 1 FROM thread_ai ai WHERE ai.accountId=commitment.accountId AND ai.threadId=commitment.threadId AND ai.category NOT IN ('people','other')) OR
                EXISTS (SELECT 1 FROM message m INDEXED BY message_by_thread WHERE m.accountId=commitment.accountId AND m.threadId=commitment.threadId AND m.listUnsubscribe IS NOT NULL))))
            """, arguments: [stamp, stamp - 45 * day])
        try db.execute(sql: "UPDATE commitment SET surfaced=1, updatedAt=? WHERE state='open' AND surfaced=0 AND surfaceAt<=?", arguments: [stamp, stamp])
    }

    /// Recent sent-only tails are the bounded backfill candidates, including archived conversations.
    public static func waitingCandidates(_ db: Database, now: Date = Date()) throws -> [ThreadKey] {
        try Row.fetchAll(db, sql: """
            SELECT t.accountId,t.id FROM thread_label sent INDEXED BY thread_label_unified
            JOIN thread t ON t.accountId=sent.accountId AND t.id=sent.threadId
            LEFT JOIN thread_ai ai ON ai.accountId=t.accountId AND ai.threadId=t.id
            WHERE sent.labelId='SENT' AND sent.lastDate BETWEEN ? AND ? AND (t.lastInboundDate IS NULL OR t.lastInboundDate<t.lastDate)
              AND (ai.category IS NULL OR ai.category IN ('people','other'))
              AND NOT EXISTS (SELECT 1 FROM thread_label x INDEXED BY thread_label_by_thread WHERE x.accountId=t.accountId AND x.threadId=t.id AND x.labelId IN ('TRASH','SPAM'))
            UNION SELECT accountId,threadId FROM commitment WHERE origin='rule' AND state='open'
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
