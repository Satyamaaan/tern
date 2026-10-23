import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import Tern
import TernCore

extension InboxPreferencesTests {
    @MainActor
    @Test func multiSelectionKeepsTheReaderObservation() async throws {
        _ = NSApplication.shared
        let database = try AppDatabase.inMemory()
        let account = Account(email: "synthetic@example.com")
        try await database.writer.write { db in
            try account.insert(db)
            try MailStore.upsertMessages(db, (0..<3).map { index in
                MailMessage(accountId: account.id, id: "m\(index)", threadId: "t\(index)",
                            date: Date(timeIntervalSince1970: Double(1_000 - index)), fromEmail: "sender@example.com",
                            subject: "Synthetic \(index)", labelIds: [SystemLabel.inbox])
            })
        }
        let services = AppServices(store: MailStore(database))
        let app = AppModel(services: services, isFake: true, databaseURL: URL(fileURLWithPath: "/unused"))
        app.reloadList()
        app.readerExpanded = true
        let hosting = NSHostingView(rootView: ReaderColumn().environment(app).environment(services))
        hosting.sizingOptions = []
        let window = MainWindow(contentView: hosting)
        window.setContentSize(NSSize(width: 640, height: 720))
        let snapshots = Snapshotter(model: app, registry: CommandRegistry(model: app, shell: nil, overrides: ShortcutOverrides()))
        snapshots.settle(window)
        weak var original = services.reader.model
        try #require(original != nil && original?.key == app.cursor)
        func shot(_ name: String) {
            guard let path = ProcessInfo.processInfo.environment["TERN_READER_LIFETIME_SHOTS"] else { return }
            let directory = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            snapshots.render(window, appearance: .aqua, to: directory.appendingPathComponent(name + ".png"))
        }
        shot("single")
        app.moveCursor(1, extend: true)
        snapshots.settle(window)
        #expect(app.checked.count == 2)
        shot("multiple")
        app.checked.removeAll()
        app.open()
        snapshots.settle(window)
        #expect(original != nil && services.reader.model === original,
                "Multi-select must reuse the reader and its concurrent detail observation")
        #expect(services.reader.model?.key == app.cursor)
        shot("returned")
    }

    @MainActor
    @Test func launchObservationsLeaveRoomForNavigationWhileTheWriterIsHeld() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-launch-freeze-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mail.sqlite")
        let database = try AppDatabase.open(at: url)
        let account = Account(email: "synthetic@example.com")
        try await database.writer.write { db in
            try account.insert(db)
            try MailStore.upsertMessages(db, [MailMessage(accountId: account.id, id: "message", threadId: "thread",
                date: Date(), fromEmail: "sender@example.com", subject: "Synthetic", labelIds: [SystemLabel.inbox])])
        }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = Task.detached {
            try database.writer.write { _ in
                entered.signal()
                if release.wait(timeout: .now() + 10) == .timedOut {
                    Issue.record("Launch observations exhausted the reader pool while the writer was held")
                }
            }
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 2) == .success)
        // Stand in for AI settings, login arrivals, notifications and pending ops. Immediate
        // startup ensures each holds its initial reader before AppModel starts its five observers.
        let background = (0..<4).map { _ in
            ValueObservation.tracking { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM pending_op") }
                .startRestarting(in: database.reader, scheduling: .immediate,
                    onError: { Issue.record($0) }, onChange: { _ in })
        }
        defer { background.forEach { $0.cancel() } }
        let services = AppServices(store: MailStore(database))
        let app = AppModel(services: services, isFake: true, databaseURL: url)
        let reader = ReaderModel()
        let start = ContinuousClock.now
        app.startObservations()
        reader.attach(services)
        defer { reader.suspend() }
        let key = ThreadKey(accountId: account.id, threadId: "thread")
        for index in 0..<24 {
            app.setScope(index.isMultiple(of: 2) ? .account(account.id) : .all)
            app.cycleTab(1)
            reader.show(index.isMultiple(of: 2) ? key : nil)
        }
        reader.show(key)
        #expect(start.duration(to: .now) < .seconds(1), "Launch and navigation must leave a reader available")
        #expect(reader.detail?.thread.key == key)
        release.signal()
        try await writer.value
    }

    @MainActor
    @Test func readerNavigationReturnsWhileTheWriterIsHeld() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-reader-freeze-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mail.sqlite")
        let database = try AppDatabase.open(at: url)
        let account = Account(email: "synthetic@example.com")
        try await database.writer.write { db in
            try account.insert(db)
            try MailStore.upsertMessages(db, (0..<30).map { index in
                MailMessage(accountId: account.id, id: "m\(index)", threadId: "t\(index)",
                    date: Date(), fromEmail: "sender@example.com", subject: "Synthetic \(index)",
                    labelIds: [SystemLabel.inbox])
            })
        }
        let services = AppServices(store: MailStore(database))
        services.accounts = [account]
        let model = ReaderModel()
        model.attach(services)
        defer { model.suspend() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = Task.detached {
            try database.writer.write { _ in
                entered.signal()
                if release.wait(timeout: .now() + 10) == .timedOut {
                    Issue.record("Reader navigation exhausted the reader pool while the writer was held")
                }
            }
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 2) == .success)
        for index in 0..<24 {
            let key = ThreadKey(accountId: account.id, threadId: "t\(index)")
            let start = ContinuousClock.now
            model.show(key)
            #expect(start.duration(to: .now) < .seconds(1), "Every thread open must return while the writer is held")
            #expect(model.detail?.thread.key == key, "The first detail must arrive in the same frame")
            if index.isMultiple(of: 3) { model.suspend(); model.show(key) }
        }
        let finalKey = ThreadKey(accountId: account.id, threadId: "t23")
        #expect(model.detail?.thread.key == finalKey)
        release.signal()
        try await writer.value
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE message SET bodyText = 'Body landed', bodyState = 1 WHERE id = 'm23'")
        }
        for _ in 0..<200 where model.detail?.messages.first?.bodyText != "Body landed" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.detail?.thread.key == finalKey)
        #expect(model.detail?.messages.first?.bodyText == "Body landed")
    }

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
                if release.wait(timeout: .now() + 10) == .timedOut {
                    Issue.record("Tab switching exhausted the reader pool while the writer was held")
                }
            }
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 2) == .success)
        for _ in 0..<24 {
            let start = ContinuousClock.now
            model.cycleTab(1)
            #expect(start.duration(to: .now) < .seconds(1), "Every tab switch must return while the writer is held")
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
        let prefs = Preferences.shared
        let saved = prefs.splitInbox
        defer { prefs.splitInbox = saved }
        prefs.splitInbox = true
        let model = AppModel(services: AppServices(store: MailStore(database)), isFake: true,
                             databaseURL: directory.appendingPathComponent("mail.sqlite"))
        model.inboxTab = .promotions
        model.reloadList()
        #expect(model.snapshot.order.count == 200 && model.hasMore)
        model.loadMore()
        for _ in 0..<200 where model.snapshot.order.count != 400 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.snapshot.order.count == 400 && model.hasMore)
        let cursor = model.snapshot.order[250]
        model.cursor = cursor
        model.checked = [cursor]
        model.readerExpanded = true
        let previousRequest = model.rowsSource.current
        model.setSplitInbox(false)
        #expect(model.rowsSource.current != previousRequest)
        try await database.writer.write { db in
            try MailStore.upsertMessages(db, [MailMessage(accountId: account.id, id: "m250", threadId: "t250",
                date: Date(timeIntervalSince1970: 750), fromEmail: "sender@example.com", subject: "Updated open thread",
                labelIds: [SystemLabel.inbox, SystemLabel.categoryPromotions])])
        }
        for _ in 0..<200 where model.snapshot.rows[cursor]?.thread.subject != "Updated open thread" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.rowsObservedGeneration == model.rowsSource.current.generation)
        #expect(model.snapshot.rows[cursor]?.thread.subject == "Updated open thread")
        #expect(model.listLoaded && model.snapshot.order.count == 400)
        #expect(model.cursor == cursor && model.checked == [cursor] && model.readerExpanded && model.readerKey == cursor)
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

    @MainActor
    @Test func scopeSwitchesReturnWhileTheWriterIsHeld() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-scope-freeze-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: directory.appendingPathComponent("mail.sqlite"))
        let account = Account(email: "synthetic@example.com")
        let other = Account(email: "other@example.com")
        try await database.writer.write { db in
            try account.insert(db)
            try other.insert(db)
            try MailLabel(accountId: account.id, id: "custom", name: "Custom").insert(db)
            try MailStore.upsertMessages(db, [account, other].map {
                MailMessage(accountId: $0.id, id: "m", threadId: "t", date: Date(),
                            fromEmail: "sender@example.com", subject: "Synthetic",
                            labelIds: [SystemLabel.inbox, SystemLabel.unread, SystemLabel.categoryPromotions])
            })
        }
        let prefs = Preferences.shared
        let saved = prefs.splitInbox
        defer { prefs.splitInbox = saved }
        prefs.splitInbox = true
        let model = AppModel(services: AppServices(store: MailStore(database)), isFake: true,
                             databaseURL: directory.appendingPathComponent("mail.sqlite"))
        model.observeScope()
        model.reloadList()
        try await database.writer.write { _ in }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = Task.detached {
            try database.writer.write { _ in
                entered.signal()
                if release.wait(timeout: .now() + 10) == .timedOut {
                    Issue.record("Scope switching exhausted the reader pool while the writer was held")
                }
            }
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 2) == .success)
        for index in 0..<24 {
            let start = ContinuousClock.now
            model.setScope(index.isMultiple(of: 2) ? .account(account.id) : .all)
            model.showInboxTab(.promotions)
            model.cycleTab(1)
            #expect(start.duration(to: .now) < .seconds(1), "Scope and tab switches must return while the writer is held")
            #expect(model.labels.map(\.id) == (index.isMultiple(of: 2) ? ["custom"] : []))
            try await Task.sleep(for: .milliseconds(10))
        }
        model.setScope(.account(account.id))
        model.showInboxTab(.promotions)
        #expect(model.snapshot.order.map(\.accountId) == [account.id])
        release.signal()
        try await writer.value
        try await database.writer.write { db in
            try MailLabel(accountId: account.id, id: "live", name: "Live").insert(db)
            try MailStore.upsertMessages(db, [MailMessage(accountId: account.id, id: "live", threadId: "live",
                date: Date().addingTimeInterval(1), fromEmail: "sender@example.com", subject: "Live update",
                labelIds: [SystemLabel.inbox, SystemLabel.unread, SystemLabel.categoryPromotions])])
        }
        for _ in 0..<200 {
            if model.snapshot.order.first?.threadId == "live", model.counts.inboxUnread == 2, model.labels.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.snapshot.order.first?.threadId == "live")
        #expect(model.counts.inboxUnread == 2 && model.counts.allAccountsInboxUnread == 3)
        #expect(model.labels.map(\.id) == ["custom", "live"])
    }
}
