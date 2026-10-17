import Foundation
import Testing
@testable import Tern
@testable import TernCore

private func sent(_ id: String, from: String, labels: [String] = ["INBOX"]) -> MailMessage {
    MailMessage(accountId: "me@example.com", id: id, threadId: "t", date: Date(), fromEmail: from, labelIds: labels)
}

@Test func logoSendersAreDistinctLowercasedAndNeverInSpamOrTrash() {
    let messages = [sent("1", from: "Maya@Lumen.io"), sent("2", from: "me@example.com"), sent("3", from: "maya@lumen.io"),
                    sent("4", from: "jonas@kiteworks.dev")]
    #expect(ReaderPayload.logoSenders(messages, threadLabels: ["INBOX"]) == ["maya@lumen.io", "me@example.com", "jonas@kiteworks.dev"])
    #expect(ReaderPayload.logoSenders(messages, threadLabels: ["INBOX", SystemLabel.spam]).isEmpty)
    #expect(ReaderPayload.logoSenders(messages, threadLabels: [SystemLabel.trash]).isEmpty)
}

@Test func logoMapHoldsDataURLsOnlyForSendersWithALogo() {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
    var asked: [String] = []
    let map = ReaderPayload.logos(["maya@lumen.io", "jonas@kiteworks.dev", "empty@example.com"]) { email in
        asked.append(email)
        switch email {
        case "maya@lumen.io": return png
        case "empty@example.com": return Data()
        default: return nil
        }
    }
    #expect(asked == ["maya@lumen.io", "jonas@kiteworks.dev", "empty@example.com"])
    #expect(map == ["maya@lumen.io": "data:image/png;base64," + png.base64EncodedString()])
    #expect(ReaderPayload.logos([]) { _ in png }.isEmpty)
}

@MainActor
@Test func readerPageAllowsAppAvatarsButNoRemoteImages() throws {
    let page = ReaderResources.page()
    let csp = try #require(page.range(of: #"Content-Security-Policy" content="[^"]*""#, options: .regularExpression)
        .map { String(page[$0]) })
    let directives = Dictionary(uniqueKeysWithValues: csp.dropFirst(#"Content-Security-Policy" content=""#.count).dropLast()
        .split(separator: ";").map { $0.split(separator: " ").map(String.init) }.filter { !$0.isEmpty }
        .map { ($0[0], Array($0.dropFirst())) })
    #expect(directives["default-src"] == ["'none'"])
    let images = try #require(directives["img-src"])
    #expect(images.contains("data:"), "sender logos are data: URLs the app builds")
    #expect(Set(images).isSubset(of: ["tern-cid:", "tern-remote:", "data:"]),
            "mail images come only through Tern's own schemes; never http(s), a wildcard or blob:")
    for source in images {
        #expect(!source.lowercased().contains("http") && !source.contains("*"))
    }
    #expect(directives["script-src"] == ["'none'"])
    #expect(page.contains("--avatarFill:") && page.contains("--avatarText:"), "letter avatars use the Theme tokens")
}

@MainActor
@Test func payloadCarriesChipIconsAndLogosButNoHues() throws {
    let store = MailStore(try AppDatabase.inMemory())
    let account = Account(email: "me@example.com")
    try store.upsertAccount(account)
    let project = Project(id: "p1", name: "Lumen redesign", colorIndex: 3, icon: "paintpalette", sortOrder: 0, createdAt: Date())
    try store.saveProject(project, rules: [])
    try store.upsertMessages([
        MailMessage(accountId: account.id, id: "m1", threadId: "t1", date: Date(), fromName: "Maya Chen", fromEmail: "maya@lumen.io",
                    subject: "Contract", snippet: "Hi", bodyText: "Hi", bodyState: .full, labelIds: ["INBOX", "Label_1"]),
    ])
    try store.database.writer.write { db in
        try ThreadAI(accountId: account.id, threadId: "t1", category: .newsletter, needsReply: true, messageCount: 1).upsert(db)
    }
    let key = ThreadKey(accountId: account.id, threadId: "t1")
    try store.setProject("p1", on: [key], assigned: true)
    let detail = try #require(try store.threadDetail(key))

    var context = ReaderContext(accountEmails: [account.email], labelNames: ["Label_1": "Clients"],
                                trust: ReaderTrust(), summary: [:])
    context.logos = ReaderPayload.logos(ReaderPayload.logoSenders(detail)) { _ in Data([1, 2, 3]) }
    let payload = ReaderPayload.make(detail, context: context).payload

    let chips = try #require(payload["chips"] as? [[String: Any]])
    #expect(chips.map { $0["kind"] as? String } == ["needs", "cat", "project", "label"])
    #expect(chips.map { $0["icon"] as? String } == [Icon.needsReply, .newsletter, .palette, .label].map(\.svgMarkup))
    #expect(chips.map { $0["color"] as? String } == [
        "var(--ink)", "var(--cat-newsletter)", ReaderResources.hex(Theme.projectColor(3)), "var(--text2)",
    ])
    #expect(payload["logos"] as? [String: String] == ["maya@lumen.io": "data:image/png;base64,AQID"])
    let message = try #require((payload["messages"] as? [[String: Any]])?.first)
    #expect(message["hue"] == nil && message["initials"] as? String == "MC" && message["email"] as? String == "maya@lumen.io")
}
