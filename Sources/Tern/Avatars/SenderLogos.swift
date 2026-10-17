import AppKit
import Observation

/// Sender pictures for list rows and the reader: the icon of the sender's own domain, cached on disk.
/// Until a logo is known, or when logos are switched off, callers draw a letter avatar.
///
/// Every call returns at once from memory; fetching happens in the background and bumps `revision`.
/// One logo per registrable domain, shared by all its senders; personal mailbox providers (Gmail,
/// iCloud…) never get one. Nothing touches the disk or network until `start()`, which only the real
/// mailbox calls: demo mail, `--check`, `--snapshot` and tests stay offline.
@MainActor
@Observable
final class SenderLogos {
    static let shared = SenderLogos()

    /// Bumps whenever a logo arrives, so views that read it redraw.
    private(set) var revision = 0

    /// Fetches running at once, at most.
    static let maxFetches = 4
    /// Domains waiting for a fetch, at most; the least recently wanted are dropped (and asked for again
    /// when their rows come back into view).
    static let maxQueued = 200
    /// How long a domain rests after a fetch failed because this Mac was offline.
    static let offlineRetry: TimeInterval = 120

    @ObservationIgnored private let isOn: @MainActor () -> Bool
    @ObservationIgnored private var cache: LogoCache?
    @ObservationIgnored private var fetcher: (any LogoFetching)?
    @ObservationIgnored private let logos = NSCache<NSString, Logo>()
    /// Domains known to have no logo (a fresh miss on disk or a fetch that found none).
    @ObservationIgnored private var misses: Set<String> = []
    /// Disk lookups in flight and domains waiting for a fetch, each with when it was last wanted.
    @ObservationIgnored private var loading: [String: Int] = [:]
    @ObservationIgnored private var queued: [String: Int] = [:]
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var restingUntil: [String: Date] = [:]
    @ObservationIgnored private var wants = 0
    @ObservationIgnored private var bumpScheduled = false

    /// `isOn` is the user's switch (Settings → Appearance); views that call `logo` follow it.
    init(isOn: @escaping @MainActor () -> Bool = { Preferences.shared.showSenderLogos }) {
        self.isOn = isOn
        logos.countLimit = 2_000
        watchSwitch()
    }

    /// Lets the instance read the disk cache and fetch. Without `fetcher` it only reads what's cached.
    func start(cache: LogoCache = LogoCache(), fetcher: (any LogoFetching)? = LogoFetcher()) {
        self.cache = cache
        self.fetcher = fetcher
    }

    /// The cached logo for this address's domain, or nil. Never waits on the network.
    func logo(forEmail email: String) -> NSImage? { entry(email)?.image }

    /// Asks for this address's logo in the background when logos are on and it isn't cached yet.
    func want(_ email: String) {
        guard let cache, isOn(), let domain = LogoDomain.forEmail(email) else { return }
        wants += 1
        if logos.object(forKey: domain as NSString) != nil || misses.contains(domain) || running[domain] != nil { return }
        if queued[domain] != nil { queued[domain] = wants; return }
        if loading[domain] != nil { loading[domain] = wants; return }
        if let until = restingUntil[domain], until > Date() { return }
        loading[domain] = wants
        Task {
            let (entry, image) = await Self.read(domain, from: cache)
            self.loaded(domain, entry, image)
        }
    }

    /// PNG bytes of the cached logo, for the reader page; nil when there is none.
    func pngData(forEmail email: String) -> Data? { entry(email)?.png }

    /// Puts a logo in memory without disk or network, for snapshots and tests.
    func install(_ png: Data, forDomain domain: String) {
        guard let image = LogoImage.decode(png) else { return }
        insert(png, image, for: domain)
    }

    // MARK: Test probes

    var queuedDomains: [String] { queued.sorted { $0.value > $1.value }.map(\.key) }
    var runningDomains: Set<String> { Set(running.keys) }
    var isStarted: Bool { cache != nil }
    /// Nothing being read from disk, waiting or fetching.
    var isIdle: Bool { loading.isEmpty && queued.isEmpty && running.isEmpty }

    // MARK: Memory

    private final class Logo {
        let image: NSImage
        let png: Data

