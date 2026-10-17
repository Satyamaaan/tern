import Foundation

public enum GoogleAuthError: Error, Equatable, Sendable {
    /// The loopback listener could not start.
    case listenerFailed(String)
    case timedOut
    /// The user pressed Cancel on Google's consent screen.
    case accessDenied
    /// Google redirected with an error other than `access_denied`.
    case authorizationFailed(String)
    /// The redirect's `state` did not match; the response was not for this sign-in.
    case stateMismatch
    /// The user unticked Gmail access on the consent screen.
    case missingGmailScope
    /// Google returned no refresh token, so Tern could not stay signed in.
    case noRefreshToken
    /// The refresh token was revoked or expired; the account needs to sign in again.
    case invalidGrant
    /// Another error from the token endpoint, such as `invalid_client`.
    case oauth(error: String, description: String?)
    case network(String)
    case invalidResponse(String)
}

/// An access token and when it stops working.
public struct GoogleAccessToken: Sendable, Hashable {
    public var value: String
    /// Seconds since 1970.
    public var expiresAt: TimeInterval

    public init(value: String, expiresAt: TimeInterval) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

/// Who signed in, from the OpenID userinfo endpoint.
public struct GoogleAccountInfo: Codable, Sendable, Hashable {
    public var email: String
    public var displayName: String
    public var pictureURL: URL?

