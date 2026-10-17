import Foundation
import Testing
@testable import Tern
@testable import TernCore

@Test func remoteImageURLsAreSignedByThisProcess() throws {
    let remote = "https://cdn.example/hero.png?w=600&q=80#x"
    let reader = ReaderRemoteImages.readerURL(for: remote)
    #expect(reader.hasPrefix("tern-remote://i/"))
    #expect(!reader.contains("cdn.example"))
    let url = try #require(URL(string: reader))
    #expect(ReaderRemoteImages.remoteURL(url)?.absoluteString == remote)

    // Mail that names the scheme itself has no valid signature.
    let forged = reader.replacingOccurrences(of: "tern-remote://i/", with: "tern-remote://i/00")
    #expect(ReaderRemoteImages.remoteURL(try #require(URL(string: forged))) == nil)
    let other = ReaderRemoteImages.readerURL(for: "https://evil.example/pixel.gif")
    let swapped = reader.split(separator: "/")[2] + "/" + other.split(separator: "/")[3]
    #expect(ReaderRemoteImages.remoteURL(try #require(URL(string: "tern-remote://i/" + swapped))) == nil)
    let file = ReaderRemoteImages.readerURL(for: "file:///etc/passwd")
    #expect(ReaderRemoteImages.remoteURL(try #require(URL(string: file))) == nil, "only http(s) is ever fetched")
}

@MainActor
@Test func readerPageFetchesNothingRemoteAndClipsMail() throws {
    let page = ReaderResources.page()
    let csp = try #require(page.range(of: "img-src[^;]*;", options: .regularExpression).map { String(page[$0]) })
    #expect(!csp.contains("http"), "the page itself never loads http(s); trusted images come through tern-remote:")
    let mbody = try #require(page.range(of: #"\.mbody \{[^}]*\}"#, options: .regularExpression).map { String(page[$0]) })
    #expect(mbody.contains("overflow: clip") && mbody.contains("contain: layout paint"), "mail can't draw over the reader's own header")
}
