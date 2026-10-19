import Foundation
import TernCore

/// Fetches mail images for the reader the way a browser that shares nothing would: no cookies, credentials or
/// referrer; public destinations only (`RemoteDestination`), checked for the URL, every redirect and, best
/// effort, the addresses the host resolves to before connecting; images only, at most `maxBytes`. An image
/// that arrives goes to an on-disk cache, so a reopened message paints it at once without asking the sender
/// again; failures are never cached.
///
/// The resolution check can't pin the address the connection then uses, so a DNS answer that changes in
/// between could still reach a private address on port 80 or 443; the port rule keeps everything else out.
final class RemoteImageFetcher: NSObject, @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// Not a public http(s) destination, or a redirect to one that isn't.
        case refused
        case status(Int)
        case tooBig
        case notAnImage
    }

    let maxBytes: Int
    let maxRedirects = 5
    let cache: URLCache?
    private let allowLoopback: Bool
    private let resolve: @Sendable (String) async -> [RemoteDestination.Address]?
    private var session: URLSession!
    private let lock = NSLock()
    private var loads: [Int: Load] = [:]
    /// Hosts already resolved, with whether every address was public, for a few minutes.
    private var verdicts: [String: (isPublic: Bool, until: Date)] = [:]

    private final class Load {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
        var data = Data()
        var response: HTTPURLResponse?
        var failure: Failure?
        var redirects = 0
        init(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) { self.continuation = continuation }
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

    /// The image at `remote` and its MIME type, from the cache or the network.
    func image(at remote: URL) async throws -> (Data, String) {
        guard RemoteDestination.allows(remote, allowLoopback: allowLoopback) else { throw Failure.refused }
        let request = URLRequest(url: remote)
        if let cached = cache?.cachedResponse(for: request), let type = Self.imageType(cached.data, declared: cached.response.mimeType) {
            return (cached.data, type)
        }
        guard await resolvesPublicly(remote) else { throw Failure.refused }
        let (data, response) = try await fetch(request)
        guard let type = Self.imageType(data, declared: response.mimeType) else { throw Failure.notAnImage }
        let noStore = response.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") == true
        if let cache, !noStore, let stored = HTTPURLResponse(url: remote, statusCode: 200, httpVersion: "HTTP/1.1",
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

    /// Literal addresses were judged by `RemoteDestination.allows`; names must resolve to public addresses only.
    private func resolvesPublicly(_ url: URL) async -> Bool {
        guard let host = RemoteDestination.host(of: url) else { return false }
        if RemoteDestination.literal(host) != nil { return true }
        let now = Date()
        if let verdict = lock.withLock({ verdicts[host] }), verdict.until > now { return verdict.isPublic }
        let addresses = await resolve(host) ?? []
        let isPublic = !addresses.isEmpty && addresses.allSatisfy(RemoteDestination.isPublic)
        lock.withLock { verdicts[host] = (isPublic, now.addingTimeInterval(300)) }
        return isPublic
    }

    private func load(_ task: URLSessionTask) -> Load? { lock.withLock { loads[task.taskIdentifier] } }

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
        guard count <= maxRedirects, let url = request.url, RemoteDestination.allows(url, allowLoopback: allowLoopback) else {
            fail(task, .refused)
            completionHandler(nil)
            return
        }
        Task {
            if await resolvesPublicly(url) {
                completionHandler(request)
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
