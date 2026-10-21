import GRDB

/// `perf-1`: the message index re-indexes a row only when its indexed text really changed. The upsert assigns
/// every column on conflict, so without the guard each metadata re-fetch (labels, read state) deleted and
/// re-inserted the message's full-text row with the same text.
enum SearchTriggerSchema {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            DROP TRIGGER message_fts_update;
            CREATE TRIGGER message_fts_update
            AFTER UPDATE OF subject, searchSender, searchRecipients, snippet, bodyText ON message
            WHEN old.subject IS NOT new.subject OR old.searchSender IS NOT new.searchSender
              OR old.searchRecipients IS NOT new.searchRecipients OR old.snippet IS NOT new.snippet
              OR old.bodyText IS NOT new.bodyText
            BEGIN
              INSERT INTO message_fts(message_fts, rowid, subject, searchSender, searchRecipients, snippet, bodyText)
              VALUES ('delete', old.seq, old.subject, old.searchSender, old.searchRecipients, old.snippet, old.bodyText);
              INSERT INTO message_fts(rowid, subject, searchSender, searchRecipients, snippet, bodyText)
              VALUES (new.seq, new.subject, new.searchSender, new.searchRecipients, new.snippet, new.bodyText);
            END;
            """)
    }
}
