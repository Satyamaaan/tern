import Foundation
import GRDB
import TernCore

// Live updates from users.history.
extension AccountSync {
    /// Applies every history record since the stored historyId, one page per transaction, saving
    /// the historyId reached with each page. Throws `.historyExpired` when a full resync is needed.
    /// All pages are read first (2 units each), so after a long gap only the newest
    /// `historyFullFetchLimit` new messages of the whole gap are fetched in full.
    public func pollHistory() async throws {
        guard let start = account.historyId else { return }
        if clock.now() >= nextLabelRefreshAt { try await syncLabels() }
        var pages: [(records: [GmailHistory], reaching: String?)] = []
        var pageToken: String?
        repeat {
            let token = pageToken
            let page = try await withRetry { [api] in try await api.history(startHistoryId: start, pageToken: token) }
            let records = page.history ?? []
            pageToken = page.nextPageToken
            // The mailbox's current historyId is only safe to store when everything fit in one page;
            // across pages, records written in between could otherwise be skipped.
            let singlePage = pages.isEmpty && pageToken == nil
            pages.append((records, singlePage ? (page.historyId ?? records.last?.id) : records.last?.id))
        } while pageToken != nil

        var added: [String] = []
        var seen = Set<String>()
        for id in pages.flatMap(\.records).flatMap({ $0.messagesAdded ?? [] }).map(\.message.id).reversed()
        where seen.insert(id).inserted {
            added.append(id)
        }
        let metadataOnly = Set(added.dropFirst(configuration.historyFullFetchLimit))
        for page in pages {
            try await apply(page.records, reaching: page.reaching, metadataOnly: metadataOnly)
            try await serviceActions()
        }
        publishAccount(phase: account.backfillDone ? "Up to date" : nil)
    }

    /// Reduces records to their net effect per message, fetches added messages in full, then writes
    /// adds, label changes (with unconfirmed local changes replayed on top) and deletes together.
    func apply(_ records: [GmailHistory], reaching historyId: String?, metadataOnly: Set<String> = []) async throws {
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
                if let labelIds = change.message.labelIds {
                    labels[id] = labelIds
                } else {
                    // No labels in the event: fetch the message rather than clear them.
                    labels[id] = nil
                    fetchSet.insert(id)
                    fetchOrder.append(id)
                }
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

        historyGeneration += 1
        let labelUpdates = labels
        let deletions = Array(deleted)
        let now = clock.now()
        // New mail comes in full; after a long gap, all but the newest arrive as metadata (at bulk
        // priority) and get their bodies on demand, so one poll can't spend minutes of quota.
        let metadataIds = fetchOrder.filter(metadataOnly.contains)
        let older = try await QuotaPriority.$current.withValue(.bulk) {
            try await fetchAndStore(metadataIds, format: .metadata)
        }
        let added = fetchOrder
        try await fetchAndStore(fetchOrder.filter { !metadataOnly.contains($0) }, format: .full) { db, missing in
            let missing = missing + older
            try MailStore.applyServerLabels(db, accountId: accountId, labelUpdates)
            try MailStore.deleteServerMessages(db, accountId: accountId, ids: deletions + missing)
            try AccountSync.rearchiveMuted(db, accountId: accountId, messageIds: added)
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
