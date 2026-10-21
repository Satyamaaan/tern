import AppKit
import CryptoKit
import Observation
import TernCore

/// The Google profile photos of the signed-in accounts, for their avatars (title bar, scope menu,
/// sidebar, From menu). Kept on disk as `<sha256(account id)>.img` in Application Support/Tern/AccountPhotos,
/// so launch shows them without the network; refreshed in the background once a week.
///
/// Every read returns at once from memory and bumps nothing; arrivals bump `revision`. Nothing touches
/// the disk or network until `start()`, which only the real mailbox calls.
@MainActor
@Observable
final class AccountPhotos {
    static let shared = AccountPhotos()

    /// Bumps whenever a photo arrives or goes, so views that read one redraw.
    private(set) var revision = 0

    static let refreshAfter: TimeInterval = 7 * 86_400
    /// Photos larger than this are refused (Google serves a few kilobytes).
    static let maxBytes = 1_000_000

    @ObservationIgnored private var photos: [String: NSImage] = [:]
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var fetching: Set<String> = []

    /// The account's photo, or nil while there is none (callers draw initials).
    func photo(for accountId: String) -> NSImage? {
        _ = revision
        return photos[accountId.lowercased()]
    }

    /// Lets the instance use the disk and network, and reads the kept photos of these accounts off the
    /// main thread.
    func start(accountIds: [String], directory: URL = AccountPhotos.defaultDirectory) {
        self.directory = directory
        let ids = accountIds.map { $0.lowercased() }
        Task.detached(priority: .utility) {
            let found = ids.compactMap { id -> (String, Data)? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.fileName(id) + ".img")) else { return nil }
                return (id, data)
            }
            await MainActor.run {
                for (id, data) in found where self.photos[id] == nil {
                    if let image = NSImage(data: data) { self.photos[id] = image }
                }
                if !found.isEmpty { self.revision += 1 }
            }
        }
    }

    /// Whether the account's photo is missing or older than a week.
    nonisolated static func isStale(_ accountId: String, in directory: URL, now: Date = Date()) -> Bool {
        let url = directory.appendingPathComponent(fileName(accountId) + ".img")
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return true }
        return now.timeIntervalSince(date) >= refreshAfter
    }

    /// Downloads the photo at `url` (from the account's Google profile) and keeps it. Nil, or a profile
    /// without a photo, leaves what's there.
    func refresh(_ accountId: String, pictureURL url: URL?) {
        let id = accountId.lowercased()
        guard let directory, let url = url.flatMap(Self.sized), !fetching.contains(id) else { return }
        fetching.insert(id)
        Task.detached(priority: .utility) {
            let data = try? await Self.download(url)
            if let data {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appendingPathComponent(Self.fileName(id) + ".img"), options: .atomic)
            }
            await MainActor.run {
                self.fetching.remove(id)
                if let data, let image = NSImage(data: data) { self.set(image, for: id) }
            }
        }
    }

    /// Forgets a removed account's photo, on disk too.
    func remove(_ accountId: String) {
        let id = accountId.lowercased()
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.fileName(id) + ".img")) }
        guard photos.removeValue(forKey: id) != nil else { return }
        revision += 1
    }

    /// For offscreen renders: a photo drawn by the caller, kept in memory only.
    func install(_ image: NSImage, for accountId: String) {
        set(image, for: accountId.lowercased())
    }

    nonisolated static var defaultDirectory: URL {
        AppDatabase.defaultURL().deletingLastPathComponent().appendingPathComponent("AccountPhotos", isDirectory: true)
    }

    // MARK: Private

    private func set(_ image: NSImage, for id: String) {
        photos[id] = image
        revision += 1
    }

    nonisolated static func fileName(_ accountId: String) -> String {
        SHA256.hash(data: Data(accountId.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Google photo URLs end in a size (`=s96-c`): ask for one sharp at 2x for the largest avatar. Only
    /// Google's own image hosts over HTTPS are fetched.
    nonisolated static func sized(_ url: URL) -> URL? {
        guard url.scheme == "https", let host = url.host?.lowercased(), host.hasSuffix(".googleusercontent.com") else { return nil }
        var text = url.absoluteString
        if let range = text.range(of: #"=s\d+(-c)?$"#, options: .regularExpression) {
            text.replaceSubrange(range, with: "=s96-c")
        } else if !text.contains("=") {
            text += "=s96-c"
        }
        return URL(string: text)
    }

    private nonisolated static func download(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maxBytes, NSImage(data: data) != nil else { return nil }
        return data
    }
}
