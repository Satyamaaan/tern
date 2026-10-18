import AppKit
import Foundation
import Testing
@testable import Tern

// All requests go to `LogoWeb`, a stub URLProtocol; nothing here touches the network.

// MARK: - The fetcher

@Test func theTouchIconComesFirstAndRequestsCarryNothingAboutTheUser() async throws {
    let web = LogoWeb(["https://acme.example/apple-touch-icon.png": .ok(Fixture.png(), type: "image/png")])
    let result = await web.fetcher().fetch("acme.example")
    guard case .logo(let png) = result else { Issue.record("expected a logo, got \(result)"); return }
    #expect(Fixture.size(png)! == (64, 64))
    #expect(web.urls == ["https://acme.example/apple-touch-icon.png"])
    let request = try #require(web.requests.first)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "Tern")
    #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
    #expect(request.value(forHTTPHeaderField: "Referer") == nil)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func pageIconsAreTriedLargestFirstSkippingSVGAndHTTP() async {
    let page = """
    <html><head>
    <link rel="icon" type="image/svg+xml" href="/logo.svg">
    <link rel="icon" href="http://acme.example/insecure.png" sizes="512x512">
    <link rel="icon" href="/small.png" sizes="16x16">
    <link rel="icon" href="/static/big.png" sizes="192x192">
    </head></html>
    """
    let web = LogoWeb([
        "https://acme.example/": .ok(Data(page.utf8), type: "text/html; charset=utf-8"),
        "https://acme.example/static/big.png": .ok(Fixture.png(192, 192), type: "image/png"),
        "https://acme.example/small.png": .ok(Fixture.png(16, 16), type: "image/png"),
    ])
    let result = await web.fetcher().fetch("acme.example")
    #expect(result != .none && result != .unavailable)
    #expect(web.urls == ["https://acme.example/apple-touch-icon.png", "https://acme.example/", "https://acme.example/static/big.png"])
    #expect(!web.urls.contains { $0.hasSuffix(".svg") || $0.hasPrefix("http:") })
}

@Test func favicon_icoIsTheLastResortAndIsAccepted() async {
    let web = LogoWeb([
        "https://acme.example/": .ok(Data("<html><head><title>Acme</title></head></html>".utf8), type: "text/html"),
        "https://acme.example/favicon.ico": .ok(Fixture.ico([Fixture.bitmap(16, 16), Fixture.bitmap(48, 48)]), type: "image/x-icon"),
    ])
    let result = await web.fetcher().fetch("acme.example")
    guard case .logo(let png) = result else { Issue.record("expected the favicon, got \(result)"); return }
    #expect(Fixture.size(png)! == (64, 64))
    #expect(web.urls == ["https://acme.example/apple-touch-icon.png", "https://acme.example/", "https://acme.example/favicon.ico"])
}

