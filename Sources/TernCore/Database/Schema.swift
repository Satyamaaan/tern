import GRDB

/// All migrations, in order. Append new migrations at the end of `register`; never edit a shipped one.
enum Schema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1-core", migrate: v1Core)
        migrator.registerMigration("v1-search", migrate: v1Search)
        migrator.registerMigration("v1-features", migrate: v1Features)
        // Lanes append their migrations below this line, one line each.
        migrator.registerMigration("search-1", migrate: SearchSchema.migrate)
        migrator.registerMigration("integrate-1", migrate: ProjectExclusion.migrate)
    }

    private static func v1Core(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE account (
              id TEXT PRIMARY KEY NOT NULL,
              email TEXT NOT NULL,
              displayName TEXT NOT NULL DEFAULT '',
              colorIndex INTEGER NOT NULL DEFAULT 0,
              sortOrder INTEGER NOT NULL DEFAULT 0,
              historyId TEXT,
              syncState TEXT NOT NULL DEFAULT 'new',
              syncError TEXT,
              backfillPageToken TEXT,
              backfillDone INTEGER NOT NULL DEFAULT 0,
              lastSyncAt DOUBLE,
              createdAt DOUBLE NOT NULL
            );

            CREATE TABLE label (
              accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
              id TEXT NOT NULL,
              name TEXT NOT NULL,
              type TEXT NOT NULL DEFAULT 'user',
              colorBackground TEXT,
              colorText TEXT,
              hidden INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (accountId, id)
            );

            -- seq is an explicit rowid so VACUUM never renumbers rows behind the full-text index.
            CREATE TABLE message (
              seq INTEGER PRIMARY KEY,
              accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
              id TEXT NOT NULL,
              threadId TEXT NOT NULL,
              historyId TEXT,
              date DOUBLE NOT NULL,
              fromName TEXT NOT NULL DEFAULT '',
              fromEmail TEXT NOT NULL DEFAULT '',
              toList TEXT NOT NULL DEFAULT '[]',
              ccList TEXT NOT NULL DEFAULT '[]',
              bccList TEXT NOT NULL DEFAULT '[]',
              replyTo TEXT NOT NULL DEFAULT '[]',
              subject TEXT NOT NULL DEFAULT '',
              snippet TEXT NOT NULL DEFAULT '',
              bodyText TEXT,
              bodyHtml TEXT,
              bodyState INTEGER NOT NULL DEFAULT 0,
              labelIds TEXT NOT NULL DEFAULT '[]',
              isUnread INTEGER NOT NULL DEFAULT 0,
              isStarred INTEGER NOT NULL DEFAULT 0,
              isDraft INTEGER NOT NULL DEFAULT 0,
              isFromMe INTEGER NOT NULL DEFAULT 0,
              hasAttachments INTEGER NOT NULL DEFAULT 0,
              rfcMessageId TEXT,
              inReplyTo TEXT,
              refs TEXT,
              listUnsubscribe TEXT,
              listUnsubscribePost TEXT,
              sizeEstimate INTEGER NOT NULL DEFAULT 0,
              searchSender TEXT NOT NULL DEFAULT '',
              searchRecipients TEXT NOT NULL DEFAULT '',
              UNIQUE (accountId, id)
            );
            CREATE INDEX message_by_thread ON message(accountId, threadId, date);
            CREATE INDEX message_by_date ON message(date DESC);
            CREATE INDEX message_by_from ON message(fromEmail);
            CREATE INDEX message_body_pending ON message(accountId, date DESC) WHERE bodyState = 0;

            CREATE TABLE attachment (
              accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
              messageId TEXT NOT NULL,
              partId TEXT NOT NULL,
              attachmentId TEXT,
              filename TEXT NOT NULL,
              mimeType TEXT NOT NULL,
              size INTEGER NOT NULL DEFAULT 0,
              contentId TEXT,
              isInline INTEGER NOT NULL DEFAULT 0,
              localPath TEXT,
              PRIMARY KEY (accountId, messageId, partId)
            );

            -- Conversations, derived from their messages by MailStore.refreshThreads.
            CREATE TABLE thread (
              accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
              id TEXT NOT NULL,
              subject TEXT NOT NULL DEFAULT '',
              snippet TEXT NOT NULL DEFAULT '',
              lastDate DOUBLE NOT NULL,
              lastInboundDate DOUBLE,
              messageCount INTEGER NOT NULL DEFAULT 0,
              unreadCount INTEGER NOT NULL DEFAULT 0,
              isStarred INTEGER NOT NULL DEFAULT 0,
              isImportant INTEGER NOT NULL DEFAULT 0,
              hasAttachments INTEGER NOT NULL DEFAULT 0,
              hasDraft INTEGER NOT NULL DEFAULT 0,
              participants TEXT NOT NULL DEFAULT '[]',
              labelIds TEXT NOT NULL DEFAULT '[]',
              PRIMARY KEY (accountId, id)
            );
            CREATE INDEX thread_by_date ON thread(lastDate DESC);

            -- One row per (thread, label) from the union of its messages' labels. Mailbox lists read this.
            CREATE TABLE thread_label (
              accountId TEXT NOT NULL,
              threadId TEXT NOT NULL,
              labelId TEXT NOT NULL,
              lastDate DOUBLE NOT NULL,
              PRIMARY KEY (accountId, labelId, threadId),
              FOREIGN KEY (accountId, threadId) REFERENCES thread(accountId, id) ON DELETE CASCADE
            );
            CREATE INDEX thread_label_unified ON thread_label(labelId, lastDate DESC);
            CREATE INDEX thread_label_account ON thread_label(accountId, labelId, lastDate DESC);
            CREATE INDEX thread_label_by_thread ON thread_label(accountId, threadId);

            CREATE TABLE setting (
              key TEXT PRIMARY KEY NOT NULL,
              value TEXT NOT NULL
            );
            """)
    }

    private static func v1Search(_ db: Database) throws {
        // External-content index over `message`; triggers keep it in step. Only text columns
        // re-index on update, so label changes stay cheap.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE message_fts USING fts5(
              subject, searchSender, searchRecipients, snippet, bodyText,
              content='message', content_rowid='seq',
              tokenize='unicode61 remove_diacritics 2',
              prefix='2 3'
            );

            CREATE TRIGGER message_fts_insert AFTER INSERT ON message BEGIN
              INSERT INTO message_fts(rowid, subject, searchSender, searchRecipients, snippet, bodyText)
              VALUES (new.seq, new.subject, new.searchSender, new.searchRecipients, new.snippet, new.bodyText);
            END;

            CREATE TRIGGER message_fts_delete AFTER DELETE ON message BEGIN
              INSERT INTO message_fts(message_fts, rowid, subject, searchSender, searchRecipients, snippet, bodyText)
              VALUES ('delete', old.seq, old.subject, old.searchSender, old.searchRecipients, old.snippet, old.bodyText);
            END;

            CREATE TRIGGER message_fts_update
            AFTER UPDATE OF subject, searchSender, searchRecipients, snippet, bodyText ON message BEGIN
              INSERT INTO message_fts(message_fts, rowid, subject, searchSender, searchRecipients, snippet, bodyText)
              VALUES ('delete', old.seq, old.subject, old.searchSender, old.searchRecipients, old.snippet, old.bodyText);
              INSERT INTO message_fts(rowid, subject, searchSender, searchRecipients, snippet, bodyText)
              VALUES (new.seq, new.subject, new.searchSender, new.searchRecipients, new.snippet, new.bodyText);
            END;
            """)
    }

    private static func v1Features(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE thread_ai (
              accountId TEXT NOT NULL,
              threadId TEXT NOT NULL,
              category TEXT NOT NULL,
              needsReply INTEGER NOT NULL DEFAULT 0,
              priority INTEGER NOT NULL DEFAULT 1,
              summary TEXT,
              source TEXT NOT NULL DEFAULT 'rules',
              messageCount INTEGER NOT NULL DEFAULT 0,
              classifiedAt DOUBLE NOT NULL,
              PRIMARY KEY (accountId, threadId),
              FOREIGN KEY (accountId, threadId) REFERENCES thread(accountId, id) ON DELETE CASCADE
            );
            CREATE INDEX thread_ai_by_category ON thread_ai(category);

            CREATE TABLE project (
              id TEXT PRIMARY KEY NOT NULL,
              name TEXT NOT NULL,
              colorIndex INTEGER NOT NULL DEFAULT 0,
              icon TEXT,
              sortOrder INTEGER NOT NULL DEFAULT 0,
              createdAt DOUBLE NOT NULL
            );

            CREATE TABLE project_rule (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
              field TEXT NOT NULL,
              value TEXT NOT NULL
            );

            CREATE TABLE thread_project (
              accountId TEXT NOT NULL,
              threadId TEXT NOT NULL,
              projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
              source TEXT NOT NULL DEFAULT 'rule',
              PRIMARY KEY (accountId, threadId, projectId),
              FOREIGN KEY (accountId, threadId) REFERENCES thread(accountId, id) ON DELETE CASCADE
            );
            CREATE INDEX thread_project_by_project ON thread_project(projectId);

            CREATE TABLE snooze (
              accountId TEXT NOT NULL,
              threadId TEXT NOT NULL,
              until DOUBLE NOT NULL,
              PRIMARY KEY (accountId, threadId)
            );
            CREATE INDEX snooze_by_until ON snooze(until);

            CREATE TABLE draft (
              id TEXT PRIMARY KEY NOT NULL,
              accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
              gmailDraftId TEXT,
              gmailMessageId TEXT,
              threadId TEXT,
              replyToMessageId TEXT,
              kind TEXT NOT NULL DEFAULT 'new',
              toList TEXT NOT NULL DEFAULT '[]',
              ccList TEXT NOT NULL DEFAULT '[]',
              bccList TEXT NOT NULL DEFAULT '[]',
              subject TEXT NOT NULL DEFAULT '',
              bodyHtml TEXT NOT NULL DEFAULT '',
              attachments TEXT NOT NULL DEFAULT '[]',
              scheduledAt DOUBLE,
              state TEXT NOT NULL DEFAULT 'editing',
              lastError TEXT,
              updatedAt DOUBLE NOT NULL,
              createdAt DOUBLE NOT NULL
            );
            CREATE INDEX draft_by_thread ON draft(accountId, threadId);

            CREATE TABLE contact (
              id TEXT PRIMARY KEY NOT NULL,
              name TEXT NOT NULL DEFAULT '',
              sentCount INTEGER NOT NULL DEFAULT 0,
              receivedCount INTEGER NOT NULL DEFAULT 0,
              lastContacted DOUBLE
            );

            CREATE TABLE pending_op (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
              kind TEXT NOT NULL,
              payload TEXT NOT NULL,
              createdAt DOUBLE NOT NULL,
              notBefore DOUBLE,
              attempts INTEGER NOT NULL DEFAULT 0,
              lastError TEXT,
              state TEXT NOT NULL DEFAULT 'pending'
            );
            CREATE INDEX pending_op_by_account ON pending_op(accountId, id);
            """)
    }
}
