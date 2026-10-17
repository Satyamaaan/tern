import Foundation
import GRDB
import TernCore

// Initial sync, backfill, full resync and body prefetch.
extension AccountSync {
    /// Profile → historyId saved first (so nothing that changes meanwhile is lost) → labels → the
    /// whole inbox in full → the newest messages of All Mail → hands over to the backfill.
    /// Safe to run again after an interruption: stored bodies aren't refetched.
    public func initialSync() async throws {
        try await prepare()
        if account.historyId == nil {
            let profile = try await withRetry { [api] in try await api.profile() }
            messagesTotal = profile.messagesTotal
            try await updateAccount { $0.historyId = profile.historyId; $0.syncState = .new; $0.syncError = nil }
        }
        publishAccount()
        try await syncLabels()

        let inboxIds = try await listIds(labelIds: [SystemLabel.inbox])
        let inboxNeeded = try await idsLackingBody(inboxIds)
        publish { $0.phase = "Fetching inbox"; $0.fetched = 0; $0.total = inboxNeeded.count }
        try await fetchAndStore(inboxNeeded, format: .full, countsProgress: true)

        let recent = try await withRetry { [api, configuration] in
            try await api.messageIds(query: nil, labelIds: [], pageToken: nil, maxResults: configuration.recentCount)
        }
        let recentNeeded = try await idsLackingBody(recent.messages?.map(\.id) ?? [])
        publish { $0.phase = "Fetching recent mail"; $0.fetched = 0; $0.total = recentNeeded.count }
        let next = recent.nextPageToken
        let accountId = self.accountId
        try await fetchAndStore(recentNeeded, format: .full, countsProgress: true) { db, _ in
            _ = try AccountSync.updateAccountRow(db, accountId) {
                $0.backfillPageToken = next
                $0.backfillDone = next == nil
                $0.syncState = next == nil ? .live : .backfilling
            }
        }
        try await reloadAccount()
        await publishBackfillProgress()
    }

    /// Fetches one page of older mail, newest first, and saves the page token with the last write
    /// so an interrupted backfill resumes there. The last page also brings in Trash and Spam, which
    /// Gmail leaves out of All Mail. Returns true while more remains.
    @discardableResult
    public func backfillStep() async throws -> Bool {
        guard !account.backfillDone else { return false }
        guard let token = account.backfillPageToken else {
            try await initialSync()
            return !account.backfillDone
        }
        if messagesTotal == nil { messagesTotal = try? await api.profile().messagesTotal }
        let page = try await withRetry { [api, configuration] in
            try await api.messageIds(query: nil, labelIds: [], pageToken: token, maxResults: configuration.listPageSize)
        }
        let next = page.nextPageToken
        var ids = page.messages?.map(\.id) ?? []
        if next == nil {
            ids += try await listIds(labelIds: [SystemLabel.trash]) + listIds(labelIds: [SystemLabel.spam])
        }
        let accountId = self.accountId
        let candidates = ids
        let stored = try await read { db in try MailStore.storedMessageIds(db, accountId: accountId, among: candidates) }
        try await fetchAndStore(ids.filter { !stored.contains($0) }, format: configuration.backfillFormat) { db, _ in
            _ = try AccountSync.updateAccountRow(db, accountId) {
                $0.backfillPageToken = next
                $0.backfillDone = next == nil
                if next == nil { $0.syncState = .live }
            }
        }
        try await reloadAccount()
        await publishBackfillProgress()
        return next != nil
    }

    /// After `historyExpired`: relists every id, refreshes labels of stored messages from metadata
    /// (bodies stay), fetches unknown messages in full, deletes local messages Gmail no longer has.
    public func fullResync() async throws {
        publish { $0.phase = "Resyncing"; $0.fetched = 0; $0.total = nil }
        let profile = try await withRetry { [api] in try await api.profile() }
        messagesTotal = profile.messagesTotal
        try await syncLabels()

        var serverIds: [String] = []
        var seen = Set<String>()
        for labels in [[], [SystemLabel.trash], [SystemLabel.spam]] {
            for id in try await listIds(labelIds: labels) where seen.insert(id).inserted { serverIds.append(id) }
        }
        let accountId = self.accountId
        let local = try await read { db in try MailStore.allMessageIds(db, accountId: accountId) }
        let known = serverIds.filter { local.contains($0) }
        let unknown = serverIds.filter { !local.contains($0) }
        var gone = local.subtracting(seen)
        publish { $0.total = serverIds.count }

        for chunk in known.syncChunks(configuration.fetchBatchSize) {
            let fetched = try await withRetry { [api] in try await api.messages(ids: chunk, format: .metadata) }
            let returned = Set(fetched.map(\.id))
            gone.formUnion(chunk.filter { !returned.contains($0) })
            var labels: [String: [String]] = [:]
            for message in fetched { labels[message.id] = message.labelIds ?? [] }
            let update = labels
            try await write { db in try MailStore.applyServerLabels(db, accountId: accountId, update) }
            publish { $0.fetched += chunk.count }
        }

        let goneIds = Array(gone)
        let historyId = profile.historyId
        let now = clock.now()
        try await fetchAndStore(unknown, format: .full, countsProgress: true) { db, missing in
            try MailStore.deleteMessages(db, accountId: accountId, ids: goneIds + missing)
            _ = try AccountSync.updateAccountRow(db, accountId) {
                $0.historyId = historyId
                $0.backfillDone = true
                $0.backfillPageToken = nil
                $0.syncState = .live
                $0.lastSyncAt = now
            }
        }
        try await reloadAccount()
        publishAccount(phase: "Up to date")
    }

