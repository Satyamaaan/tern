import Foundation
import GRDB
import Testing
@testable import TernCore

struct LedgerExtractionTests {
    private func extracted(_ message: MailMessage, direction: LedgerDirection = .waitingOn, text: String = "Review launch proposal", quote: String? = nil) -> LedgerExtraction {
        LedgerExtraction(direction: direction, counterparty: "maya@example.com", deliverable: text,
            sourceMessageId: message.id, quote: quote ?? message.snippet, sourceDate: message.date,
            dueAt: ledgerNow, dueText: "today", confidence: 2, existingId: nil)
    }

    @Test func ruleUpgradeDedupeAndUserLock() throws {
        let (db, store, message) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        let initial = try #require(store.commitments(on: [key]).first)
        try db.writer.write { db in
            try Ledger.applyExtraction(db, key: key, items: [extracted(message)], messageCount: 1, promptVersion: 1, origin: "groq", now: ledgerNow)
            try Ledger.applyExtraction(db, key: key, items: [extracted(message, text: "Review the launch proposal")], messageCount: 1, promptVersion: 1, origin: "groq", now: ledgerNow)
        }
        let rows = try store.commitments(on: [key])
        #expect(rows.count == 1)
        #expect(rows[0].id == initial.id)
        #expect(rows[0].kind == "deliverable")
        #expect(rows[0].origin == "groq")
        try db.writer.write { db in
            try db.execute(sql: "UPDATE commitment SET stateSource='user' WHERE id=?", arguments: [initial.id])
            try Ledger.applyExtraction(db, key: key, items: [extracted(message, text: "Review launch proposal again")], messageCount: 2, promptVersion: 1, origin: "groq", now: ledgerNow)
            #expect(try Commitment.fetchOne(db)?.deliverable == rows[0].deliverable)
            try db.execute(sql: "UPDATE commitment SET state='done',stateSource='user' WHERE id=?", arguments: [initial.id])
            try Ledger.applyExtraction(db, key: key, items: [extracted(message, text: "Review launch proposal again")], messageCount: 2, promptVersion: 1, origin: "groq", now: ledgerNow)
        }
        let locked = try #require(store.commitments(on: [key]).first)
        #expect(locked.state == .done)
        #expect(locked.deliverable == rows[0].deliverable)
    }

    @Test func oweRowsCountsSearchAndHints() throws {
        let (db, store, message) = try ledgerFixture(text: "I'll send the revised deck by Thursday.")
        let key = ThreadKey(accountId: "a", threadId: "t")
        try db.writer.write { db in
            try Ledger.applyExtraction(db, key: key, items: [extracted(message, direction: .iOwe, text: "Send revised deck")], messageCount: 1, promptVersion: 1, origin: "groq", now: ledgerNow)
        }
        #expect(try store.threadRows(in: Mailbox(.iOwe)).count == 1)
        #expect(try store.scopeCounts(accountId: nil).iOwe == 1)
        #expect(try SearchService(db).search("is:owe").count == 1)
        #expect(try SearchService(db).search("is:waiting").isEmpty)
        var reply = message; reply.id = "later"; reply.date = ledgerNow; reply.snippet = "Making progress on it."; reply.bodyText = reply.snippet
        try db.writer.write { db in
            let keys = try MailStore.upsertMessages(db, [reply])
            try MailStore.applyRules(db, keys: keys, now: ledgerNow)
        }
        let item = try #require(store.commitments(on: [key]).first)
        #expect(item.state == .open)
        #expect(item.hintMessageId == "later")
        let row = try #require(store.threadRows(in: Mailbox(.iOwe)).first)
        #expect(row.ledger?.hasHint == true)
        #expect(row.ledger?.deliverable == "Send revised deck")
    }

    @Test func zeroGoldLeavesDatabaseUntouched() throws {
        let db = try AppDatabase.inMemory()
        #expect(try FakeMailbox.populateLedgerAIGold(db, count: 0).isEmpty)
        #expect(try db.reader.read { try Account.fetchCount($0) } == 0)
    }
}

