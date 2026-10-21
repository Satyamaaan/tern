import Foundation
import GRDB
import TernCore

/// A thread reduced to what a prompt needs.
struct PromptThread: Hashable, Sendable {
    struct Message: Hashable, Sendable {
        var from: Participant
        var to: [Participant]
        var cc: [Participant]
        var date: Date
        /// New text only (quotes cut), whitespace collapsed and truncated.
        var text: String
        var isFromMe: Bool
    }

    var key: ThreadKey
    var subject: String
    var messageCount: Int
    var lastDate: Date
    var labels: [String]
    /// The latest messages, oldest first.
    var messages: [Message]
}

enum PromptData {
    /// Threads with their latest `messages` messages, each cut to `characters`.
    static func threads(_ db: Database, keys: [ThreadKey], messages limit: Int, characters: Int) throws -> [PromptThread] {
        guard !keys.isEmpty else { return [] }
        let placeholders = keys.map { _ in "(?, ?)" }.joined(separator: ", ")
        var arguments: StatementArguments = []
        for key in keys { _ = arguments.append(contentsOf: [key.accountId, key.threadId]) }

        var threads: [ThreadKey: PromptThread] = [:]
        for thread in try MailThread.fetchAll(db, sql: """
            SELECT * FROM thread WHERE (accountId, id) IN (VALUES \(placeholders))
            """, arguments: arguments) {
            threads[thread.key] = PromptThread(
                key: thread.key, subject: thread.subject, messageCount: thread.messageCount, lastDate: thread.lastDate,
                labels: readableLabels(thread.labelIds), messages: [])
        }
        // Each thread's latest messages come from a backwards walk of `message_by_thread` that stops after
        // `limit`, so only those rows are read and only their bodies cut.
        var unique = Set<ThreadKey>()
        var latestArguments: StatementArguments = []
        for key in keys where unique.insert(key).inserted {
            _ = latestArguments.append(contentsOf: [key.accountId, key.threadId])
        }
        _ = latestArguments.append(contentsOf: [max(limit, 0)])
        var latest: [ThreadKey: [Row]] = [:]
        for row in try Row.fetchAll(db, sql: """
            WITH k(accountId, threadId) AS (VALUES \(unique.map { _ in "(?, ?)" }.joined(separator: ", ")))
            SELECT m.accountId, m.threadId, m.date, m.fromName, m.fromEmail, m.toList, m.ccList, m.snippet,
              substr(m.bodyText, 1, 6000) AS bodyHead, m.isFromMe
            FROM k JOIN message m ON m.seq IN (
              SELECT seq FROM message
              WHERE accountId = k.accountId AND threadId = k.threadId AND isDraft = 0
              ORDER BY date DESC, seq DESC LIMIT ?)
            ORDER BY m.date, m.seq
            """, arguments: latestArguments) {
            latest[ThreadKey(accountId: row["accountId"], threadId: row["threadId"]), default: []].append(row)
        }
        for (key, rows) in latest {
            threads[key]?.messages = rows.map { message($0, characters: characters) }
        }
        return keys.compactMap { threads[$0] }.filter { !$0.messages.isEmpty }
    }

    /// The thread's message count, read without any body, when `threads` would return it (it has a message that
    /// isn't a draft); nil otherwise.
    static func messageCount(_ db: Database, key: ThreadKey) throws -> Int? {
        try Int.fetchOne(db, sql: """
            SELECT messageCount FROM thread t WHERE accountId = ? AND id = ?
              AND EXISTS (SELECT 1 FROM message WHERE accountId = t.accountId AND threadId = t.id AND isDraft = 0)
            """, arguments: [key.accountId, key.threadId])
    }

    /// The owner's own earlier messages, as voice samples for drafting: from this thread first, then
    /// to the same people, then anything recent from that account.
    static func ownSamples(_ db: Database, thread: PromptThread, limit: Int, characters: Int) throws -> [String] {
        var samples: [String] = []
        var seen = Set<String>()
        func add(_ rows: [Row]) {
            for row in rows where samples.count < limit {
                let text = sampleText(row, characters: characters)
                if !text.isEmpty, seen.insert(text).inserted { samples.append(text) }
            }
        }
        let account = thread.key.accountId
        add(try Row.fetchAll(db, sql: """
            SELECT snippet, substr(bodyText, 1, 6000) AS bodyHead FROM message
            WHERE accountId = ? AND threadId = ? AND isFromMe = 1 AND isDraft = 0 ORDER BY date DESC LIMIT 10
            """, arguments: [account, thread.key.threadId]))
        let others = Set(thread.messages.filter { !$0.isFromMe }.map { $0.from.email.lowercased() })
        for email in others.sorted() where samples.count < limit {
            add(try Row.fetchAll(db, sql: """
                SELECT snippet, substr(bodyText, 1, 6000) AS bodyHead FROM message
                WHERE accountId = ? AND isFromMe = 1 AND isDraft = 0 AND threadId != ?
                  AND instr(lower(searchRecipients), ?) > 0
                ORDER BY date DESC LIMIT 5
                """, arguments: [account, thread.key.threadId, email]))
        }
        if samples.count < limit {
            add(try Row.fetchAll(db, sql: """
                SELECT snippet, substr(bodyText, 1, 6000) AS bodyHead FROM message
                WHERE accountId = ? AND isFromMe = 1 AND isDraft = 0 ORDER BY date DESC LIMIT 10
                """, arguments: [account]))
        }
        return samples
    }

    private static func message(_ row: Row, characters: Int) -> PromptThread.Message {
        let decoder = JSONDecoder()
        let to = (try? decoder.decode([Participant].self, from: Data((row["toList"] as String).utf8))) ?? []
        let cc = (try? decoder.decode([Participant].self, from: Data((row["ccList"] as String).utf8))) ?? []
        return PromptThread.Message(
            from: Participant(name: row["fromName"], email: row["fromEmail"]), to: to, cc: cc,
            date: Date(timeIntervalSince1970: row["date"]), text: sampleText(row, characters: characters),
            isFromMe: row["isFromMe"])
    }

    private static func sampleText(_ row: Row, characters: Int) -> String {
        let body: String? = row["bodyHead"]
        let snippet: String = row["snippet"] ?? ""
        let raw = body.flatMap { $0.isEmpty ? nil : $0 } ?? snippet
        let fresh = MailText.stripQuoted(raw)
        return MailText.compact(fresh.isEmpty ? raw : fresh, limit: characters)
    }

    /// Gmail system labels a model can use as hints.
    private static func readableLabels(_ ids: [String]) -> [String] {
        let names: [String: String] = [
            SystemLabel.inbox: "inbox", SystemLabel.unread: "unread", SystemLabel.starred: "starred",
            SystemLabel.important: "important", SystemLabel.sent: "sent", SystemLabel.categoryPromotions: "promotions-tab",
            SystemLabel.categoryUpdates: "updates-tab", SystemLabel.categorySocial: "social-tab",
            SystemLabel.categoryForums: "forums-tab",
        ]
        return ids.compactMap { names[$0] }
    }
}
