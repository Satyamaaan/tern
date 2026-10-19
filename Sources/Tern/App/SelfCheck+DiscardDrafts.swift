import AppKit
import GRDB
import TernCore

/// Discard Draft: the hover bar of a draft row, the delete key on one, undo, and the reader's Edit and Discard
/// beside a draft in a conversation, against the Gmail drafts of the fake mailbox (Tern has no rows for them).
extension SelfCheck {
    func discardDrafts() {
        let services = model.services
        let store = model.store
        let pane = model.prefs.readingPane
        defer { if model.prefs.readingPane != pane { model.prefs.readingPane = pane } }
        if pane { model.prefs.readingPane = false }

        model.show(.drafts)
        wait(0.3)
        guard let row = model.snapshot.order.first(where: { MailThread.localDraftId(in: $0) == nil }),
              let message = try? services.drafts.draftMessage(inThread: row) else {
            return check("discard: a Gmail draft in Drafts", false)
        }
        let conversation = messages(row).filter { !$0.isDraft }.map(\.id)
        let list = model.listView as? MessageListController
        list?.setHovered(model.snapshot.itemIndex[row])
        let hint = registry.hint("Discard draft", "trash")
        check("a draft row's hover bar has Discard, with the trash key",
              list?.hoveredKeys == [row] && model.isDraftRow(row) && hint == "Discard draft  \(registry["trash"]?.shortcutText ?? "?")")
        list?.setHovered(nil)

        model.setCursor(row, open: false)
        model.focusList()
        check("on a draft row Move to Trash is Discard Draft", registry["trash"]?.displayTitle == "Discard Draft")
        send("\u{7f}", keyCode: 51)
        check("delete on a draft row takes it out in the same frame",
              model.snapshot.rows[row] == nil && model.toasts.last?.title == "Draft discarded" && model.toasts.last?.undo != nil)
        let gone = waitUntil { self.messages(row).allSatisfy { !$0.isDraft } }
        check("…the draft goes and the conversation stays", gone && messages(row).map(\.id) == conversation)
        let held = (try? store.database.reader.read { db in
            try PendingOp.filter(Column("kind") == PendingOp.Kind.deleteDraft.rawValue && Column("state") == "pending").fetchAll(db)
        }) ?? []
        check("…and Gmail's copy waits out the undo window",
              held.count == 1 && (held.first?.notBefore ?? .distantPast) > Date().addingTimeInterval(AppModel.discardUndoSeconds))
        send("z")
        check("z brings the draft back and cancels the deletion", waitUntil {
            self.messages(row).contains { $0.id == message.messageId } && self.pendingDeletes() == 0
        } && waitUntil { self.model.snapshot.rows[row] != nil })

        readerDraftActions()
        model.show(.inbox)
        wait(0.2)
    }

    /// The reader shows a conversation's draft with Edit and Discard; Discard takes the draft alone.
    private func readerDraftActions() {
        let services = model.services
        let rows = (try? model.store.threadRows(in: Mailbox(.drafts), limit: 20)) ?? []
        guard let thread = rows.first(where: { $0.thread.labelIds.contains(SystemLabel.inbox) })?.id,
              let message = try? services.drafts.draftMessage(inThread: thread) else {
            return check("reader: a conversation in the inbox with a draft", false)
        }
        let openDraft = services.openDraftMessage
        var opened: [MessageKey] = []
        services.openDraftMessage = { opened.append($0) }
        defer { services.openDraftMessage = openDraft }

        model.show(.inbox)
        wait(0.2)
        model.reveal(thread)
        if model.listOnly { model.readerExpanded = true }
        let shown = waitUntil(3) { services.reader.model?.key == thread && (self.pageCount("[data-act=discard-draft]") ?? 0) > 0 }
        check("the reader shows the draft with Edit and Discard", shown && (pageCount("[data-act=edit-draft]") ?? 0) > 0)
        clickInPage("[data-act=edit-draft]")
        check("Edit opens the draft", waitUntil(2) { opened == [message] })

        clickInPage("[data-act=discard-draft]")
        check("Discard says Draft discarded", waitUntil(2) { self.model.toasts.last?.title == "Draft discarded" })
        check("…takes the draft and leaves the conversation in the inbox", waitUntil {
            self.messages(thread).allSatisfy { !$0.isDraft } && ((try? self.isInInbox(thread)) ?? false)
        } && model.snapshot.rows[thread] != nil)
        model.undoLast()
        check("…and undo brings it back", waitUntil { self.messages(thread).contains { $0.id == message.messageId } && self.pendingDeletes() == 0 })
        model.back()
    }

    private func messages(_ key: ThreadKey) -> [MailMessage] {
        (try? model.store.threadDetail(key))?.messages ?? []
    }

    private func pendingDeletes() -> Int {
        (try? model.store.database.reader.read { db in
            try PendingOp.filter(Column("kind") == PendingOp.Kind.deleteDraft.rawValue).fetchCount(db)
        }) ?? -1
    }

    /// How many elements of the reader page match `selector`; nil when the page didn't answer.
    private func pageCount(_ selector: String) -> Int? {
        var answer: Int?
        var done = false
        ReaderWebEngine.shared.run("return document.querySelectorAll(s).length;", ["s": selector]) { result in
            answer = try? result.get() as? Int
            done = true
        }
        _ = waitUntil(2) { done }
        return answer
    }

    private func clickInPage(_ selector: String) {
        var done = false
        ReaderWebEngine.shared.run("const e = document.querySelector(s); if (e) e.click();", ["s": selector]) { _ in done = true }
        _ = waitUntil(2) { done }
    }
}
