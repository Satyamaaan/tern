import Foundation
import GRDB

/// Durable summaries are independent of classification, so rule refreshes cannot erase them.
public enum SummaryStore {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE thread_summary (
              accountId TEXT NOT NULL, threadId TEXT NOT NULL, messageCount INTEGER NOT NULL,
              lastDate DOUBLE NOT NULL, line TEXT NOT NULL, bullets TEXT NOT NULL,
              PRIMARY KEY(accountId,threadId),
              FOREIGN KEY(accountId,threadId) REFERENCES thread(accountId,id) ON DELETE CASCADE
            );
            """)
    }

    /// Saves only if the conversation still matches the input used by the model.
    public static func save(_ db: Database, key: ThreadKey, messageCount: Int, lastDate: Date, bullets: [String]) throws {
        guard let first = bullets.first else { return }
        let json = String(decoding: try JSONEncoder().encode(bullets), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO thread_summary(accountId,threadId,messageCount,lastDate,line,bullets)
            SELECT accountId,id,messageCount,lastDate,?,? FROM thread
            WHERE accountId=? AND id=? AND messageCount=? AND lastDate=?
            ON CONFLICT(accountId,threadId) DO UPDATE SET messageCount=excluded.messageCount,
              lastDate=excluded.lastDate,line=excluded.line,bullets=excluded.bullets
            """, arguments: [MailText.compact(first, limit: 110), json, key.accountId, key.threadId, messageCount, lastDate.timeIntervalSince1970])
    }
}