    public init(email: String, displayName: String, pictureURL: URL? = nil) {
        self.email = email
        self.displayName = displayName
        self.pictureURL = pictureURL
    }
}

/// Everything a finished sign-in produces. The refresh token is a secret: store it, never log it.
public struct GoogleSignInResult: Sendable {
    public var account: GoogleAccountInfo
    public var refreshToken: String
    public var accessToken: GoogleAccessToken
}

/// Installed-app OAuth 2.0 for Google: authorization code with PKCE (S256) and a loopback redirect
/// to `http://127.0.0.1:<random port>`, plus token refresh and revocation.
public actor GoogleAuth {
    public let config: GoogleClientConfig
    public let endpoints: GoogleEndpoints
    private let session: URLSession
    private let clock: GoogleClock
    private let timeout: TimeInterval
    private var signIn: Task<GoogleSignInResult, Error>?

    /// - Parameter timeout: how long to wait for the browser to come back.
    public init(config: GoogleClientConfig, endpoints: GoogleEndpoints = .google, session: URLSession = .shared,
                clock: GoogleClock = .live, timeout: TimeInterval = 300) {
        self.config = config
        self.endpoints = endpoints
        self.session = session
        self.clock = clock
        self.timeout = timeout
    }

    // MARK: - Sign-in

    /// Opens Google's consent page through `openURL` (the app passes `NSWorkspace.shared.open`),
    /// waits for the redirect, and exchanges the code for tokens. Starting a new sign-in cancels one
    /// still in progress. Cancelling the calling task cancels the sign-in.
    /// - Parameter loginHint: an email address to preselect, e.g. when reconnecting an account.
    public func signIn(loginHint: String? = nil,
                       openURL: @escaping @Sendable (URL) -> Void) async throws -> GoogleSignInResult {
        signIn?.cancel()
        let task = Task { try await performSignIn(loginHint: loginHint, openURL: openURL) }
        signIn = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels a sign-in that is waiting for the browser.
    public func cancelSignIn() {
        signIn?.cancel()
        signIn = nil
    }

    private func performSignIn(loginHint: String?, openURL: @Sendable (URL) -> Void) async throws -> GoogleSignInResult {
        let pkce = PKCE.generate()
        let state = PKCE.randomString(byteCount: 24)
        let server = LoopbackServer()
        defer { server.stop() }
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        openURL(authorizationURL(redirectURI: redirectURI, pkce: pkce, state: state, loginHint: loginHint))
        let code = try await waitForCode(server, state: state)
        let tokens = try await exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI)

        let granted = Set((tokens.scope ?? "").split(separator: " ").map(String.init))
        guard granted.contains(GoogleScope.gmailModify) else {
            await revoke(tokens.refresh_token ?? tokens.access_token)
            throw GoogleAuthError.missingGmailScope
        }
        guard let refreshToken = tokens.refresh_token, !refreshToken.isEmpty else {
            throw GoogleAuthError.noRefreshToken
        }
        let account = try await userInfo(accessToken: tokens.access_token)
        return GoogleSignInResult(account: account, refreshToken: refreshToken,
                                  accessToken: accessToken(from: tokens))
    }

    /// The consent URL. Exposed for tests.
    nonisolated func authorizationURL(redirectURI: String, pkce: PKCE, state: String, loginHint: String?) -> URL {
        var items = [
            ("client_id", config.clientId),
            ("redirect_uri", redirectURI),
            ("response_type", "code"),
            ("scope", GoogleScope.signIn.joined(separator: " ")),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            ("access_type", "offline"),
            ("prompt", "consent"),
        ]
        if let loginHint, !loginHint.isEmpty { items.append(("login_hint", loginHint)) }
        return FormEncoding.url(endpoints.authorization, items)
    }

    /// Answers requests on the loopback port until one carries `state`, then returns its code.
    /// Other requests (favicon, browser probes) get a 404.
    private func waitForCode(_ server: LoopbackServer, state: String) async throws -> String {
        let clock = clock
        let timeout = timeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await incoming in server.requests {
                    let query = incoming.request.query
                    guard query["state"] != nil || query["code"] != nil || query["error"] != nil else {
                        incoming.respond(status: 404, html: "")
                        continue
                    }
                    // RFC 9207: when Google names the issuer, it must be Google.
                    guard query["state"] == state, query["iss"].map({ $0 == "https://accounts.google.com" }) ?? true else {
                        incoming.respond(status: 400, html: AuthResultPage.failure(
                            "This sign-in link has expired. Start again from Tern."))
                        throw GoogleAuthError.stateMismatch
                    }
                    if let error = query["error"] {
                        incoming.respond(status: 200, html: AuthResultPage.failure(
                            error == "access_denied" ? "You cancelled. Return to Tern to try again." :
                                "Google reported “\(error)”. Return to Tern to try again."))
                        throw error == "access_denied" ? GoogleAuthError.accessDenied : .authorizationFailed(error)
                    }
                    guard let code = query["code"], !code.isEmpty else {
                        incoming.respond(status: 400, html: AuthResultPage.failure("Google sent no authorization code."))
                        throw GoogleAuthError.invalidResponse("redirect without a code")
                    }
                    incoming.respond(status: 200, html: AuthResultPage.success)
                    return code
                }
                throw CancellationError()
            }
            group.addTask {
                try await clock.sleep(timeout)
                throw GoogleAuthError.timedOut
            }
            defer { group.cancelAll() }
            guard let code = try await group.next() else { throw CancellationError() }
            return code
        }
    }

    // MARK: - Token endpoint

    struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Double?
        var refresh_token: String?
        var scope: String?
        var token_type: String?
    }

    private struct OAuthErrorBody: Decodable {
        var error: String
        var error_description: String?
    }

    nonisolated func exchange(code: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        try await tokenRequest([
            ("code", code),
            ("client_id", config.clientId),
            ("client_secret", config.clientSecret),
            ("redirect_uri", redirectURI),
            ("grant_type", "authorization_code"),
            ("code_verifier", verifier),
        ])
    }

    /// Trades a refresh token for a new access token. Throws `GoogleAuthError.invalidGrant` when the
    /// refresh token no longer works.
    public nonisolated func refresh(refreshToken: String) async throws -> GoogleAccessToken {
        let tokens = try await tokenRequest([
            ("client_id", config.clientId),
            ("client_secret", config.clientSecret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ])
        return accessToken(from: tokens)
    }

    /// Revokes a refresh or access token. Best effort: failures are ignored.
    public nonisolated func revoke(_ token: String) async {
        var request = URLRequest(url: endpoints.revocation)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode([("token", token)]).utf8)
        _ = try? await session.data(for: request)
    }

    nonisolated func userInfo(accessToken: String) async throws -> GoogleAccountInfo {
        struct UserInfo: Decodable {
            var email: String?
            var name: String?
            var picture: String?
        }
        var request = URLRequest(url: endpoints.userInfo)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await load(request)
        guard status == 200, let info = try? JSONDecoder().decode(UserInfo.self, from: data),
              let email = info.email, !email.isEmpty else {
            throw GoogleAuthError.invalidResponse("userinfo returned \(status)")
        }
        return GoogleAccountInfo(email: email, displayName: info.name ?? "",
                                 pictureURL: info.picture.flatMap(URL.init(string:)))
    }

    private nonisolated func tokenRequest(_ form: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: endpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(FormEncoding.encode(form).utf8)
        let (data, status) = try await load(request)
        if status == 200, let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) {
            return tokens
        }
        if let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data) {
            if body.error == "invalid_grant" { throw GoogleAuthError.invalidGrant }
            throw GoogleAuthError.oauth(error: body.error, description: body.error_description)
        }
        throw GoogleAuthError.invalidResponse("token endpoint returned \(status)")
    }

    private nonisolated func load(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GoogleAuthError.network(error.localizedDescription)
        }
    }

    private nonisolated func accessToken(from tokens: TokenResponse) -> GoogleAccessToken {
        GoogleAccessToken(value: tokens.access_token, expiresAt: clock.now() + (tokens.expires_in ?? 3600))
    }
}
