import AppKit
import GRDB
import Testing
@testable import Tern
import TernCore

@MainActor
@Test func anOlderPlainReadCannotRestoreRowsRemovedByTheObservation() throws {
    let database = try AppDatabase.inMemory()
    let account = Account(email: "synthetic@example.com")
    try database.writer.write { db in
        try account.insert(db)
        try MailStore.upsertMessages(db, [MailMessage(accountId: account.id, id: "m", threadId: "t", date: Date(),
            fromEmail: "sender@example.com", subject: "Synthetic", labelIds: [SystemLabel.inbox])])
    }
    let model = AppModel(services: AppServices(store: MailStore(database)), isFake: true,
                         databaseURL: URL(fileURLWithPath: "/dev/null"))
    model.inboxTab = nil
    model.reloadList()
    let old = try database.reader.read { try model.rowsSource.current.fetch($0) }
    let key = try #require(old.rows.first?.id)
    model.hidden[key] = .committed
    model.receiveRows(.init(request: old.request, rows: []), fromObservation: true)
    #expect(model.snapshot.isEmpty && model.hidden[key] == nil)
    model.receiveRows(old)
    #expect(model.snapshot.isEmpty)

    model.reloadList()
    #expect(model.snapshot.order == [key])
    model.receiveRows(.init(request: old.request, rows: []), fromObservation: true)
    #expect(model.snapshot.order == [key])
}

@MainActor
@Test func anOlderPlainReadCannotOverwriteObservedScopeCounts() throws {
    _ = NSApplication.shared
    let model = AppModel(services: AppServices(store: MailStore(try AppDatabase.inMemory())), isFake: true,
                         databaseURL: URL(fileURLWithPath: "/dev/null"))
    let request = model.scopeSource.set(accountId: "first")
    var latest = ScopeCounts()
    latest.inboxUnread = 2
    latest.tabThreads = [.promotions: 2]
    model.receiveCounts(.init(request: request, counts: latest), fromObservation: true)
    model.receiveCounts(.init(request: request, counts: ScopeCounts()))
    #expect(model.counts == latest && model.tabsWithMail == [.promotions])

    let next = model.scopeSource.set(accountId: nil)
    var all = ScopeCounts()
    all.inboxUnread = 3
    model.receiveCounts(.init(request: next, counts: all))
    model.receiveCounts(.init(request: request, counts: latest), fromObservation: true)
    #expect(model.counts == all && model.tabsWithMail.isEmpty)
}
