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
