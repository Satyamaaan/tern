import AppKit
import Foundation
import Testing
@testable import Tern

// MARK: - Domains

@Test func addressesReduceToTheRegisteredDomain() {
    #expect(LogoDomain.forEmail("no_reply@mail.notifications.apple.com") == "apple.com")
    #expect(LogoDomain.forEmail("billing@stripe.com") == "stripe.com")
    #expect(LogoDomain.forEmail("  <News@Email.Figma.COM.> ") == "figma.com")
    #expect(LogoDomain.forEmail("orders@shop.marks.co.uk") == "marks.co.uk")
    #expect(LogoDomain.forEmail("hello@team.canva.com.au") == "canva.com.au")
    #expect(LogoDomain.forEmail("alerts@hdfcbank.co.in") == "hdfcbank.co.in")
    #expect(LogoDomain.forEmail("info@news.rakuten.co.jp") == "rakuten.co.jp")
    #expect(LogoDomain.forEmail("a@b.nubank.com.br") == "nubank.com.br")
    #expect(LogoDomain.forEmail("x@trademe.co.nz") == "trademe.co.nz")
    #expect(LogoDomain.forEmail("x@grab.com.sg") == "grab.com.sg")
    #expect(LogoDomain.forEmail("x@cs.ox.ac.uk") == "ox.ac.uk")
    #expect(LogoDomain.forEmail("x@lists.wikimedia.org.uk") == "wikimedia.org.uk")
    #expect(LogoDomain.forEmail("x@accounts.google.com") == "google.com", "Google itself still has a logo; only gmail.com is personal")
    #expect(LogoDomain.forEmail("x@xn--80ak6aa92e.com") == "xn--80ak6aa92e.com")
}

@Test func oddAddressesHaveNoDomain() {
    for address in ["", "nobody", "x@", "x@localhost", "x@192.168.1.10", "x@co.uk", "x@-bad.com", "x@a..com",
                    "x@exämple.com", "x@example.c", "x@example.123"] {
        #expect(LogoDomain.forEmail(address) == nil, "\(address)")
    }
}

@Test func personalMailboxProvidersGetInitials() {
    for address in ["friend@gmail.com", "a@googlemail.com", "a@outlook.com", "a@hotmail.com", "a@hotmail.co.uk", "a@live.fr",
                    "a@msn.com", "a@yahoo.com", "a@yahoo.co.jp", "a@mail.yahoo.com", "a@ymail.com", "a@icloud.com", "a@me.com",
                    "a@mac.com", "a@aol.com", "a@proton.me", "a@protonmail.com", "a@pm.me", "a@gmx.de", "a@gmx.net", "a@web.de",
                    "a@zoho.com", "a@yandex.ru", "a@yandex.com", "a@mail.ru", "a@fastmail.com", "a@hey.com", "a@qq.com",
                    "a@163.com", "a@126.com", "a@naver.com", "a@rediffmail.com", "a@tutanota.com", "a@duck.com",
                    "abc123@privaterelay.appleid.com", "a@mozmail.com", "a@outlook.jp"] {
        #expect(LogoDomain.forEmail(address) == nil, "\(address)")
    }
}

// MARK: - Page icons

@Test func pageIconsResolveAndPreferTheLargest() throws {
    let html = """
    <!doctype html><html><head>
    <link rel="stylesheet" href="/site.css">
    <link rel="shortcut icon" href="/favicon-16.png">
    <LINK REL=icon sizes="32x32" HREF='/img/fav-32.png'>
    <link rel="icon" type="image/png" sizes="16x16 192x192" href="icons/big.png?v=2&amp;x=1">
    <link rel="apple-touch-icon" href="https://cdn.example.net/touch.png">
    <link rel="icon" type="image/svg+xml" href="/logo.svg">
    <link rel="icon" href="/vector.svg">
    <link rel="mask-icon" href="/mask.png">
    <link rel="icon" href="http://acme.example/insecure.png" sizes="512x512">
    <link rel="icon" href="data:image/png;base64,AAAA" sizes="256x256">
    <!-- <link rel="icon" sizes="999x999" href="/commented.png"> -->
    </head><body><link rel="icon" sizes="900x900" href="/in-body.png"></body></html>
    """
    let icons = LogoPageIcons.icons(in: html, base: try #require(URL(string: "https://www.acme.example/home/")))
    #expect(icons.map(\.absoluteString) == [
        "https://www.acme.example/home/icons/big.png?v=2&x=1",
        "https://cdn.example.net/touch.png",
        "https://www.acme.example/img/fav-32.png",
        "https://www.acme.example/favicon-16.png",
    ])
}

