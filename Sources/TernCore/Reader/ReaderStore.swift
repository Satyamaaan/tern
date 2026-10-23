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

/// Delivers the current thread synchronously, then follows its database changes. Main thread only.
@MainActor
public final class ThreadDetailObserver {
    private let store: MailStore
    private let source = DetailObservationSource()
    private var cancellable: AnyDatabaseCancellable?
    private var readTask: Task<Void, Never>?
    private var onChange: (ThreadDetail?) -> Void
    private var observedGeneration = -1

    /// The first value arrives before `init` returns. Failed reads and observations retry.
    public init(store: MailStore, key: ThreadKey, onChange: @escaping (ThreadDetail?) -> Void) {
        self.store = store
        self.onChange = onChange
        follow(key, onChange: onChange)
        let source = source
        // Cancellation cannot release an initial WAL snapshot waiting for the writer. Retarget
        // this observation instead of starting one per thread, including after suspend/resume.
        cancellable = ValueObservation
            .tracking(regions: DetailObservationSource.regions) { db in try source.current.fetch(db) }
            .removeDuplicates()
            .startRestarting(in: store.database.reader, scheduling: .async(onQueue: .main),
                onError: { NSLog("Tern: thread observation failed, restarting it: \($0)") }) { [weak self] value in
                    MainActor.assumeIsolated { self?.receive(value, fromObservation: true) }
                }
    }

    /// Changes the open thread without starting another observation. The first detail arrives at once.
    public func follow(_ key: ThreadKey, onChange: @escaping (ThreadDetail?) -> Void) {
        self.onChange = onChange
        let request = source.set(key)
        readTask?.cancel()
        do { receive(try store.database.reader.read { try request.fetch($0) }) }
        catch {
            Self.log(error)
            retryRead(request)
        }
    }

    /// Stops fetching while the reader is off screen, keeping its single observation for reuse.
    public func pause() {
        _ = source.set(nil)
        readTask?.cancel()
        readTask = nil
        onChange = { _ in }
    }

    /// Ends observation and any pending retries. Use `pause` when the reader will return.
    public func cancel() {
        pause()
        cancellable?.cancel()
        cancellable = nil
    }

    private func receive(_ value: DetailObservationSource.Value, fromObservation: Bool = false) {
        guard source.current == value.request, value.request.key != nil else { return }
        if fromObservation { observedGeneration = value.request.generation }
        else if observedGeneration >= value.request.generation { return }
        onChange(value.detail)
    }

    private func retryRead(_ request: DetailObservationSource.Request) {
        let reader = store.database.reader
        readTask = Task { [weak self] in
            var delay = 0.25
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard self?.source.current == request else { return }
                do {
                    let value = try await reader.read { try request.fetch($0) }
                    self?.receive(value)
                    return
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    Self.log(error)
                    delay = min(30, delay * 2)
                }
            }
        }
    }

    private static func log(_ error: Error) { NSLog("Tern: thread read failed, retrying it: \(error)") }

    deinit {
        readTask?.cancel()
        cancellable?.cancel()
    }
}
