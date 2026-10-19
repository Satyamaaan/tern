import AppKit
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

@Test func loadAutomaticallyCoversEveryMessageButSpam() {
    var trust = ReaderTrust(automatic: true)
    let stranger = mail("1", from: "news@shop.example", labels: ["INBOX"])
    let spam = mail("2", from: "news@shop.example", labels: ["SPAM"])
    #expect(trust.allows(stranger))
    #expect(!trust.allows(spam), "mail in Spam still asks")
    trust.messages.insert(spam.key)
    trust.messages.insert(stranger.key)
    #expect(trust.allows(spam), "Load images still works there")
    #expect(!trust.loadedOnce(stranger) && !trust.loadedOnce(spam), "no Always load offer in this mode")
    trust.remoteImages = false
    #expect(!trust.allows(stranger), "no remote images when the blocker isn't installed")
}

@Test func changingTheImagesSettingRendersFreshBodies() throws {
    let store = MailStore(try AppDatabase.inMemory())
    let account = Account(email: "me@example.com")
    try store.upsertAccount(account)
    let html = #"<p>Deployed</p><img src="https://res.cloudinary.com/acme/logo.png" width="250" alt="Logo">"#
        + #"<img src="https://notifylink.example.app/e/o/ZXhhbXBsZS10b2tlbg" alt="">"#
    try store.upsertMessages([
        MailMessage(accountId: account.id, id: "m1", threadId: "t1", date: Date(), fromName: "Railway", fromEmail: "team@railway.example",
                    subject: "Deployed", snippet: "Deployed", bodyHtml: html, bodyState: .full, labelIds: ["INBOX"]),
    ])
    let detail = try #require(try store.threadDetail(ThreadKey(accountId: account.id, threadId: "t1")))
    func context(_ automatic: Bool) -> ReaderContext {
        ReaderContext(accountEmails: [account.email], labelNames: [:], trust: ReaderTrust(automatic: automatic), summary: [:])
    }
    func message(_ automatic: Bool) throws -> [String: Any] {
        try #require((ReaderPayload.make(detail, context: context(automatic)).payload["messages"] as? [[String: Any]])?.first)
    }
    #expect(ReaderPayload.signature(detail, context: context(true)) != ReaderPayload.signature(detail, context: context(false)))
    let shown = try message(true), asked = try message(false)
    #expect(shown["bodyVersion"] as? String != asked["bodyVersion"] as? String, "the page doesn't keep the body it had")
    let shownBody = try #require(shown["body"] as? [String: Any]), askedBody = try #require(asked["body"] as? [String: Any])
    #expect(shownBody["blocked"] as? Int == 0 && askedBody["blocked"] as? Int == 1)
    let shownHTML = try #require(shownBody["html"] as? String)
    #expect(shownHTML.contains("src=\"tern-remote://i/") && !shownHTML.contains("cloudinary") && !shownHTML.contains("notifylink"))
    #expect(shown["imagesAllowed"] as? Bool == true && shown["imagesOnce"] as? Bool == false)

    // Without the content blocker, Load automatically loads nothing: the body is sanitized as blocked.
    let unguarded = ReaderContext(accountEmails: [account.email], labelNames: [:],
                                  trust: ReaderTrust(remoteImages: false, automatic: true), summary: [:])
    let blocked = try #require((ReaderPayload.make(detail, context: unguarded).payload["messages"] as? [[String: Any]])?.first)
    let blockedBody = try #require(blocked["body"] as? [String: Any])
    #expect(blocked["imagesAllowed"] as? Bool == false && blocked["imagesOnce"] as? Bool == false)
    #expect(blockedBody["blocked"] as? Int == 1 && (blockedBody["html"] as? String)?.contains("tern-remote") == false)
    #expect(ReaderPayload.signature(detail, context: unguarded) == ReaderPayload.signature(detail, context: context(false)))
}

@MainActor
@Test func showOriginalLetsClosedWindowsGo() {
    weak var closedWindow: NSWindow?
    autoreleasepool {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        ReaderOriginalWindow.track(window)
        closedWindow = window
        #expect(ReaderOriginalWindow.openCount == 1)
        window.close()
    }
    #expect(ReaderOriginalWindow.openCount == 0)
    #expect(closedWindow == nil, "nothing holds a closed Show Original window")
}
