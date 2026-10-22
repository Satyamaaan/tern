import Foundation
import GRDB
import Testing
@testable import TernCore

struct LedgerActionTests {
    @Test(arguments: [CommitmentState.done, .dismissed, .stale])
    func localUndoAndLock(_ state: CommitmentState) throws {
        let (database, store, ask) = try ledgerFixture()
        let before = try store.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)])
        let id = try #require(before.first?.id)
        let undo = try store.setCommitmentState([id], to: state)
        #expect(try store.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)]).first?.stateSource == "user")
        _ = try store.setCommitmentState([id], to: .open)
        try database.writer.write { try Ledger.sweep($0, now: ledgerNow.addingTimeInterval(60 * 86_400)) }
        #expect(try store.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)]).first?.state == .open)
        try store.restoreCommitments(undo)
        #expect(try store.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)]) == before)
        #expect(try database.reader.read { try PendingOp.fetchCount($0) } == 0)
    }
}


extension LedgerActionTests {
    @Test func reopenedStateSurvivesRealReply() throws {
        let (database, store, _) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        let id = try #require(store.commitments(on: [key]).first?.id)
        _ = try store.setCommitmentState([id], to: .done)
        _ = try store.setCommitmentState([id], to: .open)
        try database.writer.write { db in
            let keys = try MailStore.upsertMessages(db, [MailMessage(accountId: "a", id: "reply", threadId: "t", date: ledgerNow,
                fromEmail: "maya@example.com", subject: "Proposal", snippet: "Here's my review", labelIds: [SystemLabel.inbox])])
            try Ledger.refresh(db, keys: keys, now: ledgerNow)
        }
        #expect(try store.commitments(on: [key]).first?.state == .open)
    }
}
