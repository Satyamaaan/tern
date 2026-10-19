import AppKit
import TernCore

extension Snapshotter {
    /// A draft row hovered in Drafts (Discard in place of Archive and Snooze), and a conversation in the
    /// reader with your draft in it (Edit · Discard beside the draft).
    func draftShots(_ window: MainWindow, _ directory: URL) {
        func shot(_ name: String) {
            render(window, appearance: .aqua, to: directory.appendingPathComponent("\(name)-light.png"))
            render(window, appearance: .darkAqua, to: directory.appendingPathComponent("\(name)-dark.png"))
        }
        model.show(.drafts)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let list = model.listView as? MessageListController
        if let first = model.snapshot.order.first {
            list?.setHovered(model.snapshot.itemIndex[first])
            shot("draft-hover")
            list?.setHovered(nil)
        }

        let rows = (try? model.store.threadRows(in: Mailbox(.drafts), limit: 20)) ?? []
        if let thread = rows.first(where: { $0.thread.labelIds.contains(SystemLabel.inbox) })?.id {
            model.show(.inbox)
            var painted = false
            ReaderModel.renderObserver = { rendered, _ in if rendered == thread { painted = true } }
            model.reveal(thread)
            if model.listOnly { model.readerExpanded = true }
            let end = Date().addingTimeInterval(3)
            while !painted, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            ReaderModel.renderObserver = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            shot("reader-draft")
            model.back()
        }
        model.show(.inbox)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}
