import AppKit
import Foundation
import Testing
@testable import Tern
@testable import TernCore

// Gmail's tabs in the shell: the inbox opens on Primary, empty tabs hide unless open, the quiet counts, Move to
// tab taking a row out of the tab it was in, its commands and row menu, and keys and recent commands saved for
// the old split-inbox tabs.

/// A model over `promotions` threads filed under Promotions and `primary` under Primary, newest first in that
/// order, with inbox tabs on. Restores the shared preference afterwards.
@MainActor
private func withModel(promotions: Int = 4, primary: Int = 2, _ body: (AppModel) throws -> Void) throws {
    let prefs = Preferences.shared
    let saved = prefs.splitInbox
    defer { prefs.splitInbox = saved }
    prefs.splitInbox = true
    let database = try AppDatabase.inMemory()
    let account = Account(email: "me@example.com")
    try database.writer.write { db in
        try account.insert(db)
        let labels = Array(repeating: SystemLabel.categoryPromotions, count: promotions) + Array(repeating: SystemLabel.categoryPersonal, count: primary)
        try MailStore.upsertMessages(db, labels.enumerated().map { index, label in
            MailMessage(accountId: account.id, id: "m\(index)", threadId: "t\(index)", date: Date(timeIntervalSince1970: Double(1_000 - index)),
                        fromName: "Shop", fromEmail: "hello@shop.example", toList: [Participant(email: account.email)],
                        subject: "Thread \(index)", bodyText: "Hi", bodyState: .full, labelIds: [SystemLabel.inbox, SystemLabel.unread, label])
        })
    }
    let services = AppServices(store: MailStore(database))
    services.accounts = [account]
    let model = AppModel(services: services, isFake: true, databaseURL: URL(fileURLWithPath: "/dev/null"))
    model.reloadList()
    try body(model)
}

@MainActor
@Test func theInboxOpensOnPrimary() throws {
    try withModel { model in
        #expect(model.activeTab == .category(.primary))
        #expect(model.snapshot.order.map(\.threadId) == ["t4", "t5"])
        model.show(.sent)
        model.show(.inbox)
        #expect(model.activeTab == .category(.primary))
        // The Inbox (sidebar, g i) lands on Primary from another tab too; All stays a click away.
        model.showInboxTab(.promotions)
        model.show(.inbox)
        #expect(model.activeTab == .category(.primary))
        model.select(.all)
        #expect(model.activeTab == .all && model.snapshot.order.count == 6)

        model.setSplitInbox(false)
        model.show(.sent)
        model.show(.inbox)
        #expect(model.activeTab == .all && model.landingTab == nil)
    }
}

@MainActor
@Test func anEmptyTabHidesExceptWhileItIsOpen() throws {
    try withModel { model in
        var counts = ScopeCounts()
        counts.tabThreads = [.primary: 2, .promotions: 4]
        model.counts = counts
        let gmail = { model.tabs.compactMap { tab -> InboxTab? in if case .category(let inbox) = tab { inbox } else { nil } } }
        #expect(model.tabs.prefix(2) == [.all, .needsReply])
        #expect(gmail() == [.primary, .promotions])
        model.showInboxTab(.forums)
        #expect(gmail() == [.primary, .promotions, .forums] && model.snapshot.isEmpty)
        model.cycleTab(-1)
        #expect(model.activeTab == .category(.promotions) && gmail() == [.primary, .promotions])
        // Primary shows even when it's empty.
        model.counts = ScopeCounts()
        #expect(gmail() == [.primary, .promotions])
        model.setSplitInbox(false)
        #expect(model.tabs == [.all, .needsReply])
    }
}

@MainActor
@Test func onlyTheQuieterTabsCountUnread() throws {
    try withModel { model in
        var counts = ScopeCounts()
        counts.inboxUnread = 5
        counts.needsReply = 1
        counts.tabUnread = [.primary: 3, .promotions: 2]
        model.counts = counts
        #expect(model.count(for: .all) == nil && model.count(for: .category(.primary)) == nil)
        #expect(model.count(for: .category(.promotions)) == 2 && model.count(for: .category(.social)) == nil)
        #expect(model.count(for: .needsReply) == 1)
        // Without the tabs, All is the only place the title bar shows unread mail.
        model.setSplitInbox(false)
        #expect(model.count(for: .all) == 5)
    }
}

