import Foundation
import Testing
import WebKit
@testable import Tern
@testable import TernCore

/// Answers image requests from a table instead of the network, records every URL asked for, and how many requests
/// were open at once, overall and per host.
private final class ImageServer: URLProtocol {
    struct Answer {
        var status = 200
        var headers: [String: String] = ["Content-Type": "image/png"]
        var body = Data()
        /// Seconds before answering.
        var delay = 0.0
    }

    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    nonisolated(unsafe) static var open: [String: Int] = [:]
    nonisolated(unsafe) static var mostOpen = 0
    nonisolated(unsafe) static var mostOpenToOneHost = 0
    static let lock = NSLock()
    private var stopped = false

    static func reset(_ table: [String: Answer]) {
        lock.withLock {
            answers = table
            requests = []
            open = [:]
            mostOpen = 0
            mostOpenToOneHost = 0
        }
    }

    static var asked: [String] { lock.withLock { requests } }
    static var peaks: (total: Int, perHost: Int) { lock.withLock { (mostOpen, mostOpenToOneHost) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let host = url.host ?? ""
        let reply = Self.lock.withLock {
            Self.requests.append(url.absoluteString)
            Self.open[host, default: 0] += 1
            Self.mostOpen = max(Self.mostOpen, Self.open.values.reduce(0, +))
            Self.mostOpenToOneHost = max(Self.mostOpenToOneHost, Self.open[host] ?? 0)
            return Self.answers[url.absoluteString] ?? Answer(status: 404, headers: [:])
        }
        guard reply.delay > 0 else { return send(reply, url) }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
            guard let self, !Self.lock.withLock({ self.stopped }) else { return }
            self.send(reply, url)
        }
    }

    private func send(_ answer: Answer, _ url: URL) {
        Self.lock.withLock { Self.open[url.host ?? "", default: 1] -= 1 }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        if (300..<400).contains(answer.status), let location = answer.headers["Location"], let next = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { Self.lock.withLock { stopped = true } }
}

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 1, count: 600)
private let publicAddress = RemoteDestination.Address.v4(0x5DB8_D822)

/// A fetcher on the table above; every name resolves to `addresses`.
private func fetcher(_ directory: URL? = nil, maxBytes: Int = 20 * 1_024 * 1_024,
                     addresses: [String: [RemoteDestination.Address]] = [:]) -> RemoteImageFetcher {
    RemoteImageFetcher(cacheDirectory: directory, maxBytes: maxBytes, protocolClasses: [ImageServer.self]) { host in
        addresses[host] ?? [publicAddress]
    }
}

/// DNS answers in turn, one per lookup; the last one repeats.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[RemoteDestination.Address]?]
    private(set) var lookups = 0
    init(_ answers: [[RemoteDestination.Address]?]) { queue = answers }

    func next() -> [RemoteDestination.Address]? {
        lock.withLock {
            lookups += 1
            return queue.count > 1 ? queue.removeFirst() : queue.first ?? nil
        }
    }
}

private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("tern-images-\(UUID().uuidString)", isDirectory: true)
}

private func failure(_ work: () async throws -> (Data, String)) async -> (any Error)? {
    do { _ = try await work(); return nil } catch { return error }
}

// One server table for the whole file, so these run one at a time.
@Suite(.serialized) struct RemoteImageFetchTests {
    @Test func imagesComeBackFromDiskTheSecondTime() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logo = "https://res.cloudinary.com/acme/image/upload/v1/emails/logo.png"
        ImageServer.reset([logo: .init(headers: ["Content-Type": "image/png", "Cache-Control": "no-cache"], body: png)])

