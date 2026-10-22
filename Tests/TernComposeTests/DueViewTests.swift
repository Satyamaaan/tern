import Foundation
import GRDB
import Testing
@testable import Tern
@testable import TernCore

@MainActor
struct DueViewTests {
    private func model() throws -> AppModel {
        let database = try AppDatabase.inMemory()
        let account = Account(email: "me@example.com")
        let store = MailStore(database)
        try store.upsertAccount(account)
        try database.writer.write { db in
            try MailStore.upsertMessages(db, (0..<2).map { index in
                MailMessage(accountId: account.id, id: "m\(index)", threadId: "t\(index)", date: Date(),
                    fromEmail: "maya@example.com", toList: [Participant(email: account.email)], subject: "Proposal", labelIds: ["INBOX"])
            })
        }
        for (index, direction) in [LedgerDirection.iOwe, .waitingOn].enumerated() {
            _ = try store.trackCommitment(on: ThreadKey(accountId: account.id, threadId: "t\(index)"), direction: direction,
                deliverable: "Review proposal", counterparty: Participant(email: "maya@example.com"), dueAt: Date())
        }
        let services = AppServices(store: store)
        services.accounts = [account]
        return AppModel(services: services, isFake: true, databaseURL: URL(fileURLWithPath: "/dev/null"))
    }

    @Test func sectionsOmitEmptySidesAndKeepSameThreadInBoth() throws {
        let m = try model()
        m.show(.due)
        #expect(m.snapshot.items.compactMap { if case .header(let title) = $0 { return title }; return nil } == ["You owe", "Waiting on"])
        let rows = try m.store.threadRows(in: Mailbox(.due))
        for (direction, title) in [(LedgerDirection.iOwe, "You owe"), (.waitingOn, "Waiting on")] {
            let snapshot = ListSnapshot(rows: rows.filter { $0.ledger?.direction == direction }, groupsByDate: false, groupsByDirection: true)
            #expect(snapshot.items.first == .header(title))
            #expect(snapshot.items.count == 2)
        }
        let empty = ListSnapshot(rows: [], groupsByDate: false, groupsByDirection: true)
        #expect(empty.items.isEmpty)
        #expect(Mailbox.Kind.due.emptyLine == "Things you owe and are waiting on will appear here.")
        var waiting = rows[1]
        waiting.thread.id = rows[0].thread.id
        let duplicate = ListSnapshot(rows: [rows[0], waiting], groupsByDate: false, groupsByDirection: true)
        #expect(duplicate.items.count == 4)
        #expect(duplicate.row(at: 3)?.ledger?.direction == .waitingOn)
    }

    @Test func pinnedPreferencesMigrateAndDeduplicate() {
        let suite = "tern-due-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["mailbox:waitingOn", "mailbox:iOwe", "search:invoice"], forKey: "pinnedTabs")
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.pinnedTabs == ["mailbox:due", "search:invoice"])
        #expect(defaults.stringArray(forKey: "pinnedTabs") == prefs.pinnedTabs)
    }

    @Test func legacyDestinationsAndShortcutsMigrate() throws {
        let m = try model()
        m.show(.waitingOn)
        #expect(m.kind == .due)
        m.show(.iOwe)
        #expect(m.kind == .due)
        #expect(ListTab(pinKey: "mailbox:waitingOn") == .mailbox(.due))
        #expect(ListTab(pinKey: "mailbox:iOwe")?.pinKey == "mailbox:due")
        let overrides = ShortcutOverrides(stored: ["go.iOwe": [KeyShortcut.command("o").stored], "go.waitingOn": [KeyShortcut.command("w", shift: true).stored]])
        #expect(overrides.keys["go.due"]?.count == 2)
        #expect(overrides.keys["go.iOwe"] == nil)
        let registry = CommandRegistry(model: m, shell: nil, overrides: ShortcutOverrides(), keyBindings: KeyBindingFiles(urls: []))
        #expect(registry["go.due"]?.chord == "g u")
        #expect(registry.commands.filter { $0.chord == "g u" }.map(\.id) == ["go.due"])
        #expect(ShortcutRules.reservation(.key("u"), for: "go.due") == nil)
        #expect(try m.store.scopeCounts(accountId: nil).due == 2)
        registry.run("go.due")
        #expect(m.kind == .due && m.inLedger)
    }
}
