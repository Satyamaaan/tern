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

/// Tunables for the sync engine. Defaults suit the real Gmail API.
public struct SyncConfiguration: Sendable {
    /// History poll interval while the app is frontmost.
    public var activePollInterval: Double = 5
    /// History poll interval while the app is in the background.
    public var inactivePollInterval: Double = 60
    /// How often snoozed threads are checked.
    public var snoozeCheckInterval: Double = 30
    /// How often the label list is refreshed during live sync.
    public var labelRefreshInterval: Double = 600
    /// messages.list page size (Gmail allows up to 500).
    public var listPageSize: Int = 500
    /// Ids per messages.get batch.
    public var fetchBatchSize: Int = 100
    /// Messages per write transaction, so the UI fills in progressively.
    public var writeBatchSize: Int = 250
    /// Newest messages of All Mail fetched before the backfill starts.
    public var recentCount: Int = 500
    /// Format for backfilled older mail. `.metadata` is faster; bodies then arrive by background prefetch.
    public var backfillFormat: GmailMessageFormat = .full
    /// Messages per background body prefetch batch.
    public var prefetchBatchSize: Int = 50
    /// Most ids per batchModify call (Gmail's limit is 1000).
    public var maxBatchModifyIds: Int = 1000
    /// A queued action is marked failed after this many attempts.
    public var maxOpAttempts: Int = 8
    /// First retry delay for a failed op or request; doubles each attempt.
    public var retryBaseDelay: Double = 2
    public var retryMaxDelay: Double = 300
    /// Retries for a read request (rate limits, 5xx, network) before the sync step gives up for now.
    public var maxRequestRetries: Int = 5
    /// Where downloaded attachments are cached: `<dir>/<account>/<message>/<filename>`.
    public var attachmentCacheDirectory: URL = SyncConfiguration.defaultAttachmentDirectory
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
    public var state: SyncState
    /// Short human-readable step, e.g. "Fetching inbox".
    public var phase: String
    public var fetched: Int
    public var total: Int?
    public var lastSyncAt: Date?
    public var lastError: String?

    public init(accountId: String, state: SyncState = .new, phase: String = "", fetched: Int = 0, total: Int? = nil,
                lastSyncAt: Date? = nil, lastError: String? = nil) {
        self.accountId = accountId
        self.state = state
        self.phase = phase
        self.fetched = fetched
        self.total = total
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
    public private(set) var lastSyncAt: Date?
    public private(set) var lastError: String?
    /// Actions waiting to reach Gmail (pending or sending).
    public internal(set) var pendingOps: Int = 0
    /// Actions Gmail rejected for good; their local change was rolled back.
    public internal(set) var failedOps: Int = 0

    public init(accountId: String) {
        self.accountId = accountId
    }

    /// Fraction done for a progress bar, when the total is known.
    public var progress: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(fetched) / Double(total))
    }

    func apply(_ snapshot: SyncStatusSnapshot) {
        if state != snapshot.state { state = snapshot.state }
        if phase != snapshot.phase { phase = snapshot.phase }
        if fetched != snapshot.fetched { fetched = snapshot.fetched }
        if total != snapshot.total { total = snapshot.total }
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
