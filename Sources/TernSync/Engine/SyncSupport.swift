import Foundation
import Observation
import TernCore

/// Time for the sync engine. Tests inject a clock whose sleeps return at once.
public protocol SyncClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemSyncClock: SyncClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(max(0, seconds)))
    }
}

/// Tunables for the sync engine. Defaults suit the real Gmail API and its per-user quota.
public struct SyncConfiguration: Sendable {
    /// History poll interval while the app is frontmost.
    public var activePollInterval: Double = 5
    /// History poll interval while the app is in the background.
    public var inactivePollInterval: Double = 60
    /// How often snoozed threads are checked.
    public var snoozeCheckInterval: Double = 30
    /// How often the label list is refreshed during live sync.
    public var labelRefreshInterval: Double = 600
    /// How often send-as settings (signatures, sender names) are read again, and daily upkeep
    /// (needs-reply expiry) runs.
    public var dailyInterval: Double = 86_400

    /// Quota costs and the per-user limit (per account; accounts sync in parallel).
    public var quota = GmailQuota()
    /// Units per minute bulk work (initial inbox and recent mail) leaves for live sync and actions.
    public var bulkReserve: Int = 600
    /// Units per minute background work (older mail, body trickle) leaves for everything else.
    public var backgroundReserve: Int = 1_500
    /// Bulk and background spending is smoothed over this many seconds: in any such window they
    /// spend at most their per-minute share for that long (540 and 450 units by default), so they
    /// never burst and interactive calls don't queue behind them in the HTTP client's limiter.
    public var paceWindow: Double = 6
    /// Most units one bulk step may spend before the loop checks for polls and actions again.
    /// Half a pace window: two steps use the whole share, and one runs even after an opened thread.
    public var bulkStepUnits: Int = 270

    /// Initial sync fetches this many days of All Mail in full, after the inbox.
    public var recentDays: Int = 30
    /// At most this many of the newest inbox messages come in full in the initial sync (an inbox of
    /// 50,000 would otherwise take hours of quota); older ones arrive with the backfill.
    public var initialInboxLimit: Int = 500
    /// At most this many of the newest recent messages come in full in the initial sync.
    public var initialRecentLimit: Int = 1_000
    /// Threads with at least this many messages to fetch come from one threads.get (120 units)
    /// instead of one messages.get each (60 units).
    public var threadFetchMinimum: Int = 3
    /// messages.list page size (Gmail allows up to 500).
    public var listPageSize: Int = 500
    /// Most ids per messages.get / threads.get call.
    public var fetchBatchSize: Int = 100
    /// Most quota units one call may cost, so no single request outgrows the budget's headroom
    /// (16 full messages, 50 metadata, 8 full threads).
    public var maxUnitsPerRequest: Int = 1_000
    /// The same for bulk and background calls (4 full messages, 12 metadata, 2 full threads), so
    /// with pacing they never take more than a sliver of the HTTP client's limiter and an
    /// interactive call doesn't wait there behind them.
    public var backgroundMaxUnitsPerRequest: Int = 240
    /// Messages per write transaction, so the UI fills in progressively.
    public var writeBatchSize: Int = 250
    /// Older mail is backfilled as metadata (20 units each), this many per background step.
    public var backfillBatchSize: Int = 10
    /// New mail per history poll fetched in full (30 × 60 units); beyond it, metadata, with bodies
    /// on demand. Also caps full fetches of new inbox mail in a resync and of server-search results.
    public var historyFullFetchLimit: Int = 30
    /// After history expires, stored Trash and Spam (up to this many) have their labels read back
    /// (20 units each); beyond it they're just moved to Trash or Spam locally.
    public var resyncHiddenRefreshLimit: Int = 200
    /// Rate of the background body trickle for mail stored without a body.
    public var trickleUnitsPerMinute: Int = 1_200
    /// Messages per trickle batch.
    public var prefetchBatchSize: Int = 5
    /// Threads next to the selection whose bodies are prefetched.
    public var adjacentPrefetchLimit: Int = 4

    /// Most ids per batchModify call (Gmail's limit is 1000).
    public var maxBatchModifyIds: Int = 1000
    /// A queued action is marked failed after this many attempts.
    public var maxOpAttempts: Int = 8
    /// First retry delay for a failed op or request; doubles each attempt.
    public var retryBaseDelay: Double = 2
    public var retryMaxDelay: Double = 300
    /// Retries for a read request (5xx, network) before the sync step gives up for now.
    public var maxRequestRetries: Int = 5
    /// Where downloaded attachments are cached: `<dir>/<account>/<message>/<filename>`.
    public var attachmentCacheDirectory: URL = SyncConfiguration.defaultAttachmentDirectory
    /// `DraftStore.filesDirectory`: forwarded attachments are downloaded into a draft's folder
    /// before it's sent, and the folder is removed once it has been.
    public var draftFilesDirectory: URL = DraftStore.defaultFilesDirectory
    /// Wake snoozed threads and sync when the Mac wakes from sleep.
    public var observeSystemWake: Bool = true

