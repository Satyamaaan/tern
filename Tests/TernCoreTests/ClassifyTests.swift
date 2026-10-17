import Foundation
import GRDB
import Testing
@testable import TernCore

private let me = Account(email: "alex@kiteworks.dev")
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3_600

private struct Mail {
    var id: String
    var thread: String
    var from: String
    var fromName = ""
    var to: [String] = [me.email]
    var cc: [String] = []
    var subject: String
    var body: String = "Hello there."
    var labels: [String] = [SystemLabel.inbox]
    var hoursAgo: Double = 1
    var unsubscribe: String? = nil
    var attachment: (String, String)? = nil
}

private func makeStore(_ mails: [Mail], contacts: [String] = []) throws -> MailStore {
    let store = MailStore(try AppDatabase.inMemory())
    try store.upsertAccount(me)
    var messages: [MailMessage] = []
    var attachments: [MailAttachment] = []
    for mail in mails {
        let fromMe = mail.from == me.email
        messages.append(MailMessage(
            accountId: me.id, id: mail.id, threadId: mail.thread, date: now.addingTimeInterval(-mail.hoursAgo * hour),
            fromName: mail.fromName, fromEmail: mail.from, toList: mail.to.map { Participant(email: $0) },
            ccList: mail.cc.map { Participant(email: $0) }, subject: mail.subject, snippet: String(mail.body.prefix(140)),
            bodyText: mail.body, bodyState: .full, labelIds: fromMe ? [SystemLabel.sent] : mail.labels, isFromMe: fromMe,
            hasAttachments: mail.attachment != nil, listUnsubscribe: mail.unsubscribe))
        if let (filename, mime) = mail.attachment {
            attachments.append(MailAttachment(accountId: me.id, messageId: mail.id, partId: "1", filename: filename, mimeType: mime, size: 900))
        }
    }
    try store.upsertMessages(messages, attachments: attachments)
    try store.database.writer.write { db in
        for contact in contacts { try Contact(id: contact, sentCount: 3).insert(db) }
    }
    return store
}

private func classify(_ store: MailStore) throws -> [String: ThreadAI] {
    try store.database.writer.write { db in
        try RuleClassifier.classifyAllMissing(db, now: now)
        return Dictionary(uniqueKeysWithValues: try ThreadAI.fetchAll(db).map { ($0.threadId, $0) })
    }
}

@Test func automatedMailIsSortedByKind() throws {
    let store = try makeStore([
        Mail(id: "n1", thread: "newsletter", from: "lenny@substack.com", subject: "How the best teams run planning",
             labels: [SystemLabel.inbox, SystemLabel.categoryPromotions], unsubscribe: "<mailto:u@substack.com>"),
        Mail(id: "p1", thread: "promo", from: "hello@loomwear.com", subject: "40% off ends tonight",
             labels: [SystemLabel.inbox, SystemLabel.categoryPromotions], unsubscribe: "<mailto:u@loomwear.com>"),
        Mail(id: "g1", thread: "github", from: "notifications@github.com", subject: "[kiteworks/tern] Fix race in history poller (#142)",
             labels: [SystemLabel.inbox, SystemLabel.categoryUpdates], unsubscribe: "<mailto:u@github.com>"),
        Mail(id: "l1", thread: "linear", from: "notifications@linear.app", subject: "ENG-412 Invoice export is slow"),
        Mail(id: "r1", thread: "stripe", from: "receipts@stripe.com", subject: "Your receipt from Figma #2093-4471"),
        Mail(id: "r2", thread: "uber", from: "noreply@uber.com", subject: "Your Thursday evening trip with Uber"),
        Mail(id: "r3", thread: "amazon", from: "auto-confirm@amazon.com", subject: "Your Amazon.com order #112-4471023"),
        Mail(id: "c1", thread: "invite", from: "maya@kiteworks.dev", subject: "Invitation: Design review @ Thu 2pm – 3pm"),
        Mail(id: "c2", thread: "ics", from: "ops@harbor.dev", subject: "Planning", attachment: ("invite.ics", "text/calendar")),
        Mail(id: "s1", thread: "otp", from: "support@stripe.com", subject: "Your verification code is 482913"),
        Mail(id: "s2", thread: "github-otp", from: "noreply@github.com", subject: "[GitHub] Your sign-in code"),
        Mail(id: "s3", thread: "alert", from: "no-reply@accounts.google.com", subject: "Security alert"),
        Mail(id: "d1", thread: "drive", from: "drive-shares-dm-noreply@google.com", subject: "Jonas shared \"Q4 Planning\" with you"),
    ])
    let results = try classify(store)
    let expected: [String: MailCategory] = [
        "newsletter": .newsletter, "promo": .promotion, "github": .notification, "linear": .notification,
        "stripe": .receipt, "uber": .receipt, "amazon": .receipt, "invite": .calendar, "ics": .calendar,
        "otp": .security, "github-otp": .security, "alert": .security, "drive": .notification,
    ]
    for (thread, category) in expected {
        #expect(results[thread]?.category == category, "\(thread)")
        #expect(results[thread]?.needsReply == false, "\(thread)")
        #expect(results[thread]?.source == "rules")
    }
    #expect(results["promo"]?.priority == 0)
    #expect(results["otp"]?.priority == 2)
}

