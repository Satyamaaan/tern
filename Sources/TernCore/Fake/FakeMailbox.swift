import Foundation
import GRDB

/// Generates a realistic three-account mailbox so the UI, search and speed tests can run without
/// Google. Deterministic for a given seed.
public enum FakeMailbox {
    public struct Options: Sendable {
        public var messages: Int
        public var seed: UInt64
        public var now: Date

        public init(messages: Int = 50_000, seed: UInt64 = 7, now: Date = Date()) {
            self.messages = messages
            self.seed = seed
            self.now = now
        }
    }

    public struct Summary: Sendable {
        public var accounts: Int
        public var threads: Int
        public var messages: Int
        public var seconds: Double
    }

    public static let me = "Alex Morgan"

    public static let accounts: [Account] = [
        Account(email: "alex.morgan@gmail.com", displayName: "Personal", colorIndex: 0, sortOrder: 0, historyId: "1", syncState: .live, backfillDone: true),
        Account(email: "alex@northwind.studio", displayName: "Northwind", colorIndex: 1, sortOrder: 1, historyId: "1", syncState: .live, backfillDone: true),
        Account(email: "alex@kiteworks.dev", displayName: "Kiteworks", colorIndex: 2, sortOrder: 2, historyId: "1", syncState: .live, backfillDone: true),
    ]

    @discardableResult
    public static func populate(_ database: AppDatabase, options: Options = Options()) throws -> Summary {
        let started = Date()
        var generator = Generator(options: options)
        let batch = generator.makeAll()

        try database.writer.write { db in
            for account in accounts { try account.upsert(db) }
            for label in batch.labels { try label.upsert(db) }
            try MailStore.upsertMessages(db, batch.messages, attachments: batch.attachments)
            for ai in batch.ai { try ai.upsert(db) }
            for project in batch.projects { try project.upsert(db) }
            for rule in batch.rules { try rule.insert(db) }
            for link in batch.projectLinks { try link.upsert(db) }
            for snooze in batch.snoozes { try snooze.upsert(db) }
        }
        try MailStore(database).rebuildContacts()

        return Summary(
            accounts: accounts.count, threads: batch.threadCount, messages: batch.messages.count,
            seconds: Date().timeIntervalSince(started))
    }
}

// MARK: - Generator

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct Batch {
    var labels: [MailLabel] = []
    var messages: [MailMessage] = []
    var attachments: [MailAttachment] = []
    var ai: [ThreadAI] = []
    var projects: [Project] = []
    var rules: [ProjectRule] = []
    var projectLinks: [ThreadProject] = []
    var snoozes: [Snooze] = []
    var threadCount = 0
}

private enum Kind: CaseIterable {
    case people, notification, newsletter, receipt, calendar, promotion, security

    var category: MailCategory {
        switch self {
        case .people: .people
        case .notification: .notification
        case .newsletter: .newsletter
        case .receipt: .receipt
        case .calendar: .calendar
        case .promotion: .promotion
        case .security: .security
        }
    }

    var gmailCategory: String {
        switch self {
        case .people, .calendar: SystemLabel.categoryPersonal
        case .notification, .receipt, .security: SystemLabel.categoryUpdates
        case .newsletter, .promotion: SystemLabel.categoryPromotions
        }
    }
}

private struct Person {
    var name: String
    var email: String
    /// Index into FakeMailbox.accounts.
    var account: Int
    var domain: String { String(email.split(separator: "@").last ?? "") }
}

private struct Sender {
    var name: String
    var email: String
    var subjects: [String]
    var account: Int
}

private struct Generator {
    var rng: SplitMix64
    let options: Options
    var nextId: UInt64 = 0x18F2_0000_0000_0000
    typealias Options = FakeMailbox.Options

