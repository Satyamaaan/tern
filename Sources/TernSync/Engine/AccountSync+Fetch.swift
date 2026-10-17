import Foundation
import GRDB
import TernCore

/// What the initial sync still has to fetch, inbox first.
struct InitialPlan: Sendable {
    struct Unit: Sendable {
        var threadId: String
        /// Messages to fetch (all of them for a whole-thread fetch, as far as the listings know).
        var messageIds: [String]
        /// One threads.get instead of a messages.get per message.
        var wholeThread: Bool
        var inInbox: Bool
    }

    var units: [Unit]
    var total: Int
    var done = 0
}

/// The backfill page being worked through.
struct BackfillPage: Sendable {
    var ids: [String]
    var nextToken: String?
}

// Initial sync, backfill, full resync and bodies.
extension AccountSync {
    /// Profile → historyId saved first (so nothing that changes during the initial sync is lost)
    /// → labels. Cheap; the fetching happens in `initialStep`.
    func startInitialSync() async throws {
        let profile = try await withRetry { [api] in try await api.profile() }
        messagesTotal = profile.messagesTotal
        try await updateAccount { $0.historyId = profile.historyId; $0.syncState = .new; $0.syncError = nil }
        publishAccount()
        try await syncLabels()
    }

    /// Runs the whole initial sync (inbox, then recent mail) without the loop. The loop calls
    /// `initialStep` one slice at a time instead, so polls and actions get in between.
    public func initialSync() async throws {
        try await prepare()
        try await QuotaPriority.$current.withValue(.bulk) {
            while try await initialStep() {}
        }
    }

    /// One slice (at most `bulkStepUnits`) of the initial sync. The first call lists the inbox and
    /// the last `recentDays` of All Mail (cheap) and plans the fetches; threads with enough
    /// messages to fetch come whole from threads.get. When the plan is done the account moves to
    /// `.backfilling`. Returns false once nothing is left for it. Safe to rerun after an interruption.
    @discardableResult
    public func initialStep() async throws -> Bool {
        try await prepare()
        if account.historyId == nil { try await startInitialSync() }
        guard account.syncState == .new else { return false }
        if initialPlan == nil {
            initialPlan = try await makeInitialPlan()
            publish { $0.phase = "Fetching inbox"; $0.fetched = 0; $0.total = initialPlan?.total }
        }
        guard var plan = initialPlan, !plan.units.isEmpty else {
            try await finishInitialSync()
            return true
        }

        let quota = configuration.quota
        var slice: [InitialPlan.Unit] = []
        var cost = 0
        for unit in plan.units {
            let unitCost = unit.wholeThread ? quota.getThreadFull : unit.messageIds.count * quota.getMessageFull
            if !slice.isEmpty, cost + unitCost > configuration.bulkStepUnits { break }
            slice.append(unit)
            cost += unitCost
        }
        let inInbox = slice.first?.inInbox ?? false
        publish { $0.phase = inInbox ? "Fetching inbox" : "Fetching the last \(configuration.recentDays) days" }

        try await fetchAndStore(slice.filter { !$0.wholeThread }.flatMap(\.messageIds), format: .full)
        try await fetchThreads(slice.filter(\.wholeThread).map { ($0.threadId, $0.messageIds) })

        plan.units.removeFirst(slice.count)
        plan.done += slice.reduce(0) { $0 + $1.messageIds.count }
        initialPlan = plan
        let done = plan.done
        publish { $0.fetched = done }
        if plan.units.isEmpty { try await finishInitialSync() }
        // Finishing hands over to the backfill, which can start right away.
        return true
    }

