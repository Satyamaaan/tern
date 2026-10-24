import Foundation
import TernCore

extension SelfCheck {
    /// Drives the registered bare key and local undo through the same router as the list.
    func ledger() {
        model.show(.due)
        poll(0.3) {}
        guard let key = model.snapshot.order.first else {
            model.showInboxTab(.primary)
            return
        }
        model.setCursor(key, open: false)
        model.focus = .list
        window.makeFirstResponder(nil)
        send("d")
        poll(0.3) {}
        check("d completes an item in Due", (try? model.store.commitments(on: [key]).allSatisfy { $0.state == .done }) == true)
        model.undoLast()
        poll(0.3) {}
        check("undo reopens the Due item", (try? model.store.commitments(on: [key]).contains { $0.state == .open }) == true)
        check("undo restores the Due row", model.snapshot.rows[key] != nil)
        model.setCursor(key, open: true)
        model.focus = .list
        model.open()
        _ = waitUntil { self.model.services.reader.shows(key) && self.model.services.reader.model?.detail?.commitments.contains { $0.state == .open } == true }
        model.focus = .reader
        window.makeFirstResponder(nil)
        check("reader evidence command has items", registry["commitmentEvidence"]?.isEnabled() == true)
        if let reader = model.services.reader.model, let first = reader.focusedCommitment,
           let extra = try? model.store.trackCommitment(on: key, direction: .iOwe, deliverable: "Review focus check",
                counterparty: Participant(name: first.counterpartyName, email: first.counterpartyEmail), dueAt: nil) {
            check("strip observes two open items", waitUntil { reader.stripItems.count >= 2 })
            reader.focusedCommitmentId = extra.created.first
            registry.run("commitmentNext")
            check("next commitment moves strip focus", reader.focusedCommitment?.id != extra.created.first)
            reader.focusedCommitmentId = extra.created.first
            registry.run("commitmentDone")
            check("reader done acts on focused item", waitUntil {
                (try? self.model.store.commitments(on: [key]).first { $0.id == extra.created.first }?.state) == .done
            })
            check("reader done leaves other item open", (try? model.store.commitments(on: [key]).first { $0.id == first.id }?.state) == .open)
            model.undoLast()
            check("focused done is undoable", waitUntil {
                (try? self.model.store.commitments(on: [key]).first { $0.id == extra.created.first }?.state) == .open
            })
            try? model.store.restoreCommitments(extra)
            model.setCursor(key, open: true)
            model.focus = .list
            model.open()
            check("reader observes commitment cleanup", waitUntil {
                guard self.model.services.reader.shows(key), let reader = self.model.services.reader.model else { return false }
                return reader.detail?.commitments.contains { extra.created.contains($0.id ?? -1) } == false
                    && reader.focusedCommitment?.id == first.id && reader.focusedCommitment?.state == .open
            })
            model.focus = .reader
        }
        send("d")
        check("reader d completes its commitment", waitUntil { (try? self.model.store.commitments(on: [key]).contains { $0.state == .done }) == true })
        model.undoLast()
        check("reader done is undoable", waitUntil { (try? self.model.store.commitments(on: [key]).contains { $0.state == .open }) == true })
        model.back()
        model.showInboxTab(.primary)
        model.setCursor(key, open: false)
        check("d disabled outside ledger lists", registry["commitmentDone"]?.isEnabled() == false)
        check("D disabled outside ledger lists", registry["commitmentDismiss"]?.isEnabled() == false)
        send("d")
        send("D")
        poll(0.1) {}
        check("ledger keys leave Inbox commitments open", (try? model.store.commitments(on: [key]).contains { $0.state == .open }) == true)
    }
}
