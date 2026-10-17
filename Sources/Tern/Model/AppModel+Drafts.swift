import TernCore

// Rows of the Drafts mailbox open their draft in the composer rather than the reader: a draft Gmail
// has no copy of, or a thread's Gmail draft (its body is fetched first when only headers are stored).
extension AppModel {
    /// Opens the composer for a draft row: a local draft's row anywhere, or a row of the Drafts
    /// mailbox. False for other rows, which open in the reader.
    @discardableResult
    func openDraft(_ key: ThreadKey) -> Bool {
        if let id = MailThread.localDraftId(in: key) {
            services.compose(.draft(id: id))
            return true
        }
        guard case .drafts = kind, !isSearching,
              let message = try? services.drafts.draftMessage(inThread: key) else { return false }
        services.openDraftMessage(message)
        return true
    }
}
