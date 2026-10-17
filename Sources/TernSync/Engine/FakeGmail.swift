import Foundation
import TernCore

/// A message to put into a `FakeGmail` account.
public struct FakeEmail: Sendable {
    public var from: String
    /// Defaults to the account address.
    public var to: [String]
    public var cc: [String]
    public var subject: String
    public var text: String?
    public var html: String?
    public var date: Date
    public var labels: [String]
    /// Nil starts a new thread.
    public var threadId: String?
    public var inReplyTo: String?
    public var attachments: [FakeAttachment]

    public init(from: String = "Ann Lee <ann@example.com>", to: [String] = [], cc: [String] = [],
                subject: String = "Hello", text: String? = "Hi there", html: String? = nil,
                date: Date = Date(), labels: [String] = [SystemLabel.inbox, SystemLabel.unread],
                threadId: String? = nil, inReplyTo: String? = nil, attachments: [FakeAttachment] = []) {
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.text = text
        self.html = html
        self.date = date
        self.labels = labels
        self.threadId = threadId
        self.inReplyTo = inReplyTo
        self.attachments = attachments
    }
}

public struct FakeAttachment: Sendable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    /// Set for inline images referenced as `cid:` from the HTML.
    public var contentId: String?

    public init(filename: String, mimeType: String, data: Data, contentId: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentId = contentId
    }
}

