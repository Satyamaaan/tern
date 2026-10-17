import GRDB

/// Indexes that make search answer on every keystroke. Registered as `search-1` in `Schema.register`.
enum SearchSchema {
    static func migrate(_ db: Database) throws {
        // Rebuild the message index with a one-letter prefix index. Typing `t` otherwise merges the doclists
        // of every term starting with t (thousands, ~2 s over 50k messages); with it a one-letter prefix costs
        // the same as `the`. Insert triggers from `v1-search` keep working: they only name the table.
        try db.execute(sql: """
            DROP TABLE message_fts;
            CREATE VIRTUAL TABLE message_fts USING fts5(
              subject, searchSender, searchRecipients, snippet, bodyText,
              content='message', content_rowid='seq',
              tokenize='unicode61 remove_diacritics 2',
              prefix='1 2 3'
            );
            INSERT INTO message_fts(message_fts) VALUES('rebuild');

            -- larger: / smaller: without scanning every message.
            CREATE INDEX message_by_size ON message(sizeEstimate);
            -- is:needsreply starts from the few flagged threads instead of walking the whole list.
            CREATE INDEX thread_ai_needs_reply ON thread_ai(accountId, threadId) WHERE needsReply = 1;
            """)
    }
}
