import AppKit
import GRDB
import TernCore

/// The Drafts mailbox against the real store: a draft Gmail has no copy of is listed and counted, its
/// row opens the composer, a thread's Gmail draft opens in the composer, and r in a thread with a draft
/// written in Gmail continues it. The composer hooks are swapped for recorders, so no window opens.
extension SelfCheck {
    func draftsMailbox() {
        let services = model.services
        let store = model.store
        let compose = services.compose, openDraftMessage = services.openDraftMessage
        var composed: [ComposeRequest] = []
        var opened: [MessageKey] = []
        services.compose = { composed.append($0) }
        services.openDraftMessage = { opened.append($0) }
        defer {
            services.compose = compose
            services.openDraftMessage = openDraftMessage
        }
        guard let accountId = services.accounts.first?.id else { return check("drafts: an account", false) }

        model.show(.drafts)
        wait(0.3)
        let gmailDrafts = model.counts.drafts
        let draft = Draft(accountId: accountId, toList: [Participant(email: "pat@example.com")], subject: "Self-check failed draft",
                          bodyHtml: "<p>Hello</p>", state: .failed, lastError: "The network went away")
        do { try store.database.writer.write { db in try draft.insert(db) } } catch { return check("drafts: save a draft", false) }
        defer { _ = try? store.database.writer.write { db in try Draft.deleteOne(db, key: draft.id) } }
        let local = ThreadKey(accountId: accountId, threadId: MailThread.localDraftPrefix + draft.id)

        check("a failed draft Gmail has no copy of is listed in Drafts", waitUntil { model.snapshot.rows[local] != nil })
        check("…and counted", waitUntil { model.counts.drafts == gmailDrafts + 1 })
        model.click(local, command: false, shift: false)
        check("clicking it opens it in the composer", composed.last == .draft(id: draft.id))
        model.focusList()
        composed = []
        send("", keyCode: 36)
        check("so does Return", composed.last == .draft(id: draft.id))
        let toasts = model.toasts.count
        model.perform(.snooze(until: Date().addingTimeInterval(3600)), on: [local])
        check("mail actions pass its row by", model.snapshot.rows[local] != nil && model.toasts.count == toasts)

        guard let thread = model.snapshot.order.first(where: { MailThread.localDraftId(in: $0) == nil }),
              let message = try? services.drafts.draftMessage(inThread: thread) else {
            return check("drafts: a thread with a Gmail draft", false)
        }
        model.click(thread, command: false, shift: false)
        check("a Gmail draft in Drafts opens in the composer", opened.last == message)
        wait(0.3)
        opened = []
        model.focusList()
        send("r")
        wait(0.2)
        check("r in a thread with a draft written in Gmail continues it", opened == [message] && services.reader.model?.composing == nil)
        model.show(.inbox)
        wait(0.2)
    }
}
