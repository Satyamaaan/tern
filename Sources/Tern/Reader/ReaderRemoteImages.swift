import CryptoKit
import Foundation

/// Remote images in mail. The reader page can't fetch http(s) at all (its CSP and content blocker refuse it), so
/// the sanitizer rewrites each allowed image to a `tern-remote:` URL signed with a key that lives only in this
/// process, and the scheme handler fetches it through `RemoteImageFetcher`. Mail can't mint such a URL itself, so
/// a sanitizer gap in a message whose images are blocked still can't load anything, even when another message in
/// the same thread shows its images.
enum ReaderRemoteImages {
    static let scheme = "tern-remote"
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

    /// The reader's one fetcher, caching in ~/Library/Caches/Tern/RemoteImages.
    static let fetcher = RemoteImageFetcher(cacheDirectory: cacheDirectory, allowLoopback: allowsLoopback)

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tern", isDirectory: true).appendingPathComponent("RemoteImages", isDirectory: true)
    }

    /// Loopback is refused, except for the snapshot harness's local image server in debug builds
    /// (`TERN_READER_SNAPSHOT`); release builds never allow it.
    static var allowsLoopback: Bool {
        #if DEBUG
        !(ProcessInfo.processInfo.environment["TERN_READER_SNAPSHOT"] ?? "").isEmpty
        #else
        false
        #endif
    }

    /// Fetches the image behind a signed reader URL. Throws for unsigned URLs, refused destinations, errors,
    /// non-2xx answers, anything over the size limit and anything that isn't an image.
    static func load(_ url: URL) async throws -> (Data, String) {
        guard let remote = remoteURL(url) else { throw URLError(.unsupportedURL) }
        return try await fetcher.image(at: remote)
    }
}
