import Foundation

/// Gmail quota cost of each call, in quota units, under the model Google applies to Cloud projects
/// created on or after 2026-05-01 (every Tern user's own project).
/// Source: developers.google.com/workspace/gmail/api/reference/quota
enum GmailQuotaCost {
    static let getProfile = 1
    static let labelsList = 1
    static let labelsCreate = 5
    static let labelsDelete = 5
    static let messagesList = 5
    static let messagesBatchModify = 50
    static let messagesSend = 100
    static let attachmentsGet = 20
    static let historyList = 2
    static let threadsTrash = 20
    static let threadsUntrash = 10
    static let draftsCreate = 10
    static let draftsUpdate = 15
    static let draftsDelete = 10
    static let draftsSend = 100
    static let draftsList = 5
    static let sendAsList = 1

    /// messages.get: 20, or 60 with `format=full` or `raw`.
    static func messagesGet(_ format: GmailMessageFormat) -> Int {
        switch format {
        case .minimal, .metadata: 20
        case .full, .raw: 60
        }
    }

    /// threads.get: 40, or 120 with `format=full`.
    static func threadsGet(_ format: GmailMessageFormat) -> Int {
        switch format {
        case .minimal, .metadata: 40
        case .full, .raw: 120
        }
    }
}

/// Token bucket in Gmail quota units, one per account: a safety net under the sync engine.
///
/// The engine's `QuotaBudget` is the real scheduler: it keeps each account inside Gmail's per-user
/// quota (6,000 units a minute for projects created since 2026-05-01) and decides what goes first.
/// This bucket only catches traffic that bypasses it, so it refills at the full per-minute rate and
/// holds `burst` units (default: half a minute, room for the engine's first-sync burst plus its
/// largest interactive request), and budgeted traffic passes without waiting. Callers reserve units up front and wait for the refill,
/// so concurrent callers are served in arrival order. After a rate-limit response, `pause(for:)`
/// holds everyone back.
public actor GmailRateLimiter {
    private let unitsPerSecond: Double
    private let capacity: Double
    private let clock: GoogleClock
    private var tokens: Double
    private var lastRefill: TimeInterval
    private var blockedUntil: TimeInterval = 0

    /// - Parameters:
    ///   - unitsPerMinute: The refill rate.
    ///   - burst: Units the bucket holds; nil for half of `unitsPerMinute`.
    public init(unitsPerMinute: Double = 6000, burst: Double? = nil, clock: GoogleClock = .live) {
        self.unitsPerSecond = unitsPerMinute / 60
        self.capacity = max(1, burst ?? unitsPerMinute / 2)
        self.clock = clock
        self.tokens = capacity
        self.lastRefill = clock.now()
    }

    /// Seconds a caller asking for `units` now would wait (0 when they're available).
    public func delay(for units: Int) -> TimeInterval {
        let now = clock.now()
        refill(now)
        let debt = Double(units) - tokens
        return max(blockedUntil - now, debt > 0 ? debt / unitsPerSecond : 0, 0)
    }

    /// Waits until `units` may be spent. A pause that starts while a caller waits holds it too.
    public func acquire(_ units: Int) async throws {
        let start = clock.now()
        refill(start)
        tokens -= Double(units)
        let ready = start + (tokens < 0 ? -tokens / unitsPerSecond : 0)
        do {
            while true {
                let wait = max(ready, blockedUntil) - clock.now()
                guard wait > 0 else { return }
                try await clock.sleep(wait)
            }
        } catch {
            tokens += Double(units)
            throw error
        }
    }

    /// Stops every caller for `seconds` (after a 429 or a rate-limit 403).
    public func pause(for seconds: TimeInterval) {
        blockedUntil = max(blockedUntil, clock.now() + seconds)
    }

    private func refill(_ now: TimeInterval) {
        let elapsed = max(0, now - lastRefill)
        lastRefill = now
        tokens = min(capacity, tokens + elapsed * unitsPerSecond)
    }
}
