import Foundation
import GRDB

// Writes used by sync. Every message change goes through here so threads, labels and the
// search index stay consistent.
extension MailStore {
    public func upsertAccount(_ account: Account) throws {
        try database.writer.write { db in try account.upsert(db) }
    }

    public func updateAccount(_ id: String, _ change: @Sendable (inout Account) -> Void) throws {
        try database.writer.write { db in
            guard var account = try Account.fetchOne(db, key: id) else { return }
            change(&account)
            try account.update(db)
        }
    }

    /// Deletes the account and everything that belongs to it.
    public func removeAccount(_ id: String) throws {
        try database.writer.write { db in
            for table in ["thread_ai", "thread_project", "snooze"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE accountId = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM thread WHERE accountId = ?", arguments: [id])
            _ = try Account.deleteOne(db, key: id)
        }
    }

    /// Replaces an account's label list with what Gmail reports.
    public func replaceLabels(accountId: String, with labels: [MailLabel]) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM label WHERE accountId = ?", arguments: [accountId])
            for label in labels { try label.insert(db) }
        }
    }

    /// Inserts or updates messages and their attachments, then rebuilds the affected threads.
    /// A metadata-only record never overwrites a body that is already stored.
    public func upsertMessages(_ messages: [MailMessage], attachments: [MailAttachment] = []) throws {
        try database.writer.write { db in
            try Self.upsertMessages(db, messages, attachments: attachments)
        }
    }

    public static func upsertMessages(_ db: Database, _ messages: [MailMessage], attachments: [MailAttachment] = []) throws {
        guard !messages.isEmpty || !attachments.isEmpty else { return }
        let statement = try db.cachedStatement(sql: upsertMessageSQL)
        var touched = Set<ThreadKey>()
        for var message in messages {
            message.searchSender = searchText([message.from])
            message.searchRecipients = searchText(message.toList + message.ccList + message.bccList)
            try statement.execute(arguments: StatementArguments(message.databaseDictionary)!)
            touched.insert(message.threadKey)
        }
        for attachment in attachments { try attachment.upsert(db) }
        try refreshThreads(db, touched)
    }

    /// Sets the exact label list of existing messages (e.g. from history label events).
    public func setLabels(accountId: String, _ labelsByMessage: [String: [String]]) throws {
        try database.writer.write { db in try Self.setLabels(db, accountId: accountId, labelsByMessage) }
    }

    public static func setLabels(_ db: Database, accountId: String, _ labelsByMessage: [String: [String]]) throws {
        guard !labelsByMessage.isEmpty else { return }
        let update = try db.cachedStatement(sql: """
            UPDATE message SET labelIds = ?, isUnread = ?, isStarred = ?, isDraft = ?,
              isFromMe = isFromMe OR ?
            WHERE accountId = ? AND id = ?
            RETURNING threadId
            """)
        var touched = Set<ThreadKey>()
        for (messageId, labels) in labelsByMessage {
            let sorted = Array(Set(labels)).sorted()
            let json = String(data: try JSONEncoder().encode(sorted), encoding: .utf8)!
            let threadId = try String.fetchOne(update, arguments: [
                json, sorted.contains(SystemLabel.unread), sorted.contains(SystemLabel.starred),
                sorted.contains(SystemLabel.draft), sorted.contains(SystemLabel.sent), accountId, messageId,
            ])
            if let threadId { touched.insert(ThreadKey(accountId: accountId, threadId: threadId)) }
        }
        try refreshThreads(db, touched)
    }

    public func deleteMessages(accountId: String, ids: [String]) throws {
        try database.writer.write { db in try Self.deleteMessages(db, accountId: accountId, ids: ids) }
    }

    public static func deleteMessages(_ db: Database, accountId: String, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        var touched = Set<ThreadKey>()
        let delete = try db.cachedStatement(sql: "DELETE FROM message WHERE accountId = ? AND id = ? RETURNING threadId")
        for id in ids {
            if let threadId = try String.fetchOne(delete, arguments: [accountId, id]) {
                touched.insert(ThreadKey(accountId: accountId, threadId: threadId))
            }
            try db.execute(sql: "DELETE FROM attachment WHERE accountId = ? AND messageId = ?", arguments: [accountId, id])
        }
        try refreshThreads(db, touched)
    }

    /// Message ids still missing a body, newest first, for background prefetch.
    public func messagesNeedingBody(accountId: String, limit: Int) throws -> [String] {
        try database.reader.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM message WHERE accountId = ? AND bodyState = 0 ORDER BY date DESC LIMIT ?
                """, arguments: [accountId, limit])
        }
    }

    public func setAttachmentPath(_ attachment: MailAttachment, path: String) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE attachment SET localPath = ? WHERE accountId = ? AND messageId = ? AND partId = ?
                """, arguments: [path, attachment.accountId, attachment.messageId, attachment.partId])
        }
    }

    // MARK: Threads

    /// Rebuilds thread rows and their label index from messages. A thread with no messages left is removed.
    public static func refreshThreads(_ db: Database, _ keys: some Collection<ThreadKey>) throws {
        guard !keys.isEmpty else { return }
        let select = try db.cachedStatement(sql: """
            SELECT id, date, fromName, fromEmail, subject, snippet, labelIds, isUnread, isStarred, isDraft,
              isFromMe, hasAttachments
            FROM message WHERE accountId = ? AND threadId = ? ORDER BY date
            """)
        let deleteLabels = try db.cachedStatement(sql: "DELETE FROM thread_label WHERE accountId = ? AND threadId = ?")
        let insertLabel = try db.cachedStatement(sql: """
            INSERT INTO thread_label (accountId, threadId, labelId, lastDate) VALUES (?, ?, ?, ?)
            """)

        for key in keys {
            let parts = try ThreadPart.fetchAll(select, arguments: [key.accountId, key.threadId])
            guard !parts.isEmpty else {
                try db.execute(sql: "DELETE FROM thread WHERE accountId = ? AND id = ?", arguments: [key.accountId, key.threadId])
                continue
            }
            let thread = makeThread(key, parts)
            try thread.upsert(db)
            try deleteLabels.execute(arguments: [key.accountId, key.threadId])
            for label in thread.labelIds {
                try insertLabel.execute(arguments: [key.accountId, key.threadId, label, thread.lastDate.timeIntervalSince1970])
            }
        }
    }

    public func refreshThreads(_ keys: [ThreadKey]) throws {
        try database.writer.write { db in try Self.refreshThreads(db, keys) }
    }

    private struct ThreadPart: Decodable, FetchableRecord {
        var id: String
        var date: Double
        var fromName: String
        var fromEmail: String
        var subject: String
        var snippet: String
        var labelIds: [String]
        var isUnread: Bool
        var isStarred: Bool
        var isDraft: Bool
        var isFromMe: Bool
        var hasAttachments: Bool
    }

    private static func makeThread(_ key: ThreadKey, _ parts: [ThreadPart]) -> MailThread {
        let sent = parts.filter { !$0.isDraft }
        let visible = sent.isEmpty ? parts : sent
        let latest = visible.last!

        var participants: [Participant] = []
        var seen = Set<String>()
        for part in visible {
            let email = part.fromEmail.lowercased()
            if seen.insert(email).inserted {
                participants.append(Participant(name: part.fromName, email: part.fromEmail))
            } else if let index = participants.firstIndex(where: { $0.email.lowercased() == email }),
                      participants[index].name.isEmpty, !part.fromName.isEmpty {
                participants[index].name = part.fromName
            }
        }

        var labels = Set<String>()
        for part in parts { labels.formUnion(part.labelIds) }

        return MailThread(
            accountId: key.accountId,
            id: key.threadId,
            subject: visible.first(where: { !$0.subject.isEmpty })?.subject ?? "",
            snippet: latest.snippet,
            lastDate: Date(timeIntervalSince1970: latest.date),
            lastInboundDate: visible.last(where: { !$0.isFromMe }).map { Date(timeIntervalSince1970: $0.date) },
            messageCount: visible.count,
            unreadCount: visible.filter(\.isUnread).count,
            isStarred: parts.contains(where: \.isStarred),
            isImportant: labels.contains(SystemLabel.important),
            hasAttachments: visible.contains(where: \.hasAttachments),
            hasDraft: parts.contains(where: \.isDraft),
            participants: participants,
            labelIds: labels.sorted())
    }

    // MARK: Contacts

    /// Rebuilds the autocomplete address book from all stored mail.
    public func rebuildContacts() throws {
        try database.writer.write { db in
            try db.execute(sql: """
                DELETE FROM contact;
                INSERT INTO contact (id, name, sentCount, receivedCount, lastContacted)
                SELECT lower(email), max(name), sum(sent), sum(received), max(date) FROM (
                  SELECT json_extract(j.value, '$.email') AS email, json_extract(j.value, '$.name') AS name,
                    1 AS sent, 0 AS received, m.date AS date
                  FROM message m, json_each(m.toList) j WHERE m.isFromMe = 1 AND m.isDraft = 0
                  UNION ALL
                  SELECT json_extract(j.value, '$.email'), json_extract(j.value, '$.name'), 1, 0, m.date
                  FROM message m, json_each(m.ccList) j WHERE m.isFromMe = 1 AND m.isDraft = 0
                  UNION ALL
                  SELECT fromEmail, fromName, 0, 1, date FROM message WHERE isFromMe = 0 AND fromEmail != ''
                ) WHERE email IS NOT NULL AND email != ''
                GROUP BY lower(email);
                """)
        }
    }

    // MARK: Helpers

    static func searchText(_ people: [Participant]) -> String {
        people.map { $0.name.isEmpty ? $0.email : "\($0.name) \($0.email)" }.joined(separator: " ")
    }

    private static let messageColumns: [String] = [
        "accountId", "id", "threadId", "historyId", "date", "fromName", "fromEmail", "toList", "ccList",
        "bccList", "replyTo", "subject", "snippet", "bodyText", "bodyHtml", "bodyState", "labelIds",
        "isUnread", "isStarred", "isDraft", "isFromMe", "hasAttachments", "rfcMessageId", "inReplyTo",
        "refs", "listUnsubscribe", "listUnsubscribePost", "sizeEstimate", "searchSender", "searchRecipients",
    ]

    private static let bodyColumns: Set<String> = ["bodyText", "bodyHtml", "bodyState"]

    private static let upsertMessageSQL: String = {
        let names = messageColumns.joined(separator: ", ")
        let values = messageColumns.map { ":\($0)" }.joined(separator: ", ")
        let updates = messageColumns.filter { $0 != "accountId" && $0 != "id" }.map { (column: String) -> String in
            if bodyColumns.contains(column) {
                return "\(column) = CASE WHEN excluded.bodyState >= message.bodyState THEN excluded.\(column) ELSE message.\(column) END"
            }
            return "\(column) = excluded.\(column)"
        }.joined(separator: ",\n  ")
        return """
            INSERT INTO message (\(names)) VALUES (\(values))
            ON CONFLICT(accountId, id) DO UPDATE SET
              \(updates)
            """
    }()
}
