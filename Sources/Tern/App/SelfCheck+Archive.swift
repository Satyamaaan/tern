import AppKit
import GRDB
import TernCore

/// The Archive mailbox: archiving from a row or from the reader puts a thread there, `g e` opens it, and Move to
/// Inbox, with undo, takes it back. Prints how long its pages take to read.
extension SelfCheck {
    func archiveMailbox() {
        // Preferences are saved on every change, so only what differs is set (and put back).
        let pane = model.prefs.readingPane, after = model.prefs.afterTriage
        defer {
            if model.prefs.readingPane != pane { model.prefs.readingPane = pane }
            if model.prefs.afterTriage != after { model.prefs.afterTriage = after }
        }
        if pane { model.prefs.readingPane = false }
        if after != .next { model.prefs.afterTriage = .next }
        model.show(.inbox)
        model.showInboxTab(.primary)
        wait(0.2)
        let order = model.snapshot.order
        guard order.count > 3 else { return check("archive mailbox: rows", false) }
        let fromRow = order[0], fromReader = order[2]

        // What the row's hover button runs.
        model.perform(.archive, on: [fromRow])
        let rowUndo = model.undoStack.last
        check("archiving a row says Archived, with undo", model.toasts.last?.title == "Archived" && model.toasts.last?.undo != nil)

        // What the reader's top bar button runs.
        model.click(fromReader, command: false, shift: false)
        let opened = waitUntil(1) { self.model.services.reader.model?.key == fromReader }
        model.services.reader.model?.perform(.archive)
        let readerUndo = model.undoStack.last
        check("archiving from the reader says Archived",
              opened && model.toasts.last?.title == "Archived" && model.snapshot.rows[fromReader] == nil)
        model.back()
        let written = waitUntil { (try? !self.isInInbox(fromRow) && !self.isInInbox(fromReader)) == true }
        check("both threads are in the Archive mailbox", written && isArchived(fromRow) && isArchived(fromReader))

        send("g")
        send("e")
        check("g e opens Archive", model.kind == .archive && model.chordHUD == nil && model.inArchive)
        wait(0.2)
        let rows = model.snapshot.order.compactMap(model.row)
        let unwanted: Set<String> = [SystemLabel.inbox, SystemLabel.spam, SystemLabel.trash]
        check("Archive lists only archived mail someone else sent", !rows.isEmpty && rows.allSatisfy {
            $0.thread.lastInboundDate != nil && $0.snoozedUntil == nil && unwanted.isDisjoint(with: $0.thread.labelIds)
        })
        check("Archive is newest first", zip(rows, rows.dropFirst()).allSatisfy { $0.thread.lastDate >= $1.thread.lastDate })
        if rows.count == AppModel.pageSize {
            model.loadMore()
            check("scrolling Archive loads the next page", waitUntil(1) { self.model.snapshot.order.count == 2 * AppModel.pageSize })
            model.moveToTop()
        }

        guard let target = model.snapshot.rows[fromRow] != nil ? fromRow : model.snapshot.order.first else {
            return check("Archive: a row to move", false)
        }
        model.setCursor(target, open: false)
        model.focusList()
        check("in Archive, Move to Inbox takes Archive's place",
              registry["archive"].map(registry.canRun) == false && registry["moveToInbox"].map(registry.canRun) == true)
        let toasts = model.toasts.count
        send("e")
        check("e does nothing in Archive", model.snapshot.rows[target] != nil && model.toasts.count == toasts)
        send("I")
        check("⇧I takes the row out in the same frame and says Moved to Inbox",
              model.snapshot.rows[target] == nil && model.toasts.last?.title == "Moved to Inbox" && model.toasts.last?.undo != nil)
        check("…and the inbox has it", waitUntil { (try? self.isInInbox(target)) == true })
        model.undoLast()
        check("undo archives it again", waitUntil { (try? self.isInInbox(target)) == false && self.model.snapshot.rows[target] != nil })

        timeArchive()
        for entry in [readerUndo, rowUndo].compactMap({ $0 }) { model.undo(entry) }
        _ = waitUntil { (try? self.isInInbox(fromRow) && self.isInInbox(fromReader)) == true }
        model.show(.inbox)
        wait(0.2)
    }

    private func timeArchive() {
        let store = model.store
        for accountId in [nil, model.accounts.first?.id] {
            let mailbox = Mailbox(.archive, accountId: accountId)
            var interval = Timing.begin("archive")
            let page = (try? store.threadRows(in: mailbox, limit: AppModel.pageSize)) ?? []
            let first = Timing.end(interval)
            interval = Timing.begin("archive-next")
            _ = try? store.threadRows(in: mailbox, limit: AppModel.pageSize, before: page.last?.thread.lastDate)
            let next = Timing.end(interval)
            let scope = accountId == nil ? "all accounts" : "one account"
            print(String(format: "  archive (%@): first page %.1f ms, next page %.1f ms", scope, first, next))
            check("Archive (\(scope)) reads a page well inside the budget", !page.isEmpty && first < 50 && next < 50)
        }
    }

    /// Whether `key` is among the Archive mailbox's threads at its date.
    private func isArchived(_ key: ThreadKey) -> Bool {
        (try? model.store.database.reader.read { db -> Bool in
            guard let thread = try MailThread.fetchOne(db, key: ["accountId": key.accountId, "id": key.threadId]) else { return false }
            let rows = try MailStore.fetchThreadRows(
                db, in: Mailbox(.archive, accountId: key.accountId), limit: 20, before: thread.lastDate.addingTimeInterval(0.001))
            return rows.contains { $0.id == key }
        }) ?? false
    }
}
