import Foundation
import Synchronization

/// What the app calls for Google accounts: connect, get an account's `GmailAPI`, sign out.
/// Refresh tokens live in the Keychain (service `dev.tern.mail.google`, account = lowercased email);
/// access tokens only in memory. Clients are cached, so every caller for an account shares one
/// token cache and one rate limiter.
public final class GoogleAccounts: Sendable {
    public let auth: GoogleAuth
    private let secrets: any SecretStore
    private let session: URLSession
    private let endpoints: GoogleEndpoints
    private let clock: GoogleClock
    private let options: GmailHTTPClient.Options
    private let unitsPerMinute: Double
    private let clients = Mutex<[String: Account]>([:])

    private struct Account {
        var tokens: GoogleTokenProvider
        var client: GmailHTTPClient
    }

    /// - Parameter unitsPerMinute: the per-user Gmail quota of the user's Cloud project. 6,000 for
    ///   projects created on or after 2026-05-01, 15,000 for older ones.
    public init(config: GoogleClientConfig, secrets: any SecretStore = KeychainSecretStore(),
                session: URLSession = .shared, endpoints: GoogleEndpoints = .google, clock: GoogleClock = .live,
                signInTimeout: TimeInterval = 300, unitsPerMinute: Double = 6000,
                options: GmailHTTPClient.Options = GmailHTTPClient.Options()) {
        self.auth = GoogleAuth(config: config, endpoints: endpoints, session: session, clock: clock, timeout: signInTimeout)
        self.secrets = secrets
        self.session = session
        self.endpoints = endpoints
        self.clock = clock
        self.options = options
        self.unitsPerMinute = unitsPerMinute
    }

    /// Uses the OAuth client saved in the Keychain; nil until the user has entered one.
    public convenience init?(secrets: any SecretStore = KeychainSecretStore()) throws {
        guard let config = try GoogleClientConfigStore(secrets: secrets).load() else { return nil }
        self.init(config: config, secrets: secrets)
    }

    /// Signs in a Google account in the browser and saves its refresh token. Connecting an account
    /// that is already connected replaces its token.
    /// - Parameters:
    ///   - loginHint: an email to preselect, e.g. when an account needs to sign in again.
    ///   - openURL: opens the consent page, e.g. `{ NSWorkspace.shared.open($0) }`.
    public func connect(loginHint: String? = nil,
                        openURL: @escaping @Sendable (URL) -> Void) async throws -> GoogleAccountInfo {
        let result = try await auth.signIn(loginHint: loginHint, openURL: openURL)
        let email = result.account.email.lowercased()
        try secrets.set(Data(result.refreshToken.utf8), service: GoogleKeychain.tokenService, account: email)
        await account(for: email).tokens.seed(result.accessToken)
        return result.account
    }

    /// Cancels a `connect` that is waiting for the browser.
    public func cancelConnect() async {
        await auth.cancelSignIn()
    }

    /// The Gmail API for a connected account. Calls throw `GmailAPIError.unauthorized` once the
    /// account has no working refresh token.
    public func api(for email: String) -> any GmailAPI {
        account(for: email.lowercased()).client
    }

    /// Whether a refresh token is stored for `email`. It may still have been revoked.
    public func hasCredentials(for email: String) -> Bool {
        (try? secrets.data(service: GoogleKeychain.tokenService, account: email.lowercased())) != nil
    }

    /// Lowercased emails with a stored refresh token.
    public func connectedEmails() -> [String] {
        (try? secrets.accounts(service: GoogleKeychain.tokenService)) ?? []
    }

    /// Revokes the account's token at Google (best effort) and deletes it from the Keychain.
    public func signOut(_ email: String) async {
        let account = email.lowercased()
        if let data = try? secrets.data(service: GoogleKeychain.tokenService, account: account),
           let token = String(data: data, encoding: .utf8) {
            await auth.revoke(token)
        }
        try? secrets.remove(service: GoogleKeychain.tokenService, account: account)
        clients.withLock { _ = $0.removeValue(forKey: account) }
    }

    private func account(for email: String) -> Account {
        clients.withLock { clients in
            if let existing = clients[email] { return existing }
            let tokens = GoogleTokenProvider(email: email, auth: auth, secrets: secrets, clock: clock)
            let client = GmailHTTPClient(tokens: tokens, session: session,
                                         rateLimiter: GmailRateLimiter(unitsPerMinute: unitsPerMinute, clock: clock),
                                         endpoints: endpoints, clock: clock, options: options)
            let account = Account(tokens: tokens, client: client)
            clients[email] = account
            return account
        }
    }
}
