import Foundation
import GRDB

/// A reply ends a snooze. Gmail puts the thread back in the inbox when someone answers, so the user
/// deals with it then; waking it again on the snooze date would bring back a conversation they already
/// handled, unread.
enum SnoozeReplies {
    /// `fixapp-1`: when each snooze was set. Snoozes from before this version count as set now; the
    /// triggers stamp new and changed snoozes, so the action code needs no change.
    static func migrate(_ db: Database) throws {
        let now = "((julianday('now') - 2440587.5) * 86400.0)"
        try db.execute(sql: """
            ALTER TABLE snooze ADD COLUMN setAt DOUBLE NOT NULL DEFAULT 0;
            UPDATE snooze SET setAt = \(now);
            CREATE TRIGGER snooze_stamp_insert AFTER INSERT ON snooze BEGIN
              UPDATE snooze SET setAt = \(now) WHERE accountId = NEW.accountId AND threadId = NEW.threadId;
            END;
            CREATE TRIGGER snooze_stamp_update AFTER UPDATE OF until ON snooze BEGIN
              UPDATE snooze SET setAt = \(now) WHERE accountId = NEW.accountId AND threadId = NEW.threadId;
            END;
            """)
    }
}

extension MailStore {
    /// Ends the snoozes of `keys` that got an inbound message in the inbox after the snooze was set.
    /// Runs with the rules for threads sync just changed.
    static func endSnoozesAnswered(_ db: Database, keys: some Collection<ThreadKey>) throws {
        guard !keys.isEmpty, try Snooze.fetchCount(db) > 0 else { return }
        let statement = try db.cachedStatement(sql: """
            DELETE FROM snooze WHERE accountId = ? AND threadId = ? AND EXISTS (
              SELECT 1 FROM message m WHERE m.accountId = snooze.accountId AND m.threadId = snooze.threadId
                AND m.date > snooze.setAt AND m.isFromMe = 0 AND m.isDraft = 0 AND m.labelIds LIKE '%"INBOX"%')
            """)
        for key in keys { try statement.execute(arguments: [key.accountId, key.threadId]) }
    }
}
