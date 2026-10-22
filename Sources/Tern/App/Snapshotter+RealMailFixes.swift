import AppKit
import GRDB
import SwiftUI
import TernCore

extension Snapshotter {
    /// Targeted offscreen review against a disposable fake mailbox only.
    func realMailFixesShots(_ window: MainWindow, _ directory: URL) {
        guard model.isFake else { return }
        model.prefs.sidebarOpen = true
        model.prefs.readingPane = false
        try? model.store.database.writer.write { db in
            try db.execute(sql: "DELETE FROM commitment")
            try Setting(key: "ledger.enabled", value: "true").upsert(db)
        }
        model.counts.waitingOn = 0
        model.counts.iOwe = 0
        model.counts.ledgerEnabled = true
        model.show(.waitingOn)
        model.reloadList()
        settle(window)
        render(window, appearance: .darkAqua, to: directory.appendingPathComponent("waiting-empty-dark.png"))
        model.show(.iOwe)
        model.reloadList()
        render(window, appearance: .darkAqua, to: directory.appendingPathComponent("owe-empty-dark.png"))
        model.showInboxTab(.primary)
        model.reloadList()
        let rows = model.snapshot.order.prefix(10).compactMap { model.row($0) }
        try? model.store.database.writer.write { db in
            for row in rows {
                try SummaryStore.save(db, key: row.id, messageCount: row.thread.messageCount,
                    lastDate: row.thread.lastDate, bullets: ["Review the revised plan and confirm the next steps."])
            }
        }
        model.reloadList()
        settle(window)
        render(window, appearance: .darkAqua, to: directory.appendingPathComponent("primary-summaries-dark.png"))
        model.services.ai = AIActions(summarize: { _ in [] }, suggestReplies: { _ in [] }, draftReply: { _, _ in "" }, naturalLanguageQuery: { $0 })
        model.openSettings(.ai)
        settle(window)
        render(window, appearance: .darkAqua, to: directory.appendingPathComponent("settings-ai-dark.png"))
        print("Real mail fixes snapshots: \(directory.path)")
    }
}
