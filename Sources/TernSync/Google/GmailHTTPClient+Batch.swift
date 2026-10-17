import Foundation

extension GmailHTTPClient {
    /// users.messages.get for many ids through the batch endpoint: up to `batchSize` ids per batch,
    /// `maxConcurrentBatches` batches in flight, each paced by the rate limiter. Sub-requests that
    /// fail with 429, a rate-limit 403 or 5xx are retried in a smaller batch after a backoff; ids
    /// that answer 404 (deleted) or 400 (not a valid id) are left out. The result keeps the order of
    /// `ids`, without duplicates.
    ///
    /// A batch that still fails after its retries fails the whole call and its finished batches are
    /// dropped, so pass a few hundred ids at a time. With the 2026 quota (6,000 units a minute,
    /// 20 per metadata get, 60 per full get) 150 ids in metadata format use about half a minute of quota.
    public func messages(ids: [String], format: GmailMessageFormat) async throws -> [GmailMessage] {
        try await batchGet(ids, cost: GmailQuotaCost.messagesGet(format), id: \GmailMessage.id) { id in
            "/gmail/v1/users/me/messages/\(Self.escape(id))?format=\(format.rawValue)"
        }
    }

    /// users.threads.get for many ids, through the same batch machinery as `messages(ids:format:)`:
    /// 40 units a thread, 120 with `format=full`. threads.get has no raw format; `.raw` asks for full.
    public func threads(ids: [String], format: GmailMessageFormat) async throws -> [GmailThread] {
        let format = format == .raw ? .full : format
        return try await batchGet(ids, cost: GmailQuotaCost.threadsGet(format), id: \GmailThread.id) { id in
            "/gmail/v1/users/me/threads/\(Self.escape(id))?format=\(format.rawValue)"
        }
    }

    /// GETs `path(id)` for every id in concurrent batches; see `messages(ids:format:)`.
    func batchGet<Item: Decodable>(_ ids: [String], cost: Int, id: KeyPath<Item, String>,
                                   path: @escaping @Sendable (String) -> String) async throws -> [Item] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return [] }
        let chunks = stride(from: 0, to: unique.count, by: options.batchSize).map {
            Array(unique[$0..<min($0 + options.batchSize, unique.count)])
        }

        var found: [String: Item] = [:]
        try await withThrowingTaskGroup(of: [Item].self) { group in
            var next = 0
            func startNext() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]
                next += 1
                group.addTask { try await self.fetchBatch(chunk, cost: cost, path: path) }
            }
            for _ in 0..<options.maxConcurrentBatches { startNext() }
            while let items = try await group.next() {
                for item in items { found[item[keyPath: id]] = item }
                startNext()
            }
        }
        return unique.compactMap { found[$0] }
    }

    /// One batch of GETs, with sub-request retries.
    func fetchBatch<Item: Decodable>(_ ids: [String], cost: Int, path: (String) -> String) async throws -> [Item] {
        var pending = ids
        var found: [Item] = []
        var retries = 0
        var refreshedAuth = false

        while !pending.isEmpty {
            let paths = pending.map(path)
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
                await tokens.invalidate(response.token)
                guard !refreshedAuth else { throw GmailAPIError.unauthorized }
                refreshedAuth = true
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
