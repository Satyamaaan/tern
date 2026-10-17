import AppKit
import Foundation
import ImageIO
import Observation
import Synchronization
import UniformTypeIdentifiers
@testable import Tern

// MARK: - A fake web

/// A fake internet for logo fetches, one per test: its session tags every request with an
/// `X-Logo-Web` header that `LogoWebProtocol` uses to find it. Every request is answered here; none
/// leaves the machine.
final class LogoWeb: Sendable {
    enum Answer: Sendable {
        case ok(Data, type: String?, length: Bool = true, headers: [String: String] = [:])
        case status(Int)
        case redirect(String)
        case fail(URLError.Code)
    }

    let id = UUID().uuidString
    private let state: Mutex<(routes: [String: Answer], requests: [URLRequest])>

    init(_ routes: [String: Answer]) {
        state = Mutex((routes, []))
        LogoWebProtocol.webs.withLock { $0[id] = self }
    }

    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogoWebProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Logo-Web": id]
        return configuration
    }

    func fetcher() -> LogoFetcher { LogoFetcher(configuration: configuration) }

    /// Every request made, in order.
    var requests: [URLRequest] { state.withLock { $0.requests } }
    var urls: [String] { requests.compactMap { $0.url?.absoluteString } }

    /// Unknown URLs answer 404.
    func answer(_ request: URLRequest) -> Answer {
        state.withLock { state in
            state.requests.append(request)
            return state.routes[request.url?.absoluteString ?? ""] ?? .status(404)
        }
    }
}

final class LogoWebProtocol: URLProtocol, @unchecked Sendable {
    static let webs = Mutex<[String: LogoWeb]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Logo-Web"), let web = Self.webs.withLock({ $0[id] }),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch web.answer(request) {
        case .ok(let body, let type, let length, let extra):
            var headers = extra
            if let type { headers["Content-Type"] = type }
            if length { headers["Content-Length"] = "\(body.count)" }
            respond(url, 200, headers, body)
        case .status(let code):
            respond(url, code, ["Content-Type": "text/html"], Data("<html>nope</html>".utf8))
        case .redirect(let location):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            var next = URLRequest(url: URL(string: location)!)
            next.setValue(id, forHTTPHeaderField: "X-Logo-Web")
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    private func respond(_ url: URL, _ status: Int, _ headers: [String: String], _ body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - A fetcher the test drives

/// Fetches nothing: each call waits until the test releases its domain, then returns the domain's
/// planned result (`.none` unless set). Records how many ran at once.
final class GatedFetcher: LogoFetching {
    private struct State {
        var started: [String] = []
        var active = 0
        var maxActive = 0
        var open = false
        var released: Set<String> = []
        var waiting: [String: CheckedContinuation<Void, Never>] = [:]
        var results: [String: LogoFetchResult] = [:]
    }

    private let state = Mutex(State())

    init(open: Bool = false, results: [String: LogoFetchResult] = [:]) {
        state.withLock {
            $0.open = open
            $0.results = results
        }
    }

    var started: [String] { state.withLock { $0.started } }
    var maxActive: Int { state.withLock { $0.maxActive } }

    func fetch(_ domain: String) async -> LogoFetchResult {
        state.withLock { state in
            state.started.append(domain)
            state.active += 1
            state.maxActive = max(state.maxActive, state.active)
        }
        await withCheckedContinuation { continuation in
            let go = state.withLock { state -> Bool in
                if state.open || state.released.contains(domain) { return true }
                state.waiting[domain] = continuation
                return false
            }
            if go { continuation.resume() }
        }
        return state.withLock { state in
            state.active -= 1
            return state.results[domain] ?? .none
        }
    }

    func release(_ domain: String) {
        let continuation = state.withLock { state in
            state.released.insert(domain)
            return state.waiting.removeValue(forKey: domain)
        }
        continuation?.resume()
    }

    func releaseAll() {
        let all = state.withLock { state in
            state.open = true
            defer { state.waiting.removeAll() }
            return Array(state.waiting.values)
        }
        all.forEach { $0.resume() }
    }
}

/// The user's switch, observable like `Preferences`.
@MainActor
@Observable
final class LogoSwitch {
    var isOn = true
}

// MARK: - Helpers

@MainActor
func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tern-logos-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func setModified(_ url: URL, daysAgo: Double) throws {
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
}

enum Fixture {
    /// A `width`×`height` bitmap: `fill` everywhere, with a `mark` square in the middle.
    static func bitmap(_ width: Int, _ height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (200, 30, 30, 255),
                       mark: (UInt8, UInt8, UInt8, UInt8)? = (255, 255, 255, 255)) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let inMark = mark != nil && abs(x - width / 2) < max(1, width / 6) && abs(y - height / 2) < max(1, height / 6)
                let color = inMark ? mark! : fill
                let alpha = Double(color.3) / 255
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(Double(color.0) * alpha)
                pixels[offset + 1] = UInt8(Double(color.1) * alpha)
                pixels[offset + 2] = UInt8(Double(color.2) * alpha)
                pixels[offset + 3] = color.3
            }
        }
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    static func encode(_ images: [CGImage], as type: UTType) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)!
        images.forEach { CGImageDestinationAddImage(destination, $0, nil) }
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func png(_ width: Int = 180, _ height: Int = 180, fill: (UInt8, UInt8, UInt8, UInt8) = (200, 30, 30, 255),
                    mark: (UInt8, UInt8, UInt8, UInt8)? = (255, 255, 255, 255)) -> Data {
        encode([bitmap(width, height, fill: fill, mark: mark)], as: .png)
    }

    /// A Windows icon file holding PNG images (the format favicon.ico uses since Vista).
    static func ico(_ images: [CGImage]) -> Data {
        let pngs = images.map { encode([$0], as: .png) }
        var data = Data()
        func u16(_ value: Int) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
        func u32(_ value: Int) { u16(value & 0xFFFF); u16(value >> 16) }
        u16(0); u16(1); u16(images.count)
        var offset = 6 + 16 * images.count
        for (image, png) in zip(images, pngs) {
            data.append(contentsOf: [UInt8(image.width >= 256 ? 0 : image.width), UInt8(image.height >= 256 ? 0 : image.height), 0, 0])
            u16(1); u16(32); u32(png.count); u32(offset)
            offset += png.count
        }
        pngs.forEach { data.append($0) }
        return data
    }

    static let svg = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="red"/></svg>"#.utf8)

    /// RGBA (premultiplied) of the pixel at (x, y), counted from the top left.
    static func pixel(_ png: Data, _ x: Int, _ y: Int) -> [UInt8] {
        let image = LogoImage.decode(png)!
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (y * image.width + x) * 4
        return Array(pixels[offset..<offset + 4])
    }

    static func size(_ png: Data) -> (Int, Int)? {
        LogoImage.decode(png).map { ($0.width, $0.height) }
    }
}
