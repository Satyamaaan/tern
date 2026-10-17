import Foundation

/// Gmail quota cost of each call, in quota units, under the model Google applies to Cloud projects
/// created on or after 2026-05-01 (every Tern user's own project).
/// Source: developers.google.com/workspace/gmail/api/reference/quota
enum GmailQuota {
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
    static let sendAsList = 1

    /// messages.get: 20, or 60 with `format=full` or `raw`.
    static func messagesGet(_ format: GmailMessageFormat) -> Int {
        switch format {
        case .minimal, .metadata: 20
        case .full, .raw: 60
        }
    }
}

/// Token bucket in Gmail quota units, one per account.
///
/// Gmail allows each user 6,000 units a minute per Cloud project (15,000 for projects that used the
/// API before 2026-05-01). The bucket refills at 80% of that and holds 10%, so even a full bucket
/// plus a minute of refill stays under the limit, leaving room for retries and the user's other
/// clients. Callers reserve units up front and wait for the refill, so concurrent callers are served
/// in arrival order and a request costing more than the bucket simply waits longer. After a
/// rate-limit response, `pause(for:)` holds everyone back.
public actor GmailRateLimiter {
    private let unitsPerSecond: Double
    private let capacity: Double
    private let clock: GoogleClock
    private var tokens: Double
    private var lastRefill: TimeInterval
    private var blockedUntil: TimeInterval = 0

    public init(unitsPerMinute: Double = 6000, clock: GoogleClock = .live) {
        self.unitsPerSecond = unitsPerMinute * 0.8 / 60
        self.capacity = unitsPerMinute * 0.1
        self.clock = clock
        self.tokens = capacity
        self.lastRefill = clock.now()
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
