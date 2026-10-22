import Foundation
import GRDB
import Testing
@testable import TernCore

struct LedgerRegressionTests {
    @Test(arguments: [
        ("Here is https://example.com/path?q=review", false),
        ("See https://example.com/path? for details", false),
        ("Contact question?@example.com for details", false),
        ("Please find attached the receipt.", false),
        ("I confirm receipt of the proposal.", false),
        ("I approve the change.", false),
        ("Looking forward to our meeting.", false),
        ("Could you review this?", true),
        ("Can you confirm receipt", true),
        ("Please share the final draft", true),
        ("Please let me know when it ships", true),
        ("Approve this?", true),
        ("Would you sign the agreement", true),
        ("Please reply by Friday", true),
        ("Attached for your review", true)
    ])
    func askPhrasings(_ sample: (String, Bool)) throws {
        #expect(Ledger.isAsk(sample.0) == sample.1)
        let (_, store, _) = try ledgerFixture(text: sample.0)
        #expect(try store.commitments(on: [key]).isEmpty == !sample.1)
    }

    private var key: ThreadKey { ThreadKey(accountId: "a", threadId: "t") }

    @Test(arguments: ["support@example.com", "info@example.com", "hello@example.com", "team@example.com", "help@example.com", "billing@example.com"])
    func roleQuestionAndHumanReply(_ email: String) throws {
        let (database, store, _) = try ledgerFixture(recipients: [Participant(email: email)])
        #expect(try store.commitments(on: [key]).count == 1)
        try database.writer.write { db in
            let keys = try MailStore.upsertMessages(db, [reply(email: email)])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
        }
        #expect(try store.commitments(on: [key]).first?.state == .done)
        let (_, excluded, _) = try ledgerFixture(text: "Please review the proposal", recipients: [Participant(email: email)])
        #expect(try excluded.commitments(on: [key]).isEmpty)
    }

    private func reply(email: String) -> MailMessage {
        MailMessage(accountId: "a", id: "reply", threadId: "t", date: ledgerNow,
            fromEmail: email, subject: "Proposal", snippet: "Here is the review", labelIds: [SystemLabel.inbox])
    }

    @Test func unrelatedReplyDoesNotResolve() throws {
        let (database, store, _) = try ledgerFixture()
        try database.writer.write { db in
            let keys = try MailStore.upsertMessages(db, [reply(email: "stranger@example.com")])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
        }
        #expect(try store.commitments(on: [key]).first?.state == .open)
    }

    @Test func originalCcResolvesButLaterCcDoesNot() throws {
        let (database, store, ask) = try ledgerFixture()
        try database.writer.write { db in
            var source = ask
            source.ccList = [Participant(email: "original@example.com")]
            var nudge = source
            nudge.id = "nudge"; nudge.date = ledgerNow.addingTimeInterval(-1)
            nudge.ccList = [Participant(email: "later@example.com")]
            let keys = try MailStore.upsertMessages(db, [source, nudge, reply(email: "later@example.com")])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
            #expect(try Commitment.fetchOne(db)?.state == .open)
            var original = reply(email: "original@example.com"); original.id = "original-reply"
            _ = try MailStore.upsertMessages(db, [original])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
        }
        #expect(try store.commitments(on: [key]).first?.state == .done)
    }

