import Foundation
import GRDB
import Testing
@testable import TernCore

@Test(arguments: [12, 1_100])
func projectListsKeepOrderingPaginationAndAccountScope(memberCount: Int) throws {
    let store = MailStore(try AppDatabase.inMemory())
    let accounts = [Account(email: "one@example.com"), Account(email: "two@example.com")]
    for account in accounts { try store.upsertAccount(account) }
    let project = Project(id: "project", name: "Project")
    try store.saveProject(project, rules: [])
    let messages: [MailMessage] = (0..<(memberCount + 20)).map { i in
        let labels = i % 11 == 0 ? ["SPAM"] : i % 13 == 0 ? ["TRASH"] : ["INBOX"]
        return MailMessage(
            accountId: accounts[i % 2].id, id: "m\(i / 2)", threadId: "t\(i / 2)",
            date: Date(timeIntervalSince1970: Double(i)), fromEmail: "sender@example.com",
            labelIds: labels)
    }
    try store.upsertMessages(messages)
    try store.database.writer.write { db in
        for message in messages.prefix(memberCount) {
            try ThreadProject(accountId: message.accountId, threadId: message.threadId,
                              projectId: project.id, source: .manual).insert(db)
        }
    }

    let cursors: [Date?] = [nil, Date(timeIntervalSince1970: Double(memberCount / 2)), Date(timeIntervalSince1970: -1)]
    for before in cursors {
        let eligible = messages.prefix(memberCount).reversed().compactMap { message -> ThreadKey? in
            guard !message.labelIds.contains("SPAM"), !message.labelIds.contains("TRASH") else { return nil }
            if let before, message.date >= before { return nil }
            return ThreadKey(accountId: message.accountId, threadId: message.threadId)
        }
        for limit in [0, 1, 17, -1] {
            // Projects span accounts even when the caller has an account selected.
            let rows = try store.threadRows(in: Mailbox(.project(project.id), accountId: accounts[0].id),
                                            limit: limit, before: before)
            #expect(rows.map(\.id) == (limit < 0 ? eligible : Array(eligible.prefix(limit))))
            #expect(rows.allSatisfy { $0.projectIds == [project.id] })
        }
    }
    #expect(try store.threadRows(in: Mailbox(.project("missing"))).isEmpty)
}

@Test(arguments: ["recent", "old", "sparse"])
func projectPagesMatchMembershipSortAcrossDateDistributions(shape: String) throws {
    let store = MailStore(try AppDatabase.inMemory())
    let account = Account(email: "projects@example.com")
    try store.upsertAccount(account)
    let project = Project(id: shape, name: shape)
    try store.saveProject(project, rules: [])
    let mailboxSize = shape == "sparse" ? 24_000 : 6_000
    let messages: [MailMessage] = (0..<mailboxSize).map { i in
        let labels = i % 31 == 0 ? ["SPAM"] : i % 37 == 0 ? ["TRASH"] : ["INBOX"]
        return MailMessage(accountId: account.id, id: "m\(i)", threadId: "t\(i)",
                    date: Date(timeIntervalSince1970: Double(i)), fromEmail: "sender@example.com",
                    labelIds: labels)
    }
    try store.upsertMessages(messages)
    let members = messages.enumerated().filter { i, _ in
        switch shape {
        case "recent": return i >= 4_400
        case "old": return i < 1_600
        default: return i % 20 == 0
        }
    }.map(\.element)
    try store.database.writer.write { db in
        for message in members {
            try ThreadProject(accountId: account.id, threadId: message.threadId,
                              projectId: project.id, source: .manual).insert(db)
        }
    }
    let expected = members.reversed().filter { $0.labelIds == ["INBOX"] }
    let mailbox = Mailbox(.project(project.id))
    let all = try store.threadRows(in: mailbox, limit: -1)
    #expect(all.map(\.id) == expected.map { ThreadKey(accountId: $0.accountId, threadId: $0.threadId) })
    // Walk every page, including the partial last page and the empty page after it. Dense recent
    // pages fill the bounded scan; old first pages and sparse pages must use the member sort.
    var actual: [ThreadRow] = []
    var before: Date?
    while true {
        let page = try store.threadRows(in: mailbox, limit: 300, before: before)
        if page.isEmpty { break }
        #expect(page == Array(all.dropFirst(actual.count).prefix(300)))
        actual += page
        before = page.last!.thread.lastDate
        if actual.count > all.count { break }
    }
    #expect(actual == all)
}
