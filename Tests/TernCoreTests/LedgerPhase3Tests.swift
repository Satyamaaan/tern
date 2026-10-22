import Foundation
import GRDB
import Testing
@testable import TernCore

struct LedgerPhase3Tests {
    @Test func manualCreateDetailDoneSearchReopenAndUndo() throws {
        let (database, store, _) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        let undo = try store.trackCommitment(on: key, direction: .iOwe, deliverable: "Send revised proposal", counterparty: Participant(name: "Maya", email: "maya@example.com"), dueAt: ledgerNow, now: ledgerNow)
        let id = try #require(undo.created.first)
        let detail = try #require(try store.threadDetail(key))
        #expect(detail.commitments.contains { $0.id == id && $0.origin == "manual" && $0.stateSource == "user" })
        let doneUndo = try store.setCommitmentState([id], to: .done)
        let done = try SearchService(database).search("is:done")
        #expect(done.contains { $0.id == key })
        let reopenUndo = try store.setCommitmentState([id], to: .open)
        #expect(try database.reader.read { try Commitment.fetchOne($0, key: id)?.stateSource } == "user")
        #expect(try SearchService(database).search("is:done").isEmpty)
        try store.restoreCommitments(reopenUndo)
        #expect(try database.reader.read { try Commitment.fetchOne($0, key: id)?.state } == .done)
        try store.restoreCommitments(doneUndo)
        #expect(try database.reader.read { try Commitment.fetchOne($0, key: id)?.state } == .open)
        try store.restoreCommitments(undo)
        #expect(try database.reader.read { try Commitment.fetchOne($0, key: id) } == nil)
    }
    @Test @MainActor func readerObservationIncludesCommitments() async throws {
        let (database, store, _) = try ledgerFixture()
        let key = ThreadKey(accountId: "a", threadId: "t")
        var latest: ThreadDetail?
        let observer = ThreadDetailObserver(store: store, key: key) { latest = $0 }
        defer { observer.cancel() }
        let initial = latest?.commitments.count ?? 0
        let undo = try await Task.detached {
            try store.trackCommitment(on: key, direction: .iOwe, deliverable: "Send proposal", counterparty: Participant(email: "maya@example.com"), dueAt: nil)
        }.value
        for _ in 0..<100 {
            if latest?.commitments.count == initial + 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(latest?.commitments.contains { undo.created.contains($0.id ?? -1) } == true)
        _ = database
    }

}
