import Foundation
import GRDB
import TernCore

// Live updates from users.history.
extension AccountSync {
    /// Applies every history record since the stored historyId, one page per transaction, saving
    /// the historyId reached with each page. Throws `.historyExpired` when a full resync is needed.
    public func pollHistory() async throws {
        guard let start = account.historyId else { return }
        if clock.now() >= nextLabelRefreshAt { try await syncLabels() }
        var pageToken: String?
        repeat {
            let token = pageToken
            let page = try await withRetry { [api] in try await api.history(startHistoryId: start, pageToken: token) }
            let records = page.history ?? []
            pageToken = page.nextPageToken
            try await apply(records, reaching: pageToken == nil ? (page.historyId ?? records.last?.id) : records.last?.id)
        } while pageToken != nil
        publishAccount(phase: account.backfillDone ? "Up to date" : nil)
    }

    /// Reduces records to their net effect per message, fetches added messages in full, then writes
    /// adds, label changes (with unconfirmed local changes replayed on top) and deletes together.
    func apply(_ records: [GmailHistory], reaching historyId: String?) async throws {
        if records.isEmpty, !(historyId.map { AccountSync.isNewer($0, than: account.historyId) } ?? false) {
            // Nothing changed: keep the account row quiet, persisting the sync time once a minute.
            let now = clock.now()
            if account.lastSyncAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                try await updateAccount { $0.lastSyncAt = now }
            }
            publish { $0.lastSyncAt = now }
            return
        }

        var fetchOrder: [String] = []
        var fetchSet = Set<String>()
        var deleted = Set<String>()
        var labels: [String: [String]] = [:]

        for record in records {
            for item in record.messagesAdded ?? [] {
                let id = item.message.id
                deleted.remove(id)
                labels[id] = nil
                if fetchSet.insert(id).inserted { fetchOrder.append(id) }
            }
            for item in record.messagesDeleted ?? [] {
                let id = item.message.id
                deleted.insert(id)
                labels[id] = nil
                if fetchSet.remove(id) != nil { fetchOrder.removeAll { $0 == id } }
            }
            // The event's message carries its labels as of that record; the last one wins.
            for change in (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) {
                let id = change.message.id
                guard !deleted.contains(id), !fetchSet.contains(id) else { continue }
                labels[id] = change.message.labelIds ?? []
            }
        }

        // Label changes on messages not stored yet: fetch the ones now in the inbox so it stays
        // complete; the backfill picks up the rest.
        let accountId = self.accountId
        if !labels.isEmpty {
            let ids = Array(labels.keys)
            let stored = try await read { db in try MailStore.storedMessageIds(db, accountId: accountId, among: ids) }
            for (id, labelIds) in labels where !stored.contains(id) {
                labels[id] = nil
                if labelIds.contains(SystemLabel.inbox), fetchSet.insert(id).inserted { fetchOrder.append(id) }
            }
        }

        let labelUpdates = labels
        let deletions = Array(deleted)
        let now = clock.now()
        try await fetchAndStore(fetchOrder, format: .full) { db, missing in
            try MailStore.applyServerLabels(db, accountId: accountId, labelUpdates)
            try MailStore.deleteMessages(db, accountId: accountId, ids: deletions + missing)
            _ = try AccountSync.updateAccountRow(db, accountId) { account in
                if let historyId, AccountSync.isNewer(historyId, than: account.historyId) { account.historyId = historyId }
                account.lastSyncAt = now
            }
        }
        try await reloadAccount()
    }

    static func isNewer(_ candidate: String, than current: String?) -> Bool {
        guard let current, let old = UInt64(current), let new = UInt64(candidate) else { return true }
        return new > old
    }
}
