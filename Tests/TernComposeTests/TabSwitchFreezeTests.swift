import Foundation
import GRDB
import Testing
@testable import Tern
import TernCore

@MainActor
@Test func tabSwitchesReturnWhileTheWriterIsHeld() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-tab-freeze-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try AppDatabase.open(at: directory.appendingPathComponent("mail.sqlite"))
    let account = Account(email: "synthetic@example.com")
    try await database.writer.write { db in
        try account.insert(db)
        try MailStore.upsertMessages(db, (0..<6).map { index in
            MailMessage(accountId: account.id, id: "m\(index)", threadId: "t\(index)",
                        date: Date(timeIntervalSince1970: Double(1_000 - index)), fromEmail: "sender@example.com",
                        subject: "Synthetic \(index)", labelIds: [SystemLabel.inbox,
                            index < 4 ? SystemLabel.categoryPromotions : SystemLabel.categoryPersonal])
        })
    }
    let prefs = Preferences.shared
    let saved = prefs.splitInbox
    defer { prefs.splitInbox = saved }
    prefs.splitInbox = true
    let services = AppServices(store: MailStore(database))
    services.accounts = [account]
    let model = AppModel(services: services, isFake: true, databaseURL: directory.appendingPathComponent("mail.sqlite"))
    model.tabsWithMail = [.primary, .promotions]
    model.reloadList()
    // Let the initial observation register before blocking the writer.
    try await database.writer.write { _ in }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let writer = Task.detached {
        try database.writer.write { _ in
            entered.signal()
            // The watchdog frees a blocked main actor so a regression fails instead of hanging the suite.
            if release.wait(timeout: .now() + 3) == .timedOut {
                Issue.record("Tab switching exhausted the reader pool while the writer was held")
            }
        }
    }
    defer { release.signal() }
    try #require(entered.wait(timeout: .now() + 2) == .success)
    for _ in 0..<24 {
        let start = ContinuousClock.now
        model.cycleTab(1)
        #expect(start.duration(to: .now) < .milliseconds(100), "Every tab switch must return in the same frame")
        switch model.activeTab {
        case .all: #expect(model.snapshot.order.count == 6)
        case .needsReply: #expect(model.snapshot.isEmpty)
        case .category(.primary): #expect(model.snapshot.order.map(\.threadId) == ["t4", "t5"])
        case .category(.promotions): #expect(model.snapshot.order.map(\.threadId) == ["t0", "t1", "t2", "t3"])
        default: Issue.record("Unexpected tab")
        }
    }
    model.showInboxTab(.promotions)
    #expect(model.snapshot.order.map(\.threadId) == ["t0", "t1", "t2", "t3"])
    release.signal()
    try await writer.value
    try await database.writer.write { db in
        try MailStore.upsertMessages(db, [MailMessage(accountId: account.id, id: "live", threadId: "live",
            date: Date(), fromEmail: "sender@example.com", subject: "Live update",
            labelIds: [SystemLabel.inbox, SystemLabel.categoryPromotions])])
    }
    for _ in 0..<200 {
        if model.snapshot.order.first?.threadId == "live" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.snapshot.order.first?.threadId == "live")
}

@MainActor
@Test func listPaginationKeepsTheLatestTabAndLimit() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-list-pages-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try AppDatabase.open(at: directory.appendingPathComponent("mail.sqlite"))
    let account = Account(email: "synthetic@example.com")
    try await database.writer.write { db in
        try account.insert(db)
        try MailStore.upsertMessages(db, (0..<410).map { index in
            MailMessage(accountId: account.id, id: "m\(index)", threadId: "t\(index)",
                        date: Date(timeIntervalSince1970: Double(1_000 - index)), fromEmail: "sender@example.com",
                        subject: "Synthetic \(index)", labelIds: [SystemLabel.inbox, SystemLabel.categoryPromotions])
        })
    }
    let model = AppModel(services: AppServices(store: MailStore(database)), isFake: true,
                         databaseURL: directory.appendingPathComponent("mail.sqlite"))
    model.inboxTab = nil
    model.reloadList()
    #expect(model.snapshot.order.count == 200 && model.hasMore)
    model.loadMore()
    for _ in 0..<200 where model.snapshot.order.count != 400 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.snapshot.order.count == 400 && model.hasMore)
    let cursor = model.snapshot.order[250]
    model.cursor = cursor
    model.checked = [cursor]
    model.readerExpanded = true
    model.reloadList(keepingPlace: true)
    #expect(model.cursor == cursor && model.checked == [cursor] && model.readerExpanded)
    model.loadMore()
    model.show(.sent)
    #expect(model.snapshot.isEmpty)
    try await database.writer.write { db in
        try MailStore.upsertMessages(db, [MailMessage(accountId: account.id, id: "sent", threadId: "sent",
            date: Date(), fromEmail: account.email, subject: "Sent update", labelIds: [SystemLabel.sent], isFromMe: true)])
    }
    for _ in 0..<200 where model.snapshot.order.first?.threadId != "sent" { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.snapshot.order.map(\.threadId) == ["sent"])
}