@MainActor
@Test func movingAThreadToAnotherTabTakesItsRowAway() throws {
    try withModel { model in
        model.showInboxTab(.promotions)
        let order = model.snapshot.order
        try #require(order.count == 4 && model.cursor == order[0])
        model.perform(.moveToTab(.primary), on: [order[0]])
        #expect(model.snapshot.rows[order[0]] == nil && model.cursor == order[1])
        #expect(model.toasts.last?.title == "Moved to Primary")
        #expect(model.toasts.last?.undo != nil)

        // On All, or to the tab it's already in, the row stays.
        #expect(!model.leavesList(.moveToTab(.promotions)))
        model.select(.all)
        #expect(!model.leavesList(.moveToTab(.social)))
    }
}

@MainActor
@Test func moveCommandsOfferTheOtherTabs() throws {
    try withModel { model in
        let registry = CommandRegistry(model: model, shell: nil, overrides: ShortcutOverrides(), keyBindings: KeyBindingFiles(urls: []))
        model.registry = registry
        model.showInboxTab(.promotions)
        let enabled = { InboxTab.allCases.filter { registry.canRun(registry["moveToTab.\($0.rawValue)"]!) } }
        #expect(enabled() == [.primary, .social, .updates, .forums])
        #expect(registry["moveToTab.primary"]?.title == "Move to Primary" && registry["moveToTab.primary"]?.keys.isEmpty == true)
        #expect(registry["tab.primary"]?.keys == [.option("3")] && registry["tab.forums"]?.keys == [.option("7")])

        let item = ThreadMenu.make(registry: registry, model: model).items.first { $0.title == "Move to Tab" }
        #expect(item?.submenu?.items.map(\.title) == ["Primary", "Promotions", "Social", "Updates", "Forums"])
        #expect(item?.submenu?.items.filter { $0.state == .on }.map(\.title) == ["Promotions"])

        model.setSplitInbox(false)
        #expect(enabled().isEmpty)
        #expect(!ThreadMenu.make(registry: registry, model: model).items.contains { $0.title == "Move to Tab" })
        #expect(registry["splitInbox"]?.displayTitle == "Turn On Inbox Tabs")
    }
}

@MainActor
@Test func keysAndRecentCommandsOfTheOldTabsMoveToGmailsTabs() throws {
    let name = "tern-inbox-tabs-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let key = { (character: String) in [KeyShortcut.option(character).stored] }
    defaults.set([
        "split.important": key("i"), "split.newsletters": key("n"), "split.people": key("p"), "split.other": key("o"),
        "split.notifications": key("u"), "tab.updates": key("x"), "archive": key("e"),
    ], forKey: ShortcutOverrides.defaultsKey)
    defaults.set(["split.newsletters", "archive", "split.other", "tab.promotions", "split.important"], forKey: "recentCommands")

    Preferences.migrateInboxTabs(defaults)
    let stored = defaults.dictionary(forKey: ShortcutOverrides.defaultsKey) as? [String: [String]]
    // People and Other have no Gmail tab; Updates keeps the key it was given since.
    #expect(stored == ["tab.primary": key("i"), "tab.promotions": key("n"), "tab.updates": key("x"), "archive": key("e")])
    #expect(defaults.stringArray(forKey: "recentCommands") == ["tab.promotions", "archive", "tab.primary"])

    // Nothing left to move: a second launch changes nothing.
    Preferences.migrateInboxTabs(defaults)
    #expect(defaults.dictionary(forKey: ShortcutOverrides.defaultsKey) as? [String: [String]] == stored)

    let prefs = Preferences(defaults: defaults)
    #expect(prefs.shortcutOverrides.keys["tab.primary"] == [.option("i")])
}
