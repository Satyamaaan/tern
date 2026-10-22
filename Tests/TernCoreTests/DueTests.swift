import Foundation
import GRDB
import Testing
@testable import TernCore

struct DueTests {
    @Test func bothDirectionsKeepTheirRowsAndActions() throws {
        let (_, store, ask) = try ledgerFixture()
        let key = ThreadKey(accountId: ask.accountId, threadId: ask.threadId)
        let tracked = try store.trackCommitment(on: key, direction: .iOwe, deliverable: "Send proposal",
            counterparty: Participant(name: "Maya", email: "maya@example.com"), dueAt: ledgerNow, now: ledgerNow)
        let rows = try store.threadRows(in: Mailbox(.due), limit: 1)
        #expect(rows.map { $0.ledger?.direction } == [.iOwe, .waitingOn])
        let counts = try store.scopeCounts(accountId: nil)
        #expect(counts.waitingOn + counts.iOwe == 2)
        #expect(try store.threadRows(in: Mailbox(.due, accountId: "other")).isEmpty)
        let ids = try store.commitments(on: [key]).compactMap(\.id)
        let undo = try store.setCommitmentState(ids, to: .done)
        #expect(try store.threadRows(in: Mailbox(.due)).isEmpty)
        try store.restoreCommitments(undo)
        #expect(try store.threadRows(in: Mailbox(.due)).count == 2)
        _ = try store.setCommitmentState(ids, to: .dismissed)
        #expect(try store.threadRows(in: Mailbox(.due)).isEmpty)
        try store.restoreCommitments(tracked)
    }

    @Test func dueSearchKeepsDirectionalTokens() throws {
        let (_, store, _) = try ledgerFixture()
        let search = SearchService(store.database)
        #expect(try search.search("is:due").count == 1)
        #expect(try search.search("is:waiting").count == 1)
        #expect(try search.search("is:owe").isEmpty)
    }
}
