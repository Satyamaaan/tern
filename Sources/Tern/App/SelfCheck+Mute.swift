import AppKit
import GRDB
import TernCore
import TernSync

/// Mute against the real store (no network: the first mute in an account queues the stand-in label).
extension SelfCheck {
    /// m, then z before the write could have finished: the mute is undone, not left to land afterwards.
    func muteThenUndo() {
        let services = model.services
        let store = model.store
        let previous = services.muteThreads
        services.muteThreads = { keys in try AccountSync.mute(keys, in: store) }
        defer { services.muteThreads = previous }
        model.show(.inbox)
        model.showSplit(.people)
        wait(0.2)
        guard let key = model.cursor else { return check("mute: a row to mute", false) }

        model.mute()
        check("m hides the row in the same frame", model.snapshot.rows[key] == nil)
        model.undoLast()
        poll(0.8) {}
        check("z right after m puts the row back for good", model.snapshot.rows[key] != nil)
        let state = try? store.database.reader.read { db -> (inbox: Bool, queued: Int) in
            let inbox = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM thread_label WHERE accountId = ? AND threadId = ? AND labelId = 'INBOX')
                """, arguments: [key.accountId, key.threadId]) ?? false
            let queued = try Int.fetchOne(db, sql: "SELECT count(*) FROM pending_op WHERE instr(payload, ?) > 0",
                                          arguments: [MailStore.pendingMuteLabel]) ?? 0
            return (inbox, queued)
        }
        check("…in the database too, with nothing queued for Gmail", state?.inbox == true && state?.queued == 0)
    }
}