        init(image: NSImage, png: Data) {
            self.image = image
            self.png = png
        }
    }

    private func entry(_ email: String) -> Logo? {
        _ = revision
        guard isOn(), let domain = LogoDomain.forEmail(email) else { return nil }
        return logos.object(forKey: domain as NSString)
    }

    private func insert(_ png: Data, _ image: CGImage, for domain: String) {
        let size = NSSize(width: LogoImage.side / 2, height: LogoImage.side / 2)
        logos.setObject(Logo(image: NSImage(cgImage: image, size: size), png: png), forKey: domain as NSString)
        misses.remove(domain)
        scheduleBump()
    }

    /// Many logos land together while a list scrolls; views redraw once per run-loop turn.
    private func scheduleBump() {
        guard !bumpScheduled else { return }
        bumpScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.bumpScheduled = false
                self.revision += 1
            }
        }
    }

    // MARK: Disk, then network

    private nonisolated static func read(_ domain: String, from cache: LogoCache) async -> (LogoCache.Entry, CGImage?) {
        let entry = cache.lookup(domain)
        if case .logo(let png, _) = entry { return (entry, LogoImage.decode(png)) }
        return (entry, nil)
    }

    private func loaded(_ domain: String, _ entry: LogoCache.Entry, _ image: CGImage?) {
        guard let wanted = loading.removeValue(forKey: domain) else { return }
        switch entry {
        case .logo(let png, let stale):
            if let image {
                insert(png, image, for: domain)
                // Refresh in the background, after every domain that has no logo yet.
                if stale { enqueue(domain, wanted: Int.min) }
            } else {
                enqueue(domain, wanted: wanted)
            }
        case .miss(stale: false):
            misses.insert(domain)
        case .miss(stale: true), .unknown:
            enqueue(domain, wanted: wanted)
        }
    }

    private func enqueue(_ domain: String, wanted: Int) {
        guard fetcher != nil, isOn() else { return }
        queued[domain] = wanted
        if queued.count > Self.maxQueued, let oldest = queued.min(by: { $0.value < $1.value })?.key {
            queued[oldest] = nil
        }
        pump()
    }

    /// Starts the most recently wanted domains while fewer than four fetches run.
    private func pump() {
        guard let cache, let fetcher, isOn() else {
            queued.removeAll()
            return
        }
        while running.count < Self.maxFetches, let domain = queued.max(by: { $0.value < $1.value })?.key {
            queued[domain] = nil
            running[domain] = Task {
                let (result, image) = await Self.fetch(domain, with: fetcher, into: cache)
                guard !Task.isCancelled else { return }
                self.fetched(domain, result, image)
            }
        }
    }

    private nonisolated static func fetch(_ domain: String, with fetcher: any LogoFetching,
                                          into cache: LogoCache) async -> (LogoFetchResult, CGImage?) {
        let result = await fetcher.fetch(domain)
        guard !Task.isCancelled else { return (.unavailable, nil) }
        switch result {
        case .logo(let png):
            cache.saveLogo(png, for: domain)
            return (result, LogoImage.decode(png))
        case .none:
            cache.saveMiss(for: domain)
        case .unavailable:
            break
        }
        return (result, nil)
    }

    private func fetched(_ domain: String, _ result: LogoFetchResult, _ image: CGImage?) {
        running[domain] = nil
        switch result {
        case .logo(let png):
            if let image { insert(png, image, for: domain) }
        case .none:
            if logos.object(forKey: domain as NSString) == nil { misses.insert(domain) }
        case .unavailable:
            restingUntil[domain] = Date().addingTimeInterval(Self.offlineRetry)
        }
        pump()
    }

    // MARK: The switch

    /// Follows the user's switch: turning logos off cancels fetches and drops the queue; either way
    /// views redraw (cached logos come back when it's turned on again).
    private func watchSwitch() {
        withObservationTracking { _ = isOn() } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.switchChanged() } }
        }
    }

    private func switchChanged() {
        watchSwitch()
        if !isOn() {
            queued.removeAll()
            running.values.forEach { $0.cancel() }
            running.removeAll()
        }
        revision += 1
    }
}
