import CryptoKit
import Foundation

/// Remote images for messages the user chose to trust. The reader page can't fetch http(s) at all (its
/// CSP and content blocker refuse it), so the sanitizer rewrites each allowed image to a
/// `tern-remote:` URL signed with a key that lives only in this process, and the scheme handler fetches
/// it. Mail can't mint such a URL itself, so a sanitizer gap in one untrusted message still can't load
/// anything, even when another message in the same thread shows its images.
enum ReaderRemoteImages {
    static let scheme = "tern-remote"
    /// Larger responses are refused.
    static let maxBytes = 20 * 1_024 * 1_024

    private static let key = SymmetricKey(size: .bits256)

    /// The URL the reader loads `remote` (an http(s) URL) through.
    static func readerURL(for remote: String) -> String {
        let encoded = Data(remote.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(scheme)://i/\(signature(remote))/\(encoded)"
    }

    /// The http(s) URL behind a reader URL, if this process signed it.
    static func remoteURL(_ url: URL) -> URL? {
        guard url.scheme == scheme else { return nil }
        let parts = url.absoluteString.dropFirst("\(scheme)://i/".count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let remote = String(data: data, encoding: .utf8),
              signature(remote) == parts[0], let result = URL(string: remote),
              let resultScheme = result.scheme?.lowercased(), resultScheme == "http" || resultScheme == "https" else { return nil }
        return result
    }

    private static func signature(_ text: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// No cookies, no stored cache, no referrer: the request carries nothing about the reader.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 32 * 1_024 * 1_024, diskCapacity: 0)
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = [
            "Accept": "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
        ]
        return URLSession(configuration: configuration)
    }()

    /// Fetches the image behind a signed reader URL. Throws for unsigned URLs, errors and non-2xx answers.
    static func load(_ url: URL) async throws -> (Data, String) {
        guard let remote = remoteURL(url) else { throw URLError(.unsupportedURL) }
        let (data, response) = try await session.data(from: remote)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
        let mimeType = response.mimeType.flatMap { $0.hasPrefix("image/") ? $0 : nil } ?? "application/octet-stream"
        return (data, mimeType)
    }
}
