import Foundation
@testable import GRDB
import Testing
@testable import Tern
@testable import TernCore

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

@Test func scopeObservationsCoverCountsAndLabelsQueries() throws {
    let database = try AppDatabase.inMemory()
    let account = Account(email: "synthetic@example.com")
    try database.writer.write { db in
        try account.insert(db)
        try Draft(accountId: account.id, subject: "Local draft").insert(db)
        let countsRegion = try observationRegion(ScopeObservationSource.countsRegions, db)
        let labelsRegion = try observationRegion(ScopeObservationSource.labelsRegions, db)
        for enabled in [true, false] {
            try Setting(key: "ledger.enabled", value: String(enabled)).upsert(db)
            for showMaybe in [true, false] {
                try Setting(key: "ledger.showMaybe", value: String(showMaybe)).upsert(db)
                for accountId in [nil, account.id] {
                    let request = ScopeObservationSource.Request(accountId: accountId)
                    var selectedCounts = DatabaseRegion()
                    _ = try db.recordingSelection(&selectedCounts) { try request.fetchCounts(db) }
                    #expect(countsRegion.union(selectedCounts) == countsRegion, "Missing counts region: \(selectedCounts)")
                    var selectedLabels = DatabaseRegion()
                    _ = try db.recordingSelection(&selectedLabels) { try request.fetchLabels(db) }
                    #expect(labelsRegion.union(selectedLabels) == labelsRegion, "Missing labels region: \(selectedLabels)")
                }
            }
        }
    }
}

@Test func unrelatedHotColumnsDoNotInvalidateMailObservations() throws {
    let database = try AppDatabase.inMemory()
    try database.reader.read { db in
        let list = try observationRegion(ListObservationSource.regions, db)
        let counts = try observationRegion(ScopeObservationSource.countsRegions, db)
        for region in [list, counts] {
            #expect(!region.isModified(byEventsOfKind: .update(tableName: "message", columnNames: ["bodyText", "bodyHtml", "bodyState"])))
            #expect(!region.isModified(byEventsOfKind: .update(tableName: "thread_ai", columnNames: ["classifiedAt"])))
        }
        #expect(!list.isModified(byEventsOfKind: .update(tableName: "account", columnNames: ["historyId", "lastSyncAt"])))
        #expect(list.isModified(byEventsOfKind: .update(tableName: "message", columnNames: ["searchRecipients"])))
        #expect(list.isModified(byEventsOfKind: .update(tableName: "draft", columnNames: ["bodyHtml"])))
        #expect(!counts.isModified(byEventsOfKind: .update(tableName: "draft", columnNames: ["bodyHtml", "updatedAt"])))
        #expect(!counts.isModified(byEventsOfKind: .update(tableName: "commitment", columnNames: ["sourceQuote", "updatedAt"])))
    }
}

@Test func detailObservationCoversEveryDetailQuery() throws {
    let database = try AppDatabase.inMemory()
    let store = MailStore(database)
    let account = Account(email: "synthetic@example.com")
    let key = ThreadKey(accountId: account.id, threadId: "thread")
    try database.writer.write { db in
        try account.insert(db)
        try MailStore.upsertMessages(db, [
            MailMessage(accountId: account.id, id: "message", threadId: key.threadId, date: Date(),
                fromEmail: "sender@example.com", bodyText: "Please send the proposal", labelIds: [SystemLabel.inbox]),
            MailMessage(accountId: account.id, id: "draft", threadId: "draft", date: Date(),
                fromEmail: account.email, bodyHtml: "<p>Draft reply</p>", labelIds: [SystemLabel.draft]),
        ])
        try MailAttachment(accountId: account.id, messageId: "message", partId: "1", filename: "proposal.pdf",
                           mimeType: "application/pdf", size: 100).insert(db)
        let project = Project(name: "Proposal")
        try project.insert(db)
        try ThreadProject(accountId: account.id, threadId: key.threadId, projectId: project.id, source: .manual).insert(db)
        try ThreadAI(accountId: account.id, threadId: key.threadId, category: .people, summary: "Send proposal", messageCount: 1).insert(db)
        try Snooze(accountId: account.id, threadId: key.threadId, until: Date()).insert(db)
    }
    _ = try store.trackCommitment(on: key, direction: .iOwe, deliverable: "Send proposal",
                                 counterparty: Participant(email: "sender@example.com"), dueAt: nil)
    try database.writer.write { db in
        try db.execute(sql: "UPDATE commitment SET sourceQuote = ''")
        let observed = try observationRegion(DetailObservationSource.regions, db)
        for enabled in [true, false] {
            try Setting(key: "ledger.enabled", value: String(enabled)).upsert(db)
            for showMaybe in [true, false] {
                try Setting(key: "ledger.showMaybe", value: String(showMaybe)).upsert(db)
                for threadId in [key.threadId, "draft", "missing"] {
                    var selected = DatabaseRegion()
                    let detail = try db.recordingSelection(&selected) {
                        try MailStore.fetchThreadDetail(db, ThreadKey(accountId: account.id, threadId: threadId))
                    }
                    if enabled && threadId == key.threadId {
                        #expect(detail?.commitments.first?.sourceQuote == "Please send the proposal")
                    }
                    #expect(observed.union(selected) == observed, "Missing detail region: \(selected)")
                }
            }
        }
        #expect(!observed.isModified(byEventsOfKind: .update(tableName: "thread_project", columnNames: ["source"])))
        #expect(!observed.isModified(byEventsOfKind: .update(tableName: "account", columnNames: ["historyId", "lastSyncAt"])))
        #expect(!observed.isModified(byEventsOfKind: .update(tableName: "draft", columnNames: ["bodyHtml"])))
        #expect(observed.isModified(byEventsOfKind: .update(tableName: "message", columnNames: ["bodyHtml", "bodyState"])))
    }
}