    private func makeInitialPlan() async throws -> InitialPlan {
        let inbox = try await listRefs(labelIds: [SystemLabel.inbox], query: nil, limit: configuration.initialInboxLimit)
        let since = Int(clock.now().timeIntervalSince1970) - configuration.recentDays * 86_400
        let recent = try await listRefs(labelIds: [], query: "after:\(since)", limit: configuration.initialRecentLimit)

        // Every listed message per thread, in order of first appearance (newest first).
        var threadOrder: [String] = []
        var threadMessages: [String: [String]] = [:]
        var inboxThreads = Set<String>()
        var seen = Set<String>()
        for (ref, isInbox) in inbox.map({ ($0, true) }) + recent.map({ ($0, false) }) where seen.insert(ref.id).inserted {
            if threadMessages[ref.threadId] == nil { threadOrder.append(ref.threadId) }
            threadMessages[ref.threadId, default: []].append(ref.id)
            if isInbox { inboxThreads.insert(ref.threadId) }
        }
        let accountId = self.accountId
        let allIds = Array(seen)
        let full = try await read { db in try MailStore.fullMessageIds(db, accountId: accountId, among: allIds) }

        var units: [InitialPlan.Unit] = []
        for threadId in threadOrder.filter(inboxThreads.contains) + threadOrder.filter({ !inboxThreads.contains($0) }) {
            let known = threadMessages[threadId] ?? []
            let needed = known.filter { !full.contains($0) }
            guard !needed.isEmpty else { continue }
            units.append(InitialPlan.Unit(threadId: threadId, messageIds: needed,
                                          wholeThread: prefersThreadFetch(needed: needed.count, known: known.count),
                                          inInbox: inboxThreads.contains(threadId)))
        }
        return InitialPlan(units: units, total: units.reduce(0) { $0 + $1.messageIds.count })
    }

    /// threads.get full (120) beats a messages.get full (60) per message from three messages,
    /// and ties at two when the thread has more messages than those two.
    func prefersThreadFetch(needed: Int, known: Int) -> Bool {
        guard !threadsUnsupported else { return false }
        let quota = configuration.quota
        return needed >= configuration.threadFetchMinimum
            || (needed * quota.getMessageFull >= quota.getThreadFull && known > needed)
    }

    /// The inbox and recent mail are in. Every write already sorted its threads (`MailStore.applyRules`);
    /// now the address book is rebuilt, so the split inbox knows who the user writes to, and the
    /// account's threads are sorted again with it.
    private func finishInitialSync() async throws {
        initialPlan = nil
        try await updateAccount {
            if $0.backfillPageToken == nil { $0.backfillPageToken = "" }
            $0.syncState = $0.backfillDone ? .live : .backfilling
        }
        let accountId = self.accountId
        try await write { db in
            try MailStore.rebuildContacts(db)
            let keys = try String.fetchAll(db, sql: "SELECT id FROM thread WHERE accountId = ?", arguments: [accountId])
                .map { ThreadKey(accountId: accountId, threadId: $0) }
            try RuleClassifier.classify(db, keys: keys)
            try RuleClassifier.classifyAllMissing(db)
        }
        await publishBackfillProgress()
    }

    /// Fetches whole threads (`format` full or metadata) and stores their messages. Falls back to
    /// messages.get for the known ids when the client has no threads.get.
    func fetchThreads(_ threads: [(threadId: String, knownIds: [String])], format: GmailMessageFormat = .full,
                      guardHistory: Bool = false) async throws {
        guard !threads.isEmpty else { return }
        if threadsUnsupported {
            try await fetchAndStore(threads.flatMap(\.knownIds), format: format, guardHistory: guardHistory)
            return
        }
        let accountId = self.accountId
        let email = account.email
        for chunk in threads.syncChunks(batchSize(cost: configuration.quota.threadCost(format))) {
            var fetched: [GmailThread] = []
            do {
                for attempt in 0..<3 {
                    let generation = historyGeneration
                    fetched = try await withRetry { [api] in try await api.threads(ids: chunk.map(\.threadId), format: format) }
                    if !guardHistory || generation == historyGeneration || attempt == 2 { break }
                }
            } catch GmailAPIError.server(501, GmailThread.unsupported) {
                threadsUnsupported = true
                try await fetchAndStore(threads.flatMap(\.knownIds), format: format, guardHistory: guardHistory)
                return
            }
            var parsed: [ParsedMessage] = []
            for thread in fetched {
                for message in thread.messages ?? [] {
                    if format == .full, let complete = try await withExternalBodies(message) {
                        parsed.append(GmailMessageParser.parse(complete, accountId: accountId, accountEmail: email, format: .full))
                    } else {
                        if format == .full { failedBodies.insert(message.id) }
                        parsed.append(GmailMessageParser.parse(message, accountId: accountId, accountEmail: email,
                                                               format: format == .full ? .metadata : format))
                    }
                }
                completeThreads.insert(thread.id)
            }
            let batch = parsed
            try await write { db in
                try MailStore.upsertServerMessages(db, batch.map(\.message), attachments: batch.flatMap(\.attachments))
            }
        }
    }