        let first = fetcher(directory)
        defer { first.invalidate() }
        let (data, type) = try await first.image(at: try #require(URL(string: logo)))
        #expect(data == png && type == "image/png")
        #expect(ImageServer.asked == [logo])

        // A fetcher made later, as after a relaunch, paints it from the cache folder without asking again.
        var stored = false
        for _ in 0..<40 where !stored {
            stored = URLCache(memoryCapacity: 0, diskCapacity: 200 << 20, directory: directory)
                .cachedResponse(for: URLRequest(url: try #require(URL(string: logo))))?.data == png
            if !stored { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(stored, "written to disk")
        let second = fetcher(directory)
        defer { second.invalidate() }
        let again = try await second.image(at: try #require(URL(string: logo)))
        #expect(again.0 == png && again.1 == "image/png")
        #expect(ImageServer.asked == [logo], "served from disk")
    }

    @Test func failuresAndNoStoreAreNotCached() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = "https://cdn.example.com/missing.png"
        let page = "https://cdn.example.com/page.png"
        let live = "https://cdn.example.com/countdown.gif"
        ImageServer.reset([
            missing: .init(status: 404),
            page: .init(headers: ["Content-Type": "image/png"], body: Data("<html><body>Not here</body></html>".utf8)),
            live: .init(headers: ["Content-Type": "image/gif", "Cache-Control": "no-store"], body: Data("GIF89a".utf8) + png),
        ])
        let images = fetcher(directory)
        defer { images.invalidate() }
        #expect(await failure { try await images.image(at: URL(string: missing)!) } as? RemoteImageFetcher.Failure == .status(404))
        #expect(await failure { try await images.image(at: URL(string: page)!) } as? RemoteImageFetcher.Failure == .notAnImage)
        #expect(try await images.image(at: URL(string: live)!).1 == "image/gif")

        ImageServer.reset([missing: .init(body: png), live: .init(headers: ["Content-Type": "image/gif"], body: Data("GIF89a".utf8))])
        #expect(try await images.image(at: URL(string: missing)!).0 == png, "a 404 earlier doesn't stick")
        _ = try await images.image(at: URL(string: live)!)
        #expect(ImageServer.asked == [missing, live], "no-store and failed answers are fetched again")
    }

    @Test func refusesLocalDestinationsBeforeAnyRequest() async throws {
        ImageServer.reset([:])
        let images = fetcher(addresses: ["cdn.example.com": [publicAddress], "intranet.acme.com": [.v4(0x0A00_0005)],
                                         "mixed.acme.com": [publicAddress, .v4(0x7F00_0001)], "gone.acme.com": []])
        defer { images.invalidate() }
        for url in ["http://192.168.1.1/a.png", "http://3232235777/a.png", "http://[::ffff:10.0.0.1]/a.png",
                    "http://localhost/a.png", "http://cdn.example.com:8080/a.png", "https://intranet.acme.com/a.png",
                    "https://mixed.acme.com/a.png", "https://gone.acme.com/a.png", "http://127.0.0.1:18766/hero.png"] {
            #expect(await failure { try await images.image(at: URL(string: url)!) } as? RemoteImageFetcher.Failure == .refused, "\(url)")
        }
        #expect(ImageServer.asked.isEmpty, "nothing was requested")
    }

    @Test func refusesRedirectsToLocalPlaces() async throws {
        let start = "https://cdn.example.com/r"
        ImageServer.reset([
            start: .init(status: 302, headers: ["Location": "http://10.0.0.1/admin.png"]),
            "https://cdn.example.com/named": .init(status: 301, headers: ["Location": "https://intranet.acme.com/a.png"]),
            "https://cdn.example.com/file": .init(status: 302, headers: ["Location": "file:///etc/passwd"]),
            "https://cdn.example.com/ok": .init(status: 302, headers: ["Location": "https://images.example.com/logo.png"]),
            "https://images.example.com/logo.png": .init(body: png),
        ] .merging((0..<7).map { ("https://cdn.example.com/loop\($0)", ImageServer.Answer(status: 302, headers: ["Location": "https://cdn.example.com/loop\($0 + 1)"])) }) { $1 })
        let images = fetcher(addresses: ["intranet.acme.com": [.v4(0xC0A8_0001)]])
        defer { images.invalidate() }
        for url in [start, "https://cdn.example.com/named", "https://cdn.example.com/file", "https://cdn.example.com/loop0"] {
            #expect(await failure { try await images.image(at: URL(string: url)!) } != nil, "\(url)")
        }
        #expect(!ImageServer.asked.contains { $0.contains("10.0.0.1") || $0.contains("intranet") || $0.hasPrefix("file:") })
        #expect(!ImageServer.asked.contains("https://cdn.example.com/loop6"), "at most five redirects")
        #expect(try await images.image(at: URL(string: "https://cdn.example.com/ok")!).0 == png, "public redirects are followed")
    }

    @Test func refusesOversizedAnswers() async throws {
        let big = "https://cdn.example.com/big.png"
        ImageServer.reset([big: .init(body: png + Data(repeating: 0, count: 5_000))])
        let images = fetcher(maxBytes: 2_000)
        defer { images.invalidate() }
        #expect(await failure { try await images.image(at: URL(string: big)!) } as? RemoteImageFetcher.Failure == .tooBig)
    }

    @Test func namesGoOverHTTPSAndAddressesAsWritten() async throws {
        ImageServer.reset([
            "https://cdn.example.com/logo.png": .init(body: png),
            "https://cdn.example.com/logo.png?w=2": .init(body: png),
            "http://93.184.216.34/x.png": .init(body: png),
            "https://cdn.example.com/r": .init(status: 302, headers: ["Location": "http://images.example.com/a.png"]),
            "https://images.example.com/a.png": .init(body: png),
        ])
        let images = fetcher()
        defer { images.invalidate() }
        #expect(try await images.image(at: URL(string: "http://cdn.example.com/logo.png")!).0 == png)
        #expect(try await images.image(at: URL(string: "http://CDN.example.com:80/logo.png?w=2")!).0 == png)
        #expect(try await images.image(at: URL(string: "http://93.184.216.34/x.png")!).0 == png, "no DNS, nothing to rebind")
        #expect(try await images.image(at: URL(string: "https://cdn.example.com/r")!).0 == png, "an http redirect to a name is upgraded")
        #expect(ImageServer.asked == ["https://cdn.example.com/logo.png", "https://cdn.example.com/logo.png?w=2",
                                      "http://93.184.216.34/x.png", "https://cdn.example.com/r", "https://images.example.com/a.png"])
        for url in ["https://cdn.example.com:80/x.png", "http://cdn.example.com:443/x.png"] {
            #expect(await failure { try await images.image(at: URL(string: url)!) } as? RemoteImageFetcher.Failure == .refused, "\(url)")
        }
        #expect(RemoteDestination.requestURL(for: URL(string: "http://cdn.example.com/a%20b.png?q=%2F#f")!)?.absoluteString
            == "https://cdn.example.com/a%20b.png?q=%2F#f", "the rest of the URL stays as it was written")
    }

    @Test func lookupsAreNeverRemembered() async throws {
        ImageServer.reset(["https://cdn.example.com/a.png": .init(body: png)])
        let url = URL(string: "https://cdn.example.com/a.png")!

        // Offline (or just woken): refused now, fetched once DNS answers again.
        let offline = Answers([nil, [], [publicAddress]])
        let waking = RemoteImageFetcher(cacheDirectory: nil, protocolClasses: [ImageServer.self]) { _ in offline.next() }
        defer { waking.invalidate() }
        #expect(await failure { try await waking.image(at: url) } as? RemoteImageFetcher.Failure == .refused)
        #expect(await failure { try await waking.image(at: url) } as? RemoteImageFetcher.Failure == .refused)
        #expect(try await waking.image(at: url).0 == png)

        // A public answer doesn't outlive itself: the name moving to a private address is caught on the next fetch.
        let rebinding = Answers([[publicAddress], [.v4(0xC0A8_0001)]])
        let moved = RemoteImageFetcher(cacheDirectory: nil, protocolClasses: [ImageServer.self]) { _ in rebinding.next() }
        defer { moved.invalidate() }
        #expect(try await moved.image(at: url).0 == png)
        #expect(await failure { try await moved.image(at: url) } as? RemoteImageFetcher.Failure == .refused)
        #expect(offline.lookups == 3 && rebinding.lookups == 2)
    }

    @Test func oneFetchForEveryImageAskingAtOnce() async throws {
        let logo = URL(string: "https://cdn.example.com/logo.png")!
        ImageServer.reset([logo.absoluteString: .init(body: png, delay: 0.3)])
        let images = fetcher()
        defer { images.invalidate() }
        async let first = images.image(at: logo)
        async let second = images.image(at: URL(string: "http://cdn.example.com/logo.png")!)
        let results = try await [first, second]
        #expect(results.allSatisfy { $0.0 == png })
        #expect(ImageServer.asked == [logo.absoluteString])

        // One of them stops asking (its message closed): the other still gets the image from the same fetch.
        ImageServer.reset([logo.absoluteString: .init(body: png, delay: 0.3)])
        let leaving = Task { try await images.image(at: logo) }
        let staying = Task { try await images.image(at: logo) }
        try await Task.sleep(for: .milliseconds(100))
        leaving.cancel()
        #expect(try await staying.value.0 == png)
        #expect(ImageServer.asked == [logo.absoluteString])

        // When every caller stops, the fetch stops, and the next one starts fresh.
        ImageServer.reset([logo.absoluteString: .init(body: png, delay: 0.3)])
        let alone = Task { try await images.image(at: logo) }
        try await Task.sleep(for: .milliseconds(100))
        alone.cancel()
        #expect(await failure { try await alone.value } != nil)
        #expect(try await images.image(at: logo).0 == png)
        #expect(ImageServer.asked == [logo.absoluteString, logo.absoluteString])
    }

    @Test func fetchesTakeTurns() async throws {
        let urls = (0..<3).flatMap { host in (0..<7).map { "https://cdn\(host).example.com/\($0).png" } }
        ImageServer.reset(Dictionary(uniqueKeysWithValues: urls.map { ($0, ImageServer.Answer(body: png, delay: 0.15)) }))
        let images = fetcher()
        defer { images.invalidate() }
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for url in urls { group.addTask { try await images.image(at: URL(string: url)!).0 } }
            return try await group.reduce(into: [Data]()) { $0.append($1) }
        }
        #expect(results.count == urls.count && results.allSatisfy { $0 == png }, "all of them arrive, none timed out in a queue")
        let peaks = ImageServer.peaks
        #expect(peaks.total <= RemoteImageFetcher.concurrent && peaks.perHost <= RemoteImageFetcher.perHost, "\(peaks)")
        #expect(peaks.perHost == RemoteImageFetcher.perHost, "and they do run side by side")
    }

