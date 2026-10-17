import Foundation

/// Wall time, sleeping and jitter for token expiry, retries and rate limiting. Tests inject a
/// virtual clock so backoff runs instantly.
public struct GoogleClock: Sendable {
    /// Seconds since 1970.
    public var now: @Sendable () -> TimeInterval
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    /// Uniform in 0..<1, for jitter.
    public var random: @Sendable () -> Double

    public init(now: @escaping @Sendable () -> TimeInterval,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
                random: @escaping @Sendable () -> Double) {
        self.now = now
        self.sleep = sleep
        self.random = random
    }

    public static let live = GoogleClock(
        now: { Date().timeIntervalSince1970 },
        sleep: { seconds in
            guard seconds > 0 else { return }
            try await Task.sleep(for: .seconds(seconds))
        },
        random: { Double.random(in: 0..<1) }
    )
}

/// Exponential backoff with jitter for 429, rate-limit 403s and 5xx.
public struct GmailRetryPolicy: Sendable, Hashable {
    /// Tries per request, the first one included.
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 32) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Delay before retry number `retry` (0 for the first retry). A server-supplied `Retry-After`
    /// wins; otherwise `base · 2^retry`, capped, with "equal jitter" (between half and all of it).
    func delay(retry: Int, retryAfter: TimeInterval?, random: Double) -> TimeInterval {
        if let retryAfter { return max(0, retryAfter) }
        let exponential = min(maxDelay, baseDelay * pow(2, Double(retry)))
        return exponential * (0.5 + 0.5 * random)
    }
}
