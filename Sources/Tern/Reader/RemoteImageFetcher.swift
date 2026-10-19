import Foundation
import TernCore

/// Fetches mail images for the reader the way a browser that shares nothing would: no cookies, credentials or
/// referrer; public destinations only (`RemoteDestination`), checked for the URL, every redirect and the addresses a
/// name resolves to before connecting, and names over HTTPS only; images only, at most `maxBytes`. An image that
/// arrives goes to an on-disk cache, so a reopened message paints it at once without asking the sender again;
/// failures are never cached. A URL is fetched once for every image asking for it at the time, and fetches take
/// turns (`FetchGate`), so the last images of a long newsletter don't time out queued behind its first ones.
final class RemoteImageFetcher: NSObject, @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// Not a public destination, or a redirect to one that isn't.
        case refused
        case status(Int)
        case tooBig
        case notAnImage
    }

    /// At most this many fetches run at once, and at most `perHost` to one host; the rest wait their turn before
    /// their timeouts start.
    static let concurrent = 8
    static let perHost = 4

    let maxBytes: Int
    let maxRedirects = 5
    let cache: URLCache?
    private let allowLoopback: Bool
    private let resolve: @Sendable (String) async -> [RemoteDestination.Address]?
    private var session: URLSession!
    private let gate = FetchGate(total: RemoteImageFetcher.concurrent, perHost: RemoteImageFetcher.perHost)
    private let lock = NSLock()
    private var loads: [Int: Load] = [:]
    private var flights: [URL: Flight] = [:]

    private final class Load {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
        var data = Data()
        var response: HTTPURLResponse?
        var failure: Failure?
        var redirects = 0
        init(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) { self.continuation = continuation }
    }

    /// One fetch, shared by every caller asking for its URL while it runs; it stops once they have all stopped asking.
    private final class Flight: @unchecked Sendable {
        var task: Task<(Data, String), any Error>?
        var callers = 1
    }

    /// `cacheDirectory` nil keeps nothing on disk. Tests pass `protocolClasses` and `resolve` to stand in for
    /// the network.
    init(cacheDirectory: URL?, allowLoopback: Bool = false, maxBytes: Int = 20 * 1_024 * 1_024,
         protocolClasses: [AnyClass]? = nil,
         resolve: @escaping @Sendable (String) async -> [RemoteDestination.Address]? = { await RemoteDestination.resolve($0) }) {
        cache = cacheDirectory.map { URLCache(memoryCapacity: 32 * 1_024 * 1_024, diskCapacity: 200 * 1_024 * 1_024, directory: $0) }
        self.allowLoopback = allowLoopback
        self.maxBytes = maxBytes
        self.resolve = resolve
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        // The cache is kept by hand, below: only images that arrived whole, whatever the response's headers say.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = [
            "Accept": "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
        ]
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// Ends the session; the fetcher can't be used afterwards. The app's one fetcher lives as long as the app.
    func invalidate() { session.invalidateAndCancel() }

    /// The image at `remote` and its MIME type, from the cache or the network. A name is asked for over HTTPS.
    func image(at remote: URL) async throws -> (Data, String) {
        guard let target = RemoteDestination.requestURL(for: remote, allowLoopback: allowLoopback) else { throw Failure.refused }
        if let cached = cache?.cachedResponse(for: URLRequest(url: target)),
           let type = Self.imageType(cached.data, declared: cached.response.mimeType) {
            return (cached.data, type)
        }
        let flight = lock.withLock { () -> Flight in
            if let flight = flights[target] {
                flight.callers += 1
                return flight
            }
            let flight = Flight()
            flights[target] = flight
            flight.task = Task { [weak self] in
                defer { self?.land(flight, target) }
                guard let self else { throw CancellationError() }
                return try await self.load(target)
            }
            return flight
        }
        let task = lock.withLock { flight.task }
        return try await withTaskCancellationHandler {
            guard let task else { throw CancellationError() }
            return try await task.value
        } onCancel: {
            self.abandon(flight, target)
        }
    }

    /// The fetch is over: the next caller starts a new one (or reads the cache).
    private func land(_ flight: Flight, _ target: URL) {
        lock.withLock { if flights[target] === flight { flights[target] = nil } }
    }

    /// A caller stopped asking; when it was the last one, the fetch stops too.
    private func abandon(_ flight: Flight, _ target: URL) {
        let task = lock.withLock { () -> Task<(Data, String), any Error>? in
            flight.callers -= 1
            guard flight.callers == 0 else { return nil }
            if flights[target] === flight { flights[target] = nil }
            return flight.task
        }
        task?.cancel()
    }

    /// Waits its turn, checks where the name resolves, fetches, and keeps a complete image on disk.
    private func load(_ target: URL) async throws -> (Data, String) {
        let host = RemoteDestination.host(of: target) ?? ""
        try await gate.enter(host)
        defer { gate.leave(host) }
        guard await resolvesPublicly(target) else { throw Failure.refused }
        let request = URLRequest(url: target)
        let (data, response) = try await fetch(request)
        guard let type = Self.imageType(data, declared: response.mimeType) else { throw Failure.notAnImage }
        let noStore = response.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") == true
        if let cache, !noStore, let stored = HTTPURLResponse(url: target, statusCode: 200, httpVersion: "HTTP/1.1",
                                                             headerFields: ["Content-Type": type, "Content-Length": String(data.count)]) {
            cache.storeCachedResponse(CachedURLResponse(response: stored, data: data, userInfo: nil, storagePolicy: .allowed), for: request)
        }
        return (data, type)
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { loads[task.taskIdentifier] = Load(continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Literal addresses were judged by `RemoteDestination`; a name must resolve, and only to public addresses.
    /// Nothing is remembered: a lookup that failed (offline, just woken) mustn't refuse the host afterwards, and a
    /// public answer mustn't outlive its DNS record. Repeated lookups are answered by the system's own DNS cache.
    private func resolvesPublicly(_ url: URL) async -> Bool {
        guard let host = RemoteDestination.host(of: url) else { return false }
        if RemoteDestination.literal(host) != nil { return true }
        guard let addresses = await resolve(host), !addresses.isEmpty else { return false }
        return addresses.allSatisfy(RemoteDestination.isPublic)
    }

    private func fail(_ task: URLSessionTask, _ failure: Failure) {
        lock.withLock { loads[task.taskIdentifier]?.failure = failure }
        task.cancel()
    }

    /// The MIME type WebKit should decode `data` as, from its first bytes; SVG also needs its declared type or
    /// an `<svg` at the start. Nil when it isn't an image.
    static func imageType(_ data: Data, declared: String?) -> String? {
        let head = [UInt8](data.prefix(32))
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return "image/gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "image/webp" }
        if starts([0x42, 0x4D]) { return "image/bmp" }
        if starts([0x00, 0x00, 0x01, 0x00]) || starts([0x00, 0x00, 0x02, 0x00]) { return "image/x-icon" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if starts([0xFF, 0x0A]) || starts([0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20]) { return "image/jxl" }
        if starts(Array("ftyp".utf8), at: 4), head.count >= 12 {
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            if brand == "avif" || brand == "avis" { return "image/avif" }
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) { return "image/heic" }
        }
        let text = String(decoding: data.prefix(1_024), as: UTF8.self).lowercased()
        let trimmed = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        if trimmed.hasPrefix("<svg") || ((trimmed.hasPrefix("<?xml") || declared?.lowercased() == "image/svg+xml") && text.contains("<svg")) {
            return "image/svg+xml"
        }
        return nil
    }
}

extension RemoteImageFetcher: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let count = lock.withLock { () -> Int in
            loads[task.taskIdentifier]?.redirects += 1
            return loads[task.taskIdentifier]?.redirects ?? .max
        }
        guard count <= maxRedirects, let url = request.url,
              let next = RemoteDestination.requestURL(for: url, allowLoopback: allowLoopback) else {
            fail(task, .refused)
            completionHandler(nil)
            return
        }
        // A redirect to a name over http goes over HTTPS instead, like any other request for a name.
        var upgraded = request
        upgraded.url = next
        Task {
            if await resolvesPublicly(next) {
                completionHandler(upgraded)
            } else {
                fail(task, .refused)
                completionHandler(nil)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            lock.withLock { loads[dataTask.taskIdentifier]?.failure = .status((response as? HTTPURLResponse)?.statusCode ?? 0) }
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength <= maxBytes else {
            lock.withLock { loads[dataTask.taskIdentifier]?.failure = .tooBig }
            completionHandler(.cancel)
            return
        }
        lock.withLock { loads[dataTask.taskIdentifier]?.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooBig = lock.withLock { () -> Bool in
            guard let load = loads[dataTask.taskIdentifier] else { return false }
            load.data.append(data)
            return load.data.count > maxBytes
        }
        if tooBig { fail(dataTask, .tooBig) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Server trust is checked as usual; no password or client certificate ever goes out with a mail image.
        let trust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        completionHandler(trust ? .performDefaultHandling : .rejectProtectionSpace, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let load = lock.withLock({ loads.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = load.failure {
            load.continuation.resume(throwing: failure)
        } else if let error {
            load.continuation.resume(throwing: error)
        } else if let response = load.response {
            load.continuation.resume(returning: (load.data, response))
        } else {
            load.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

/// Lets at most `total` fetches run at once, and at most `perHost` to one host; the others wait in order of arrival.
/// A waiter whose task is cancelled leaves the line.
private final class FetchGate: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let host: String
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let total: Int
    private let perHost: Int
    private let lock = NSLock()
    private var running = 0
    private var runningByHost: [String: Int] = [:]
    private var waiting: [Waiter] = []
    private var lastId: UInt64 = 0

    init(total: Int, perHost: Int) {
        self.total = total
        self.perHost = perHost
    }

    func enter(_ host: String) async throws {
        let id = lock.withLock { () -> UInt64 in
            lastId += 1
            return lastId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let admitted = lock.withLock { () -> Bool? in
                    if Task.isCancelled { return nil }
                    if canRun(host) {
                        admit(host)
                        return true
                    }
                    waiting.append(Waiter(id: id, host: host, continuation: continuation))
                    return false
                }
                switch admitted {
                case .none: continuation.resume(throwing: CancellationError())
                case .some(true): continuation.resume()
                case .some(false): break
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> Waiter? in
                guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func leave(_ host: String) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            running -= 1
            runningByHost[host, default: 1] -= 1
            if runningByHost[host] == 0 { runningByHost[host] = nil }
            var ready: [CheckedContinuation<Void, any Error>] = []
            var index = 0
            while index < waiting.count, running < total {
                if canRun(waiting[index].host) {
                    let waiter = waiting.remove(at: index)
                    admit(waiter.host)
                    ready.append(waiter.continuation)
                } else {
                    index += 1
                }
            }
            return ready
        }
        ready.forEach { $0.resume() }
    }

    /// Call with the lock held.
    private func canRun(_ host: String) -> Bool { running < total && runningByHost[host, default: 0] < perHost }

    /// Call with the lock held.
    private func admit(_ host: String) {
        running += 1
        runningByHost[host, default: 0] += 1
    }
}
