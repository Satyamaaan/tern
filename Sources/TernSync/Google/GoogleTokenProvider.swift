import Foundation

/// Hands out access tokens for one account. `GmailHTTPClient` calls it before every request.
public protocol GmailAccessTokenSource: Sendable {
    /// A token that is valid for at least a minute. Throws `GmailAPIError.unauthorized` when the
    /// account must sign in again.
    func accessToken() async throws -> String
    /// Marks `token` as rejected (the API answered 401) so the next call refreshes. A no-op when a
    /// newer token is already cached.
    func invalidate(_ token: String) async
}

/// Caches one account's access token, refreshes it about a minute before it expires, and lets
/// concurrent callers share a single refresh.
public actor GoogleTokenProvider: GmailAccessTokenSource {
    public typealias Refresh = @Sendable () async throws -> GoogleAccessToken

    private let refresher: Refresh
    private let clock: GoogleClock
    private let earlyRefresh: TimeInterval
    private var cached: GoogleAccessToken?
    private var refreshing: Task<GoogleAccessToken, Error>?

    public init(clock: GoogleClock = .live, earlyRefresh: TimeInterval = 60, refresh: @escaping Refresh) {
        self.refresher = refresh
        self.clock = clock
        self.earlyRefresh = earlyRefresh
    }

    /// Reads the account's refresh token from `secrets` at each refresh, so signing out takes effect
    /// at once.
    public init(email: String, auth: GoogleAuth, secrets: any SecretStore, clock: GoogleClock = .live) {
        let account = email.lowercased()
        self.init(clock: clock) {
            let stored = try? secrets.data(service: GoogleKeychain.tokenService, account: account)
            guard let stored, let refreshToken = String(data: stored, encoding: .utf8), !refreshToken.isEmpty else {
                throw GmailAPIError.unauthorized
            }
            return try await auth.refresh(refreshToken: refreshToken)
        }
    }

    public func accessToken() async throws -> String {
        if let cached, cached.expiresAt - earlyRefresh > clock.now() { return cached.value }
        let task: Task<GoogleAccessToken, Error>
        if let refreshing {
            task = refreshing
        } else {
            let refresher = refresher
            task = Task { try await refresher() }
            refreshing = task
        }
        do {
            let token = try await task.value
            if refreshing == task { refreshing = nil }
            cached = token
            return token.value
        } catch {
            if refreshing == task { refreshing = nil }
            throw Self.map(error)
        }
    }

    public func invalidate(_ token: String) {
        if cached?.value == token { cached = nil }
    }

    /// Starts with a token from sign-in so the first request does not refresh.
    public func seed(_ token: GoogleAccessToken) {
        cached = token
    }

    static func map(_ error: Error) -> Error {
        switch error {
        case GoogleAuthError.invalidGrant:
            return GmailAPIError.unauthorized
        case GoogleAuthError.oauth(let code, let description):
            // A deleted or mistyped OAuth client also means the user has to act.
            if ["invalid_client", "unauthorized_client", "deleted_client"].contains(code) { return GmailAPIError.unauthorized }
            return GmailAPIError.server(status: 400, message: description ?? code)
        case GoogleAuthError.network(let message):
            return GmailAPIError.network(message)
        case GoogleAuthError.invalidResponse(let message):
            return GmailAPIError.server(status: 0, message: message)
        default:
            return error
        }
    }
}
