import Foundation

/// `GmailAPI` over Gmail API v1 with URLSession. One instance per account: it owns that account's
/// rate limiter and asks its token source for an access token before each request.
///
/// Errors: 401 refreshes the token once, then throws `.unauthorized`; 429, rate-limit 403s and 5xx
/// are retried with backoff (honouring `Retry-After`); 404 is `.notFound` (`.historyExpired` from
/// `history`); transport failures are `.network`.
///
/// Calls that create something (`send`, `sendDraft`, `createDraft`, `createLabel`) are not retried
/// after a 5xx or a transport failure, because Gmail may have done the work before failing: a
/// `.server` or `.network` error from them means "maybe". Before sending again, look for the message
/// with `messageIds(query: "rfc822msgid:<Message-ID>", …)`.
public final class GmailHTTPClient: GmailAPI {
    public struct Options: Sendable {
        /// Batches of `messages(ids:format:)` / `threads(ids:format:)` in flight at once.
        public var maxConcurrentBatches: Int
        /// Sub-requests per batch, at most 50.
        public var batchSize: Int
        public var retry: GmailRetryPolicy
        /// Messages larger than this go through the media upload endpoint.
        public var uploadThreshold: Int

        public init(maxConcurrentBatches: Int = 3, batchSize: Int = 50,
                    retry: GmailRetryPolicy = GmailRetryPolicy(), uploadThreshold: Int = 5 * 1024 * 1024) {
            self.maxConcurrentBatches = max(1, maxConcurrentBatches)
            self.batchSize = min(max(1, batchSize), 100)
            self.retry = retry
            self.uploadThreshold = uploadThreshold
        }
    }

    let tokens: any GmailAccessTokenSource
    let session: URLSession
    let rateLimiter: GmailRateLimiter
    let endpoints: GoogleEndpoints
    let clock: GoogleClock
    let options: Options

    public init(tokens: any GmailAccessTokenSource, session: URLSession = .shared,
                rateLimiter: GmailRateLimiter? = nil, endpoints: GoogleEndpoints = .google,
                clock: GoogleClock = .live, options: Options = Options()) {
        self.tokens = tokens
        self.session = session
        self.rateLimiter = rateLimiter ?? GmailRateLimiter(clock: clock)
        self.endpoints = endpoints
        self.clock = clock
        self.options = options
    }

    // MARK: - Profile and labels

    public func profile() async throws -> GmailProfile {
        try await get("users/me/profile", cost: GmailQuotaCost.getProfile)
    }

    public func labels() async throws -> [GmailLabel] {
        struct List: Decodable { var labels: [GmailLabel]? }
        let list: List = try await get("users/me/labels", cost: GmailQuotaCost.labelsList)
        return list.labels ?? []
    }

    public func createLabel(name: String) async throws -> GmailLabel {
        struct Body: Encodable {
            var name: String
            var labelListVisibility = "labelShow"
            var messageListVisibility = "show"
        }
        return try await send("POST", "users/me/labels", json: Body(name: name), cost: GmailQuotaCost.labelsCreate,
                              idempotent: false)
    }

    public func deleteLabel(id: String) async throws {
        _ = try await perform(request("DELETE", "users/me/labels/\(Self.escape(id))"), cost: GmailQuotaCost.labelsDelete)
    }

    // MARK: - Messages and history

    public func messageIds(query: String?, labelIds: [String], pageToken: String?, maxResults: Int) async throws -> GmailIdPage {
        var items: [(String, String)] = []
        if let query, !query.isEmpty { items.append(("q", query)) }
        items += labelIds.map { ("labelIds", $0) }
        if let pageToken { items.append(("pageToken", pageToken)) }
        items.append(("maxResults", String(min(max(1, maxResults), 500))))
        if labelIds.contains(where: { $0 == "SPAM" || $0 == "TRASH" }) { items.append(("includeSpamTrash", "true")) }
        return try await get("users/me/messages", query: items, cost: GmailQuotaCost.messagesList)
    }