    /// Fetches bodies for messages stored without one, newest first. Returns how many were tried.
    @discardableResult
    public func prefetchBodies() async throws -> Int {
        let accountId = self.accountId
        let limit = configuration.prefetchBatchSize
        let ids = try await read { db in try MailStore.messageIdsNeedingBody(db, accountId: accountId, limit: limit) }
        guard !ids.isEmpty else { return 0 }
        try await fetchAndStore(ids, format: .full) { db, missing in
            try MailStore.deleteMessages(db, accountId: accountId, ids: missing)
        }
        return ids.count
    }

    func syncLabels() async throws {
        let labels = try await withRetry { [api] in try await api.labels() }
        let accountId = self.accountId
        let records = labels.map { label in
            MailLabel(accountId: accountId, id: label.id, name: label.name, type: label.type?.lowercased() ?? "user",
                      colorBackground: label.color?.backgroundColor, colorText: label.color?.textColor,
                      hidden: label.labelListVisibility == "labelHide")
        }
        try await write { db in try MailStore.replaceLabels(db, accountId: accountId, with: records) }
        nextLabelRefreshAt = clock.now().addingTimeInterval(configuration.labelRefreshInterval)
    }

    /// Every id matching `labelIds`, newest first, across all pages.
    func listIds(labelIds: [String]) async throws -> [String] {
        var ids: [String] = []
        var token: String?
        repeat {
            let pageToken = token
            let page = try await withRetry { [api, configuration] in
                try await api.messageIds(query: nil, labelIds: labelIds, pageToken: pageToken, maxResults: configuration.listPageSize)
            }
            ids += page.messages?.map(\.id) ?? []
            token = page.nextPageToken
        } while token != nil
        return ids
    }

    /// `ids` that aren't stored with a full body, in order.
    func idsLackingBody(_ ids: [String]) async throws -> [String] {
        let accountId = self.accountId
        let full = try await read { db in try MailStore.fullMessageIds(db, accountId: accountId, among: ids) }
        var seen = Set<String>()
        return ids.filter { !full.contains($0) && seen.insert($0).inserted }
    }

    /// Fetches messages in batches and writes them in transactions of `writeBatchSize`, replaying
    /// unconfirmed local changes on top. `finally` runs inside the last write (even when `ids` is
    /// empty) with the ids Gmail no longer has. Returns those ids.
    @discardableResult
    func fetchAndStore(_ ids: [String], format: GmailMessageFormat, countsProgress: Bool = false,
                       finally: (@Sendable (Database, [String]) throws -> Void)? = nil) async throws -> [String] {
        let accountId = self.accountId
        let email = account.email
        let chunks = ids.syncChunks(configuration.fetchBatchSize)
        guard !chunks.isEmpty else {
            if let finally { try await write { db in try finally(db, []) } }
            return []
        }
        var missing: [String] = []
        var buffer: [ParsedMessage] = []
        for (index, chunk) in chunks.enumerated() {
            let fetched = try await withRetry { [api] in try await api.messages(ids: chunk, format: format) }
            let returned = Set(fetched.map(\.id))
            missing += chunk.filter { !returned.contains($0) }
            buffer += fetched.map { GmailMessageParser.parse($0, accountId: accountId, accountEmail: email, format: format) }

            let isLast = index == chunks.count - 1
            guard isLast || buffer.count >= configuration.writeBatchSize else { continue }
            let batch = buffer
            let gone = missing
            buffer = []
            try await write { db in
                try MailStore.upsertServerMessages(db, batch.map(\.message), attachments: batch.flatMap(\.attachments))
                if isLast, let finally { try finally(db, gone) }
            }
            if countsProgress { publish { $0.fetched += batch.count } }
        }
        return missing
    }

    func publishBackfillProgress() async {
        let accountId = self.accountId
        let count = (try? await read { db in try MailStore.messageCount(db, accountId: accountId) }) ?? 0
        let account = self.account
        let total = messagesTotal
        publish {
            $0.state = account.syncState
            $0.phase = account.backfillDone ? "Up to date" : "Fetching older mail"
            $0.fetched = count
            $0.total = total
        }
    }
}