    /// One background step of the older-mail backfill: metadata only (20 units a message), newest
    /// first, `backfillBatchSize` messages at a time. The page token is saved once a whole page is
    /// stored, so an interrupted backfill resumes at that page. The last page also brings in Trash
    /// and Spam, which Gmail leaves out of All Mail. Returns true while more remains.
    @discardableResult
    public func backfillStep() async throws -> Bool {
        guard account.syncState != .new, !account.backfillDone else { return false }
        let accountId = self.accountId
        if backfillPage == nil {
            let token = account.backfillPageToken.flatMap { $0.isEmpty ? nil : $0 }
            let listed: GmailIdPage
            do {
                listed = try await withRetry { [api, configuration] in
                    try await api.messageIds(query: nil, labelIds: [], pageToken: token, maxResults: configuration.listPageSize)
                }
            } catch GmailAPIError.server(400, _) where token != nil {
                // The saved page token went stale; start over from the top (stored mail is skipped).
                try await updateAccount { $0.backfillPageToken = "" }
                return true
            }
            var ids = listed.messages?.map(\.id) ?? []
            if listed.nextPageToken == nil {
                ids += try await listIds(labelIds: [SystemLabel.trash]) + listIds(labelIds: [SystemLabel.spam])
            }
            let candidates = ids
            let stored = try await read { db in try MailStore.storedMessageIds(db, accountId: accountId, among: candidates) }
            var seen = Set<String>()
            backfillPage = BackfillPage(ids: ids.filter { !stored.contains($0) && seen.insert($0).inserted },
                                        nextToken: listed.nextPageToken)
            if messagesTotal == nil { messagesTotal = try? await api.profile().messagesTotal }
        }
        guard let page = backfillPage else { return false }

        if !page.ids.isEmpty {
            let batch = Array(page.ids.prefix(configuration.backfillBatchSize))
            try await fetchAndStore(batch, format: .metadata)
            let done = Set(batch)
            backfillPage?.ids.removeAll { done.contains($0) }
            await publishBackfillProgress()
            if !(backfillPage?.ids.isEmpty ?? true) { return true }
        }

        let next = backfillPage?.nextToken
        try await updateAccount {
            $0.backfillPageToken = next
            $0.backfillDone = next == nil
            if next == nil { $0.syncState = .live }
        }
        // All mail is in: the address book learns everyone the user has written to.
        if next == nil { try await write { db in try MailStore.rebuildContacts(db) } }
        backfillPage = nil
        await publishBackfillProgress()
        return next != nil
    }

    /// After `historyExpired`. Lists every id, then rebuilds each stored message's labels from one
    /// cheap messages.list per label (5 units per 500 messages, instead of 20 per message), keeping
    /// bodies. The newest new inbox mail is fetched in full; every other message Gmail has and we
    /// don't is left to the backfill, which restarts from the top and skips what's stored. Local
    /// messages Gmail no longer has are deleted. Queued actions still go out between the lists.
    public func fullResync() async throws {
        try await QuotaPriority.$current.withValue(.bulk) { try await resync() }
    }