    public func history(startHistoryId: String, pageToken: String?) async throws -> GmailHistoryPage {
        var items = [("startHistoryId", startHistoryId), ("maxResults", "500")]
        if let pageToken { items.append(("pageToken", pageToken)) }
        do {
            return try await get("users/me/history", query: items, cost: GmailQuotaCost.historyList)
        } catch GmailAPIError.notFound {
            throw GmailAPIError.historyExpired
        }
    }

    public func batchModify(messageIds: [String], add: [String], remove: [String]) async throws {
        struct Body: Encodable {
            var ids: [String]
            var addLabelIds: [String]
            var removeLabelIds: [String]
        }
        guard !messageIds.isEmpty, !(add.isEmpty && remove.isEmpty) else { return }
        // batchModify takes at most 1,000 ids.
        for start in stride(from: 0, to: messageIds.count, by: 1000) {
            let ids = Array(messageIds[start..<min(start + 1000, messageIds.count)])
            var request = try request("POST", "users/me/messages/batchModify")
            request.httpBody = try JSONEncoder().encode(Body(ids: ids, addLabelIds: add, removeLabelIds: remove))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            _ = try await perform(request, cost: GmailQuotaCost.messagesBatchModify)
        }
    }

    public func trashThread(id: String) async throws {
        _ = try await perform(request("POST", "users/me/threads/\(Self.escape(id))/trash"), cost: GmailQuotaCost.threadsTrash)
    }

    public func untrashThread(id: String) async throws {
        _ = try await perform(request("POST", "users/me/threads/\(Self.escape(id))/untrash"), cost: GmailQuotaCost.threadsUntrash)
    }

    public func attachment(messageId: String, attachmentId: String) async throws -> Data {
        struct Body: Decodable { var data: String? }
        let body: Body = try await get(
            "users/me/messages/\(Self.escape(messageId))/attachments/\(Self.escape(attachmentId))",
            cost: GmailQuotaCost.attachmentsGet)
        guard let encoded = body.data else { return Data() }
        guard let data = Data(base64URLEncoded: encoded) else {
            throw GmailAPIError.server(status: 200, message: "Attachment data is not base64url")
        }
        return data
    }

    // MARK: - Sending and drafts

    public func send(raw: Data, threadId: String?) async throws -> GmailMessageRef {
        if raw.count > options.uploadThreshold {
            let metadata = threadId.map { ["threadId": $0] }
            return try await upload("POST", "users/me/messages/send", raw: raw, metadata: metadata,
                                    cost: GmailQuotaCost.messagesSend, idempotent: false)
        }
        return try await send("POST", "users/me/messages/send", json: MessageBody(raw: raw, threadId: threadId),
                              cost: GmailQuotaCost.messagesSend, idempotent: false)
    }

    public func createDraft(raw: Data, threadId: String?) async throws -> GmailDraft {
        if raw.count > options.uploadThreshold {
            let metadata = threadId.map { DraftMetadata(id: nil, message: ["threadId": $0]) }
            return try await upload("POST", "users/me/drafts", raw: raw, metadata: metadata, cost: GmailQuotaCost.draftsCreate,
                                    idempotent: false)
        }
        return try await send("POST", "users/me/drafts",
                              json: DraftBody(id: nil, message: MessageBody(raw: raw, threadId: threadId)),
                              cost: GmailQuotaCost.draftsCreate, idempotent: false)
    }

    public func updateDraft(id: String, raw: Data, threadId: String?) async throws -> GmailDraft {
        let path = "users/me/drafts/\(Self.escape(id))"
        if raw.count > options.uploadThreshold {
            let metadata = DraftMetadata(id: id, message: threadId.map { ["threadId": $0] })
            return try await upload("PUT", path, raw: raw, metadata: metadata, cost: GmailQuotaCost.draftsUpdate, idempotent: true)
        }
        return try await send("PUT", path, json: DraftBody(id: id, message: MessageBody(raw: raw, threadId: threadId)),
                              cost: GmailQuotaCost.draftsUpdate)
    }

    public func deleteDraft(id: String) async throws {
        _ = try await perform(request("DELETE", "users/me/drafts/\(Self.escape(id))"), cost: GmailQuotaCost.draftsDelete)
    }

    public func sendDraft(id: String) async throws -> GmailMessageRef {
        try await send("POST", "users/me/drafts/send", json: ["id": id], cost: GmailQuotaCost.draftsSend, idempotent: false)
    }

