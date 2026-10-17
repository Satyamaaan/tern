import Foundation
import Synchronization
import TernCore
@testable import TernSync

// MARK: - URLProtocol stub

struct StubRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var bodyText: String { String(decoding: body, as: UTF8.self) }

    /// Query items, first value per name.
    var query: [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where result[item.name] == nil {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    /// Form fields of an `application/x-www-form-urlencoded` body.
    var form: [String: String] {
        var result: [String: String] = [:]
        for pair in bodyText.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let decode = { (s: String) in s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s }
            result[decode(parts[0])] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return result
    }
}

struct StubResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(status: status, headers: headers.merging(["Content-Type": "application/json; charset=UTF-8"]) { a, _ in a },
                     body: Data(text.utf8))
    }

    static func error(_ status: Int, reason: String? = nil, message: String = "error", headers: [String: String] = [:]) -> StubResponse {
        let errors = reason.map { #","errors":[{"domain":"usageLimits","reason":"\#($0)","message":"\#(message)"}]"# } ?? ""
        return .json(#"{"error":{"code":\#(status),"message":"\#(message)"\#(errors)}}"#, status: status, headers: headers)
    }
}

/// A fake Google: one per test, so parallel tests never share handlers. Its session tags every
/// request with an `X-Stub-Id` header that `StubURLProtocol` uses to find the right server.
final class StubServer: Sendable {
    typealias Handler = @Sendable (StubRequest) throws -> StubResponse

    let id = UUID().uuidString
    let session: URLSession
    private let state: Mutex<(handler: Handler, requests: [StubRequest])>

    init(_ handler: @escaping Handler) {
        state = Mutex((handler, []))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub-Id": id]
        session = URLSession(configuration: configuration)
        StubURLProtocol.servers.withLock { $0[id] = self }
    }

    var requests: [StubRequest] { state.withLock { $0.requests } }

    func handle(_ request: StubRequest) throws -> StubResponse {
        let handler = state.withLock { state in
            state.requests.append(request)
            return state.handler
        }
        return try handler(request)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let servers = Mutex<[String: StubServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let headers = request.allHTTPHeaderFields ?? [:]
        guard let id = headers["X-Stub-Id"], let server = Self.servers.withLock({ $0[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let recorded = StubRequest(method: request.httpMethod ?? "GET", url: request.url!,
                                   headers: headers.filter { $0.key != "X-Stub-Id" }, body: body)
        do {
            let response = try server.handle(recorded)
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                                       headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Virtual clock

/// Time that only moves when someone sleeps, so backoff and rate-limit waits take no real time.
final class TestClock: Sendable {
    private let state = Mutex<(now: TimeInterval, sleeps: [TimeInterval])>((1_800_000_000, []))

    var now: TimeInterval { state.withLock { $0.now } }
    var sleeps: [TimeInterval] { state.withLock { $0.sleeps } }

    func advance(_ seconds: TimeInterval) {
        state.withLock { $0.now += seconds }
    }

    var clock: GoogleClock {
        GoogleClock(
            now: { self.now },
            sleep: { seconds in
                try Task.checkCancellation()
                self.state.withLock { state in
                    state.sleeps.append(seconds)
                    state.now += seconds
                }
            },
            random: { 0.5 }
        )
    }
}

// MARK: - Doubles

final class MemorySecretStore: SecretStore {
    private let items = Mutex<[String: Data]>([:])

    func data(service: String, account: String) throws -> Data? {
        items.withLock { $0["\(service)|\(account)"] }
    }

    func set(_ data: Data, service: String, account: String) throws {
        items.withLock { $0["\(service)|\(account)"] = data }
    }

    func remove(service: String, account: String) throws {
        items.withLock { _ = $0.removeValue(forKey: "\(service)|\(account)") }
    }

    func accounts(service: String) throws -> [String] {
        items.withLock { items in
            items.keys.filter { $0.hasPrefix(service + "|") }.map { String($0.dropFirst(service.count + 1)) }.sorted()
        }
    }
}

/// Hands out "token-1", "token-2"… and records invalidations.
actor CountingTokens: GmailAccessTokenSource {
    private(set) var issued = 0
    private(set) var invalidated: [String] = []
    private var current: String?

    func accessToken() async throws -> String {
        if let current { return current }
        issued += 1
        let token = "token-\(issued)"
        current = token
        return token
    }

    func invalidate(_ token: String) {
        invalidated.append(token)
        if current == token { current = nil }
    }
}

let testConfig = GoogleClientConfig(clientId: "1234567890-abcdefghijklmnop.apps.googleusercontent.com",
                                    clientSecret: "GOCSPX-test-secret")

func makeClient(_ server: StubServer, clock: TestClock, tokens: CountingTokens = CountingTokens(),
                options: GmailHTTPClient.Options = GmailHTTPClient.Options()) -> GmailHTTPClient {
    GmailHTTPClient(tokens: tokens, session: server.session,
                    rateLimiter: GmailRateLimiter(unitsPerMinute: 1_000_000_000, clock: clock.clock),
                    clock: clock.clock, options: options)
}

/// A Gmail message as JSON.
func messageJSON(_ id: String, thread: String = "t1") -> String {
    #"{"id":"\#(id)","threadId":"\#(thread)","labelIds":["INBOX"],"snippet":"Hi \#(id)","historyId":"100"}"#
}

/// A batch response with the given (Content-ID index, status, JSON body) parts.
func batchResponse(_ parts: [(index: Int, status: Int, body: String)], boundary: String = "batch_resp_XYZ",
                   headers: [String: String] = [:]) -> StubResponse {
    var text = "--\(boundary)\r\n"
    for (offset, part) in parts.enumerated() {
        let reason = HTTPURLResponse.localizedString(forStatusCode: part.status)
        text += "Content-Type: application/http\r\nContent-ID: <response-item-\(part.index)>\r\n\r\n"
        text += "HTTP/1.1 \(part.status) \(reason)\r\nContent-Type: application/json; charset=UTF-8\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(part.body.utf8.count)\r\n\r\n\(part.body)\r\n"
        text += offset == parts.count - 1 ? "--\(boundary)--\r\n" : "--\(boundary)\r\n"
    }
    return StubResponse(status: 200, headers: ["Content-Type": "multipart/mixed; boundary=\(boundary)"], body: Data(text.utf8))
}

/// The message ids a batch request asks for, in part order.
func batchIds(_ request: StubRequest) -> [String] {
    request.bodyText.components(separatedBy: "\r\n")
        .filter { $0.hasPrefix("GET /gmail/v1/users/me/messages/") }
        .map { line in
            let path = line.dropFirst("GET /gmail/v1/users/me/messages/".count)
            return String(path.prefix { $0 != "?" })
        }
}

/// A shareable, lock-protected value for state that test closures pass around.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value { mutex.withLock { $0 } }

    func set(_ value: Value) {
        mutex.withLock { $0 = value }
    }
}
