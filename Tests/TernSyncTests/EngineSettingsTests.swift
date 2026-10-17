import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

extension Harness {
    func setting(_ key: String) throws -> String? {
        try store.database.reader.read { db in try Setting.fetchOne(db, key: key)?.value }
    }
}

private let identities = [
    GmailSendAs(sendAsEmail: testEmail, displayName: "Sam Rivera", signature: "<div>Sam</div>", isPrimary: true, isDefault: false),
    GmailSendAs(sendAsEmail: "sam@alias.example", displayName: "Sam at Alias", signature: "<div>Sam · Alias Inc.</div>",
                isPrimary: false, isDefault: true),
]

@Test func theDefaultGmailSignatureAndSenderNameAreReadOnStartAndDaily() async throws {
    let h = try Harness()
    await h.fake.setSendAs(identities)
    try await h.sync.syncOnce()
    #expect(try h.setting(DraftStore.SettingKey.signature(testEmail)) == "<div>Sam · Alias Inc.</div>", "the default identity's")
    #expect(try h.setting(DraftStore.SettingKey.senderName(testEmail)) == "Sam Rivera", "the account address's own name")
    #expect(await h.fake.callCount(.sendAs) == 1)

    // The composer starts new mail with it.
    let content = try #require(try h.drafts.makeDraft(.new(accountId: testEmail)))
    #expect(content.signatureHtml == "<div>Sam · Alias Inc.</div>")

    // Read again once a day, not on every pass.
    await h.fake.setSendAs([GmailSendAs(sendAsEmail: testEmail, displayName: "Sam R.", signature: "", isPrimary: true, isDefault: true)])
    h.clock.advance(3600)
    try await h.sync.syncOnce()
    #expect(await h.fake.callCount(.sendAs) == 1)
    h.clock.advance(86_400)
    try await h.sync.syncOnce()
    #expect(await h.fake.callCount(.sendAs) == 2)
    #expect(try h.setting(DraftStore.SettingKey.signature(testEmail)) == nil, "removed in Gmail, removed here")
    #expect(try h.setting(DraftStore.SettingKey.senderName(testEmail)) == "Sam R.")
}

@Test func aSignatureSetInTernIsNotReplaced() async throws {
    let h = try Harness()
    await h.fake.setSendAs(identities)
    try await h.drafts.setSignature("<b>Mine</b>", accountId: testEmail)
    try await h.sync.syncOnce()
    #expect(try h.setting(DraftStore.SettingKey.signature(testEmail)) == "<b>Mine</b>")
    #expect(try h.setting(DraftStore.SettingKey.senderName(testEmail)) == "Sam Rivera")

    try await h.drafts.useGmailSignature(accountId: testEmail)
    try await h.sync.refreshSendAs()
    #expect(try h.setting(DraftStore.SettingKey.signature(testEmail)) == "<div>Sam · Alias Inc.</div>")
}

@Test func aFailedSettingsReadDoesNotStopSync() async throws {
    let h = try Harness()
    await seed(h.fake, count: 3)
    await h.fake.failNext(10, with: .server(status: 500, message: "Backend Error"), on: .sendAs)
    try await h.sync.syncOnce()
    #expect(try h.account().historyId != nil)
    let next = await h.sync.nextSendAsRefreshAt
    #expect(next > h.clock.now() && next <= h.clock.now().addingTimeInterval(3600), "tried again within the hour")
}