    public init() {}

    /// ~/Library/Caches/Tern/attachments
    public static var defaultAttachmentDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tern", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
    }
}

/// One account's sync progress, as a value. `SyncStatus` is the observable form the UI reads.
public struct SyncStatusSnapshot: Sendable, Hashable {
    public var accountId: String
    /// `.new` until the inbox and recent mail are in; `.backfilling` while older mail arrives in
    /// the background (the account is usable); `.live` when everything is in.
    public var state: SyncState
    /// The foreground step, e.g. "Fetching inbox" or "Up to date".
    public var phase: String
    /// Progress of the foreground step.
    public var fetched: Int
    public var total: Int?
    /// What happens in the background, e.g. "Older mail syncing in the background". Nil when idle.
    public var background: String?
    /// Messages stored for the account, and how many Gmail has, while older mail backfills.
    public var backfillFetched: Int
    public var backfillTotal: Int?
    /// Set while Gmail has asked Tern to slow down; sync resumes at this time.
    public var rateLimitedUntil: Date?
    /// Quota units spent in the last minute, out of the per-user limit.
    public var quotaUsed: Int
    public var lastSyncAt: Date?
    public var lastError: String?

    public init(accountId: String, state: SyncState = .new, phase: String = "", fetched: Int = 0, total: Int? = nil,
                background: String? = nil, backfillFetched: Int = 0, backfillTotal: Int? = nil,
                rateLimitedUntil: Date? = nil, quotaUsed: Int = 0, lastSyncAt: Date? = nil, lastError: String? = nil) {
        self.accountId = accountId
        self.state = state
        self.phase = phase
        self.fetched = fetched
        self.total = total
        self.background = background
        self.backfillFetched = backfillFetched
        self.backfillTotal = backfillTotal
        self.rateLimitedUntil = rateLimitedUntil
        self.quotaUsed = quotaUsed
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
    }
}

/// Live sync status for one account, updated on the main actor.
@MainActor
@Observable
public final class SyncStatus: Identifiable {
    public nonisolated let accountId: String
    public nonisolated var id: String { accountId }
    public private(set) var state: SyncState = .new
    public private(set) var phase: String = ""
    public private(set) var fetched: Int = 0
    /// Expected total for the current phase, when known.
    public private(set) var total: Int?
    /// E.g. "Older mail syncing in the background"; nil when nothing runs in the background.
    public private(set) var background: String?
    public private(set) var backfillFetched: Int = 0
    public private(set) var backfillTotal: Int?
    /// Gmail asked to slow down; nothing syncs for this account until then.
    public private(set) var rateLimitedUntil: Date?
    /// Quota units used in the last minute (the limit is `quotaLimit`).
    public private(set) var quotaUsed: Int = 0
    public let quotaLimit: Int
    public private(set) var lastSyncAt: Date?
    public private(set) var lastError: String?
    /// Actions waiting to reach Gmail (pending or sending).
    public internal(set) var pendingOps: Int = 0
    /// Actions Gmail rejected for good; their local change was rolled back.
    public internal(set) var failedOps: Int = 0

    public init(accountId: String, quotaLimit: Int = GmailQuota().unitsPerMinute) {
        self.accountId = accountId
        self.quotaLimit = quotaLimit
    }

    /// Fraction done of the foreground step, when the total is known.
    public var progress: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(fetched) / Double(total))
    }

    /// Fraction of older mail in, while it backfills.
    public var backfillProgress: Double? {
        guard let backfillTotal, backfillTotal > 0 else { return nil }
        return min(1, Double(backfillFetched) / Double(backfillTotal))
    }

    func apply(_ snapshot: SyncStatusSnapshot) {
        if state != snapshot.state { state = snapshot.state }
        if phase != snapshot.phase { phase = snapshot.phase }
        if fetched != snapshot.fetched { fetched = snapshot.fetched }
        if total != snapshot.total { total = snapshot.total }
        if background != snapshot.background { background = snapshot.background }
        if backfillFetched != snapshot.backfillFetched { backfillFetched = snapshot.backfillFetched }
        if backfillTotal != snapshot.backfillTotal { backfillTotal = snapshot.backfillTotal }
        if rateLimitedUntil != snapshot.rateLimitedUntil { rateLimitedUntil = snapshot.rateLimitedUntil }
        if quotaUsed != snapshot.quotaUsed { quotaUsed = snapshot.quotaUsed }
        if lastSyncAt != snapshot.lastSyncAt { lastSyncAt = snapshot.lastSyncAt }
        if lastError != snapshot.lastError { lastError = snapshot.lastError }
    }
}

extension Array {
    /// Consecutive slices of at most `size` elements.
    func syncChunks(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
