import Testing
@testable import TernSync

@Test func gmailErrorEquality() {
    #expect(GmailAPIError.notFound == .notFound)
}
