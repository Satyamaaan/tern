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
