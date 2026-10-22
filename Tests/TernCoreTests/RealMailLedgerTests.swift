import Foundation
import GRDB
import Testing
@testable import TernCore

struct RealMailLedgerTests {
    @Test(arguments: ["Yes", "Sounds good", "Here is a short update without any request to act.", "Okay"])
    func sentOnlyClosersAreCandidatesButNotPromises(_ text: String) throws {
        let (db, _, _) = try ledgerFixture(text: text)
        let counts = try db.reader.read { (try Ledger.waitingCandidates($0, now: ledgerNow).count, try Commitment.fetchCount($0)) }
        #expect(counts.0 == 1 && counts.1 == 0)
    }

    @Test func staleBackfillFlagCannotSuppressRequests() throws {
        let (db, _, _) = try ledgerFixture()
        try db.writer.write {
            try Commitment.deleteAll($0)
            try Setting(key: "ledger.backfilled", value: "1").upsert($0)
        }
        try Ledger.rebuildWaiting(in: db, now: ledgerNow, onlyIfNeeded: true)
        #expect(try db.reader.read { try Commitment.fetchCount($0) } == 1)
    }

    @Test func emptySidebarVisibilityTracksFeatureSwitch() throws {
        let db = try AppDatabase.inMemory()
        let store = MailStore(db)
        let counts = try store.scopeCounts(accountId: nil)
        #expect(counts.ledgerEnabled && counts.waitingOn == 0 && counts.iOwe == 0)
        try store.setLedgerSettings(enabled: false, waitingDays: 3)
        #expect(try store.scopeCounts(accountId: nil).ledgerEnabled == false)
    }

}
