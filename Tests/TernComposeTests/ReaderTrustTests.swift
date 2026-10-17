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

private func mail(_ id: String, from: String, labels: [String], fromMe: Bool = false) -> MailMessage {
    MailMessage(accountId: "me@example.com", id: id, threadId: "t", date: Date(), fromEmail: from, labelIds: labels, isFromMe: fromMe)
}

@Test func imagesLoadByLabelsAndChoicesNotByTheFromHeader() {
    var trust = ReaderTrust(senders: ["news@shop.example"])
    let sent = mail("1", from: "me@example.com", labels: ["SENT"])
    let forgedMe = mail("2", from: "me@example.com", labels: ["INBOX"], fromMe: true)
    let newsletter = mail("3", from: "News@Shop.example", labels: ["INBOX"])
    let spoofedInSpam = mail("4", from: "news@shop.example", labels: ["SPAM"])
    let stranger = mail("5", from: "pixel@tracker.example", labels: ["INBOX"])

    #expect(trust.allows(sent), "your own sent mail, by Gmail's SENT label")
    #expect(!trust.allows(forgedMe), "a From header naming you isn't enough")
    #expect(trust.allows(newsletter))
    #expect(!trust.allows(spoofedInSpam), "a trusted sender never counts in Spam")
    #expect(!trust.allows(stranger))

    trust.messages.insert(stranger.key)
    #expect(trust.allows(stranger), "Load images covers that message")
    #expect(trust.loadedOnce(stranger), "and offers Always load for its sender")
    #expect(!trust.allows(mail("6", from: "pixel@tracker.example", labels: ["INBOX"])), "but not the sender's other mail")
    trust.messages.insert(spoofedInSpam.key)
    #expect(trust.allows(spoofedInSpam) && !trust.loadedOnce(spoofedInSpam), "no Always offer for mail in Spam")

    trust.remoteImages = false
    #expect(![sent, newsletter, stranger].contains(where: trust.allows), "no remote images when the blocker isn't installed")
}