@Test func onlyHTMLPagesAreReadForIcons() async {
    let web = LogoWeb([
        "https://acme.example/": .ok(Data(#"<link rel="icon" href="/hidden.png">"#.utf8), type: "text/plain"),
        "https://acme.example/hidden.png": .ok(Fixture.png(), type: "image/png"),
    ])
    #expect(await web.fetcher().fetch("acme.example") == .none)
    #expect(!web.urls.contains("https://acme.example/hidden.png"))
}

@Test func redirectsToHTTPAreNotFollowed() async {
    let web = LogoWeb([
        "https://acme.example/apple-touch-icon.png": .redirect("http://acme.example/apple-touch-icon.png"),
        "http://acme.example/apple-touch-icon.png": .ok(Fixture.png(), type: "image/png"),
    ])
    #expect(await web.fetcher().fetch("acme.example") == .none)
    #expect(!web.urls.contains { $0.hasPrefix("http:") }, "the http URL was never requested")
}

@Test func httpsRedirectsAreFollowedUpToFive() async {
    let followed = LogoWeb([
        "https://acme.example/apple-touch-icon.png": .redirect("https://www.acme.example/apple-touch-icon.png"),
        "https://www.acme.example/apple-touch-icon.png": .redirect("https://cdn.acme.example/touch.png"),
        "https://cdn.acme.example/touch.png": .ok(Fixture.png(), type: "image/png"),
    ])
    if case .logo = await followed.fetcher().fetch("acme.example") {} else { Issue.record("expected the redirected logo") }

    var routes: [String: LogoWeb.Answer] = ["https://loop.example/apple-touch-icon.png": .redirect("https://loop.example/r1")]
    for hop in 1...6 { routes["https://loop.example/r\(hop)"] = .redirect("https://loop.example/r\(hop + 1)") }
    routes["https://loop.example/r7"] = .ok(Fixture.png(), type: "image/png")
    let loop = LogoWeb(routes)
    #expect(await loop.fetcher().fetch("loop.example") == .none)
    #expect(!loop.urls.contains("https://loop.example/r6"), "the sixth redirect is refused")
}

@Test func oversizedResponsesAreAbandoned() async {
    let big = Fixture.png() + Data(repeating: 0, count: 600 * 1_024)
    let declared = LogoWeb([
        "https://acme.example/apple-touch-icon.png": .ok(big, type: "image/png"),
        "https://acme.example/favicon.ico": .ok(Fixture.ico([Fixture.bitmap(32, 32, fill: (10, 10, 200, 255))]), type: "image/x-icon"),
    ])
    guard case .logo(let png) = await declared.fetcher().fetch("acme.example") else { Issue.record("expected the favicon"); return }
    #expect(Fixture.pixel(png, 2, 2)[2] > 150, "the logo is the blue favicon, not the oversized touch icon")

    let streamed = LogoWeb(["https://acme.example/apple-touch-icon.png": .ok(big, type: "image/png", length: false)])
    #expect(await streamed.fetcher().fetch("acme.example") == .none, "no Content-Length: cut off at 512 KB")
}

@Test func svgIsNeverDecoded() async {
    let web = LogoWeb([
        "https://acme.example/apple-touch-icon.png": .ok(Fixture.svg, type: "image/svg+xml"),
        "https://acme.example/favicon.ico": .ok(Fixture.svg, type: "image/x-icon"),
    ])
    #expect(await web.fetcher().fetch("acme.example") == .none)
}

@Test func anUnreachableDomainTriesWWWOnce() async {
    let web = LogoWeb([
        "https://acme.example/apple-touch-icon.png": .fail(.cannotFindHost),
        "https://www.acme.example/apple-touch-icon.png": .ok(Fixture.png(), type: "image/png"),
    ])
    if case .logo = await web.fetcher().fetch("acme.example") {} else { Issue.record("expected the www logo") }
    #expect(web.urls == ["https://acme.example/apple-touch-icon.png", "https://www.acme.example/apple-touch-icon.png"])

    let dead = LogoWeb(["https://gone.example/apple-touch-icon.png": .fail(.cannotConnectToHost),
                        "https://www.gone.example/apple-touch-icon.png": .fail(.cannotFindHost)])
    #expect(await dead.fetcher().fetch("gone.example") == .none)
    #expect(dead.urls.count == 2)
}

@Test func beingOfflineCachesNothing() async {
    let web = LogoWeb(["https://acme.example/apple-touch-icon.png": .fail(.notConnectedToInternet)])
    #expect(await web.fetcher().fetch("acme.example") == .unavailable)
}

@Test func cookiesAreNeitherKeptNorSent() async {
    let web = LogoWeb([
        "https://acme.example/": .ok(Data(#"<link rel="icon" href="/i.png">"#.utf8), type: "text/html", headers: ["Set-Cookie": "id=tracker; Path=/"]),
        "https://acme.example/i.png": .ok(Fixture.png(), type: "image/png"),
    ])
    _ = await web.fetcher().fetch("acme.example")
    #expect(web.urls.last == "https://acme.example/i.png")
    #expect(web.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
}

// MARK: - SenderLogos

// Waits on the fetcher's own calls, never on a clock: four fetches begin and stay held, so nothing else can begin
// until the test lets one finish.
@MainActor
@Test(.timeLimit(.minutes(1))) func atMostFourFetchesRunAndTheMostRecentlyWantedGoesNext() async throws {
    let fetcher = GatedFetcher()
    let logos = SenderLogos(isOn: { true })
    logos.start(cache: LogoCache(directory: temporaryDirectory()), fetcher: fetcher)
    for index in 0..<10 { logos.want("news@d\(index).example") }
    await fetcher.started(count: 4)
    // The other six wait once their disk lookups (misses) are back.
    await settled { logos.queuedDomains.count == 6 }
    #expect(logos.runningDomains.count == 4 && fetcher.started.count == 4)
    #expect(Set(fetcher.started) == logos.runningDomains)

    let waiting = logos.queuedDomains
    let oldest = try #require(waiting.last)
    logos.want("other@mail.\(oldest)")
    #expect(logos.queuedDomains.first == oldest, "wanting it again puts it first")

    fetcher.release(try #require(fetcher.started.first))
    await fetcher.started(count: 5)
    #expect(fetcher.started.count == 5 && fetcher.started.last == oldest)

    fetcher.releaseAll()
    await fetcher.started(count: 10)
    await settled { logos.isIdle }
    #expect(Set(fetcher.started).count == 10 && fetcher.started.count == 10)
    #expect(fetcher.maxActive == 4)
}

@MainActor
@Test func oneFetchPerDomainForAllItsSenders() async {
    let fetcher = GatedFetcher(open: true, results: ["acme.example": .logo(LogoImage.normalized(Fixture.png())!)])
    let logos = SenderLogos(isOn: { true })
    logos.start(cache: LogoCache(directory: temporaryDirectory()), fetcher: fetcher)
    for address in ["a@acme.example", "b@mail.acme.example", "c@news.acme.example", "a@acme.example"] { logos.want(address) }
    #expect(await eventually { logos.logo(forEmail: "zed@acme.example") != nil })
    for address in ["a@acme.example", "d@eu.acme.example"] { logos.want(address) }
    #expect(await eventually { logos.isIdle })
    #expect(fetcher.started == ["acme.example"])
    #expect(logos.logo(forEmail: "b@mail.acme.example") === logos.logo(forEmail: "c@news.acme.example"))
}

@MainActor
@Test func personalAddressesAreNeverFetched() async {
    let fetcher = GatedFetcher(open: true)
    let logos = SenderLogos(isOn: { true })
    logos.start(cache: LogoCache(directory: temporaryDirectory()), fetcher: fetcher)
    for address in ["friend@gmail.com", "x@icloud.com", "y@outlook.com", "z@yahoo.co.uk", "not an address"] { logos.want(address) }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(logos.isIdle && fetcher.started.isEmpty)
}

@MainActor
@Test func missesAreRememberedForFourteenDays() async throws {
    let directory = temporaryDirectory()
    let first = GatedFetcher(open: true)
    let logos = SenderLogos(isOn: { true })
    logos.start(cache: LogoCache(directory: directory), fetcher: first)
    logos.want("hello@nologo.example")
    #expect(await eventually { first.started.count == 1 && logos.isIdle })
    logos.want("again@nologo.example")
    try? await Task.sleep(for: .milliseconds(30))
    #expect(first.started.count == 1, "this session remembers the miss")

    let cache = LogoCache(directory: directory)
    #expect(cache.lookup("nologo.example") == .miss(stale: false))
    let second = GatedFetcher(open: true)
    let relaunched = SenderLogos(isOn: { true })
    relaunched.start(cache: cache, fetcher: second)
    relaunched.want("hello@nologo.example")
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await eventually { relaunched.isIdle })
    #expect(second.started.isEmpty, "the next launch reads the miss from disk")

    try setModified(cache.missURL("nologo.example"), daysAgo: 15)
    let third = GatedFetcher(open: true)
    let later = SenderLogos(isOn: { true })
    later.start(cache: cache, fetcher: third)
    later.want("hello@nologo.example")
    #expect(await eventually { third.started == ["nologo.example"] }, "two weeks later it's tried again")
}

@MainActor
@Test func cachedLogosShowAtOnceAndOldOnesRefreshInTheBackground() async throws {
    let cache = LogoCache(directory: temporaryDirectory())
    let png = try #require(LogoImage.normalized(Fixture.png()))
    cache.saveLogo(png, for: "fresh.example")
    cache.saveLogo(png, for: "old.example")
    try setModified(cache.logoURL("old.example"), daysAgo: 31)

    let fetcher = GatedFetcher()
    let logos = SenderLogos(isOn: { true })
    logos.start(cache: cache, fetcher: fetcher)
    let before = logos.revision
    logos.want("a@fresh.example")
    logos.want("b@old.example")
    #expect(await eventually { logos.logo(forEmail: "a@fresh.example") != nil && logos.logo(forEmail: "b@old.example") != nil })
    #expect(logos.pngData(forEmail: "a@fresh.example") == png)
    #expect(await eventually { logos.revision > before })
    #expect(await eventually { fetcher.started == ["old.example"] }, "only the 31-day-old logo is fetched again")
    fetcher.releaseAll()
    #expect(await eventually { logos.isIdle })
    #expect(logos.logo(forEmail: "b@old.example") != nil, "a refresh that finds nothing keeps the old logo")
}

@MainActor
@Test func theSwitchHidesLogosAndStopsFetching() async throws {
    let toggle = LogoSwitch()
    let fetcher = GatedFetcher(results: ["acme.example": .logo(try #require(LogoImage.normalized(Fixture.png())))])
    let logos = SenderLogos(isOn: { toggle.isOn })
    logos.start(cache: LogoCache(directory: temporaryDirectory()), fetcher: fetcher)
    logos.want("a@acme.example")
    logos.want("b@slow.example")
    #expect(await eventually { logos.runningDomains.count == 2 })
    fetcher.release("acme.example")
    #expect(await eventually { logos.logo(forEmail: "a@acme.example") != nil })

    let before = logos.revision
    toggle.isOn = false
    #expect(await eventually { logos.revision > before }, "views redraw when the switch changes")
    #expect(logos.logo(forEmail: "a@acme.example") == nil && logos.pngData(forEmail: "a@acme.example") == nil)
    #expect(logos.runningDomains.isEmpty, "running fetches are cancelled")
    logos.want("c@new.example")
    try? await Task.sleep(for: .milliseconds(30))
    #expect(!fetcher.started.contains("new.example"))

    toggle.isOn = true
    #expect(await eventually { logos.logo(forEmail: "a@acme.example") != nil }, "cached logos come back")
    fetcher.releaseAll()
}

@MainActor
@Test func aLogoTravelsFromTheWebToDiskAndScreen() async throws {
    let web = LogoWeb(["https://acme.example/apple-touch-icon.png": .ok(Fixture.png(), type: "image/png")])
    let cache = LogoCache(directory: temporaryDirectory())
    let logos = SenderLogos(isOn: { true })
    logos.start(cache: cache, fetcher: web.fetcher())
    logos.want("receipts@mail.acme.example")
    logos.want("team@acme.example")
    #expect(await eventually { logos.logo(forEmail: "team@acme.example") != nil })
    let png = try #require(logos.pngData(forEmail: "receipts@mail.acme.example"))
    #expect(Fixture.size(png)! == (64, 64))
    #expect(cache.lookup("acme.example") == .logo(png, stale: false))
    #expect(web.urls == ["https://acme.example/apple-touch-icon.png"])
}

@MainActor
@Test func theSharedInstanceStaysOfflineUntilTheRealMailboxStartsIt() {
    #expect(!SenderLogos.shared.isStarted)
    SenderLogos.shared.want("someone@acme.example")
    #expect(SenderLogos.shared.isIdle)
}
