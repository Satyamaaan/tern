import Foundation
import GRDB
import Testing
@testable import TernCore

struct LedgerWaitingTests {
    @Test(arguments: ["Thanks!", "OK", "Sounds good", "Great!", "Got it", "Here is a long update without any request for action."])
    func skipsClosers(_ text: String) throws {
        let (_, store, ask) = try ledgerFixture(text: text)
        #expect(try store.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)]).isEmpty)
    }

    @Test(arguments: ["noreply@example.com", "mailer-daemon@example.com", "me@example.com"])
    func skipsRecipients(_ email: String) throws {
        let (_, store, ask) = try ledgerFixture(recipients: [Participant(email: email)])
        #expect(try store.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)]).isEmpty)
    }

    @Test func skipsBulkAndCrowds() throws {
        let (_, bulk, ask) = try ledgerFixture(unsubscribe: "unsubscribe")
        #expect(try bulk.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)]).isEmpty)
        let (_, crowd, other) = try ledgerFixture(recipients: (0..<7).map { Participant(email: "person\($0)@example.com") })
        #expect(try crowd.commitments(on: [ThreadKey(accountId: other.accountId, threadId: other.threadId)]).isEmpty)
    }

    @Test func nudgeAndThreshold() throws {
        let (database, store, ask) = try ledgerFixture()
        var nudge = ask
        nudge.id = "nudge"; nudge.date = ledgerNow.addingTimeInterval(-86_400)
        try database.writer.write { db in
            let keys = try MailStore.upsertMessages(db, [nudge])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
            #expect(try Commitment.fetchCount(db) == 1)
        }
        let item = try #require(store.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)]).first)
        #expect(item.sourceMessageId == "ask")
        #expect(item.surfaced)
        try store.setLedgerSettings(enabled: true, waitingDays: 7, now: ledgerNow)
        #expect(try store.threadRows(in: Mailbox(.waitingOn)).isEmpty)
        try database.writer.write { try Ledger.sweep($0, now: ledgerNow.addingTimeInterval(3 * 86_400)) }
        #expect(try store.threadRows(in: Mailbox(.waitingOn)).count == 1)
    }

    @Test(arguments: ["Automatic reply", "Out of office", "Autoreply", "Proposal"])
    func resolution(_ subject: String) throws {
        let (database, store, ask) = try ledgerFixture()
        let reply = MailMessage(accountId: "a", id: "reply", threadId: "t", date: ledgerNow,
            fromEmail: "maya@example.com", subject: subject, snippet: "Hello", labelIds: [SystemLabel.inbox])
        try database.writer.write { db in
            let keys = try MailStore.upsertMessages(db, [reply])
            try MailStore.applyRules(db, keys: keys, now: ledgerNow)
        }
        let item = try #require(store.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)]).first)
        #expect(item.state == (subject == "Proposal" ? .done : .open))
    }

    @Test func mutedAndStale() throws {
        let (database, store, ask) = try ledgerFixture()
        try database.writer.write { db in
            try Commitment.deleteAll(db)
            try Setting(key: MailStore.muteLabelKey("a"), value: "muted").upsert(db)
            var muted = ask; muted.labelIds.append("muted")
            let keys = try MailStore.upsertMessages(db, [muted])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
            #expect(try Commitment.fetchCount(db) == 0)
            _ = try MailStore.upsertMessages(db, [ask])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
            try Ledger.sweep(db, now: ledgerNow.addingTimeInterval(46 * 86_400))
        }
        #expect(try store.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)]).first?.state == .stale)
    }
}


extension LedgerWaitingTests {
    @Test(arguments: ["TRASH", "SPAM", "missing"])
    func invalidSourcesBecomeStale(_ label: String) throws {
        let (database, store, ask) = try ledgerFixture()
        try database.writer.write { db in
            if label == "missing" {
                try db.execute(sql: "DELETE FROM message WHERE id='ask'")
            } else {
                var changed = ask; changed.labelIds.append(label)
                _ = try MailStore.upsertMessages(db, [changed])
            }
            try Ledger.sweep(db, now: ledgerNow)
        }
        #expect(try store.commitments(on: [ThreadKey(accountId: "a", threadId: "t")]).first?.state == .stale)
    }

    @Test func draftsAndOtherOwnAccounts() throws {
        let (database, store, ask) = try ledgerFixture()
        try database.writer.write { db in
            try Commitment.deleteAll(db)
            try Account(email: "second@example.com").upsert(db)
            var own = ask; own.toList = [Participant(email: "second@example.com")]
            _ = try MailStore.upsertMessages(db, [own])
            try Ledger.refresh(db, keys: [ThreadKey(accountId: "a", threadId: "t")], now: ledgerNow)
            #expect(try Commitment.fetchCount(db) == 0)
            var draft = ask; draft.id = "draft"; draft.isDraft = true; draft.date = ledgerNow
            _ = try MailStore.upsertMessages(db, [ask, draft])
            try Ledger.refresh(db, keys: [ThreadKey(accountId: "a", threadId: "t")], now: ledgerNow)
        }
        #expect(try store.commitments(on: [ThreadKey(accountId: "a", threadId: "t")]).first?.sourceMessageId == "ask")
    }
}

extension LedgerWaitingTests {
    @Test(arguments: ["noreply@example.com", "mailer-daemon@example.com", "me@example.com"])
    func automatedAndOwnRepliesDoNotResolve(_ email: String) throws {
        let (database, store, _) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        try database.writer.write { db in
            let keys = try MailStore.upsertMessages(db, [MailMessage(accountId: "a", id: "reply", threadId: "t", date: ledgerNow,
                fromEmail: email, subject: "Proposal", snippet: "Message received", labelIds: [SystemLabel.inbox])])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
        }
        #expect(try store.commitments(on: [key]).first?.state == .open)
    }
}

extension LedgerWaitingTests {
    @Test func reenableReconcilesRepliesReceivedWhileDisabled() throws {
        let (database, store, _) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        try store.setLedgerSettings(enabled: false, waitingDays: 3, now: ledgerNow)
        try database.writer.write { db in
            let keys = try MailStore.upsertMessages(db, [MailMessage(accountId: "a", id: "reply", threadId: "t", date: ledgerNow,
                fromEmail: "maya@example.com", subject: "Proposal", snippet: "Here's my review", labelIds: [SystemLabel.inbox])])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
            try Setting(key: "ledger.enabled", value: "true").upsert(db)
            try Ledger.rebuildWaiting(db, now: ledgerNow)
        }
        #expect(try store.commitments(on: [key]).first?.state == .done)
    }
}