@Test func humanQuestionNeedsReply() throws {
    let store = try makeStore([
        Mail(id: "a1", thread: "question", from: "ethan.brooks@gmail.com", fromName: "Ethan Brooks", subject: "Dinner Saturday?",
             body: "Hi Alex,\n\nAre you around this weekend? We were thinking of a hike.\n\nEthan"),
        Mail(id: "b1", thread: "fyi", from: "ethan.brooks@gmail.com", subject: "Photos", body: "Here are the photos from the weekend."),
        Mail(id: "c1", thread: "cc", from: "ethan.brooks@gmail.com", to: ["sam@icloud.com"], cc: [me.email],
             subject: "Plans", body: "Can you send the address?"),
        Mail(id: "d1", thread: "old", from: "ethan.brooks@gmail.com", subject: "Old", body: "Could you check this?", hoursAgo: 20 * 24),
        Mail(id: "e1", thread: "answered", from: "ethan.brooks@gmail.com", subject: "Lunch?", body: "Lunch tomorrow?", hoursAgo: 3),
        Mail(id: "e2", thread: "answered", from: me.email, to: ["ethan.brooks@gmail.com"], subject: "Re: Lunch?", body: "Yes!", hoursAgo: 2),
        Mail(id: "f1", thread: "urgent", from: "maya@kiteworks.dev", subject: "Contract — urgent",
             body: "Please sign the contract today, it's urgent.\n\nOn Mon, Ann wrote:\n> anything?"),
        Mail(id: "g1", thread: "quoted", from: "ethan.brooks@gmail.com", subject: "Re: Notes",
             body: "Thanks, all good.\n\nOn Tue, Alex wrote:\n> Can you review this?"),
    ])
    let results = try classify(store)
    #expect(results["question"]?.category == .people)
    #expect(results["question"]?.needsReply == true)
    #expect(results["question"]?.priority == 2)
    #expect(results["fyi"]?.needsReply == false)
    #expect(results["cc"]?.needsReply == false)
    #expect(results["old"]?.needsReply == false)
    #expect(results["answered"]?.category == .people)
    #expect(results["answered"]?.needsReply == false)
    #expect(results["urgent"]?.category == .people)
    #expect(results["urgent"]?.priority == 3)
    #expect(results["quoted"]?.needsReply == false)
}

@Test func unknownCompanySenderIsOtherUntilKnown() throws {
    let mails = [Mail(id: "a1", thread: "t1", from: "sofia@lumen.io", subject: "Contract for the redesign", body: "Attached.")]
    #expect(try classify(try makeStore(mails))["t1"]?.category == .other)
    #expect(try classify(try makeStore(mails, contacts: ["sofia@lumen.io"]))["t1"]?.category == .people)
}

@Test func aiRowSurvivesUntilThreadGrows() throws {
    let store = try makeStore([Mail(id: "a1", thread: "t1", from: "ethan.brooks@gmail.com", subject: "Hi", body: "Hello")])
    let key = ThreadKey(accountId: me.id, threadId: "t1")
    let untouched = try store.database.writer.write { db in
        try ThreadAI(accountId: me.id, threadId: "t1", category: .other, priority: 3, summary: "AI says hi",
                     source: "claude", messageCount: 1).insert(db)
        return try RuleClassifier.classify(db, keys: [key], now: now)
    }
    #expect(untouched == 0)
    #expect(try store.threadDetail(key)?.ai?.source == "claude")

    try store.upsertMessages([MailMessage(
        accountId: me.id, id: "a2", threadId: "t1", date: now, fromName: "Ethan", fromEmail: "ethan.brooks@gmail.com",
        toList: [Participant(email: me.email)], subject: "Re: Hi", snippet: "Can you call me?", bodyText: "Can you call me?",
        bodyState: .full, labelIds: [SystemLabel.inbox])])
    let rewritten = try store.database.writer.write { db in try RuleClassifier.classify(db, keys: [key], now: now) }
    #expect(rewritten == 1)
    let ai = try #require(try store.threadDetail(key)?.ai)
    #expect(ai.source == "rules")
    #expect(ai.category == .people)
    #expect(ai.needsReply)
    #expect(ai.summary == nil)
    #expect(ai.messageCount == 2)
}

@Test func expiredNeedsReplyIsCleared() throws {
    let store = try makeStore([Mail(id: "a1", thread: "t1", from: "ethan.brooks@gmail.com", subject: "Hi", body: "Free tomorrow?")])
    let expired = try store.database.writer.write { db in
        try RuleClassifier.classifyAllMissing(db, now: now)
        return [
            try RuleClassifier.expireNeedsReply(db, now: now),
            try RuleClassifier.expireNeedsReply(db, now: now.addingTimeInterval(15 * 86_400)),
        ]
    }
    #expect(expired == [0, 1])
}

@Test func fakeMailboxRulesAgreeWithGenerator() throws {
    let database = try AppDatabase.inMemory()
    try FakeMailbox.populate(database, options: .init(messages: 3_000, now: now))
    let generated = try database.reader.read { db in
        Dictionary(uniqueKeysWithValues: try ThreadAI.fetchAll(db).map { ("\($0.accountId)/\($0.threadId)", $0.category) })
    }
    let started = Date()
    let written = try database.writer.write { db in
        try db.execute(sql: "DELETE FROM thread_ai")
        return try RuleClassifier.classifyAllMissing(db, now: now)
    }
    let elapsed = Date().timeIntervalSince(started)
    #expect(written == generated.count)
    #expect(elapsed < 2)

    let classified = try database.reader.read { db in try ThreadAI.fetchAll(db) }
    var agree: [MailCategory: (Int, Int)] = [:]
    for ai in classified {
        guard let truth = generated["\(ai.accountId)/\(ai.threadId)"] else { continue }
        let (hit, total) = agree[truth] ?? (0, 0)
        // People at unfamiliar company domains are left to the AI as "other".
        let ok = ai.category == truth || (truth == .people && ai.category == .other)
        agree[truth] = (hit + (ok ? 1 : 0), total + 1)
    }
    for (category, (hit, total)) in agree {
        #expect(Double(hit) / Double(total) >= 0.95, "\(category): \(hit)/\(total)")
    }
}