@Test func pageIconsFollowBaseHrefAndProtocolRelativeLinks() throws {
    let html = #"<head><base href="https://static.acme.example/assets/"><link rel="icon" href="i.png"><link rel="apple-touch-icon-precomposed" href="//img.acme.example/t.png" sizes="120x120"></head>"#
    let icons = LogoPageIcons.icons(in: html, base: try #require(URL(string: "https://acme.example/")))
    #expect(icons.map(\.absoluteString) == ["https://img.acme.example/t.png", "https://static.acme.example/assets/i.png"])
    #expect(LogoPageIcons.icons(in: "<p>no icons here</p>", base: try #require(URL(string: "https://acme.example/"))).isEmpty)
}

// MARK: - Images

@Test func bitmapIconsBecomeA64PixelPNG() throws {
    for (name, data) in [
        ("png", Fixture.png(180, 180)),
        ("jpeg", Fixture.encode([Fixture.bitmap(48, 48)], as: .jpeg)),
        ("gif", Fixture.encode([Fixture.bitmap(32, 32)], as: .gif)),
        ("ico", Fixture.ico([Fixture.bitmap(16, 16), Fixture.bitmap(32, 32)])),
        ("bmp", Fixture.encode([Fixture.bitmap(16, 16)], as: .bmp)),
    ] {
        let png = try #require(LogoImage.normalized(data), "\(name)")
        #expect(Fixture.size(png)! == (64, 64), "\(name)")
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(name) is stored as PNG")
    }
}

@Test func icoPicksTheRepresentationThatScalesBest() throws {
    let small = Fixture.bitmap(16, 16, fill: (220, 20, 20, 255), mark: nil)
    let large = Fixture.bitmap(128, 128, fill: (20, 20, 220, 255), mark: (255, 255, 255, 255))
    let huge = Fixture.bitmap(256, 256, fill: (20, 200, 20, 255), mark: (255, 255, 255, 255))
    let png = try #require(LogoImage.normalized(Fixture.ico([small, huge, large])))
    let corner = Fixture.pixel(png, 2, 2)
    #expect(corner[2] > 150 && corner[0] < 80 && corner[1] < 80, "the 128 px blue icon: the smallest one at least 64 px")
}

@Test func nonBitmapsAndEmptyPicturesAreRefused() {
    let refused: [(String, Data)] = [
        ("svg", Fixture.svg),
        ("svg with leading whitespace", Data("\n  ".utf8) + Fixture.svg),
        ("html", Data("<!doctype html><html><body>404</body></html>".utf8)),
        ("garbage", Data((0..<400).map { UInt8($0 % 251) })),
        ("1×1", Fixture.png(1, 1)),
        ("8×8", Fixture.png(8, 8)),
        ("fully transparent", Fixture.png(64, 64, fill: (0, 0, 0, 0), mark: nil)),
        ("one colour", Fixture.png(64, 64, fill: (255, 255, 255, 255), mark: nil)),
        ("banner", Fixture.png(400, 40)),
        ("tiff", Fixture.encode([Fixture.bitmap(64, 64)], as: .tiff)),
        ("pdf", pdf()),
    ]
    for (name, data) in refused {
        #expect(LogoImage.normalized(data) == nil, "\(name)")
    }
}

@Test func wideIconsKeepTheirShapeCentredOnTransparent() throws {
    let png = try #require(LogoImage.normalized(Fixture.png(64, 32, fill: (200, 30, 30, 255), mark: (255, 255, 255, 255))))
    #expect(Fixture.pixel(png, 32, 2)[3] == 0, "transparent band above")
    #expect(Fixture.pixel(png, 32, 61)[3] == 0, "transparent band below")
    #expect(Fixture.pixel(png, 2, 32)[3] == 255, "the icon fills the middle")
}

private func pdf() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 64, height: 64)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 8, y: 8, width: 30, height: 30))
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

// MARK: - Disk cache

@Test func cacheKeepsLogosAndMissesUnderHashedNames() throws {
    let cache = LogoCache(directory: temporaryDirectory())
    #expect(cache.lookup("acme.example") == .unknown)

    let png = Fixture.png()
    cache.saveLogo(png, for: "acme.example")
    #expect(cache.lookup("acme.example") == .logo(png, stale: false))
    let names = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
    #expect(names == [LogoCache.fileName("acme.example") + ".png"])
    #expect(!names.joined().contains("acme"), "file names don't reveal who mails you")

    try setModified(cache.logoURL("acme.example"), daysAgo: 29)
    #expect(cache.lookup("acme.example") == .logo(png, stale: false))
    try setModified(cache.logoURL("acme.example"), daysAgo: 31)
    #expect(cache.lookup("acme.example") == .logo(png, stale: true), "logos refresh after 30 days")

    cache.saveMiss(for: "acme.example")
    #expect(cache.lookup("acme.example") == .logo(png, stale: false), "a failed refresh keeps the logo for another 30 days")

    cache.saveMiss(for: "nothing.example")
    #expect(cache.lookup("nothing.example") == .miss(stale: false))
    try setModified(cache.missURL("nothing.example"), daysAgo: 13)
    #expect(cache.lookup("nothing.example") == .miss(stale: false))
    try setModified(cache.missURL("nothing.example"), daysAgo: 15)
    #expect(cache.lookup("nothing.example") == .miss(stale: true), "misses are retried after 14 days")

    cache.saveLogo(png, for: "nothing.example")
    #expect(cache.lookup("nothing.example") == .logo(png, stale: false))
    #expect(!FileManager.default.fileExists(atPath: cache.missURL("nothing.example").path), "a found logo clears the miss")
}

@Test func theDefaultCacheLivesInApplicationSupport() {
    let path = LogoCache().directory.path
    #expect(path.hasSuffix("Application Support/Tern/Logos"))
}
