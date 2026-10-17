import Foundation

/// Gmail API quota costs and the per-user limit. Every Tern user brings their own Cloud project;
/// projects created since 2026-05-01 get 6,000 units per user per minute.
public struct GmailQuota: Sendable, Hashable {
    public var unitsPerMinute = 6_000
    public var getMessage = 20
    /// messages.get with format full or raw.
    public var getMessageFull = 60
    public var getThread = 40
    /// threads.get with format full.
    public var getThreadFull = 120
    public var list = 5
    public var history = 2
    public var batchModify = 50
    public var send = 100
    public var createDraft = 10
    public var updateDraft = 15
    public var deleteDraft = 10
    public var listDrafts = 5
    public var profile = 1
    public var labels = 1
    public var changeLabel = 5
    public var attachment = 20
    public var trashThread = 20
    public var sendAs = 1

    public init() {}

    public func messageCost(_ format: GmailMessageFormat) -> Int {
        format == .full || format == .raw ? getMessageFull : getMessage
    }

    public func threadCost(_ format: GmailMessageFormat) -> Int {
        format == .full || format == .raw ? getThreadFull : getThread
    }
}

/// Who is asking for quota. Live sync and user actions always come first; background work only
/// gets what they leave over.
public enum QuotaPriority: Int, Sendable, Comparable {
    /// Older-mail backfill and the body trickle.
    case background
    /// Initial inbox and recent mail, full resync, prefetch of adjacent threads.
    case bulk
    /// History polls, queued actions, sends, bodies of the thread being opened.
    case interactive

    public static func < (lhs: QuotaPriority, rhs: QuotaPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The priority calls made by the current task are charged at.
    @TaskLocal public static var current: QuotaPriority = .interactive
}

/// One account's quota: units spent in a rolling one-minute window. Interactive calls may use the
/// whole minute; bulk and background calls stop short of it, keeping a reserve free so a poll, an
/// action or an opened thread never waits behind a backfill. After Gmail rate limits the account,
/// every call fails fast with `.rateLimited` until the pause ends.
public actor QuotaBudget {
    public nonisolated let unitsPerMinute: Int
    private let reserves: [QuotaPriority: Int]
    private let clock: any SyncClock
    private var spent: [(at: Date, units: Int)] = []
    public private(set) var pausedUntil: Date?
    /// Every unit charged since the budget was created.
    public private(set) var totalUnits = 0

    public init(unitsPerMinute: Int, bulkReserve: Int, backgroundReserve: Int, clock: any SyncClock) {
        self.unitsPerMinute = unitsPerMinute
        self.reserves = [.interactive: 0, .bulk: bulkReserve, .background: max(bulkReserve, backgroundReserve)]
        self.clock = clock
    }

    /// Waits until `units` fit in the window for `priority`, then charges them.
    public func acquire(_ units: Int, priority: QuotaPriority) async throws {
        while true {
            try Task.checkCancellation()
            let now = clock.now()
            if let until = pausedUntil, until > now {
                throw GmailAPIError.rateLimited(retryAfter: until.timeIntervalSince(now))
            }
            let wait = delay(for: units, priority: priority, now: now)
            if wait <= 0 {
                spent.append((now, units))
                totalUnits += units
                return
            }
            try await clock.sleep(seconds: wait)
        }
    }

    /// Seconds until `units` would fit for `priority` (0 when they fit now).
    public func delay(for units: Int, priority: QuotaPriority) -> Double {
        let now = clock.now()
        if let until = pausedUntil, until > now { return until.timeIntervalSince(now) }
        return delay(for: units, priority: priority, now: now)
    }

    /// Gives back units charged for a request that never reached Gmail.
    public func refund(_ units: Int) {
        if let index = spent.lastIndex(where: { $0.units == units }) {
            spent.remove(at: index)
            totalUnits -= units
        }
    }

    /// Stops all calls for the account (Gmail asked to wait, or its retries ran out).
    public func pause(seconds: Double) {
        let until = clock.now().addingTimeInterval(max(1, seconds))
        pausedUntil = max(pausedUntil ?? until, until)
    }

    /// Units charged in the last minute.
    public var unitsLastMinute: Int {
        let now = clock.now()
        prune(now)
        return spent.reduce(0) { $0 + $1.units }
    }

    private func delay(for units: Int, priority: QuotaPriority, now: Date) -> Double {
        prune(now)
        let ceiling = unitsPerMinute - (reserves[priority] ?? 0)
        var used = spent.reduce(0) { $0 + $1.units }
        // A request bigger than the ceiling still runs once the window is empty.
        if used + units <= ceiling || used == 0 { return 0 }
        for entry in spent {
            used -= entry.units
            if used + units <= ceiling || used == 0 { return entry.at.addingTimeInterval(60).timeIntervalSince(now) }
        }
        return 60
    }

    private func prune(_ now: Date) {
        let cutoff = now.addingTimeInterval(-60)
        if let index = spent.firstIndex(where: { $0.at > cutoff }) {
            spent.removeFirst(index)
        } else {
            spent.removeAll()
        }
    }
}

/// Charges every call to the account's `QuotaBudget` at `QuotaPriority.current` before making it,
/// and pauses the budget when Gmail answers `.rateLimited`.
struct BudgetedGmail: GmailAPI {
    let base: any GmailAPI
    let budget: QuotaBudget
    let quota: GmailQuota

