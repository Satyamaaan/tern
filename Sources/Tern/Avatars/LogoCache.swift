import CryptoKit
import Foundation
import TernCore

/// Logos on disk: one `<sha256(domain)>.png` per domain that has one, and an empty
/// `<sha256(domain)>.none` for domains that had none. File names don't reveal the domains. A file's
/// modification date is when it was last fetched: misses are retried after 14 days, logos refreshed
/// after 30. Every call touches the disk; use it off the main thread.
struct LogoCache: Sendable {
    /// What's on disk for a domain.
    enum Entry: Equatable, Sendable {
        case logo(Data, stale: Bool)
        case miss(stale: Bool)
        case unknown
    }

    static let retryMissesAfter: TimeInterval = 14 * 86_400
    static let refreshLogosAfter: TimeInterval = 30 * 86_400

    let directory: URL

    /// `directory` nil uses Application Support/Tern/Logos.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    static var defaultDirectory: URL {
        AppDatabase.defaultURL().deletingLastPathComponent().appendingPathComponent("Logos", isDirectory: true)
    }

    func lookup(_ domain: String, now: Date = Date()) -> Entry {
        if let date = modified(logoURL(domain)), let data = try? Data(contentsOf: logoURL(domain)) {
            return .logo(data, stale: now.timeIntervalSince(date) >= Self.refreshLogosAfter)
        }
        if let date = modified(missURL(domain)) {
            return .miss(stale: now.timeIntervalSince(date) >= Self.retryMissesAfter)
        }
        return .unknown
    }

    func saveLogo(_ png: Data, for domain: String) {
        guard prepareDirectory() else { return }
        try? png.write(to: logoURL(domain), options: .atomic)
        try? FileManager.default.removeItem(at: missURL(domain))
    }

    /// Records that the domain has no logo. A logo already kept stays (a failed refresh doesn't wipe it)
    /// and waits another 30 days.
    func saveMiss(for domain: String) {
        guard prepareDirectory() else { return }
        let logo = logoURL(domain)
        if FileManager.default.fileExists(atPath: logo.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: logo.path)
        } else {
            try? Data().write(to: missURL(domain), options: .atomic)
        }
    }

    func logoURL(_ domain: String) -> URL { directory.appendingPathComponent(Self.fileName(domain) + ".png") }
    func missURL(_ domain: String) -> URL { directory.appendingPathComponent(Self.fileName(domain) + ".none") }

    static func fileName(_ domain: String) -> String {
        SHA256.hash(data: Data(domain.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func prepareDirectory() -> Bool {
        (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
    }
}
