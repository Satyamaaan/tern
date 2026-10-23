import Foundation
@testable import GRDB
import Testing
@testable import Tern
import TernCore

@Test func listObservationCoversEveryMailboxQuery() throws {
    let database = try AppDatabase.inMemory()
    let account = Account(email: "synthetic@example.com")
    try database.writer.write { db in
        try account.insert(db)
        try Draft(accountId: account.id, subject: "Local draft", bodyHtml: "<p>Unsent</p>").insert(db)
        try Setting(key: "ledger.enabled", value: "true").insert(db)
        let kinds: [Mailbox.Kind] = [.inbox, .starred, .important, .snoozed, .sent, .drafts, .allMail,
            .archive, .spam, .trash, .label("custom"), .project("project"), .needsReply, .due, .iOwe, .waitingOn]
            + MailCategory.allCases.map(Mailbox.Kind.category)
        let observed = try observationRegion(ListObservationSource.regions, db)
        for accountId in [nil, account.id] {
            for kind in kinds {
                let tabs: [InboxTab?] = kind == .inbox ? [nil] + InboxTab.allCases.map(Optional.some) : [nil]
                for tab in tabs {
                    let source = ListSource(mailbox: Mailbox(kind, accountId: accountId), tab: tab)
                    var selected = DatabaseRegion()
                    let rows = try db.recordingSelection(&selected) { try source.fetch(db, limit: 200) }
                    if kind == .drafts { #expect(rows.contains { MailThread.localDraftId(in: $0.id) != nil }) }
                    #expect(observed.union(selected) == observed, "Missing region for \(source): \(selected)")
                }
            }
        }
    }
}

private func observationRegion(_ regions: [any DatabaseRegionConvertible], _ db: Database) throws -> DatabaseRegion {
    try regions.reduce(into: DatabaseRegion()) { result, region in
        try result.formUnion(region.databaseRegion(db))
    }
}