    public func drafts(query: String?, pageToken: String?, maxResults: Int) async throws -> GmailDraftPage {
        var items: [(String, String)] = []
        if let query, !query.isEmpty { items.append(("q", query)) }
        if let pageToken { items.append(("pageToken", pageToken)) }
        items.append(("maxResults", String(min(max(1, maxResults), 500))))
        return try await get("users/me/drafts", query: items, cost: GmailQuotaCost.draftsList)
    }

    public func sendAs() async throws -> [GmailSendAs] {
        struct List: Decodable { var sendAs: [GmailSendAs]? }
        let list: List = try await get("users/me/settings/sendAs", cost: GmailQuotaCost.sendAsList)
        return list.sendAs ?? []
    }

    private struct MessageBody: Encodable {
        var raw: String
        var threadId: String?

        init(raw: Data, threadId: String?) {
            self.raw = raw.base64URLEncodedString()
            self.threadId = threadId
        }
    }

    private struct DraftBody: Encodable {
        var id: String?
        var message: MessageBody
    }

    private struct DraftMetadata: Encodable {
        var id: String?
        var message: [String: String]?
    }

    /// The media upload endpoint: `uploadType=media` with the bare `message/rfc822` body, or
    /// `uploadType=multipart` when JSON metadata (such as `threadId`) has to travel with it.
    private func upload<Metadata: Encodable, Response: Decodable>(
        _ method: String, _ path: String, raw: Data, metadata: Metadata?, cost: Int, idempotent: Bool
    ) async throws -> Response {
        var request: URLRequest
        if let metadata {
            let boundary = "tern-upload-\(UUID().uuidString)"
            request = try self.request(method, path, query: [("uploadType", "multipart")], upload: true)
            var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
            body += try JSONEncoder().encode(metadata)
            body += Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8)
            body += raw
            body += Data("\r\n--\(boundary)--\r\n".utf8)
            request.httpBody = body
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        } else {
            request = try self.request(method, path, query: [("uploadType", "media")], upload: true)
            request.httpBody = raw
            request.setValue("message/rfc822", forHTTPHeaderField: "Content-Type")
        }
        return try decode(try await perform(request, cost: cost, idempotent: idempotent).data)
    }

    // MARK: - Requests

    struct Response {
        var data: Data
        var http: HTTPURLResponse
        /// The access token the request went out with.
        var token: String
    }

    /// `/gmail/v1/<path>` under the Gmail base URL, or `/upload/gmail/v1/<path>`.
    func request(_ method: String, _ path: String, query: [(String, String)] = [], upload: Bool = false) throws -> URLRequest {
        let base = endpoints.gmail.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + (upload ? "/upload" : "") + "/gmail/v1/" + path) else {
            throw GmailAPIError.server(status: 0, message: "Bad URL for \(path)")
        }
        var request = URLRequest(url: FormEncoding.url(url, query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get<T: Decodable>(_ path: String, query: [(String, String)] = [], cost: Int) async throws -> T {
        try decode(try await perform(request("GET", path, query: query), cost: cost).data)
    }

    private func send<Body: Encodable, T: Decodable>(_ method: String, _ path: String, json: Body, cost: Int,
                                                     idempotent: Bool = true) async throws -> T {
        var request = try request(method, path)
        request.httpBody = try JSONEncoder().encode(json)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try decode(try await perform(request, cost: cost, idempotent: idempotent).data)
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GmailAPIError.server(status: 200, message: "Unexpected response: \(error)")
        }
    }

    /// Sends `request` with rate limiting, auth, and retries. A non-idempotent request is retried
    /// only when Gmail refused it outright (401, 429, rate-limit 403), never after a 5xx.
    func perform(_ request: URLRequest, cost: Int, idempotent: Bool = true) async throws -> Response {
        var retries = 0
        var refreshedAuth = false
        while true {
            try Task.checkCancellation()
            try await rateLimiter.acquire(cost)
            let token = try await tokens.accessToken()
            var authorized = request
            authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let data: Data
            let http: HTTPURLResponse
            do {
                let (body, response) = try await session.data(for: authorized)
                guard let response = response as? HTTPURLResponse else {
                    throw GmailAPIError.network("Not an HTTP response")
                }
                (data, http) = (body, response)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as GmailAPIError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw GmailAPIError.network(error.localizedDescription)
            }

            switch GmailResponseDisposition(status: http.statusCode, body: data,
                                            retryAfter: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now()) {
            case .success:
                return Response(data: data, http: http, token: token)
            case .unauthorized:
                await tokens.invalidate(token)
                guard !refreshedAuth else { throw GmailAPIError.unauthorized }
                refreshedAuth = true
            case .retry(_, false, let error) where !idempotent:
                throw error
            case .retry(let retryAfter, let rateLimited, let error):
                try await backOff(retry: retries, retryAfter: retryAfter, rateLimited: rateLimited, finalError: error)
                retries += 1
            case .fail(let error):
                throw error
            }
        }
    }

    /// Sleeps before retry number `retry`, or throws `finalError` when retries are used up or the
    /// server asks for a longer pause than Tern waits in-line.
    func backOff(retry: Int, retryAfter: TimeInterval?, rateLimited: Bool, finalError: GmailAPIError) async throws {
        guard retry + 1 < options.retry.maxAttempts else { throw finalError }
        if let retryAfter, retryAfter > options.retry.maxDelay * 2 {
            await rateLimiter.pause(for: retryAfter)
            throw GmailAPIError.rateLimited(retryAfter: retryAfter)
        }
        let delay = options.retry.delay(retry: retry, retryAfter: retryAfter, random: clock.random())
        if rateLimited { await rateLimiter.pause(for: delay) }
        try await clock.sleep(delay)
    }

    /// Percent-encodes an id for a path segment.
    static func escape(_ id: String) -> String {
        FormEncoding.escape(id)
    }
}

