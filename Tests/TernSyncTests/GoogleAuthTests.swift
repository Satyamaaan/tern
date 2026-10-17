import Foundation
import Security
import Synchronization
import Testing
@testable import TernSync

@Suite struct GoogleAuthTests {
    // MARK: PKCE and the consent URL

    @Test func pkceMatchesRFC7636Example() {
        // RFC 7636, appendices A and B.
        #expect(Data([3, 236, 255, 224, 193]).base64URLEncodedString() == "A-z_4ME")
        #expect(Data(base64URLEncoded: "A-z_4ME") == Data([3, 236, 255, 224, 193]))
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifiersAreValidAndUnique() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifiers = (0..<50).map { _ in PKCE.generate().verifier }
        #expect(Set(verifiers).count == 50)
        for verifier in verifiers {
            #expect((43...128).contains(verifier.count))
            #expect(verifier.allSatisfy(allowed.contains))
        }
    }

    @Test func consentURLCarriesEverything() async throws {
        let auth = GoogleAuth(config: testConfig)
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = auth.authorizationURL(redirectURI: "http://127.0.0.1:50123", pkce: pkce, state: "s+1/=",
                                        loginHint: "Me@Example.com")
        #expect(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"))
        let query = StubRequest(method: "GET", url: url, headers: [:], body: Data()).query
        #expect(query == [
            "client_id": testConfig.clientId,
            "redirect_uri": "http://127.0.0.1:50123",
            "response_type": "code",
            "scope": "https://www.googleapis.com/auth/gmail.modify openid email profile",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
            "state": "s+1/=",
            "access_type": "offline",
            "prompt": "consent",
            "login_hint": "Me@Example.com",
        ])
        #expect(url.query?.contains("state=s%2B1%2F%3D") == true)
    }

    // MARK: Client config

    @Test func clientIdValidation() throws {
        #expect(GoogleClientConfig.isValidClientId("1234567890-abc123def456.apps.googleusercontent.com"))
        #expect(!GoogleClientConfig.isValidClientId("1234567890-abc123def456"))
        #expect(!GoogleClientConfig.isValidClientId(".apps.googleusercontent.com"))
        #expect(!GoogleClientConfig.isValidClientId("evil.com/.apps.googleusercontent.com"))
        #expect(!GoogleClientConfig.isValidClientId("12 34.apps.googleusercontent.com"))
        #expect(throws: GoogleClientConfigError.invalidClientSecret) {
            try GoogleClientConfig(clientId: testConfig.clientId, clientSecret: "  ").validate()
        }
        let padded = GoogleClientConfig(clientId: " \(testConfig.clientId)\n", clientSecret: "\tGOCSPX-x ")
        #expect(padded == GoogleClientConfig(clientId: testConfig.clientId, clientSecret: "GOCSPX-x"))
    }

    @Test func clientConfigFromDownloadedJSON() throws {
        let installed = #"{"installed":{"client_id":"\#(testConfig.clientId)","project_id":"tern-123","auth_uri":"https://accounts.google.com/o/oauth2/auth","client_secret":"GOCSPX-test-secret","redirect_uris":["http://localhost"]}}"#
        #expect(try GoogleClientConfig(downloadedJSON: Data(installed.utf8)) == testConfig)
        let web = #"{"web":{"client_id":"\#(testConfig.clientId)","client_secret":"x"}}"#
        #expect(throws: GoogleClientConfigError.notDesktopClient) { try GoogleClientConfig(downloadedJSON: Data(web.utf8)) }
        #expect(throws: GoogleClientConfigError.unreadableFile) { try GoogleClientConfig(downloadedJSON: Data("nope".utf8)) }
    }

    @Test func clientConfigStoreRoundTrip() throws {
        let secrets = MemorySecretStore()
        let store = GoogleClientConfigStore(secrets: secrets)
        #expect(try store.load() == nil)
        #expect(throws: GoogleClientConfigError.invalidClientId) {
            try store.save(GoogleClientConfig(clientId: "nope", clientSecret: "x"))
        }
        try store.save(testConfig)
        #expect(try store.load() == testConfig)
        #expect(try secrets.accounts(service: "dev.tern.mail.oauth-client") == ["default"])
        try store.delete()
        #expect(try store.load() == nil)
    }

    @Test func accountsLoadTheSavedClient() throws {
        let secrets = MemorySecretStore()
        #expect(try GoogleAccounts(secrets: secrets) == nil)
        try GoogleClientConfigStore(secrets: secrets).save(testConfig)
        let accounts = try #require(try GoogleAccounts(secrets: secrets))
        #expect(accounts.auth.config == testConfig)
        #expect(accounts.connectedEmails().isEmpty)
    }

    // MARK: Token provider

    @Test func concurrentCallersShareOneRefresh() async throws {
        let refreshes = Mutex(0)
        let clock = TestClock()
        let provider = GoogleTokenProvider(clock: clock.clock) {
            let n = refreshes.withLock { $0 += 1; return $0 }
            try await Task.sleep(for: .milliseconds(50))
            return GoogleAccessToken(value: "access-\(n)", expiresAt: clock.now + 3600)
        }
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await provider.accessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(tokens) == ["access-1"])
        #expect(refreshes.withLock { $0 } == 1)

        // Cached until a minute before expiry.
        clock.advance(3600 - 61)
        #expect(try await provider.accessToken() == "access-1")
        clock.advance(2)
        #expect(try await provider.accessToken() == "access-2")

        // A rejected token is dropped; an outdated rejection is ignored.
        await provider.invalidate("access-1")
        #expect(try await provider.accessToken() == "access-2")
        await provider.invalidate("access-2")
        #expect(try await provider.accessToken() == "access-3")
    }

    @Test func revokedRefreshTokenMeansUnauthorized() async throws {
        let server = StubServer { _ in
            .json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, status: 400)
        }
        let secrets = MemorySecretStore()
        try secrets.set(Data("1//refresh".utf8), service: GoogleKeychain.tokenService, account: "me@example.com")
        let auth = GoogleAuth(config: testConfig, session: server.session)
        let provider = GoogleTokenProvider(email: "Me@Example.com", auth: auth, secrets: secrets, clock: TestClock().clock)
        await #expect(throws: GmailAPIError.unauthorized) { try await provider.accessToken() }

        let form = try #require(server.requests.first).form
        #expect(form == [
            "client_id": testConfig.clientId, "client_secret": testConfig.clientSecret,
            "refresh_token": "1//refresh", "grant_type": "refresh_token",
        ])
        let missing = GoogleTokenProvider(email: "other@example.com", auth: auth, secrets: secrets)
        await #expect(throws: GmailAPIError.unauthorized) { try await missing.accessToken() }
        #expect(server.requests.count == 1)
    }

    @Test func lockedKeychainIsNotASignOut() async throws {
        struct LockedKeychain: SecretStore {
            func data(service: String, account: String) throws -> Data? { throw KeychainError(status: errSecInteractionNotAllowed) }
            func set(_ data: Data, service: String, account: String) throws {}
            func remove(service: String, account: String) throws {}
            func accounts(service: String) throws -> [String] { [] }
        }
        let auth = GoogleAuth(config: testConfig, session: StubServer { _ in .json("{}") }.session)
        let provider = GoogleTokenProvider(email: "me@example.com", auth: auth, secrets: LockedKeychain())
        await #expect {
            try await provider.accessToken()
        } throws: { error in
            if case GmailAPIError.network = error { return true }
            return false
        }
    }

    @Test func refreshReturnsExpiry() async throws {
        let server = StubServer { _ in .json(#"{"access_token":"ya29.new","expires_in":3599,"token_type":"Bearer"}"#) }
        let clock = TestClock()
        let auth = GoogleAuth(config: testConfig, session: server.session, clock: clock.clock)
        let token = try await auth.refresh(refreshToken: "1//r")
        #expect(token == GoogleAccessToken(value: "ya29.new", expiresAt: clock.now + 3599))
        #expect(server.requests.first?.header("Content-Type") == "application/x-www-form-urlencoded")
    }

    // MARK: Sign-in over the loopback redirect

    /// Google's token and userinfo endpoints, plus a record of revocations.
    private static func fakeGoogle(scope: String = "https://www.googleapis.com/auth/gmail.modify openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile",
                                   refreshToken: String? = "1//refresh-secret") -> StubServer {
        StubServer { request in
            switch request.url.absoluteString {
            case "https://oauth2.googleapis.com/token":
                let refresh = refreshToken.map { #","refresh_token":"\#($0)""# } ?? ""
                return .json(#"{"access_token":"ya29.first","expires_in":3599,"scope":"\#(scope)","token_type":"Bearer"\#(refresh)}"#)
            case "https://openidconnect.googleapis.com/v1/userinfo":
                return .json(#"{"sub":"1","email":"Me@Example.com","email_verified":true,"name":"Mia Example","picture":"https://lh3.googleusercontent.com/a/x"}"#)
            case "https://oauth2.googleapis.com/revoke":
                return StubResponse(status: 200)
            default:
                return .json(#"{"emailAddress":"me@example.com","historyId":"7"}"#)
            }
        }
    }

    /// Plays the browser: follows the consent URL straight to the loopback redirect.
    private static func browser(_ redirect: @escaping @Sendable (_ state: String) -> String,
                                page: Locked<(Int, String)?> = Locked(nil)) -> @Sendable (URL) -> Void {
        { url in
            let query = StubRequest(method: "GET", url: url, headers: [:], body: Data()).query
            let target = URL(string: query["redirect_uri"]! + "/?" + redirect(query["state"]!))!
            Task {
                let (data, response) = try await URLSession(configuration: .ephemeral).data(from: target)
                page.set(((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    @Test func connectSignsInAndStoresTheRefreshToken() async throws {
        let google = Self.fakeGoogle()
        let secrets = MemorySecretStore()
        let accounts = GoogleAccounts(config: testConfig, secrets: secrets, session: google.session)
        let consentURL = Mutex<URL?>(nil)
        let page = Locked<(Int, String)?>(nil)
        let browser = Self.browser({ "state=\($0)&code=4%2F0Acode&scope=email&iss=https%3A%2F%2Faccounts.google.com" }, page: page)

        let info = try await accounts.connect { url in
            consentURL.withLock { $0 = url }
            browser(url)
        }
        #expect(info == GoogleAccountInfo(email: "Me@Example.com", displayName: "Mia Example",
                                          pictureURL: URL(string: "https://lh3.googleusercontent.com/a/x")))
        #expect(accounts.hasCredentials(for: "ME@example.com"))
        #expect(accounts.connectedEmails() == ["me@example.com"])
        #expect(try secrets.data(service: "dev.tern.mail.google", account: "me@example.com") == Data("1//refresh-secret".utf8))

        // The code exchange proves possession of the verifier behind the challenge it sent.
        let exchange = try #require(google.requests.first { $0.url.path == "/token" }).form
        let consent = StubRequest(method: "GET", url: try #require(consentURL.withLock { $0 }), headers: [:], body: Data()).query
        #expect(exchange["grant_type"] == "authorization_code")
        #expect(exchange["code"] == "4/0Acode")
        #expect(exchange["redirect_uri"] == consent["redirect_uri"])
        #expect(exchange["client_secret"] == testConfig.clientSecret)
        #expect(PKCE.challenge(for: try #require(exchange["code_verifier"])) == consent["code_challenge"])
        #expect(consent["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)

        let userinfo = try #require(google.requests.first { $0.url.path == "/v1/userinfo" })
        #expect(userinfo.header("Authorization") == "Bearer ya29.first")

        // The first API call reuses the access token from sign-in instead of refreshing.
        _ = try await accounts.api(for: "me@example.com").profile()
        #expect(google.requests.last?.header("Authorization") == "Bearer ya29.first")
        #expect(google.requests.filter { $0.url.path == "/token" }.count == 1)

        try await waitFor { page.value != nil }
        let (status, html) = try #require(page.value)
        #expect(status == 200)
        #expect(html.contains("You can close this tab and return to Tern."))
    }

    @Test func signOutRevokesAndForgets() async throws {
        let google = Self.fakeGoogle()
        let secrets = MemorySecretStore()
        try secrets.set(Data("1//old".utf8), service: GoogleKeychain.tokenService, account: "me@example.com")
        let accounts = GoogleAccounts(config: testConfig, secrets: secrets, session: google.session)
        await accounts.signOut("Me@Example.com")
        #expect(!accounts.hasCredentials(for: "me@example.com"))
        let revoke = try #require(google.requests.first)
        #expect(revoke.url.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(revoke.form == ["token": "1//old"])
        await #expect(throws: GmailAPIError.unauthorized) { try await accounts.api(for: "me@example.com").labels() }
    }

    @Test func strayRequestsDoNotEndSignIn() async throws {
        let auth = GoogleAuth(config: testConfig, session: Self.fakeGoogle().session)
        let statuses = Locked<[Int]>([])
        let result = try await auth.signIn { url in
            let query = StubRequest(method: "GET", url: url, headers: [:], body: Data()).query
            let base = query["redirect_uri"]! + "/?"
            let state = query["state"]!
            Task {
                let session = URLSession(configuration: .ephemeral)
                for target in ["state=forged&code=stolen", "state=\(state)&code=x&iss=https%3A%2F%2Fevil.example",
                               "state=\(state)&code=real&iss=https%3A%2F%2Faccounts.google.com"] {
                    let (_, response) = try await session.data(from: URL(string: base + target)!)
                    statuses.set(statuses.value + [(response as! HTTPURLResponse).statusCode])
                }
            }
        }
        #expect(result.account.email == "Me@Example.com")
        try await waitFor { statuses.value.count == 3 }
        #expect(statuses.value == [400, 400, 200])
    }

    @Test func cancelledConsentIsReported() async throws {
        let auth = GoogleAuth(config: testConfig, session: Self.fakeGoogle().session)
        await #expect(throws: GoogleAuthError.accessDenied) {
            try await auth.signIn(openURL: Self.browser({ "state=\($0)&error=access_denied" }))
        }
    }

    @Test func untickedGmailScopeIsReportedAndRevoked() async throws {
        let google = Self.fakeGoogle(scope: "openid https://www.googleapis.com/auth/userinfo.email")
        let auth = GoogleAuth(config: testConfig, session: google.session)
        let page = Locked<(Int, String)?>(nil)
        await #expect(throws: GoogleAuthError.missingGmailScope) {
            try await auth.signIn(openURL: Self.browser({ "state=\($0)&code=abc" }, page: page))
        }
        // The tab only learns the outcome after the exchange, so it never claims success.
        try await waitFor { page.value != nil }
        #expect(page.value?.1.contains("leaving the Gmail box ticked") == true)
        #expect(page.value?.1.contains("close this tab") == false)
        #expect(google.requests.last?.url.path == "/revoke")
        #expect(google.requests.last?.form["token"] == "1//refresh-secret")
    }

    @Test func missingRefreshTokenIsAnError() async throws {
        let auth = GoogleAuth(config: testConfig, session: Self.fakeGoogle(refreshToken: nil).session)
        await #expect(throws: GoogleAuthError.noRefreshToken) {
            try await auth.signIn(openURL: Self.browser({ "state=\($0)&code=abc" }))
        }
    }

    @Test func signInTimesOut() async throws {
        let auth = GoogleAuth(config: testConfig, session: Self.fakeGoogle().session, timeout: 0.2)
        await #expect(throws: GoogleAuthError.timedOut) { try await auth.signIn(openURL: { _ in }) }
    }

    @Test func signInCanBeCancelled() async throws {
        let auth = GoogleAuth(config: testConfig, session: Self.fakeGoogle().session)
        let opened = Mutex(false)
        let task = Task { try await auth.signIn(openURL: { _ in opened.withLock { $0 = true } }) }
        try await waitFor { opened.withLock { $0 } }
        await auth.cancelSignIn()
        await #expect(throws: CancellationError.self) { try await task.value }

        let second = Task { try await auth.signIn(openURL: { _ in }) }
        try await Task.sleep(for: .milliseconds(50))
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
    }

    @Test func faviconAndProbesGet404() async throws {
        let auth = GoogleAuth(config: testConfig, session: Self.fakeGoogle().session)
        let probe = Mutex<Int?>(nil)
        let result = try await auth.signIn { url in
            let query = StubRequest(method: "GET", url: url, headers: [:], body: Data()).query
            let base = query["redirect_uri"]!
            Task {
                let session = URLSession(configuration: .ephemeral)
                let (_, response) = try await session.data(from: URL(string: base + "/favicon.ico")!)
                probe.withLock { $0 = (response as! HTTPURLResponse).statusCode }
                _ = try await session.data(from: URL(string: base + "/?code=abc&state=\(query["state"]!)")!)
            }
        }
        #expect(result.refreshToken == "1//refresh-secret")
        #expect(probe.withLock { $0 } == 404)
    }
}

/// Polls `condition` for up to two seconds.
func waitFor(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting")
}
