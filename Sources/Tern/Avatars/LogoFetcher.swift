import Foundation
import Synchronization

/// What fetching a domain's logo found.
enum LogoFetchResult: Equatable, Sendable {
    /// The logo, already normalized to a 64×64 PNG.
    case logo(Data)
    /// The site answered (or can't be reached at all) and has no usable icon. Cached as a miss.
    case none
    /// This Mac is offline or the fetch was cancelled. Nothing is cached; try again later.
    case unavailable
}

/// Fetches one domain's logo. `SenderLogos` limits how many run at once.
protocol LogoFetching: Sendable {
    func fetch(_ domain: String) async -> LogoFetchResult
}

/// Finds a domain's icon over https with a session that carries nothing about the user: no cookies,
/// no cache, no credentials, no referrer, a plain "Tern" user agent.
///
/// Order: `/apple-touch-icon.png`, then the icons the home page declares (largest first), then
/// `/favicon.ico`. When the bare domain can't be reached at all, `www.<domain>` is tried once.
/// Each request times out after 6 s, follows at most 5 redirects (https only) and is cut off past
/// 512 KB (256 KB for the page).
final class LogoFetcher: LogoFetching {
    static let timeout: TimeInterval = 6
    static let maxRedirects = 5
    static let maxImageBytes = 512 * 1_024
    static let maxPageBytes = 256 * 1_024
    /// Page-declared icons tried, at most.
    static let maxPageIcons = 4

    private let session: URLSession

    /// `configuration` is hardened before use; tests pass one with a stub protocol.
    init(configuration: URLSessionConfiguration = .ephemeral) {
        session = URLSession(configuration: Self.harden(configuration))
    }

    static func harden(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = "Tern"
        headers["Accept-Language"] = "en"
        configuration.httpAdditionalHeaders = headers
        return configuration
    }

    func fetch(_ domain: String) async -> LogoFetchResult {
        switch await fetch(host: domain) {
        case .found(let png): return .logo(png)
        case .nothing: return .none
        case .offline: return .unavailable
        case .unreachable:
            switch await fetch(host: "www." + domain) {
            case .found(let png): return .logo(png)
            case .offline: return .unavailable
            case .nothing, .unreachable: return .none
            }
        }
    }

    // MARK: One host

    private enum HostResult {
        case found(Data)
        case nothing
        /// The host didn't answer at all (DNS, connection, TLS, timeout).
        case unreachable
        case offline
    }

    private func fetch(host: String) async -> HostResult {
        guard let root = URL(string: "https://\(host)/") else { return .nothing }
        switch await image(root.appending(path: "apple-touch-icon.png")) {
        case .found(let png): return .found(png)
        case .offline: return .offline
        case .unreachable: return .unreachable
        case .nothing: break
        }

        switch await get(root, accept: "text/html,application/xhtml+xml", limit: Self.maxPageBytes, page: true) {
        case .offline: return .offline
        case .body(let data, let response):
            let icons = LogoPageIcons.icons(in: String(decoding: data, as: UTF8.self), base: response.url ?? root)
            for url in icons.prefix(Self.maxPageIcons) {
                switch await image(url) {
                case .found(let png): return .found(png)
                case .offline: return .offline
                case .nothing, .unreachable: continue
                }
            }
        case .refused, .unreachable: break
        }

        switch await image(root.appending(path: "favicon.ico")) {
        case .found(let png): return .found(png)
        case .offline: return .offline
        case .nothing, .unreachable: return .nothing
        }
    }

    private func image(_ url: URL) async -> HostResult {
        switch await get(url, accept: "image/png,image/x-icon,image/*;q=0.8", limit: Self.maxImageBytes, page: false) {
        case .body(let data, _): LogoImage.normalized(data).map(HostResult.found) ?? .nothing
        case .refused: .nothing
        case .unreachable: .unreachable
        case .offline: .offline
        }
    }

    // MARK: One request

    private enum Response {
        case body(Data, URLResponse)
        /// An answer that isn't usable: an error status, the wrong type, too large, a refused redirect.
        case refused
        case unreachable
        case offline
    }

    private func get(_ url: URL, accept: String, limit: Int, page: Bool) async -> Response {
        guard url.scheme?.lowercased() == "https" else { return .refused }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpShouldHandleCookies = false
        request.setValue(accept, forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RequestGuard())
            let mime = response.mimeType?.lowercased() ?? ""
            let wrongType = page ? !["text/html", "application/xhtml+xml"].contains(mime) : mime == "image/svg+xml" || mime == "text/html"
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !wrongType,
                  response.expectedContentLength <= Int64(limit) else {
                bytes.task.cancel()
                return .refused
            }
            var buffer: [UInt8] = []
            buffer.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 16_384)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > limit {
                    bytes.task.cancel()
                    return .refused
                }
            }
            return .body(Data(buffer), response)
        } catch {
            return Self.classify(error)
        }
    }

    private static func classify(_ error: Error) -> Response {
        if error is CancellationError { return .offline }
        guard let error = error as? URLError else { return .refused }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .cancelled:
            return .offline
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            return .unreachable
        default:
            return .refused
        }
    }
}

/// Per-request rules: at most 5 redirects, each to https and without a Referer; no credentials offered
/// to any challenge except the server's own TLS certificate.
private final class RequestGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let redirects = Mutex(0)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        let count = redirects.withLock { count in
            count += 1
            return count
        }
        guard count <= LogoFetcher.maxRedirects, request.url?.scheme?.lowercased() == "https" else { return nil }
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Referer")
        return next
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
    }
}
