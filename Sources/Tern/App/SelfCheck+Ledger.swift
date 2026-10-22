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
        model.showInboxTab(.primary)
    }
}