    @Test func readsTheImageTypeFromTheBytes() {
        func type(_ bytes: [UInt8], _ declared: String? = "application/octet-stream") -> String? {
            RemoteImageFetcher.imageType(Data(bytes) + Data(repeating: 0, count: 16), declared: declared)
        }
        #expect(type([0xFF, 0xD8, 0xFF, 0xE0]) == "image/jpeg")
        #expect(type(Array("GIF89a".utf8)) == "image/gif")
        #expect(type(Array("RIFF".utf8) + [1, 2, 3, 4] + Array("WEBP".utf8)) == "image/webp")
        #expect(type([0, 0, 0, 0x1C] + Array("ftypavif".utf8)) == "image/avif")
        #expect(type(Array("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)) == "image/svg+xml")
        #expect(type(Array("<?xml version='1.0'?><svg/>".utf8)) == "image/svg+xml")
        #expect(type(Array("<!doctype html><svg></svg>".utf8), "image/svg+xml") == "image/svg+xml")
        #expect(type(Array("<!doctype html><svg></svg>".utf8), "text/html") == nil, "an HTML page isn't an image")
        #expect(type(Array("{\"ok\":true}".utf8), "image/png") == nil, "nor is anything that only claims to be")
    }
}

/// A scheme task that records what it was told.
private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var events: [String] = []
    init(_ url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { events.append("response") }
    func didReceive(_ data: Data) { events.append("data") }
    func didFinish() { events.append("finish") }
    func didFailWithError(_ error: any Error) { events.append("fail") }
}