    @Test func newAskAfterReplyKeepsDismissedHistory() throws {
        let (database, store, ask) = try ledgerFixture()
        let first = try #require(store.commitments(on: [key]).first)
        _ = try store.setCommitmentState([try #require(first.id)], to: .dismissed)
        try database.writer.write { db in
            var next = ask; next.id = "next"; next.date = ledgerNow.addingTimeInterval(1)
            let keys = try MailStore.upsertMessages(db, [reply(email: "maya@example.com"), next])
            try Ledger.refresh(db, keys: keys, now: ledgerNow.addingTimeInterval(2))
        }
        let items = try store.commitments(on: [key])
        #expect(items.count == 2)
        #expect(items.first?.state == .dismissed)
        #expect(items.last?.sourceMessageId == "next")
        #expect(items.last?.fingerprint != first.fingerprint)
    }

    @Test func skipsNonAskAtStartOfSentRun() throws {
        let (database, store, first) = try ledgerFixture(text: "Here is the update.")
        try database.writer.write { db in
            var ask = first; ask.id = "actual-ask"; ask.snippet = "Can you confirm the date?"; ask.date = first.date.addingTimeInterval(1)
            var nudge = ask; nudge.id = "nudge"; nudge.date = ledgerNow
            let keys = try MailStore.upsertMessages(db, [ask, nudge])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
        }
        #expect(try store.commitments(on: [key]).first?.sourceMessageId == "actual-ask")
    }

    @Test(arguments: ["mute", "category", "list", "TRASH", "SPAM"])
    func changedConditionsStaleExistingRules(_ condition: String) throws {
        let (database, store, ask) = try ledgerFixture()
        try database.writer.write { db in
            var changed = ask
            if condition == "mute" { changed.labelIds.append(MailStore.pendingMuteLabel) }
            if condition == "TRASH" || condition == "SPAM" { changed.labelIds.append(condition) }
            if condition == "list" { changed.listUnsubscribe = "unsubscribe" }
            _ = try MailStore.upsertMessages(db, [changed])
            if condition == "category" { try db.execute(sql: "UPDATE thread_ai SET category='promotions' WHERE accountId='a' AND threadId='t'") }
            try Ledger.refresh(db, keys: [key], now: ledgerNow)
        }
        #expect(try store.commitments(on: [key]).first?.state == .stale)
        #expect(try store.threadRows(in: Mailbox(.waitingOn)).isEmpty)
    }

    @Test(arguments: ["TRASH", "SPAM", MailStore.pendingMuteLabel, "custom-muted"])
    func lockedItemsHidden(_ label: String) throws {
        let (database, store, ask) = try ledgerFixture()
        _ = try store.setCommitmentState([try #require(store.commitments(on: [key]).first?.id)], to: .open)
        try database.writer.write { db in
            try Setting(key: MailStore.muteLabelKey("a"), value: "custom-muted").upsert(db)
            var changed = ask; changed.labelIds.append(label)
            _ = try MailStore.upsertMessages(db, [changed])
            try Ledger.refresh(db, keys: [key], now: ledgerNow)
            #expect(try MailStore.fetchLedgerCount(db, accountId: nil) == 0)
        }
        #expect(try store.threadRows(in: Mailbox(.waitingOn)).isEmpty)
    }

    @Test func malformedJsonDoesNotAbortRefresh() throws {
        let (database, _, _) = try ledgerFixture()
        try database.writer.write { db in
            try db.execute(sql: "UPDATE message SET toList='bad',ccList='bad'")
            try Ledger.refresh(db, keys: [key], now: ledgerNow)
            try db.execute(sql: "UPDATE thread SET labelIds='bad'")
            try Ledger.refresh(db, keys: [key], now: ledgerNow)
        }
    }

    @Test func availabilityProbeBoundsSelections() throws {
        let (_, store, _) = try ledgerFixture()
        #expect(try store.hasCommitments(on: [key], state: .open))
        #expect(try !store.hasCommitments(on: Array(repeating: key, count: 51), state: .open))
    }
}

extension LedgerRegressionTests {
    @Test func replyBeforeReopenDoesNotResolveAgain() throws {
        let (database, store, _) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        let id = try #require(store.commitments(on: [key]).first?.id)
        try database.writer.write { db in
            let keys = try MailStore.upsertMessages(db, [MailMessage(accountId: "a", id: "reply", threadId: "t", date: ledgerNow,
                fromEmail: "maya@example.com", subject: "Proposal", snippet: "Done", labelIds: [SystemLabel.inbox])])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
            _ = try MailStore.setCommitmentState(db, [id], to: .open, now: ledgerNow.addingTimeInterval(1))
            try Ledger.refresh(db, keys: keys, now: ledgerNow.addingTimeInterval(2))
        }
        #expect(try store.commitments(on: [key]).first?.state == .open)
    }

    @Test(arguments: [CommitmentState.done, .dismissed])
    func userDecisionsStayStickyAfterReply(_ state: CommitmentState) throws {
        let (database, store, _) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        _ = try store.setCommitmentState([try #require(store.commitments(on: [key]).first?.id)], to: state)
        try database.writer.write { db in
            let keys = try MailStore.upsertMessages(db, [MailMessage(accountId: "a", id: "reply", threadId: "t", date: ledgerNow,
                fromEmail: "maya@example.com", subject: "Proposal", snippet: "Done", labelIds: [SystemLabel.inbox])])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
        }
        let item = try #require(store.commitments(on: [key]).first)
        #expect(item.state == state && item.stateSource == "user")
    }
}