    private func resync() async throws {
        publish { $0.phase = "Resyncing"; $0.fetched = 0; $0.total = nil }
        let wasNew = account.syncState == .new
        backfillPage = nil
        let profile = try await withRetry { [api] in try await api.profile() }
        messagesTotal = profile.messagesTotal
        let labels = try await syncLabels()

        let listed = try await listIds(labelIds: [])
        let trash = try await listIds(labelIds: [SystemLabel.trash])
        let spam = try await listIds(labelIds: [SystemLabel.spam])
        let hidden = Set(trash).union(spam)
        let serverIds = Set(listed).union(hidden)
        let accountId = self.accountId
        let local = try await read { db in try MailStore.allMessageIds(db, accountId: accountId) }

        // Per-label lists leave out Trash and Spam, so they rebuild everything else exactly.
        var labelsById: [String: [String]] = [:]
        for id in listed where local.contains(id) && !hidden.contains(id) { labelsById[id] = [] }
        var inboxIds: [String] = []
        for label in labels where label.id != SystemLabel.trash && label.id != SystemLabel.spam {
            try await serviceActions()
            let members = try await listIds(labelIds: [label.id])
            if label.id == SystemLabel.inbox { inboxIds = members }
            for id in members where labelsById[id] != nil { labelsById[id]?.append(label.id) }
        }
        for chunk in Array(labelsById).syncChunks(configuration.writeBatchSize) {
            let update = Dictionary(uniqueKeysWithValues: chunk)
            try await write { db in try MailStore.applyServerLabels(db, accountId: accountId, update) }
        }

        // Stored Trash and Spam: read their labels while that's cheap, else just move them there.
        let knownHidden = Array(hidden.filter(local.contains))
        var gone = local.subtracting(serverIds)
        if knownHidden.count <= configuration.resyncHiddenRefreshLimit {
            for chunk in knownHidden.syncChunks(batchSize(cost: configuration.quota.getMessage)) {
                try await serviceActions()
                let fetched = try await withRetry { [api] in try await api.messages(ids: chunk, format: .minimal) }
                let returned = Set(fetched.map(\.id))
                gone.formUnion(chunk.filter { !returned.contains($0) })
                let update = Dictionary(fetched.map { ($0.id, $0.labelIds ?? []) }, uniquingKeysWith: { $1 })
                try await write { db in try MailStore.applyServerLabels(db, accountId: accountId, update) }
            }
        } else {
            let trashSet = Set(trash)
            for chunk in knownHidden.syncChunks(configuration.writeBatchSize) {
                try await write { db in
                    var update: [String: [String]] = [:]
                    for row in try Row.fetchAll(db, sql: """
                        SELECT id, labelIds FROM message WHERE accountId = ? AND id IN (\(databaseQuestionMarks(count: chunk.count)))
                        """, arguments: StatementArguments([accountId] + chunk)) {
                        let id: String = row["id"]
                        let json: String = row["labelIds"]
                        var labels = Set((try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? [])
                        labels.remove(SystemLabel.inbox)
                        labels.insert(trashSet.contains(id) ? SystemLabel.trash : SystemLabel.spam)
                        update[id] = Array(labels)
                    }
                    try MailStore.applyServerLabels(db, accountId: accountId, update)
                }
            }
        }

        let newInbox = inboxIds.filter { !local.contains($0) }
        let fetchNow = Array(newInbox.prefix(configuration.historyFullFetchLimit))
        try await fetchAndStore(fetchNow, format: .full, guardHistory: false)
        let unknownLeft = serverIds.count - local.intersection(serverIds).count - fetchNow.count

        let goneIds = Array(gone)
        let historyId = profile.historyId
        let now = clock.now()
        try await write { db in
            try MailStore.deleteServerMessages(db, accountId: accountId, ids: goneIds)
            _ = try AccountSync.updateAccountRow(db, accountId) {
                $0.historyId = historyId
                $0.lastSyncAt = now
                if wasNew { return }
                if unknownLeft > 0 || !$0.backfillDone {
                    $0.backfillDone = false
                    $0.backfillPageToken = ""
                }
                $0.syncState = $0.backfillDone ? .live : .backfilling
            }
        }
        // An unfinished initial sync plans again from the new lists.
        if wasNew { initialPlan = nil }
        try await reloadAccount()
        publishAccount(phase: wasNew ? "Fetching inbox" : "Up to date")
        await publishBackfillProgress()
    }

    /// The body trickle: fetches bodies for messages stored without one, newest first.
    /// Returns how many were tried.
    @discardableResult
    public func prefetchBodies() async throws -> Int {
        let accountId = self.accountId
        let skip = failedBodies
        let limit = configuration.prefetchBatchSize
        let ids = try await read { db in
            try MailStore.messageIdsNeedingBody(db, accountId: accountId, limit: limit + skip.count)
        }.filter { !skip.contains($0) }.prefix(limit).map { $0 }
        guard !ids.isEmpty else { return 0 }
        try await fetchAndStore(ids, format: .full) { db, missing in
            try MailStore.deleteServerMessages(db, accountId: accountId, ids: missing)
        }
        return ids.count
    }

    /// Makes sure every message of a thread is stored with its body. Call when the user opens it;
    /// interactive priority, so it never waits behind the backfill. Missing bodies come from one
    /// threads.get when there are several, else messages.get. While older mail is still
    /// backfilling, the thread is first checked for messages not stored yet (threads.get metadata,
    /// 40 units), unless it was fetched whole this run.
    public func fetchBodies(_ thread: ThreadKey) async throws {
        guard thread.accountId == accountId else { return }
        let accountId = self.accountId
        let threadId = thread.threadId
        let local = try await read { db in
            try Row.fetchAll(db, sql: "SELECT id, bodyState FROM message WHERE accountId = ? AND threadId = ?",
                             arguments: [accountId, threadId])
                .map { (id: $0["id"] as String, full: ($0["bodyState"] as Int) == MailMessage.BodyState.full.rawValue) }
        }
        var missing = local.filter { !$0.full }.map(\.id)
        let unsure = !account.backfillDone && !completeThreads.contains(threadId)
        guard !missing.isEmpty || unsure || local.isEmpty else { return }

        if local.isEmpty || missing.count >= configuration.threadFetchMinimum || (unsure && threadsUnsupported) {
            try await fetchThreads([(threadId, missing)], format: .full, guardHistory: true)
            return
        }
        if unsure {
            let generation = historyGeneration
            var fetched: [GmailThread]
            do {
                fetched = try await withRetry { [api] in try await api.threads(ids: [threadId], format: .metadata) }
            } catch GmailAPIError.server(501, GmailThread.unsupported) {
                threadsUnsupported = true
                fetched = []
            }
            // History moved while we read: its changes win; the full fetch below brings the rest.
            if generation != historyGeneration { fetched = [] }
            let localIds = Set(local.map(\.id))
            let email = account.email
            let messages = fetched.first?.messages ?? []
            let unknown = messages.filter { !localIds.contains($0.id) }
            let parsed = unknown.map { GmailMessageParser.parse($0, accountId: accountId, accountEmail: email, format: .metadata) }
            let labels = Dictionary(messages.filter { localIds.contains($0.id) }.map { ($0.id, $0.labelIds ?? []) }, uniquingKeysWith: { $1 })
            try await write { db in
                try MailStore.upsertServerMessages(db, parsed.map(\.message), attachments: [])
                try MailStore.applyServerLabels(db, accountId: accountId, labels)
            }
            if !fetched.isEmpty { completeThreads.insert(threadId) }
            missing += unknown.map(\.id)
            if missing.count >= configuration.threadFetchMinimum {
                try await fetchThreads([(threadId, missing)], format: .full, guardHistory: true)
                return
            }
        }
        try await fetchAndStore(missing, format: .full, guardHistory: true)
    }

    @discardableResult
    func syncLabels() async throws -> [GmailLabel] {
        let labels = try await withRetry { [api] in try await api.labels() }
        let accountId = self.accountId
        let records = labels.map { label in
            MailLabel(accountId: accountId, id: label.id, name: label.name, type: label.type?.lowercased() ?? "user",
                      colorBackground: label.color?.backgroundColor, colorText: label.color?.textColor,
                      hidden: label.labelListVisibility == "labelHide")
        }
        try await write { db in try MailStore.replaceLabels(db, accountId: accountId, with: records) }
        nextLabelRefreshAt = clock.now().addingTimeInterval(configuration.labelRefreshInterval)
        return labels
    }

    /// Message refs matching the filter, newest first, across pages (5 units a page): every one,
    /// or the first `limit`.
    func listRefs(labelIds: [String], query: String?, limit: Int? = nil) async throws -> [GmailMessageRef] {
        var refs: [GmailMessageRef] = []
        var token: String?
        repeat {
            let pageToken = token
            let size = limit.map { min(configuration.listPageSize, max(1, $0 - refs.count)) } ?? configuration.listPageSize
            let page = try await withRetry { [api] in
                try await api.messageIds(query: query, labelIds: labelIds, pageToken: pageToken, maxResults: size)
            }
            refs += page.messages ?? []
            token = page.nextPageToken
        } while token != nil && refs.count < (limit ?? .max)
        return limit.map { Array(refs.prefix($0)) } ?? refs
    }

    /// Every id matching `labelIds`, newest first, across all pages.
    func listIds(labelIds: [String]) async throws -> [String] {
        try await listRefs(labelIds: labelIds, query: nil).map(\.id)
    }

    /// Ids per call so one request costs at most `maxUnitsPerRequest`, or
    /// `backgroundMaxUnitsPerRequest` for bulk and background work.
    func batchSize(cost: Int) -> Int {
        let limit = QuotaPriority.current == .interactive ? configuration.maxUnitsPerRequest : configuration.backgroundMaxUnitsPerRequest
        return max(1, min(configuration.fetchBatchSize, limit / max(1, cost)))
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
    ///
    /// `guardHistory` is for callers outside the sync loop (server search): each batch is written
    /// right after its fetch, and refetched first when history was applied in between, so a delete
    /// or label change that history skipped (the message wasn't stored yet) isn't overwritten.
    @discardableResult
    func fetchAndStore(_ ids: [String], format: GmailMessageFormat, countsProgress: Bool = false, guardHistory: Bool = false,
                       finally: (@Sendable (Database, [String]) throws -> Void)? = nil) async throws -> [String] {
        let accountId = self.accountId
        let email = account.email
        let chunks = ids.syncChunks(batchSize(cost: configuration.quota.messageCost(format)))
        guard !chunks.isEmpty else {
            if let finally { try await write { db in try finally(db, []) } }
            return []
        }
        var missing: [String] = []
        var buffer: [ParsedMessage] = []
        for (index, chunk) in chunks.enumerated() {
            // Bulk and background fetches are the run loop's: queued actions go out in between.
            if index > 0, QuotaPriority.current != .interactive { try await serviceActions() }
            var fetched: [GmailMessage] = []
            for attempt in 0..<3 {
                let generation = historyGeneration
                fetched = try await withRetry { [api] in try await api.messages(ids: chunk, format: format) }
                if !guardHistory || generation == historyGeneration || attempt == 2 { break }
            }
            let returned = Set(fetched.map(\.id))
            missing += chunk.filter { !returned.contains($0) }
            for message in fetched {
                if format == .full, let complete = try await withExternalBodies(message) {
                    buffer.append(GmailMessageParser.parse(complete, accountId: accountId, accountEmail: email, format: .full))
                } else {
                    // A body part couldn't be fetched: store headers now, a later open tries again.
                    if format == .full { failedBodies.insert(message.id) }
                    buffer.append(GmailMessageParser.parse(message, accountId: accountId, accountEmail: email,
                                                           format: format == .full ? .metadata : format))
                }
            }

            let isLast = index == chunks.count - 1
            guard isLast || guardHistory || buffer.count >= configuration.writeBatchSize else { continue }
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

    /// Gmail returns large text bodies by attachment id instead of inline data. Fetches them into
    /// the payload so the parser sees the whole body. Nil when one couldn't be fetched; rate
    /// limits, sign-in problems and cancellation still throw.
    func withExternalBodies(_ message: GmailMessage) async throws -> GmailMessage? {
        guard var payload = message.payload else { return message }
        let paths = AccountSync.externalBodyPaths(payload)
        guard !paths.isEmpty else { return message }
        for (path, attachmentId) in paths {
            let data: Data
            do {
                data = try await withRetry { [api] in try await api.attachment(messageId: message.id, attachmentId: attachmentId) }
            } catch let error as GmailAPIError {
                switch error {
                case .rateLimited, .unauthorized: throw error
                default: return nil
                }
            }
            AccountSync.setBodyData(&payload, path: path[...], data: MailParsing.base64URLEncode(data))
        }
        var complete = message
        complete.payload = payload
        return complete
    }

    /// Text body parts (not attachments) whose data Gmail left out, as child-index paths.
    static func externalBodyPaths(_ part: GmailMessagePart, path: [Int] = []) -> [([Int], String)] {
        var found: [([Int], String)] = []
        let type = (part.mimeType ?? "").lowercased()
        if type == "text/plain" || type == "text/html", part.body?.data == nil, let attachmentId = part.body?.attachmentId,
           (part.filename ?? "").isEmpty,
           part.header("Content-Disposition").map(MailParsing.parameterizedValue)?.value != "attachment" {
            found.append((path, attachmentId))
        }
        for (index, child) in (part.parts ?? []).enumerated() {
            found += externalBodyPaths(child, path: path + [index])
        }
        return found
    }

    static func setBodyData(_ part: inout GmailMessagePart, path: ArraySlice<Int>, data: String) {
        guard let index = path.first else {
            part.body?.data = data
            return
        }
        guard var children = part.parts, children.indices.contains(index) else { return }
        setBodyData(&children[index], path: path.dropFirst(), data: data)
        part.parts = children
    }

    func publishBackfillProgress() async {
        let accountId = self.accountId
        let count = (try? await read { db in try MailStore.messageCount(db, accountId: accountId) }) ?? 0
        let account = self.account
        let total = messagesTotal
        publish {
            $0.state = account.syncState
            if account.syncState != .new { $0.phase = "Up to date"; $0.fetched = 0; $0.total = nil }
            $0.background = account.syncState == .backfilling ? "Older mail syncing in the background" : nil
            $0.backfillFetched = count
            $0.backfillTotal = total.map { max($0, count) }
        }
    }
}
