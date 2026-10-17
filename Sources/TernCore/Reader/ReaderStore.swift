import Foundation
import GRDB

/// Reader settings and live thread reads, so the app doesn't need GRDB.
extension MailStore {
    /// Settings key prefix for senders whose remote images load automatically.
    public static let imageAllowPrefix = "images.allow."

    /// Lowercased addresses whose remote images the user chose to load.
    public func imageAllowedSenders() throws -> Set<String> {
        try database.reader.read { db in
            let keys = try String.fetchAll(
                db, sql: "SELECT key FROM setting WHERE key LIKE ? ESCAPE '\\'",
                arguments: [Self.imageAllowPrefix.replacingOccurrences(of: "_", with: "\\_") + "%"])
            return Set(keys.map { String($0.dropFirst(Self.imageAllowPrefix.count)) })
        }
    }

    public func setImagesAllowed(_ allowed: Bool, sender: String) throws {
        try setSetting(Self.imageAllowPrefix + sender.lowercased(), allowed ? "1" : nil)
    }
}

/// Delivers a thread's detail now and again whenever its rows change. Main thread only.
public final class ThreadDetailObserver {
    private var cancellable: AnyDatabaseCancellable?

    /// The first value arrives synchronously, before `init` returns, so a cached thread draws in the same frame.
    public init(store: MailStore, key: ThreadKey, onChange: @escaping (ThreadDetail?) -> Void) {
        cancellable = store.observeThreadDetail(key).start(
            in: store.database.reader, scheduling: .immediate,
            onError: { _ in }, onChange: onChange)
    }

    public func cancel() {
        cancellable?.cancel()
        cancellable = nil
    }

    deinit { cancellable?.cancel() }
}
