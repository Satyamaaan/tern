import Foundation
import TernCore

extension SelfCheck {
    /// Drives the registered bare key and local undo through the same router as the list.
    func ledger() {
        model.show(.waitingOn)
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
        check("d completes a waiting request", (try? model.store.commitments(on: [key]).allSatisfy { $0.state == .done }) == true)
        model.undoLast()
        poll(0.3) {}
        check("undo reopens the waiting request", (try? model.store.commitments(on: [key]).contains { $0.state == .open }) == true)
        check("undo restores the waiting row", model.snapshot.rows[key] != nil)
        model.setCursor(key, open: true)
        model.focus = .list
        model.open()
        _ = waitUntil { self.model.services.reader.shows(key) && self.model.services.reader.model?.detail?.commitments.contains { $0.state == .open } == true }
        model.focus = .reader
        window.makeFirstResponder(nil)
        check("reader evidence command has items", registry["commitmentEvidence"]?.isEnabled() == true)
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