/// An in-memory Gmail account that behaves like the API, for engine tests and offline work:
/// labels and threads, a monotonically increasing historyId with a history record for every
/// change, history expiry, newest-first pagination, batchModify/trash/send/drafts, attachments,
/// latency and injected failures. Helpers simulate new mail and changes made from another client.
public actor FakeGmail: GmailAPI {
    public enum Operation: String, Sendable, CaseIterable {
        case profile, labels, createLabel, deleteLabel, messageIds, messages, threads, history, batchModify
        case trashThread, untrashThread, attachment, send, createDraft, updateDraft, deleteDraft, sendDraft, sendAs
        case drafts
    }

    public struct ListCall: Sendable, Hashable {
        public var query: String?
        public var labelIds: [String]
        public var pageToken: String?
    }

    public struct FetchCall: Sendable, Hashable {
        public var ids: [String]
        public var format: GmailMessageFormat
    }

    public struct ModifyCall: Sendable, Hashable {
        public var ids: [String]
        public var add: [String]
        public var remove: [String]
    }

    private struct Failure {
        var operation: Operation?
        var error: GmailAPIError
        var remaining: Int
        var skip: Int
    }

    public nonisolated let email: String
    public private(set) var currentHistoryId: Int
    public private(set) var callCounts: [Operation: Int] = [:]
    public private(set) var listCalls: [ListCall] = []
    public private(set) var fetchCalls: [FetchCall] = []
    public private(set) var threadCalls: [FetchCall] = []
    public private(set) var modifyCalls: [ModifyCall] = []
    /// Raw messages passed to send, createDraft and updateDraft.
    public private(set) var sentRaw: [Data] = []
    public private(set) var draftRaw: [Data] = []

    private var latency: Double
    private var historyPageSize: Int
    private var historyRetention: Int?
    private let sleep: @Sendable (Double) async throws -> Void

    private var store: [String: GmailMessage] = [:]
    private var history: [GmailHistory] = []
    /// A startHistoryId below this needs records that are gone.
    private var minimumStartHistoryId = 0
    private var labelList: [GmailLabel]
    private var drafts: [String: String] = [:]
    private var attachmentData: [String: Data] = [:]
    private var failures: [Failure] = []
    private var lostResponses: [Operation: Int] = [:]
    private var rejectsUnknownIds = false
    /// Ids the search index knows while it's stalled; nil when search is current.
    private var indexedIds: Set<String>?
    private var quota: GmailQuota?
    private var quotaClock: (any SyncClock)?
    private var quotaLedger: [(at: Date, units: Int)] = []
    /// Quota units charged for every call, as Gmail would.
    public private(set) var unitsSpent = 0
    /// Calls refused because they would have gone over the per-minute quota.
    public private(set) var quotaViolations = 0
    private var counter = 0
    private var labelCounter = 0

    /// - Parameters:
    ///   - historyRetention: Keep at most this many history records; older start points throw `.historyExpired`.
    ///   - sleep: Used for `latency`; inject an instant sleeper in tests.
    public init(email: String, historyId: Int = 1000, latency: Double = 0, historyPageSize: Int = 100,
                historyRetention: Int? = nil,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.email = email
        self.currentHistoryId = historyId
        self.latency = latency
        self.historyPageSize = historyPageSize
        self.historyRetention = historyRetention
        self.sleep = sleep
        self.labelList = FakeGmail.systemLabels
    }

    private static let systemLabels: [GmailLabel] = [
        "INBOX", "SENT", "DRAFT", "SPAM", "TRASH", "UNREAD", "STARRED", "IMPORTANT", "CHAT",
        "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS",
    ].map { GmailLabel(id: $0, name: $0, type: "system") }

    // MARK: Test controls

    public func setLatency(_ seconds: Double) { latency = seconds }
    public func setHistoryPageSize(_ size: Int) { historyPageSize = size }

    public func setHistoryRetention(_ records: Int?) {
        historyRetention = records
        trimHistory()
    }

    /// Drops all history, as Gmail does after about a week: any older startHistoryId now expires.
    public func expireHistory() {
        history.removeAll()
        minimumStartHistoryId = currentHistoryId
    }

    /// The next `count` calls (to `operation`, or any call) throw `error`, after `after` successful ones.
    public func failNext(_ count: Int = 1, with error: GmailAPIError, on operation: Operation? = nil, after: Int = 0) {
        failures.append(Failure(operation: operation, error: error, remaining: count, skip: after))
    }

    public func clearFailures() {
        failures.removeAll()
        lostResponses.removeAll()
    }

    /// The next `count` calls to `operation` take effect, but the response is lost (`.network`),
    /// like a timeout after Gmail accepted the request.
    public func loseNextResponse(_ count: Int = 1, on operation: Operation) {
        lostResponses[operation, default: 0] += count
    }

    /// batchModify rejects the whole call with `.notFound` when any id doesn't exist.
    public func setRejectsUnknownIds(_ rejects: Bool) { rejectsUnknownIds = rejects }

    /// Enforces the per-user quota on `clock`: a call that would go over it fails with `.rateLimited`
    /// and counts in `quotaViolations`.
    public func enforceQuota(_ quota: GmailQuota, clock: any SyncClock) {
        self.quota = quota
        quotaClock = clock
    }

    /// Search (queries) stops seeing new messages, like Gmail's index lagging behind a send.
    public func stallSearchIndex() { indexedIds = Set(store.keys) }
    public func resumeSearchIndex() { indexedIds = nil }

    public func callCount(_ operation: Operation) -> Int { callCounts[operation] ?? 0 }

    public func resetCallLog() {
        callCounts = [:]
        listCalls = []
        fetchCalls = []
        threadCalls = []
        modifyCalls = []
        unitsSpent = 0
    }

    // MARK: Simulated mail and other clients

    /// New mail arriving (or an existing message, when seeding the account).
    @discardableResult
    public func deliver(_ email: FakeEmail) -> GmailMessage {
        let id = nextId()
        let message = GmailMessage(
            id: id, threadId: email.threadId ?? id, labelIds: email.labels,
            snippet: Self.snippet(text: email.text, html: email.html),
            internalDate: String(Int64((email.date.timeIntervalSince1970 * 1000).rounded())),
            payload: payload(for: email, id: id), sizeEstimate: 0)
        return add(message)
    }

    /// Adds a message with a hand-built payload. `attachments` maps attachmentId to data.
    @discardableResult
    public func insert(_ message: GmailMessage, attachments: [String: Data] = [:]) -> GmailMessage {
        for (attachmentId, data) in attachments { attachmentData["\(message.id)/\(attachmentId)"] = data }
        return add(message)
    }

    /// Another client (the user's phone) changes labels.
    public func remoteModify(_ ids: [String], add: [String] = [], remove: [String] = []) {
        modify(ids, add: add, remove: remove)
    }

    /// Another client archives a whole thread.
    public func remoteArchive(threadId: String) {
        modify(ids(inThread: threadId), add: [], remove: [SystemLabel.inbox])
    }

    /// Permanent deletion (emptying trash, or deletion from another client).
    public func remoteDelete(_ ids: [String]) {
        for id in ids { remove(id) }
    }

    public func message(_ id: String) -> GmailMessage? { store[id] }
    public func labels(of id: String) -> [String]? { store[id]?.labelIds }
    public var allMessageIds: [String] { sortedMessages().map(\.id) }
    public var draftIds: [String] { Array(drafts.keys) }

    public func ids(inThread threadId: String) -> [String] {
        sortedMessages().filter { $0.threadId == threadId }.map(\.id)
    }

    // MARK: GmailAPI

    public func profile() async throws -> GmailProfile {
        try await begin(.profile, units: GmailQuota().profile)
        return GmailProfile(emailAddress: email, messagesTotal: store.count,
                            threadsTotal: Set(store.values.map(\.threadId)).count, historyId: String(currentHistoryId))
    }

    public func labels() async throws -> [GmailLabel] {
        try await begin(.labels, units: GmailQuota().labels)
        return labelList
    }

    public func createLabel(name: String) async throws -> GmailLabel {
        try await begin(.createLabel, units: GmailQuota().changeLabel)
        if labelList.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw GmailAPIError.server(status: 409, message: "Label name exists or conflicts")
        }
        labelCounter += 1
        let label = GmailLabel(id: "Label_\(labelCounter)", name: name, type: "user")
        labelList.append(label)
        return label
    }

    public func deleteLabel(id: String) async throws {
        try await begin(.deleteLabel, units: GmailQuota().changeLabel)
        guard labelList.contains(where: { $0.id == id && $0.type == "user" }) else { throw GmailAPIError.notFound }
        modify(store.values.filter { $0.labelIds?.contains(id) ?? false }.map(\.id), add: [], remove: [id])
        labelList.removeAll { $0.id == id }
    }

    public func messageIds(query: String?, labelIds: [String], pageToken: String?, maxResults: Int) async throws -> GmailIdPage {
        try await begin(.messageIds, units: GmailQuota().list)
        listCalls.append(ListCall(query: query, labelIds: labelIds, pageToken: pageToken))
        let lowerQuery = query?.lowercased() ?? ""
        let includeHidden = labelIds.contains(SystemLabel.trash) || labelIds.contains(SystemLabel.spam)
            || ["in:trash", "in:spam", "in:anywhere"].contains { lowerQuery.contains($0) }
        let required = Set(labelIds)
        var matches = sortedMessages().filter { message in
            let labels = Set(message.labelIds ?? [])
            if !includeHidden, labels.contains(SystemLabel.trash) || labels.contains(SystemLabel.spam) { return false }
            guard required.isSubset(of: labels) else { return false }
            guard let query else { return true }
            if let indexedIds, !indexedIds.contains(message.id) { return false }
            return matchesQuery(query, message)
        }
        let total = matches.count
        if let pageToken {
            // The token marks the last message returned, so pages stay stable while mail arrives.
            let parts = pageToken.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let date = Int64(parts[0]) else {
                throw GmailAPIError.server(status: 400, message: "Invalid pageToken")
            }
            let lastId = String(parts[1])
            matches = matches.filter { message in
                let messageDate = Int64(message.internalDate ?? "0") ?? 0
                return messageDate < date || (messageDate == date && message.id < lastId)
            }
        }
        let page = Array(matches.prefix(max(1, min(maxResults, 500))))
        let next = page.count < matches.count ? page.last.map(cursorToken) : nil
        return GmailIdPage(messages: page.isEmpty ? nil : page.map { GmailMessageRef(id: $0.id, threadId: $0.threadId) },
                           nextPageToken: next, resultSizeEstimate: total)
    }

    public func messages(ids: [String], format: GmailMessageFormat) async throws -> [GmailMessage] {
        try await begin(.messages, units: ids.count * GmailQuota().messageCost(format))
        fetchCalls.append(FetchCall(ids: ids, format: format))
        return ids.compactMap { id in store[id].map { formatted($0, format) } }
    }

    public func threads(ids: [String], format: GmailMessageFormat) async throws -> [GmailThread] {
        try await begin(.threads, units: ids.count * GmailQuota().threadCost(format))
        threadCalls.append(FetchCall(ids: ids, format: format))
        let messages = sortedMessages().reversed()
        return ids.compactMap { id in
            let members = messages.filter { $0.threadId == id }.map { formatted($0, format) }
            guard !members.isEmpty else { return nil }
            return GmailThread(id: id, snippet: members.last?.snippet, historyId: members.compactMap(\.historyId).max(),
                               messages: members)
        }
    }

    public func history(startHistoryId: String, pageToken: String?) async throws -> GmailHistoryPage {
        try await begin(.history, units: GmailQuota().history)
        guard let start = Int(startHistoryId) else { throw GmailAPIError.server(status: 400, message: "Invalid startHistoryId") }
        if start < minimumStartHistoryId { throw GmailAPIError.historyExpired }
        let records = history.filter { Int($0.id)! > start }
        let offset = pageToken.flatMap(Int.init) ?? 0
        let page = Array(records.dropFirst(offset).prefix(historyPageSize))
        let next = offset + page.count < records.count ? String(offset + page.count) : nil
        return GmailHistoryPage(history: page.isEmpty ? nil : page, nextPageToken: next, historyId: String(currentHistoryId))
    }

    public func batchModify(messageIds: [String], add: [String], remove: [String]) async throws {
        try await begin(.batchModify, units: GmailQuota().batchModify)
        modifyCalls.append(ModifyCall(ids: messageIds, add: add, remove: remove))
        guard messageIds.count <= 1000 else { throw GmailAPIError.server(status: 400, message: "Too many ids") }
        let known = Set(labelList.map(\.id))
        if let unknown = (add + remove).first(where: { !known.contains($0) }) {
            throw GmailAPIError.server(status: 400, message: "Invalid label: \(unknown)")
        }
        if rejectsUnknownIds, messageIds.contains(where: { store[$0] == nil }) { throw GmailAPIError.notFound }
        modify(messageIds, add: add, remove: remove)
        try finish(.batchModify)
    }

    public func trashThread(id: String) async throws {
        try await begin(.trashThread, units: GmailQuota().trashThread)
        let ids = ids(inThread: id)
        guard !ids.isEmpty else { throw GmailAPIError.notFound }
        modify(ids, add: [SystemLabel.trash], remove: [SystemLabel.inbox, SystemLabel.spam])
    }

    public func untrashThread(id: String) async throws {
        try await begin(.untrashThread, units: GmailQuota().trashThread)
        let ids = ids(inThread: id)
        guard !ids.isEmpty else { throw GmailAPIError.notFound }
        modify(ids, add: [], remove: [SystemLabel.trash])
    }

    public func attachment(messageId: String, attachmentId: String) async throws -> Data {
        try await begin(.attachment, units: GmailQuota().attachment)
        guard let data = attachmentData["\(messageId)/\(attachmentId)"] else { throw GmailAPIError.notFound }
        return data
    }

    public func send(raw: Data, threadId: String?) async throws -> GmailMessageRef {
        try await begin(.send, units: GmailQuota().send)
        sentRaw.append(raw)
        let message = add(messageFromRaw(raw, threadId: threadId, labels: [SystemLabel.sent]))
        try finish(.send)
        return GmailMessageRef(id: message.id, threadId: message.threadId)
    }

    public func createDraft(raw: Data, threadId: String?) async throws -> GmailDraft {
        try await begin(.createDraft, units: GmailQuota().createDraft)
        draftRaw.append(raw)
        let message = add(messageFromRaw(raw, threadId: threadId, labels: [SystemLabel.draft]))
        let draftId = "r\(nextCounter())"
        drafts[draftId] = message.id
        try finish(.createDraft)
        return GmailDraft(id: draftId, message: GmailMessage(id: message.id, threadId: message.threadId, labelIds: message.labelIds))
    }

    public func updateDraft(id: String, raw: Data, threadId: String?) async throws -> GmailDraft {
        try await begin(.updateDraft, units: GmailQuota().updateDraft)
        guard let old = drafts[id], let previous = store[old] else { throw GmailAPIError.notFound }
        draftRaw.append(raw)
        remove(old)
        let message = add(messageFromRaw(raw, threadId: threadId ?? previous.threadId, labels: [SystemLabel.draft]))
        drafts[id] = message.id
        try finish(.updateDraft)
        return GmailDraft(id: id, message: GmailMessage(id: message.id, threadId: message.threadId, labelIds: message.labelIds))
    }

    public func deleteDraft(id: String) async throws {
        try await begin(.deleteDraft, units: GmailQuota().deleteDraft)
        guard let messageId = drafts.removeValue(forKey: id) else { throw GmailAPIError.notFound }
        remove(messageId)
        try finish(.deleteDraft)
    }

    public func sendDraft(id: String) async throws -> GmailMessageRef {
        try await begin(.sendDraft, units: GmailQuota().send)
        guard let messageId = drafts.removeValue(forKey: id), var message = store[messageId] else { throw GmailAPIError.notFound }
        remove(messageId)
        message.id = nextId()
        message.labelIds = [SystemLabel.sent]
        for (key, data) in attachmentData where key.hasPrefix(messageId + "/") {
            attachmentData[message.id + key.dropFirst(messageId.count)] = data
        }
        let sent = add(message)
        try finish(.sendDraft)
        return GmailMessageRef(id: sent.id, threadId: sent.threadId)
    }

    public func drafts(query: String?, pageToken: String?, maxResults: Int) async throws -> GmailDraftPage {
        try await begin(.drafts, units: GmailQuota().listDrafts)
        let matching = drafts.compactMap { draftId, messageId -> (draftId: String, message: GmailMessage)? in
            guard let message = store[messageId] else { return nil }
            if let query, !query.isEmpty, !matchesQuery(query, message) { return nil }
            return (draftId, message)
        }.sorted { lhs, rhs in
            let left = Int64(lhs.message.internalDate ?? "0") ?? 0, right = Int64(rhs.message.internalDate ?? "0") ?? 0
            return left != right ? left > right : lhs.draftId > rhs.draftId
        }
        let offset = pageToken.flatMap(Int.init) ?? 0
        let page = Array(matching.dropFirst(offset).prefix(max(1, min(maxResults, 500))))
        let next = offset + page.count < matching.count ? String(offset + page.count) : nil
        return GmailDraftPage(
            drafts: page.isEmpty ? nil : page.map {
                GmailDraft(id: $0.draftId, message: GmailMessage(id: $0.message.id, threadId: $0.message.threadId))
            },
            nextPageToken: next, resultSizeEstimate: matching.count)
    }

    public func sendAs() async throws -> [GmailSendAs] {
        try await begin(.sendAs, units: GmailQuota().sendAs)
        return [GmailSendAs(sendAsEmail: email, isPrimary: true, isDefault: true)]
    }

    // MARK: Mutations

    private func begin(_ operation: Operation, units: Int) async throws {
        callCounts[operation, default: 0] += 1
        if latency > 0 { try await sleep(latency) }
        if let quota, let quotaClock {
            let now = quotaClock.now()
            quotaLedger.removeAll { $0.at <= now.addingTimeInterval(-60) }
            let used = quotaLedger.reduce(0) { $0 + $1.units }
            if used + units > quota.unitsPerMinute, used > 0 {
                quotaViolations += 1
                let wait = quotaLedger.first.map { $0.at.addingTimeInterval(60).timeIntervalSince(now) } ?? 60
                throw GmailAPIError.rateLimited(retryAfter: wait)
            }
            quotaLedger.append((now, units))
        }
        unitsSpent += units
        guard let index = failures.firstIndex(where: { $0.operation == nil || $0.operation == operation }) else { return }
        if failures[index].skip > 0 {
            failures[index].skip -= 1
            return
        }
        let error = failures[index].error
        failures[index].remaining -= 1
        if failures[index].remaining <= 0 { failures.remove(at: index) }
        throw error
    }

    private func finish(_ operation: Operation) throws {
        guard let lost = lostResponses[operation], lost > 0 else { return }
        lostResponses[operation] = lost - 1
        throw GmailAPIError.network("The response was lost")
    }

    @discardableResult
    private func add(_ message: GmailMessage) -> GmailMessage {
        var message = message
        let historyId = bumpHistoryId()
        message.historyId = historyId
        if message.sizeEstimate == nil || message.sizeEstimate == 0 { message.sizeEstimate = 512 + (message.snippet?.count ?? 0) }
        store[message.id] = message
        let ref = GmailMessage(id: message.id, threadId: message.threadId, labelIds: message.labelIds)
        record(GmailHistory(id: historyId, messages: [GmailMessageRef(id: message.id, threadId: message.threadId)],
                            messagesAdded: [GmailHistoryMessage(message: ref)]))
        return message
    }

    private func remove(_ id: String) {
        guard let message = store.removeValue(forKey: id) else { return }
        let historyId = bumpHistoryId()
        let ref = GmailMessage(id: message.id, threadId: message.threadId, labelIds: message.labelIds)
        record(GmailHistory(id: historyId, messages: [GmailMessageRef(id: id, threadId: message.threadId)],
                            messagesDeleted: [GmailHistoryMessage(message: ref)]))
    }

    private func modify(_ ids: [String], add: [String], remove: [String]) {
        for id in ids {
            guard var message = store[id] else { continue }
            var labels = message.labelIds ?? []
            let added = add.filter { !labels.contains($0) }
            let removed = remove.filter { labels.contains($0) && !add.contains($0) }
            guard !added.isEmpty || !removed.isEmpty else { continue }
            labels.removeAll { removed.contains($0) }
            labels += added
            let historyId = bumpHistoryId()
            message.labelIds = labels
            message.historyId = historyId
            store[id] = message
            let ref = GmailMessage(id: id, threadId: message.threadId, labelIds: labels)
            record(GmailHistory(
                id: historyId, messages: [GmailMessageRef(id: id, threadId: message.threadId)],
                labelsAdded: added.isEmpty ? nil : [GmailHistoryLabelChange(message: ref, labelIds: added)],
                labelsRemoved: removed.isEmpty ? nil : [GmailHistoryLabelChange(message: ref, labelIds: removed)]))
        }
    }

    private func bumpHistoryId() -> String {
        currentHistoryId += 1
        return String(currentHistoryId)
    }

    private func record(_ entry: GmailHistory) {
        history.append(entry)
        trimHistory()
    }

    private func trimHistory() {
        guard let limit = historyRetention, history.count > limit else { return }
        let dropped = history.prefix(history.count - limit)
        if let last = dropped.last, let id = Int(last.id) { minimumStartHistoryId = id }
        history.removeFirst(dropped.count)
    }

    private func nextCounter() -> Int {
        counter += 1
        return counter
    }

    private func nextId() -> String {
        String(format: "%016llx", UInt64(0x1890_0000_0000_0000) + UInt64(nextCounter()))
    }

    // MARK: Lists and formats

    private func sortedMessages() -> [GmailMessage] {
        store.values.sorted { lhs, rhs in
            let left = Int64(lhs.internalDate ?? "0") ?? 0, right = Int64(rhs.internalDate ?? "0") ?? 0
            return left != right ? left > right : lhs.id > rhs.id
        }
    }

    private func cursorToken(_ message: GmailMessage) -> String { "\(message.internalDate ?? "0"):\(message.id)" }

    private func formatted(_ message: GmailMessage, _ format: GmailMessageFormat) -> GmailMessage {
        var copy = message
        switch format {
        case .full:
            break
        case .metadata:
            copy.payload = message.payload.map {
                GmailMessagePart(partId: "", mimeType: $0.mimeType, filename: "", headers: $0.headers, body: GmailPartBody(size: 0))
            }
        case .minimal:
            copy.payload = nil
        case .raw:
            copy.payload = nil
            copy.raw = MailParsing.base64URLEncode(Data(Self.rawText(message).utf8))
        }
        return copy
    }

    private func matchesQuery(_ query: String, _ message: GmailMessage) -> Bool {
        let labels = Set(message.labelIds ?? [])
        let payload = message.payload
        let text = searchableText(message)
        for token in query.lowercased().split(separator: " ").map(String.init) {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count == 2 ? parts[1] : ""
            switch parts.count == 2 ? parts[0] : "" {
            case "in" where value == "anywhere":
                continue
            case "in", "label":
                let aliases = ["drafts": "DRAFT", "sent": "SENT", "inbox": "INBOX"]
                let wanted = aliases[value]
                    ?? labelList.first { $0.id.lowercased() == value || $0.name.lowercased() == value }?.id ?? value.uppercased()
                if !labels.contains(wanted) { return false }
            case "after", "before":
                guard let seconds = Double(value) else { return false }
                let date = (Double(message.internalDate ?? "0") ?? 0) / 1000
                if parts[0] == "after" ? date <= seconds : date >= seconds { return false }
            case "rfc822msgid":
                let id = payload?.header("Message-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()
                if id != value { return false }
            case "is":
                let wanted = ["unread": SystemLabel.unread, "starred": SystemLabel.starred, "important": SystemLabel.important][value]
                if let wanted, !labels.contains(wanted) { return false }
            case "from":
                if !(payload?.header("From")?.lowercased().contains(value) ?? false) { return false }
            case "to":
                if !(payload?.header("To")?.lowercased().contains(value) ?? false) { return false }
            case "subject":
                if !(payload?.header("Subject")?.lowercased().contains(value) ?? false) { return false }
            case "has" where value == "attachment":
                if !Self.hasFilename(payload) { return false }
            default:
                if !text.contains(token) { return false }
            }
        }
        return true
    }

    private func searchableText(_ message: GmailMessage) -> String {
        var pieces = [message.snippet ?? ""]
        for name in ["Subject", "From", "To"] { pieces.append(message.payload?.header(name) ?? "") }
        func walk(_ part: GmailMessagePart) {
            if let data = part.body?.data.flatMap(MailParsing.base64URLDecode), (part.mimeType ?? "").hasPrefix("text/") {
                pieces.append(String(decoding: data, as: UTF8.self))
            }
            part.parts?.forEach(walk)
        }
        if let payload = message.payload { walk(payload) }
        return pieces.joined(separator: " ").lowercased()
    }

    private static func hasFilename(_ part: GmailMessagePart?) -> Bool {
        guard let part else { return false }
        if !(part.filename ?? "").isEmpty { return true }
        return part.parts?.contains { hasFilename($0) } ?? false
    }

    // MARK: Building payloads

    private func payload(for email: FakeEmail, id: String) -> GmailMessagePart {
        var bodyParts: [GmailMessagePart] = []
        if let text = email.text { bodyParts.append(Self.textPart("text/plain", text)) }
        if let html = email.html { bodyParts.append(Self.textPart("text/html", html)) }
        if bodyParts.isEmpty { bodyParts.append(Self.textPart("text/plain", "")) }
        var body = bodyParts.count == 1 ? bodyParts[0] : Self.multipart("alternative", bodyParts)

        let inline = email.attachments.filter { $0.contentId != nil }
        let regular = email.attachments.filter { $0.contentId == nil }
        if !inline.isEmpty { body = Self.multipart("related", [body] + inline.map { attachmentPart($0, messageId: id) }) }
        var root = regular.isEmpty ? body : Self.multipart("mixed", [body] + regular.map { attachmentPart($0, messageId: id) })

        var headers = [
            GmailHeader(name: "From", value: email.from),
            GmailHeader(name: "To", value: (email.to.isEmpty ? [self.email] : email.to).joined(separator: ", ")),
            GmailHeader(name: "Subject", value: email.subject),
            GmailHeader(name: "Date", value: Self.rfc2822(email.date)),
            GmailHeader(name: "Message-ID", value: "<\(id)@fake.tern>"),
            GmailHeader(name: "MIME-Version", value: "1.0"),
        ]
        if !email.cc.isEmpty { headers.append(GmailHeader(name: "Cc", value: email.cc.joined(separator: ", "))) }
        if let reply = email.inReplyTo {
            headers.append(GmailHeader(name: "In-Reply-To", value: reply))
            headers.append(GmailHeader(name: "References", value: reply))
        }
        root.headers = headers + (root.headers ?? [])
        Self.assignPartIds(&root, id: "")
        return root
    }

    private func attachmentPart(_ attachment: FakeAttachment, messageId: String) -> GmailMessagePart {
        let attachmentId = "ANGjdJ\(nextCounter())"
        attachmentData["\(messageId)/\(attachmentId)"] = attachment.data
        var headers = [
            GmailHeader(name: "Content-Type", value: "\(attachment.mimeType); name=\"\(attachment.filename)\""),
            GmailHeader(name: "Content-Disposition", value: "\(attachment.contentId == nil ? "attachment" : "inline"); filename=\"\(attachment.filename)\""),
            GmailHeader(name: "Content-Transfer-Encoding", value: "base64"),
        ]
        if let cid = attachment.contentId { headers.append(GmailHeader(name: "Content-ID", value: "<\(cid)>")) }
        return GmailMessagePart(mimeType: attachment.mimeType, filename: attachment.filename, headers: headers,
                                body: GmailPartBody(attachmentId: attachmentId, size: attachment.data.count))
    }

    private static func textPart(_ type: String, _ text: String) -> GmailMessagePart {
        let data = Data(text.utf8)
        return GmailMessagePart(mimeType: type, filename: "",
                                headers: [GmailHeader(name: "Content-Type", value: "\(type); charset=\"UTF-8\"")],
                                body: GmailPartBody(size: data.count, data: MailParsing.base64URLEncode(data)))
    }

    private static func multipart(_ subtype: String, _ parts: [GmailMessagePart]) -> GmailMessagePart {
        GmailMessagePart(mimeType: "multipart/\(subtype)", filename: "",
                         headers: [GmailHeader(name: "Content-Type", value: "multipart/\(subtype); boundary=\"b-\(subtype)\"")],
                         body: GmailPartBody(size: 0), parts: parts)
    }

    /// Gmail numbers parts "0", "1", "0.1"…; the root is "".
    private static func assignPartIds(_ part: inout GmailMessagePart, id: String) {
        part.partId = id
        guard var children = part.parts else { return }
        for index in children.indices {
            assignPartIds(&children[index], id: id.isEmpty ? "\(index)" : "\(id).\(index)")
        }
        part.parts = children
    }

    /// Reads an RFC 822 message into a payload: multipart trees, base64 and quoted-printable parts,
    /// attachments (served by `attachment`). Like Gmail, it joins `threadId` only when the message
    /// refers to one of that thread's messages in In-Reply-To or References.
    private func messageFromRaw(_ raw: Data, threadId: String?, labels: [String]) -> GmailMessage {
        let id = nextId()
        var payload = parsePart(raw, messageId: id)
        if payload.header("Message-ID") == nil {
            payload.headers = (payload.headers ?? []) + [GmailHeader(name: "Message-ID", value: "<\(id)@fake.tern>")]
        }
        Self.assignPartIds(&payload, id: "")
        let referenced = Set(Self.messageIds(in: [payload.header("In-Reply-To"), payload.header("References")]
            .compactMap { $0 }.joined(separator: " ")))
        let joined = threadId.flatMap { tid in
            store.values.contains { $0.threadId == tid && $0.payload?.header("Message-ID").map(referenced.contains) == true } ? tid : nil
        }
        let text = Self.text(of: payload, type: "text/plain")
        let html = text == nil ? Self.text(of: payload, type: "text/html") : nil
        return GmailMessage(id: id, threadId: joined ?? id, labelIds: labels, snippet: Self.snippet(text: text, html: html),
                            internalDate: String(Int64(newestDate() * 1000)), payload: payload)
    }

    /// One MIME part and its children. Text parts keep their data inline; files are stored as
    /// attachments of `messageId`.
    private func parsePart(_ data: Data, messageId: String) -> GmailMessagePart {
        let (lines, body) = MultipartReader.headerLinesAndBody(data)
        let headers = lines.compactMap { line -> GmailHeader? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return GmailHeader(name: String(line[..<colon]), value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        func header(_ name: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        let type = MailParsing.parameterizedValue(header("Content-Type") ?? "text/plain; charset=UTF-8")
        let disposition = header("Content-Disposition").map(MailParsing.parameterizedValue)
        if type.value.hasPrefix("multipart/"), let boundary = type.parameters["boundary"],
           let sections = try? MultipartReader.split(body, boundary: boundary) {
            return GmailMessagePart(mimeType: type.value, filename: "", headers: headers, body: GmailPartBody(size: 0),
                                    parts: sections.map { parsePart($0, messageId: messageId) })
        }
        let bytes = Self.decodeTransfer(body, encoding: header("Content-Transfer-Encoding"))
        let filename = disposition?.parameters["filename"] ?? type.parameters["name"] ?? ""
        let mimeType = type.value.isEmpty ? "text/plain" : type.value
        if !filename.isEmpty || disposition?.value == "attachment" || !mimeType.hasPrefix("text/") {
            let attachmentId = "ANGjdJ\(nextCounter())"
            attachmentData["\(messageId)/\(attachmentId)"] = bytes
            return GmailMessagePart(mimeType: mimeType, filename: filename, headers: headers,
                                    body: GmailPartBody(attachmentId: attachmentId, size: bytes.count))
        }
        return GmailMessagePart(mimeType: mimeType, filename: "", headers: headers,
                                body: GmailPartBody(size: bytes.count, data: MailParsing.base64URLEncode(bytes)))
    }

    private static func decodeTransfer(_ body: Data, encoding: String?) -> Data {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            let compact = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: compact) ?? Data()
        case "quoted-printable":
            let text = String(decoding: body, as: UTF8.self)
                .replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
            return Data(MailParsing.quotedPrintableBytes(text[...], underscoreIsSpace: false))
        default:
            return body
        }
    }

    /// The first text part of `type`, decoded.
    private static func text(of part: GmailMessagePart, type: String) -> String? {
        if part.mimeType == type, part.body?.attachmentId == nil, let data = part.body?.data.flatMap(MailParsing.base64URLDecode) {
            return String(decoding: data, as: UTF8.self)
        }
        for child in part.parts ?? [] {
            if let found = text(of: child, type: type) { return found }
        }
        return nil
    }

    /// `<…>` ids in a References or In-Reply-To value.
    private static func messageIds(in value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" || $0 == "," })
            .map(String.init).filter { $0.hasPrefix("<") && $0.hasSuffix(">") }
    }

    /// Now, or just after the newest message when the account's mail is dated in the future.
    private func newestDate() -> Double {
        let latest = store.values.compactMap { Double($0.internalDate ?? "") }.max().map { $0 / 1000 + 1 } ?? 0
        return max(Date().timeIntervalSince1970, latest)
    }

    private static func snippet(text: String?, html: String?) -> String {
        let source = text ?? html.map(MailParsing.plainText(fromHTML:)) ?? ""
        return String(MailParsing.collapseWhitespace(source).prefix(120))
    }

    private static func rfc2822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    private static func rawText(_ message: GmailMessage) -> String {
        let headers = (message.payload?.headers ?? []).map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
        var body = ""
        func walk(_ part: GmailMessagePart) {
            if body.isEmpty, let data = part.body?.data.flatMap(MailParsing.base64URLDecode), (part.mimeType ?? "").hasPrefix("text/") {
                body = String(decoding: data, as: UTF8.self)
            }
            part.parts?.forEach(walk)
        }
        if let payload = message.payload { walk(payload) }
        return headers + "\r\n\r\n" + body
    }
}