    private func charge<T>(_ units: Int, _ call: () async throws -> T) async throws -> T {
        try await budget.acquire(units, priority: QuotaPriority.current)
        do {
            return try await call()
        } catch GmailAPIError.rateLimited(let retryAfter) {
            await budget.pause(seconds: retryAfter ?? 60)
            throw GmailAPIError.rateLimited(retryAfter: retryAfter)
        }
    }

    func profile() async throws -> GmailProfile { try await charge(quota.profile) { try await base.profile() } }
    func labels() async throws -> [GmailLabel] { try await charge(quota.labels) { try await base.labels() } }

    func createLabel(name: String) async throws -> GmailLabel {
        try await charge(quota.changeLabel) { try await base.createLabel(name: name) }
    }

    func deleteLabel(id: String) async throws {
        try await charge(quota.changeLabel) { try await base.deleteLabel(id: id) }
    }

    func messageIds(query: String?, labelIds: [String], pageToken: String?, maxResults: Int) async throws -> GmailIdPage {
        try await charge(quota.list) {
            try await base.messageIds(query: query, labelIds: labelIds, pageToken: pageToken, maxResults: maxResults)
        }
    }

    func messages(ids: [String], format: GmailMessageFormat) async throws -> [GmailMessage] {
        guard !ids.isEmpty else { return [] }
        return try await charge(ids.count * quota.messageCost(format)) { try await base.messages(ids: ids, format: format) }
    }

    func threads(ids: [String], format: GmailMessageFormat) async throws -> [GmailThread] {
        guard !ids.isEmpty else { return [] }
        let units = ids.count * quota.threadCost(format)
        do {
            return try await charge(units) { try await base.threads(ids: ids, format: format) }
        } catch GmailAPIError.server(501, GmailThread.unsupported) {
            // The client has no threads.get; nothing reached Gmail.
            await budget.refund(units)
            throw GmailAPIError.server(status: 501, message: GmailThread.unsupported)
        }
    }

    func history(startHistoryId: String, pageToken: String?) async throws -> GmailHistoryPage {
        try await charge(quota.history) { try await base.history(startHistoryId: startHistoryId, pageToken: pageToken) }
    }

    func batchModify(messageIds: [String], add: [String], remove: [String]) async throws {
        try await charge(quota.batchModify) { try await base.batchModify(messageIds: messageIds, add: add, remove: remove) }
    }

    func trashThread(id: String) async throws { try await charge(quota.trashThread) { try await base.trashThread(id: id) } }
    func untrashThread(id: String) async throws { try await charge(quota.trashThread) { try await base.untrashThread(id: id) } }

    func attachment(messageId: String, attachmentId: String) async throws -> Data {
        try await charge(quota.attachment) { try await base.attachment(messageId: messageId, attachmentId: attachmentId) }
    }

    func send(raw: Data, threadId: String?) async throws -> GmailMessageRef {
        try await charge(quota.send) { try await base.send(raw: raw, threadId: threadId) }
    }

    func createDraft(raw: Data, threadId: String?) async throws -> GmailDraft {
        try await charge(quota.createDraft) { try await base.createDraft(raw: raw, threadId: threadId) }
    }

    func updateDraft(id: String, raw: Data, threadId: String?) async throws -> GmailDraft {
        try await charge(quota.updateDraft) { try await base.updateDraft(id: id, raw: raw, threadId: threadId) }
    }

    func deleteDraft(id: String) async throws { try await charge(quota.deleteDraft) { try await base.deleteDraft(id: id) } }

    func sendDraft(id: String) async throws -> GmailMessageRef {
        try await charge(quota.send) { try await base.sendDraft(id: id) }
    }

    func drafts(query: String?, pageToken: String?, maxResults: Int) async throws -> GmailDraftPage {
        do {
            return try await charge(quota.listDrafts) {
                try await base.drafts(query: query, pageToken: pageToken, maxResults: maxResults)
            }
        } catch GmailAPIError.server(501, GmailDraftPage.unsupported) {
            await budget.refund(quota.listDrafts)
            throw GmailAPIError.server(status: 501, message: GmailDraftPage.unsupported)
        }
    }

    func sendAs() async throws -> [GmailSendAs] { try await charge(quota.sendAs) { try await base.sendAs() } }
}