    init(options: Options) {
        self.options = options
        rng = SplitMix64(state: options.seed)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &rng)] }

    mutating func newId() -> String {
        nextId &+= UInt64.random(in: 1...0xFFFF, using: &rng)
        return String(nextId, radix: 16)
    }

    /// Spread over two years, denser toward now.
    mutating func pastDate() -> Date {
        let r = Double.random(in: 0..<1, using: &rng)
        let days = pow(r, 1.3) * 730
        return options.now.addingTimeInterval(-days * 86_400 - Double(int(0...3_600)))
    }

    // MARK: Pools

    static let people: [Person] = {
        let rows: [(String, String, Int)] = [
            ("Maya Chen", "maya@northwind.studio", 1), ("Jonas Weber", "jonas@northwind.studio", 1),
            ("Priya Raman", "priya@northwind.studio", 1), ("Leo Martins", "leo@northwind.studio", 1),
            ("Hana Sato", "hana@northwind.studio", 1), ("Sofia Rossi", "sofia@lumen.io", 1),
            ("Daniel Okafor", "daniel@lumen.io", 1), ("Grace Kim", "grace@brightpath.co", 1),
            ("Tom Becker", "tom@brightpath.co", 1), ("Amara Diallo", "amara@atlas.vc", 1),
            ("Ethan Brooks", "ethan.brooks@gmail.com", 0), ("Nina Petrova", "nina.petrova@gmail.com", 0),
            ("Mom", "linda.morgan@gmail.com", 0), ("Sam Rivera", "sam.rivera@icloud.com", 0),
            ("Chloe Dubois", "chloe@fernwood.org", 0), ("Ravi Patel", "ravi.patel@outlook.com", 0),
            ("Isla Murphy", "isla@harbor.dev", 2), ("Kenji Watanabe", "kenji@kiteworks.dev", 2),
            ("Zoe Laurent", "zoe@kiteworks.dev", 2), ("Omar Haddad", "omar@harbor.dev", 2),
            ("Lucía Gómez", "lucia@meridian.design", 2), ("Ben Turner", "ben@turner.law", 0),
        ]
        return rows.map { Person(name: $0.0, email: $0.1, account: $0.2) }
    }()

    static let peopleSubjects = [
        "Q4 roadmap review", "Contract for the Lumen redesign", "Dinner Saturday?", "Intro: Maya <> Alex",
        "Feedback on the onboarding flow", "Invoice 2026-118", "Flight details for Lisbon", "Can we move our 1:1?",
        "Design review notes", "Offer letter — final version", "Pricing page copy", "Quick question about the API",
        "Photos from the weekend", "Board deck draft", "Hiring plan for Q1", "Launch checklist",
        "Re: Sync engine edge cases", "Coffee next week?", "Lease renewal", "Brand guidelines v2",
        "Bug in the export flow", "Customer interview recap", "Travel reimbursement", "Wedding RSVP",
        "Your talk at the conference", "Partnership proposal", "Moving the standup", "Mockups for the mobile app",
    ]

    static let sentences = [
        "I went through the doc last night and left a few comments inline.",
        "Can we lock this down before Thursday so the team has time to review?",
        "The numbers look better than last quarter, mostly because of the enterprise deals.",
        "I think the second option is cleaner, but I'd like to hear what Jonas thinks.",
        "Attaching the latest version — the changes are on pages 3 and 7.",
        "No rush on this, whenever you get a chance this week is fine.",
        "We hit the same issue in staging; it only shows up with more than one account.",
        "Let me know if a quick call would be easier than going back and forth here.",
        "I booked the room for 2pm, but we can move it if that's tight for you.",
        "Thanks again for jumping on this so quickly, it really helped.",
        "The client asked whether we can ship the first milestone two weeks earlier.",
        "I'm not sure the current plan accounts for the holidays in December.",
        "Here's the summary from the call: scope stays, timeline moves by a week.",
        "Could you send over the final invoice when you have it?",
        "I pushed a fix for the flaky test, it should be green now.",
        "Happy to help with the intro, I'll loop you both in tomorrow morning.",
        "Do you have the login for the analytics dashboard? Mine expired.",
        "We're leaning toward the warmer palette after the user tests.",
        "The contract needs one more signature from your side, then we're done.",
        "Are you around this weekend? We were thinking of a hike on Sunday.",
    ]

    static let notificationSenders: [Sender] = [
        Sender(name: "GitHub", email: "notifications@github.com", subjects: [
            "[kiteworks/tern] Fix race in history poller (#142)", "[kiteworks/tern] Add FTS5 prefix index (#151)",
            "[kiteworks/web] Bump next from 15.3 to 15.4 (#88)", "Re: [kiteworks/tern] Thread list jumps on archive (#139)",
            "[kiteworks/tern] Release v0.4.0", "[kiteworks/api] CI failed on main",
        ], account: 2),
        Sender(name: "Linear", email: "notifications@linear.app", subjects: [
            "ENG-412 Search results flash on first keystroke", "ENG-398 Undo send window setting",
            "DES-77 New empty states", "ENG-420 Snooze picker keyboard support", "You were assigned ENG-431",
        ], account: 1),
        Sender(name: "Vercel", email: "notifications@vercel.com", subjects: [
            "Deployment ready: kiteworks-web (main)", "Failed deployment: kiteworks-docs", "Usage alert: 80% of bandwidth",
        ], account: 2),
        Sender(name: "Figma", email: "no-reply@figma.com", subjects: [
            "Maya commented on Onboarding v3", "Hana invited you to Brand 2026", "Priya mentioned you in Mobile app",
        ], account: 1),
        Sender(name: "Sentry", email: "noreply@sentry.io", subjects: [
            "New issue: TypeError in ThreadList.render", "Regression: SyncError in HistoryPoller",
        ], account: 2),
        Sender(name: "Slack", email: "feedback@slack.com", subjects: [
            "New messages in #design", "You have 4 unread mentions", "Daily summary for Northwind",
        ], account: 1),
        Sender(name: "Google Drive", email: "drive-shares-dm-noreply@google.com", subjects: [
            "Jonas shared \"Q4 Planning\" with you", "Sofia shared \"Lumen — SOW\" with you",
        ], account: 1),
    ]

    static let newsletterSenders: [Sender] = [
        Sender(name: "Lenny's Newsletter", email: "lenny@substack.com", subjects: [
            "How the best teams run planning", "The state of product hiring", "What I learned from 100 PM interviews",
        ], account: 0),
        Sender(name: "TLDR", email: "dan@tldrnewsletter.com", subjects: [
            "Apple's new chips, AI agents in prod, Rust in the kernel", "OpenAI DevDay recap, SQLite tricks",
        ], account: 0),
        Sender(name: "The Pragmatic Engineer", email: "pragmaticengineer@substack.com", subjects: [
            "Inside a fast-growing infra team", "The software engineering job market in 2026",
        ], account: 2),
        Sender(name: "Dense Discovery", email: "kai@densediscovery.com", subjects: ["Issue 312: Quiet tools", "Issue 313: Small web"], account: 0),
        Sender(name: "Stratechery", email: "email@stratechery.com", subjects: ["The aggregation of agents", "Apple and the AI distribution"], account: 0),
    ]

    static let receiptSenders: [Sender] = [
        Sender(name: "Stripe", email: "receipts@stripe.com", subjects: ["Your receipt from Figma #2093-4471", "Your receipt from Linear #1188-2030"], account: 1),
        Sender(name: "Apple", email: "no_reply@email.apple.com", subjects: ["Your receipt from Apple", "Your iCloud+ subscription"], account: 0),
        Sender(name: "Uber", email: "noreply@uber.com", subjects: ["Your Thursday evening trip with Uber", "Your Sunday morning trip with Uber"], account: 0),
        Sender(name: "Amazon", email: "auto-confirm@amazon.com", subjects: ["Your Amazon.com order #112-4471023", "Your package has shipped"], account: 0),
        Sender(name: "AWS", email: "aws-billing@amazon.com", subjects: ["Amazon Web Services invoice available"], account: 2),
        Sender(name: "Google Workspace", email: "payments-noreply@google.com", subjects: ["Your Google Workspace invoice is available"], account: 1),
    ]

    static let promotionSenders: [Sender] = [
        Sender(name: "Loomwear", email: "hello@loomwear.com", subjects: ["The fall edit is here", "40% off ends tonight", "Back in stock: the Field Jacket"], account: 0),
        Sender(name: "Airbnb", email: "discover@airbnb.com", subjects: ["Ideas for your next getaway", "Homes you might like in Lisbon"], account: 0),
        Sender(name: "Notion", email: "team@makenotion.com", subjects: ["What's new in Notion — October", "Meet Notion Mail"], account: 1),
        Sender(name: "Raycast", email: "hello@raycast.com", subjects: ["Raycast 2.0 is here"], account: 2),
    ]

    static let securitySenders: [Sender] = [
        Sender(name: "Google", email: "no-reply@accounts.google.com", subjects: ["Security alert", "New sign-in on Mac"], account: 0),
        Sender(name: "GitHub", email: "noreply@github.com", subjects: ["[GitHub] Your sign-in code", "[GitHub] A new SSH key was added"], account: 2),
        Sender(name: "Stripe", email: "support@stripe.com", subjects: ["Your verification code is 482913"], account: 1),
    ]

    static let calendarSubjects = [
        "Invitation: Design review @ Thu 2pm – 3pm", "Updated invitation: Q4 planning @ Mon 10am",
        "Accepted: Weekly sync @ Wed 11am", "Invitation: Lumen kickoff @ Tue 9:30am", "Declined: Coffee chat",
    ]

    // MARK: Build

    mutating func makeAll() -> Batch {
        var batch = Batch()
        batch.labels = makeLabels()
        let mix: [(Kind, Double)] = [
            (.people, 0.30), (.notification, 0.30), (.newsletter, 0.11), (.receipt, 0.08),
            (.calendar, 0.05), (.promotion, 0.13), (.security, 0.03),
        ]
        while batch.messages.count < options.messages {
            var roll = Double.random(in: 0..<1, using: &rng)
            var kind = Kind.people
            for (candidate, share) in mix {
                roll -= share
                if roll < 0 { kind = candidate; break }
            }
            makeThread(kind, into: &batch)
        }
        makeProjects(into: &batch)
        return batch
    }

    func makeLabels() -> [MailLabel] {
        var labels: [MailLabel] = []
        for account in FakeMailbox.accounts {
            for id in SystemLabel.all {
                labels.append(MailLabel(accountId: account.id, id: id, name: id.capitalized, type: "system"))
            }
            for (id, name, color) in [
                ("Label_finance", "Finance", "#16a766"), ("Label_travel", "Travel", "#4a86e8"),
                ("Label_clients", "Clients", "#a479e2"), ("Label_hiring", "Hiring", "#f691b3"),
            ] {
                labels.append(MailLabel(accountId: account.id, id: id, name: name, colorBackground: color, colorText: "#ffffff"))
            }
        }
        return labels
    }

    mutating func makeThread(_ kind: Kind, into batch: inout Batch) {
        let start = pastDate()
        let age = options.now.timeIntervalSince(start) / 86_400
        var parts: [(from: Participant, to: [Participant], cc: [Participant], date: Date, subject: String, text: String, html: String?)] = []
        var accountIndex: Int
        var listUnsubscribe: String?
        var threadLabels: Set<String> = [kind.gmailCategory]

        switch kind {
        case .people:
            let person = pick(Self.people)
            accountIndex = person.account
            let me = Participant(name: FakeMailbox.me, email: FakeMailbox.accounts[accountIndex].email)
            let them = Participant(name: person.name, email: person.email)
            let cc = chance(0.25) ? [Participant(name: pick(Self.people).name, email: pick(Self.people).email)] : []
            let subject = pick(Self.peopleSubjects)
            let count = [1, 1, 2, 2, 3, 3, 4, 5, 6, 8][int(0...9)]
            var date = start
            var fromMe = chance(0.3)
            for index in 0..<count {
                let from = fromMe ? me : them
                let to = fromMe ? [them] : [me]
                var text = "Hi \(fromMe ? them.firstName : me.firstName),\n\n"
                for _ in 0..<int(1...4) { text += pick(Self.sentences) + " " }
                text += "\n\n" + pick(["Thanks,", "Best,", "Cheers,", "—"]) + "\n" + from.firstName
                if let previous = parts.last {
                    let quoted = previous.text.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
                    text += "\n\nOn \(previous.date.formatted(date: .abbreviated, time: .shortened)), \(previous.from.displayName) wrote:\n\(quoted)"
                }
                parts.append((from, to, index == 0 ? cc : [], date, index == 0 ? subject : "Re: \(subject)", text, nil))
                date = date.addingTimeInterval(Double(int(600...90_000)))
                if date > options.now { break }
                fromMe.toggle()
            }
            if chance(0.5) { threadLabels.insert(SystemLabel.important) }
            if subject.contains("Flight") || subject.contains("Travel") { threadLabels.insert("Label_travel") }
            if subject.contains("Invoice") || subject.contains("Lease") { threadLabels.insert("Label_finance") }
            if person.domain == "lumen.io" || person.domain == "brightpath.co" { threadLabels.insert("Label_clients") }
            if subject.contains("Hiring") || subject.contains("Offer") { threadLabels.insert("Label_hiring") }

        case .calendar:
            let organizer = pick(Self.people.filter { $0.account == 1 })
            accountIndex = 1
            let me = Participant(name: FakeMailbox.me, email: FakeMailbox.accounts[1].email)
            let subject = pick(Self.calendarSubjects)
            let text = "\(organizer.name) has invited you to an event.\n\n\(subject)\nJoining: meet.google.com/abc-defg-hij\n\nGoing? Yes - Maybe - No"
            parts.append((Participant(name: organizer.name, email: organizer.email), [me], [], start, subject, text, nil))

        default:
            let pool: [Sender] = switch kind {
            case .notification: Self.notificationSenders
            case .newsletter: Self.newsletterSenders
            case .receipt: Self.receiptSenders
            case .promotion: Self.promotionSenders
            default: Self.securitySenders
            }
            let sender = pick(pool)
            accountIndex = sender.account
            let me = Participant(name: FakeMailbox.me, email: FakeMailbox.accounts[accountIndex].email)
            let subject = pick(sender.subjects)
            let text = automatedText(kind, sender: sender.name, subject: subject)
            let html = kind == .newsletter || kind == .promotion || kind == .receipt
                ? newsletterHTML(sender: sender.name, subject: subject, text: text) : nil
            if kind == .newsletter || kind == .promotion {
                listUnsubscribe = "<mailto:unsubscribe@\(sender.email.split(separator: "@").last ?? "example.com")>"
            }
            let count = kind == .notification && chance(0.3) ? int(2...4) : 1
            var date = start
            for index in 0..<count {
                parts.append((Participant(name: sender.name, email: sender.email), [me], [], date,
                              index == 0 ? subject : "Re: \(subject)", text, html))
                date = date.addingTimeInterval(Double(int(300...20_000)))
            }
            if kind == .receipt { threadLabels.insert("Label_finance") }
        }

        let account = FakeMailbox.accounts[accountIndex]
        let threadId = newId()
        let lastDate = parts.last!.date
        let recentDays = options.now.timeIntervalSince(lastDate) / 86_400
        let lastIsInbound = parts.last!.from.email != account.email

        // Where the thread lives now.
        var inInbox: Bool
        switch kind {
        case .people: inInbox = recentDays < 10 ? chance(0.6) : chance(0.002)
        case .notification: inInbox = recentDays < 4 ? chance(0.4) : chance(0.001)
        case .calendar, .security: inInbox = recentDays < 7 ? chance(0.6) : false
        default: inInbox = recentDays < 10 ? chance(0.35) : chance(0.001)
        }
        if !lastIsInbound && kind == .people { inInbox = inInbox && chance(0.4) }
        let unreadChance = !inInbox ? 0.005 : recentDays < 2 ? 0.45 : 0.08
        let trashed = kind == .promotion && chance(0.05)
        let spam = kind == .promotion && !trashed && chance(0.03)
        let starred = kind == .people && chance(0.04)
        let snoozed = kind == .people && !inInbox && recentDays < 10 && chance(0.05)

        for (index, part) in parts.enumerated() {
            let id = index == 0 ? threadId : newId()
            let isMine = part.from.email == account.email
            var labels = threadLabels
            if isMine { labels.insert(SystemLabel.sent) }
            if !isMine && inInbox && !trashed && !spam { labels.insert(SystemLabel.inbox) }
            if inInbox && !isMine && chance(unreadChance) { labels.insert(SystemLabel.unread) }
            if trashed { labels.insert(SystemLabel.trash) }
            if spam { labels.insert(SystemLabel.spam) }
            if starred && index == parts.count - 1 { labels.insert(SystemLabel.starred) }
            if isMine { labels.remove(SystemLabel.inbox) }

            var hasAttachment = false
            if (kind == .people && chance(0.08)) || (kind == .receipt && chance(0.5)) {
                hasAttachment = true
                let (name, mime, size) = pick([
                    ("Proposal.pdf", "application/pdf", 482_113), ("Screenshot 2026-10-02.png", "image/png", 1_204_551),
                    ("Budget Q4.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", 88_210),
                    ("Contract.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", 61_002),
                    ("Invoice.pdf", "application/pdf", 120_404),
                ])
                batch.attachments.append(MailAttachment(
                    accountId: account.id, messageId: id, partId: "1", attachmentId: "fake-\(id)",
                    filename: name, mimeType: mime, size: size))
            }

            let html = part.html ?? plainToHTML(part.text)
            var message = MailMessage(
                accountId: account.id, id: id, threadId: threadId, historyId: "1", date: part.date,
                fromName: part.from.name, fromEmail: part.from.email, toList: part.to, ccList: part.cc,
                subject: part.subject, snippet: String(part.text.replacingOccurrences(of: "\n", with: " ").prefix(140)),
                bodyText: part.text, bodyHtml: html, bodyState: .full, labelIds: labels.sorted(),
                isFromMe: isMine, hasAttachments: hasAttachment,
                rfcMessageId: "<\(id)@mail.fake>", listUnsubscribe: listUnsubscribe,
                sizeEstimate: html.utf8.count)
            message.inReplyTo = index > 0 ? "<\(threadId)@mail.fake>" : nil
            batch.messages.append(message)
        }

        // A few unsent drafts on recent conversations.
        if kind == .people && recentDays < 5 && chance(0.04) {
            let id = newId()
            batch.messages.append(MailMessage(
                accountId: account.id, id: id, threadId: threadId, date: lastDate.addingTimeInterval(120),
                fromName: FakeMailbox.me, fromEmail: account.email, toList: [parts.last!.from],
                subject: "Re: \(parts[0].subject)", snippet: "Sounds good, let me check with the team and",
                bodyText: "Sounds good, let me check with the team and", bodyHtml: "<p>Sounds good, let me check with the team and</p>",
                bodyState: .full, labelIds: [SystemLabel.draft], isFromMe: true))
        }

        let needsReply = kind == .people && inInbox && lastIsInbound && recentDays < 7 && chance(0.3)
        batch.ai.append(ThreadAI(
            accountId: account.id, threadId: threadId, category: kind.category, needsReply: needsReply,
            priority: kind == .people ? (needsReply ? 2 : 1) : 0,
            summary: kind == .people && chance(0.5) ? summary(parts.last!.from.firstName, subject: parts[0].subject) : nil,
            source: "rules", messageCount: parts.count, classifiedAt: options.now))

        if snoozed {
            batch.snoozes.append(Snooze(
                accountId: account.id, threadId: threadId,
                until: options.now.addingTimeInterval(Double(int(3_600...(6 * 86_400))))))
        }
        batch.threadCount += 1
        _ = age
    }

    mutating func summary(_ name: String, subject: String) -> String {
        pick([
            "\(name) wants a decision on \(subject.lowercased()) by Thursday.",
            "\(name) shared an update and asks if a quick call works this week.",
            "\(name) needs your sign-off before it goes to the client.",
            "\(name) is waiting on the final numbers from you.",
            "\(name) proposes moving the date by a week; reply to confirm.",
        ])
    }

    mutating func automatedText(_ kind: Kind, sender: String, subject: String) -> String {
        switch kind {
        case .notification:
            return "\(subject)\n\n\(pick(Self.sentences))\n\nView it on \(sender): https://example.com/item/\(int(100...999))\n\nYou are receiving this because you are subscribed to this thread."
        case .newsletter:
            return "\(subject)\n\n" + (0..<6).map { _ in pick(Self.sentences) }.joined(separator: " ") + "\n\nRead online · Unsubscribe"
        case .receipt:
            return "Thanks for your purchase.\n\nAmount paid: $\(int(4...480)).\(int(10...99))\nDate: \(options.now.formatted(date: .abbreviated, time: .omitted))\nPayment method: Visa •••• 4242\n\nQuestions? Reply to this email."
        case .promotion:
            return "\(subject)\n\nNew arrivals picked for you. Free shipping on orders over $50.\n\nShop now · Unsubscribe"
        default:
            return "\(subject)\n\nYour code is \(int(100_000...999_999)). It expires in 10 minutes. If this wasn't you, secure your account."
        }
    }

    func plainToHTML(_ text: String) -> String {
        var html = ""
        var quote: [String] = []
        func flushQuote() {
            guard !quote.isEmpty else { return }
            html += "<blockquote class=\"gmail_quote\">" + quote.map(escape).joined(separator: "<br>") + "</blockquote>"
            quote = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("> ") { quote.append(String(line.dropFirst(2))); continue }
            flushQuote()
            html += line.isEmpty ? "<br>" : "<div>\(escape(String(line)))</div>"
        }
        flushQuote()
        return "<div dir=\"ltr\">\(html)</div>"
    }

    func newsletterHTML(sender: String, subject: String, text: String) -> String {
        let paragraphs = text.split(separator: "\n").dropFirst().map { "<p style=\"margin:0 0 14px;line-height:1.6\">\(escape(String($0)))</p>" }.joined()
        return """
            <table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f1ec;font-family:Georgia,serif">
            <tr><td align="center" style="padding:32px 16px">
            <table width="600" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:8px">
            <tr><td style="padding:28px 36px 8px;font:600 13px Helvetica,Arial,sans-serif;letter-spacing:.08em;color:#9a6b3f;text-transform:uppercase">\(escape(sender))</td></tr>
            <tr><td style="padding:0 36px 16px;font:700 28px/1.25 Georgia,serif;color:#1c1b19">\(escape(subject))</td></tr>
            <tr><td style="padding:0 36px 8px;font:16px Georgia,serif;color:#33302b">\(paragraphs)</td></tr>
            <tr><td style="padding:8px 36px 32px"><a href="https://example.com" style="display:inline-block;background:#1c1b19;color:#fff;padding:12px 22px;border-radius:6px;font:600 14px Helvetica,Arial,sans-serif;text-decoration:none">Read more</a></td></tr>
            </table>
            <p style="font:12px Helvetica,Arial,sans-serif;color:#8a857d">You're receiving this because you subscribed. <a href="https://example.com/unsubscribe" style="color:#8a857d">Unsubscribe</a></p>
            </td></tr></table>
            """
    }

    func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    mutating func makeProjects(into batch: inout Batch) {
        let lumen = Project(id: "proj-lumen", name: "Lumen redesign", colorIndex: 3, icon: "paintpalette", sortOrder: 0, createdAt: options.now)
        let tern = Project(id: "proj-kiteworks", name: "Kiteworks", colorIndex: 4, icon: "paperplane", sortOrder: 1, createdAt: options.now)
        let home = Project(id: "proj-home", name: "Home & travel", colorIndex: 5, icon: "house", sortOrder: 2, createdAt: options.now)
        batch.projects = [lumen, tern, home]
        batch.rules = [
            ProjectRule(projectId: lumen.id, field: .fromDomain, value: "lumen.io"),
            ProjectRule(projectId: lumen.id, field: .subjectContains, value: "Lumen"),
            ProjectRule(projectId: tern.id, field: .account, value: "alex@kiteworks.dev"),
            ProjectRule(projectId: home.id, field: .label, value: "Label_travel"),
            ProjectRule(projectId: home.id, field: .from, value: "linda.morgan@gmail.com"),
        ]
        var linked = Set<String>()
        for message in batch.messages {
            let key = "\(message.accountId)/\(message.threadId)"
            var projects: [String] = []
            if message.fromEmail.hasSuffix("@lumen.io") || message.subject.contains("Lumen") { projects.append(lumen.id) }
            if message.accountId == "alex@kiteworks.dev" { projects.append(tern.id) }
            if message.labelIds.contains("Label_travel") || message.fromEmail == "linda.morgan@gmail.com" { projects.append(home.id) }
            for project in projects where linked.insert("\(key)#\(project)").inserted {
                batch.projectLinks.append(ThreadProject(accountId: message.accountId, threadId: message.threadId, projectId: project, source: .rule))
            }
        }
    }
}