/// What to do with one HTTP response (top-level or a batch part).
enum GmailResponseDisposition: Equatable {
    case success
    case unauthorized
    case retry(retryAfter: TimeInterval?, rateLimited: Bool, error: GmailAPIError)
    case fail(GmailAPIError)

    private struct ErrorBody: Decodable {
        struct Inner: Decodable {
            struct Reason: Decodable { var reason: String? }
            struct Detail: Decodable { var reason: String? }
            var code: Int?
            var message: String?
            var status: String?
            var errors: [Reason]?
            var details: [Detail]?
        }
        var error: Inner?
    }

    private static let rateLimitReasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded", "RATE_LIMIT_EXCEEDED"]
    private static let scopeReasons: Set<String> = ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"]

    init(status: Int, body: Data, retryAfter: String?, now: TimeInterval) {
        if (200..<300).contains(status) {
            self = .success
            return
        }
        let error = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
        let reasons = Set((error?.errors ?? []).compactMap(\.reason) + (error?.details ?? []).compactMap(\.reason))
        let message = error?.message ?? String(decoding: body.prefix(500), as: UTF8.self)
        let delay = Self.parseRetryAfter(retryAfter, now: now)

        switch status {
        case 401:
            self = .unauthorized
        case 404:
            self = .fail(.notFound)
        case 429:
            self = .retry(retryAfter: delay, rateLimited: true, error: .rateLimited(retryAfter: delay))
        case 403 where !reasons.isDisjoint(with: Self.rateLimitReasons) || error?.status == "RESOURCE_EXHAUSTED":
            self = .retry(retryAfter: delay, rateLimited: true, error: .rateLimited(retryAfter: delay))
        case 403 where reasons.contains("dailyLimitExceeded") || reasons.contains("quotaExceeded"):
            self = .fail(.rateLimited(retryAfter: delay))
        case 403 where !reasons.isDisjoint(with: Self.scopeReasons):
            // The user unticked Gmail access; signing in again fixes it.
            self = .fail(.unauthorized)
        case 500, 502, 503, 504:
            self = .retry(retryAfter: delay, rateLimited: false, error: .server(status: status, message: message))
        default:
            self = .fail(.server(status: status, message: message))
        }
    }

    /// `Retry-After` as seconds or an HTTP date.
    static func parseRetryAfter(_ value: String?, now: TimeInterval) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince1970 - now)
    }
}
