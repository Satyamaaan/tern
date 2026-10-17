import Foundation

extension GmailHTTPClient {
    /// users.messages.get for many ids through the batch endpoint: up to `batchSize` ids per batch,
    /// `maxConcurrentBatches` batches in flight, each paced by the rate limiter. Sub-requests that
    /// fail with 429, a rate-limit 403 or 5xx are retried in a smaller batch after a backoff; ids
    /// that answer 404 (deleted) or 400 (not a valid id) are left out. The result keeps the order of
    /// `ids`, without duplicates.
    public func messages(ids: [String], format: GmailMessageFormat) async throws -> [GmailMessage] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return [] }
        let chunks = stride(from: 0, to: unique.count, by: options.batchSize).map {
            Array(unique[$0..<min($0 + options.batchSize, unique.count)])
        }

        var found: [String: GmailMessage] = [:]
        try await withThrowingTaskGroup(of: [GmailMessage].self) { group in
            var next = 0
            func startNext() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]
                next += 1
                group.addTask { try await self.fetchBatch(chunk, format: format) }
            }
            for _ in 0..<options.maxConcurrentBatches { startNext() }
            while let messages = try await group.next() {
                for message in messages { found[message.id] = message }
                startNext()
            }
        }
        return unique.compactMap { found[$0] }
    }

    /// One batch of messages.get, with sub-request retries.
    func fetchBatch(_ ids: [String], format: GmailMessageFormat) async throws -> [GmailMessage] {
        var pending = ids
        var found: [GmailMessage] = []
        var retries = 0
        var refreshedAuth = false
        let cost = GmailQuota.messagesGet(format)

        while !pending.isEmpty {
            let paths = pending.map { "/gmail/v1/users/me/messages/\(Self.escape($0))?format=\(format.rawValue)" }
            let boundary = "tern-batch-\(UUID().uuidString)"
            var request = try batchRequest()
            request.httpBody = GmailBatch.body(paths: paths, boundary: boundary)
            request.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let response = try await perform(request, cost: cost * pending.count)

            guard let responseBoundary = GmailBatch.boundary(fromContentType: response.http.value(forHTTPHeaderField: "Content-Type")) else {
                throw GmailAPIError.server(status: response.http.statusCode, message: "Batch response is not multipart")
            }
            var parts: [Int: GmailBatch.Part] = [:]
            for part in try GmailBatch.parse(response.data, boundary: responseBoundary) {
                if let index = GmailBatch.index(of: part) { parts[index] = part }
            }

            var retry: [String] = []
            var retryAfter: TimeInterval?
            var rateLimited = false
            var serverFailed = false
            var unauthorized = false
            var lastError = GmailAPIError.server(status: 0, message: "Batch part missing")
            for (index, id) in pending.enumerated() {
                guard let part = parts[index] else {
                    retry.append(id)
                    continue
                }
                switch GmailResponseDisposition(status: part.status, body: part.body,
                                                retryAfter: part.header("Retry-After"), now: clock.now()) {
                case .success:
                    found.append(try decode(part.body))
                case .fail(.notFound), .fail(.server(status: 400, message: _)):
                    continue
                case .fail(let error):
                    throw error
                case .unauthorized:
                    unauthorized = true
                    retry.append(id)
                case .retry(let after, let limited, let error):
                    retry.append(id)
                    serverFailed = true
                    rateLimited = rateLimited || limited
                    if let after { retryAfter = max(retryAfter ?? 0, after) }
                    lastError = error
                }
            }
            pending = retry
            guard !pending.isEmpty else { break }

            if unauthorized {
                guard !refreshedAuth else { throw GmailAPIError.unauthorized }
                refreshedAuth = true
                await tokens.invalidate(response.token)
                // A rejected token is not a server fault: no backoff unless something else failed too.
                if !serverFailed { continue }
            }
            try await backOff(retry: retries, retryAfter: retryAfter, rateLimited: rateLimited,
                              finalError: rateLimited ? .rateLimited(retryAfter: retryAfter) : lastError)
            retries += 1
        }
        return found
    }

    private func batchRequest() throws -> URLRequest {
        let base = endpoints.gmail.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/batch/gmail/v1") else {
            throw GmailAPIError.server(status: 0, message: "Bad batch URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        return request
    }
}