@MainActor
@Test func aStoppedImageHearsNothingMoreWhileItsFailureIsMarked() async throws {
    let handler = ReaderSchemeHandler()
    let webView = WKWebView(frame: .zero)
    var marking: [() -> Void] = []
    handler.markFailed = { _, done in marking.append(done) }
    handler.loadRemote = { _ in throw URLError(.cannotFindHost) }
    let url = try #require(URL(string: ReaderRemoteImages.readerURL(for: "https://cdn.example.com/gone.png")))
    func waitForMarking(_ count: Int) async {
        for _ in 0..<200 where marking.count < count { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // WebKit stops the load (the message closed) while the page marks the image: the late failure isn't delivered.
    let stopped = RecordingSchemeTask(url)
    handler.webView(webView, start: stopped)
    await waitForMarking(1)
    handler.webView(webView, stop: stopped)
    marking.forEach { $0() }
    #expect(marking.count == 1 && stopped.events.isEmpty)

    // Otherwise the image is marked first and then fails.
    let failing = RecordingSchemeTask(url)
    handler.webView(webView, start: failing)
    await waitForMarking(2)
    #expect(failing.events.isEmpty, "nothing before the page has marked it")
    marking[1]()
    #expect(failing.events == ["fail"])

    // An image that arrives is answered and never marked.
    handler.loadRemote = { _ in (Data([1, 2, 3]), "image/png") }
    let arriving = RecordingSchemeTask(url)
    handler.webView(webView, start: arriving)
    for _ in 0..<200 where arriving.events.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(arriving.events == ["response", "data", "finish"] && marking.count == 2)
}

@Test func theImageCacheStaysOutOfBackups() throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let prepared = ReaderRemoteImages.prepared(directory)
    #expect(try prepared.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}