extension LedgerExtractionTests {
    @Test func similarDeliverablesRemainSeparateAndDismissalSticks() throws {
        let (db, store, message) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM commitment")
            let deck = extracted(message, text: "Send revised deck", quote: "Please send the revised deck tomorrow.")
            let budget = extracted(message, text: "Send revised budget", quote: "Please send the revised budget tomorrow.")
            try Ledger.applyExtraction(db, key: key, items: [deck, budget], messageCount: 1, promptVersion: 2, origin: "groq", now: ledgerNow)
            #expect(try Commitment.fetchCount(db) == 2)
            #expect(Set(try Commitment.fetchAll(db).map(\.fingerprint)).count == 2)
            try db.execute(sql: "UPDATE commitment SET state='dismissed',stateSource='user' WHERE deliverable='Send revised deck'")
            let reworded = extracted(message, text: "Send the revised deck", quote: "send the revised deck tomorrow.")
            try Ledger.applyExtraction(db, key: key, items: [reworded], messageCount: 1, promptVersion: 2, origin: "groq", now: ledgerNow)
        }
        let items = try store.commitments(on: [key])
        #expect(items.count == 2)
        #expect(items.filter { $0.state == .dismissed }.count == 1)
    }

    @Test func localCalendarDueFormatting() {
        for zone in ["America/Los_Angeles", "Asia/Kolkata"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 23))!
            var brief = CommitmentBrief(id: 1, counterpartyEmail: "m@example.com", counterpartyName: "Maya", sourceDate: now, extraCount: 0, surfaceAt: now)
            for (offset, expected) in [(0, "Today"), (1, "Tomorrow"), (2, "Sat"), (7, "Oct 29"), (-1, "Yesterday"), (-2, "2d late"), (-15, "Oct 7")] {
                brief.dueAt = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))
                #expect(brief.timeText(now: now, calendar: calendar) == expected)
                #expect(brief.isOverdue(now: now, calendar: calendar) == (offset < 0))
            }
        }
    }
}

extension LedgerExtractionTests {
    @Test func resolutionCannotChangeUserLockedItem() throws {
        let (database, _, message) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        try database.writer.write { db in
            try Ledger.applyExtraction(db, key: key, items: [extracted(message)], messageCount: 1, promptVersion: 2, origin: "groq", now: ledgerNow)
            var item = try #require(try Commitment.fetchOne(db))
            item.stateSource = "user"
            try item.update(db)
            try Ledger.applyResolutionHint(db, id: item.id!, messageId: "later", at: ledgerNow,
                note: "withdrawn: Please cancel the proposal request.", newDueAt: ledgerNow.addingTimeInterval(86400), now: ledgerNow)
            #expect(try Commitment.fetchOne(db) == item)
        }
    }

    @Test func emptyTokensAndDifferentSourcesHaveUniqueFingerprints() throws {
        let (database, _, message) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM commitment")
            var second = message; second.id = "other"
            let values = [extracted(message, text: "!!!", quote: "First evidence"), extracted(message, text: "???", quote: "Second evidence"), extracted(second, text: "!!!", quote: "Third evidence")]
            try Ledger.applyExtraction(db, key: key, items: values, messageCount: 2, promptVersion: 2, origin: "groq", now: ledgerNow)
            #expect(try Commitment.fetchCount(db) == 3)
            #expect(Set(try Commitment.fetchAll(db).map(\.fingerprint)).count == 3)
        }
    }
}

extension LedgerExtractionTests {
    @Test func refinementPreservesEvidenceDateAndConfidence() throws {
        let (database, _, message) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        try database.writer.write { db in
            try Ledger.applyExtraction(db, key: key, items: [extracted(message)], messageCount: 1, promptVersion: 2, origin: "groq", now: ledgerNow)
            let original = try #require(try Commitment.fetchOne(db))
            var next = extracted(message)
            next.existingId = original.id; next.sourceMessageId = "later"; next.sourceDate = ledgerNow
            next.confidence = 1; next.dueAt = nil; next.dueText = nil
            try Ledger.applyExtraction(db, key: key, items: [next], messageCount: 2, promptVersion: 2, origin: "groq", now: ledgerNow)
            let updated = try #require(try Commitment.fetchOne(db))
            #expect(updated.dueAt == original.dueAt)
            #expect(updated.confidence == 2)
            #expect(updated.sourceMessageId == message.id)
            #expect(updated.sourceDate == message.date)
            try Ledger.applyResolutionHint(db, id: original.id!, messageId: nil, at: nil, note: nil,
                newDueAt: ledgerNow.addingTimeInterval(86400), now: ledgerNow)
            #expect(try Commitment.fetchOne(db)?.dueAt == original.dueAt)
        }
    }
}

extension LedgerExtractionTests {
    @Test func rescheduleWithSharedEvidenceKeepsOriginalSource() throws {
        let (database, _, message) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM commitment")
            let original = extracted(message, text: "Send revised deck.pptx", quote: "I'll send the revised deck.pptx by Thursday.")
            var changed = extracted(message, text: "Send revised deck.pptx tomorrow", quote: "Update: I will send the revised deck.pptx tomorrow instead.")
            changed.sourceMessageId = "reschedule"; changed.sourceDate = ledgerNow
            changed.dueAt = ledgerNow.addingTimeInterval(86400)
            try Ledger.applyExtraction(db, key: key, items: [changed, original], messageCount: 2, promptVersion: 2, origin: "groq", now: ledgerNow)
            let rows = try Commitment.fetchAll(db)
            #expect(rows.count == 1)
            #expect(rows.first?.sourceMessageId == message.id)
            #expect(rows.first?.dueAt == changed.dueAt)
        }
    }
}
