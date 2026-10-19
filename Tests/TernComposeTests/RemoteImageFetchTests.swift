import Foundation
import Testing
@testable import Tern
@testable import TernCore

/// Answers image requests from a table instead of the network and records every URL asked for.
private final class ImageServer: URLProtocol {
    struct Answer {
        var status = 200
        var headers: [String: String] = ["Content-Type": "image/png"]
        var body = Data()
    }

    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    static let lock = NSLock()

    static func reset(_ table: [String: Answer]) {
        lock.withLock {
            answers = table
            requests = []
        }
    }

    static var asked: [String] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let answer = Self.lock.withLock {
            Self.requests.append(url.absoluteString)
            return Self.answers[url.absoluteString] ?? Answer(status: 404, headers: [:])
        }
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

    override func stopLoading() {}
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
