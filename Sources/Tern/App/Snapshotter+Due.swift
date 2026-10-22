import AppKit
import GRDB
import TernCore

extension Snapshotter {
    /// Review the combined destination on a disposable fake mailbox, without opening a visible window.
    func dueShots(_ window: MainWindow, _ directory: URL) {
        guard model.isFake else { return }
        let saved = (model.prefs.sidebarOpen, model.prefs.readingPane)
        defer {
            model.prefs.sidebarOpen = saved.0
            model.prefs.readingPane = saved.1
        }
        model.prefs.sidebarOpen = true
        model.prefs.readingPane = false
        model.show(.inbox)
        model.reloadList()
        let keys = Array(model.snapshot.order.prefix(2))
        try? model.store.database.writer.write { db in
            try db.execute(sql: "DELETE FROM commitment")
            try Setting(key: "ledger.enabled", value: "true").upsert(db)
        }
        for (key, direction) in zip(keys, [LedgerDirection.iOwe, .waitingOn]) {
            _ = try? model.store.trackCommitment(on: key, direction: direction,
                deliverable: direction == .iOwe ? "Send the revised proposal" : "Review the launch checklist",
                counterparty: Participant(name: "Maya Chen", email: "maya@example.com"),
                dueAt: Date().addingTimeInterval(direction == .iOwe ? -86_400 : 86_400))
        }
        model.show(.due)
        model.reloadList()
        settle(window)
        render(window, appearance: .darkAqua, to: directory.appendingPathComponent("due-both-dark.png"))
        try? model.store.database.writer.write { db in
            try db.execute(sql: "DELETE FROM commitment WHERE direction='iOwe'")
        }
        model.reloadList()
        settle(window)
        render(window, appearance: .darkAqua, to: directory.appendingPathComponent("due-waiting-dark.png"))
        try? model.store.database.writer.write { db in try db.execute(sql: "DELETE FROM commitment") }
        model.reloadList()
        settle(window)
        render(window, appearance: .darkAqua, to: directory.appendingPathComponent("due-empty-dark.png"))
    }
}
