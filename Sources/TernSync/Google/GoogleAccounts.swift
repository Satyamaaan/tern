import Foundation
import Synchronization

/// What the app calls for Google accounts: connect, get an account's `GmailAPI`, sign out.
/// Refresh tokens live in the Keychain (service `dev.tern.mail.google`, account = lowercased email);
/// access tokens only in memory. A refresh token only works with the OAuth client that issued it, so it is
/// stored with that client's ID (`GoogleCredential`); tokens stored without one use the default client. Clients are cached, so every caller for an account shares one token cache and one
/// rate limiter.
public final class GoogleAccounts: Sendable {
    /// The default client's sign-in.
    public let auth: GoogleAuth
    /// Every client's sign-in, by client ID.
    private let auths: [String: GoogleAuth]
    /// Client IDs in the order the store keeps them, the default first.
    public let clientIds: [String]
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
    public convenience init(config: GoogleClientConfig, secrets: any SecretStore = KeychainSecretStore(),
                            session: URLSession = .shared, endpoints: GoogleEndpoints = .google, clock: GoogleClock = .live,
                            signInTimeout: TimeInterval = 300, unitsPerMinute: Double = 6000,
                            options: GmailHTTPClient.Options = GmailHTTPClient.Options()) {
        self.init(configs: [config], secrets: secrets, session: session, endpoints: endpoints, clock: clock,
                  signInTimeout: signInTimeout, unitsPerMinute: unitsPerMinute, options: options)!
    }

    /// - Parameter configs: every OAuth client, the default first. Nil when it is empty.
    public init?(configs: [GoogleClientConfig], secrets: any SecretStore = KeychainSecretStore(),
                 session: URLSession = .shared, endpoints: GoogleEndpoints = .google, clock: GoogleClock = .live,
                 signInTimeout: TimeInterval = 300, unitsPerMinute: Double = 6000,
                 options: GmailHTTPClient.Options = GmailHTTPClient.Options()) {
        var auths: [String: GoogleAuth] = [:]
        var ids: [String] = []
        for config in configs where auths[config.clientId] == nil {
            auths[config.clientId] = GoogleAuth(config: config, endpoints: endpoints, session: session, clock: clock,
                                                timeout: signInTimeout)
            ids.append(config.clientId)
        }
        guard let first = ids.first, let auth = auths[first] else { return nil }
        self.auth = auth
        self.auths = auths
        self.clientIds = ids
        self.secrets = secrets
        self.session = session
        self.endpoints = endpoints
        self.clock = clock
        self.options = options
        self.unitsPerMinute = unitsPerMinute
    }

    /// Uses the OAuth clients saved in the Keychain; nil until the user has entered one.
    public convenience init?(secrets: any SecretStore = KeychainSecretStore()) throws {
        self.init(configs: try GoogleClientConfigStore(secrets: secrets).loadAll(), secrets: secrets)
    }

    /// The client ID `email` signs in with: the one it connected with, or the default when that one is
    /// gone or it connected before Tern kept more than one.
    public func clientId(for email: String) -> String {
        auth(for: email).config.clientId
    }

    /// The stored client `email` signed in with: nil when it has no credential, signed in before Tern kept
    /// more than one client, or its client was removed (all of which sign in through the default). Throws
    /// when the Keychain can't be read right now, so signing in again never quietly switches clients.
    public func storedClientId(for email: String) throws -> String? {
        let data = try secrets.data(service: GoogleKeychain.tokenService, account: email.lowercased())
        return data.flatMap(GoogleCredential.init(data:))?.clientId.flatMap { auths[$0] == nil ? nil : $0 }
    }

    /// Signs in a Google account in the browser and saves its refresh token and the client it signed
    /// in with. Connecting an account that is already connected replaces both.
    /// - Parameters:
    ///   - clientId: the OAuth client to sign in with; nil uses the default one.
    ///   - loginHint: an email to preselect, e.g. when an account needs to sign in again.
    ///   - openURL: opens the consent page, e.g. `{ NSWorkspace.shared.open($0) }`.
    public func connect(clientId: String? = nil, loginHint: String? = nil,
                        openURL: @escaping @Sendable (URL) -> Void) async throws -> GoogleAccountInfo {
        guard let auth = clientId.map({ auths[$0] }) ?? auth else { throw GoogleAccountsError.unknownClient }
        let result = try await auth.signIn(loginHint: loginHint, openURL: openURL)
        let email = result.account.email.lowercased()
        let credential = GoogleCredential(refreshToken: result.refreshToken, clientId: auth.config.clientId)
        try secrets.set(try credential.encoded(), service: GoogleKeychain.tokenService, account: email)
        await account(for: email).tokens.seed(result.accessToken)
        return result.account
    }

    /// Cancels a `connect` that is waiting for the browser.
    public func cancelConnect() async {
        for auth in auths.values { await auth.cancelSignIn() }
    }

    /// The Gmail API for a connected account. Calls throw `GmailAPIError.unauthorized` once the
    /// account has no working refresh token.
    public func api(for email: String) -> any GmailAPI {
        account(for: email.lowercased()).client
    }

    /// The account's Google profile (name and photo), read with its own token.
    public func profile(for email: String) async throws -> GoogleAccountInfo {
        let email = email.lowercased()
        let token = try await account(for: email).tokens.accessToken()
        return try await auth(for: email).userInfo(accessToken: token)
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
           let credential = GoogleCredential(data: data) {
            await client(credential.clientId).revoke(credential.refreshToken)
        }
        try? secrets.remove(service: GoogleKeychain.tokenService, account: account)
        clients.withLock { _ = $0.removeValue(forKey: account) }
    }

    private func account(for email: String) -> Account {
        clients.withLock { clients in
            if let existing = clients[email] { return existing }
            // The client comes from the stored credential at each refresh, so signing in again with another
            // one takes effect at once.
            let (auths, auth) = (auths, auth)
            let tokens = GoogleTokenProvider(email: email, auth: { Self.client($0, in: auths, default: auth) },
                                             secrets: secrets, clock: clock)
            let client = GmailHTTPClient(tokens: tokens, session: session,
                                         rateLimiter: GmailRateLimiter(unitsPerMinute: unitsPerMinute, clock: clock),
                                         endpoints: endpoints, clock: clock, options: options)
            let account = Account(tokens: tokens, client: client)
            clients[email] = account
            return account
        }
    }

    /// The client the account's stored credential names, or the default one.
    private func auth(for email: String) -> GoogleAuth {
        let stored = (try? secrets.data(service: GoogleKeychain.tokenService, account: email.lowercased()))?
            .flatMap(GoogleCredential.init(data:))
        return client(stored?.clientId)
    }

    private func client(_ clientId: String?) -> GoogleAuth {
        Self.client(clientId, in: auths, default: auth)
    }

    /// A client that is no longer stored falls back to the default; its token then fails and the account
    /// asks to sign in again.
    private static func client(_ clientId: String?, in auths: [String: GoogleAuth], default auth: GoogleAuth) -> GoogleAuth {
        clientId.flatMap { auths[$0] } ?? auth
    }
}

public enum GoogleAccountsError: Error, Equatable, Sendable {
    /// `connect` named a client that isn't stored.
    case unknownClient
}
