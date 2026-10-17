import Foundation
import GRDB

/// Instant, offline triage from headers and labels. Sync calls it for every thread it touches so the
/// split inbox works before (or without) the AI classifier, which later refines people/other threads.
public enum RuleClassifier {
    public static let source = "rules"
    /// `needsReply` is only set while the last message is younger than this.
    public static let needsReplyWindow: TimeInterval = 14 * 86_400

    public struct Verdict: Hashable, Sendable {
        public var category: MailCategory
        public var needsReply: Bool
        public var priority: Int
    }

    /// Classifies these threads and writes their `ThreadAI` rows. An AI-sourced row is kept unless the
    /// thread has grown since it was classified. Returns the number of rows written.
    @discardableResult
    public static func classify(_ db: Database, keys: some Collection<ThreadKey>, now: Date = Date()) throws -> Int {
        guard !keys.isEmpty else { return 0 }
        let context = try Context.load(db)
        var written = 0
        for chunk in Array(keys).chunked(by: 400) {
            written += try classifyChunk(db, chunk, context: context, now: now)
        }
        return written
    }

    /// Backfill: classifies every thread with no row yet, or whose row predates new messages.
    @discardableResult
    public static func classifyAllMissing(_ db: Database, now: Date = Date()) throws -> Int {
        let keys = try Row.fetchAll(db, sql: """
            SELECT t.accountId, t.id FROM thread t
            LEFT JOIN thread_ai ai ON ai.accountId = t.accountId AND ai.threadId = t.id
            WHERE ai.threadId IS NULL OR ai.messageCount != t.messageCount
            ORDER BY t.lastDate DESC
            """).map { ThreadKey(accountId: $0[0], threadId: $0[1]) }
        return try classify(db, keys: keys, now: now)
    }

    /// Clears `needsReply` on threads whose last message aged past the window.
    @discardableResult
    public static func expireNeedsReply(_ db: Database, now: Date = Date()) throws -> Int {
        try db.execute(sql: """
            UPDATE thread_ai SET needsReply = 0
            WHERE needsReply = 1 AND EXISTS (
              SELECT 1 FROM thread t WHERE t.accountId = thread_ai.accountId AND t.id = thread_ai.threadId
                AND t.lastDate < ?)
            """, arguments: [now.timeIntervalSince1970 - needsReplyWindow])
        return db.changesCount
    }

    // MARK: Decision

    /// What a thread looks like to the classifier. Messages are non-drafts, oldest first.
    struct Input {
        struct Message {
            var fromEmail: String
            var to: [Participant]
            var subject: String
            /// Snippet, or the start of the body when it is stored.
            var text: String
            var isFromMe: Bool
            var date: Date
            var hasListUnsubscribe: Bool
        }

        var key: ThreadKey
        var accountEmail: String
        var messageCount: Int
        var subject: String
        var labelIds: Set<String>
        var isStarred: Bool
        var lastDate: Date
        var hasCalendarPart: Bool
        var messages: [Message]
    }

    struct Context {
        /// Account id → its address, lowercased.
        var accountEmails: [String: String]
        /// Addresses the user has written to.
        var correspondents: Set<String>

        static func load(_ db: Database) throws -> Context {
            var emails: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, email FROM account") {
                emails[row[0]] = (row[1] as String).lowercased()
            }
            let correspondents = try String.fetchSet(db, sql: "SELECT id FROM contact WHERE sentCount > 0")
            return Context(accountEmails: emails, correspondents: correspondents)
        }
    }

    static func verdict(for input: Input, context: Context, now: Date) -> Verdict {
        let category = category(for: input, context: context)
        let needsReply = category == .people && needsReply(input, now: now)
        return Verdict(category: category, needsReply: needsReply, priority: priority(category, input: input, needsReply: needsReply))
    }

    static func category(for input: Input, context: Context) -> MailCategory {
        let subject = input.subject
        if input.hasCalendarPart || hasCalendarSubject(subject) { return .calendar }

        guard let inbound = input.messages.last(where: { !$0.isFromMe }) else { return .people }
        let sender = inbound.fromEmail.lowercased()
        let domain = MailText.domain(of: sender)
        if sender == "calendar-notification@google.com" { return .calendar }

        let human = isHuman(sender, accountEmail: input.accountEmail, context: context) && !inbound.hasListUnsubscribe
        let isTool = toolDomains.contains(where: { MailText.domain(domain, isWithin: $0) })
        let looksLikeReceipt = matches(receiptPatterns, subject) || matches(receiptBodyPatterns, inbound.text)

        if !human {
            if matches(securityPatterns, subject) || matches(securityCodePatterns, inbound.text) { return .security }
            if !isTool && looksLikeReceipt { return .receipt }
        }
        let promotionsTab = input.labelIds.contains(SystemLabel.categoryPromotions)
        if isTool && !promotionsTab {
            // Tools mention invoices in issue titles; only their billing senders send receipts.
            return billingLocalParts.contains(MailText.localPart(of: sender)) && looksLikeReceipt ? .receipt : .notification
        }
        if inbound.hasListUnsubscribe || promotionsTab {
            if newsletterDomains.contains(where: { MailText.domain(domain, isWithin: $0) })
                || matches(newsletterPatterns, subject) {
                return .newsletter
            }
            // Sales language counts in the subject or the opening lines; an article that mentions a
            // "deal" deep in its text is still a newsletter.
            let opening = subject + "\n" + String(inbound.text.prefix(240))
            if matches(promotionPatterns, opening) { return .promotion }
            // In the Promotions tab without sales language: an article-length body reads as a newsletter.
            if promotionsTab { return inbound.text.count > 300 ? .newsletter : .promotion }
            return .newsletter
        }
        if isAutomated(sender) || input.labelIds.contains(SystemLabel.categorySocial)
            || input.labelIds.contains(SystemLabel.categoryUpdates) && !human {
            return .notification
        }
        return human ? .people : .other
    }

    static func needsReply(_ input: Input, now: Date) -> Bool {
        guard let last = input.messages.last, !last.isFromMe,
              now.timeIntervalSince(last.date) <= needsReplyWindow,
              last.to.contains(where: { $0.email.lowercased() == input.accountEmail })
        else { return false }
        let text = MailText.stripQuoted(last.text)
        return text.contains("?") || matches(requestPatterns, text) || matches(requestPatterns, last.subject)
    }

    static func priority(_ category: MailCategory, input: Input, needsReply: Bool) -> Int {
        switch category {
        case .people:
            if needsReply, let last = input.messages.last, matches(urgentPatterns, last.subject + "\n" + last.text) { return 3 }
            return needsReply || input.isStarred || input.labelIds.contains(SystemLabel.important) ? 2 : 1
        case .security: return 2
        case .calendar, .other: return 1
        case .notification: return input.labelIds.contains(SystemLabel.important) ? 1 : 0
        case .receipt, .newsletter, .promotion: return 0
        }
    }

    // MARK: Senders

    static func isHuman(_ sender: String, accountEmail: String, context: Context) -> Bool {
        guard !isAutomated(sender) else { return false }
        let domain = MailText.domain(of: sender)
        if personalDomains.contains(domain) || context.correspondents.contains(sender) { return true }
        let ownDomain = MailText.domain(of: accountEmail)
        return !personalDomains.contains(ownDomain) && domain == ownDomain
    }

    static func isAutomated(_ sender: String) -> Bool {
        let local = MailText.localPart(of: sender)
        if roleLocalParts.contains(local) { return true }
        if automatedFragments.contains(where: { local.contains($0) }) { return true }
        let domain = MailText.domain(of: sender)
        return bulkSubdomainPrefixes.contains(where: { domain.hasPrefix($0) })
    }

    static func hasCalendarSubject(_ subject: String) -> Bool {
        let lower = subject.lowercased()
        return calendarPrefixes.contains(where: { lower.hasPrefix($0) })
    }

    // MARK: Word lists

    static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com",
        "hotmail.co.uk", "live.com", "msn.com", "yahoo.com", "yahoo.co.uk", "ymail.com", "aol.com",
        "proton.me", "protonmail.com", "pm.me", "fastmail.com", "fastmail.fm", "hey.com", "gmx.com",
        "gmx.de", "gmx.net", "web.de", "mail.com", "zoho.com", "yandex.com", "yandex.ru", "qq.com",
        "163.com", "naver.com", "comcast.net", "verizon.net", "att.net", "btinternet.com",
    ]

    /// Developer and work tools whose mail is activity notifications.
    static let toolDomains: [String] = [
        "github.com", "gitlab.com", "bitbucket.org", "linear.app", "vercel.com", "netlify.com", "figma.com",
        "sentry.io", "slack.com", "atlassian.net", "atlassian.com", "jira.com", "notion.so", "asana.com",
        "trello.com", "clickup.com", "monday.com", "airtable.com", "zoom.us", "calendly.com", "loom.com",
        "miro.com", "discord.com", "discordapp.com", "circleci.com", "heroku.com", "render.com", "fly.io",
        "railway.app", "supabase.io", "supabase.com", "cloudflare.com", "digitalocean.com", "pagerduty.com",
        "datadoghq.com", "statuspage.io", "intercom.io", "zendesk.com", "docusign.net", "docusign.com",
        "dropbox.com", "stripe.com", "posthog.com", "expo.dev", "testflight.apple.com",
    ]

    static let newsletterDomains: [String] = [
        "substack.com", "beehiiv.com", "buttondown.email", "convertkit.com", "ck.page", "ghost.io",
        "mailchimpapp.com", "list-manage.com", "medium.com", "tldrnewsletter.com", "morningbrew.com",
    ]

    static let roleLocalParts: Set<String> = [
        "notifications", "notification", "notify", "alerts", "alert", "mailer-daemon", "postmaster",
        "bounce", "bounces", "automated", "receipts", "receipt", "billing", "invoice", "invoices", "payments",
        "orders", "order", "shipping", "support", "info", "news", "newsletter", "hello", "team", "marketing",
        "updates", "digest", "security", "account", "accounts", "verify", "feedback", "store", "shop",
        "auto-confirm", "help", "email", "mail",
    ]

    static let billingLocalParts: Set<String> = ["receipts", "receipt", "billing", "invoice", "invoices", "payments", "payment", "orders"]

    static let automatedFragments = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply", "notification"]

    static let bulkSubdomainPrefixes = ["email.", "mail.", "e.", "em.", "news.", "info.", "mailer.", "notifications.", "updates.", "marketing."]

    static let calendarPrefixes = [
        "invitation:", "updated invitation", "invitation from google calendar", "accepted:", "declined:",
        "tentatively accepted:", "tentative:", "canceled event", "cancelled event", "canceled:", "cancelled:",
        "new event:", "event canceled", "event cancelled",
    ]

    static let securityPatterns = regexes([
        #"\b(sign[- ]?in|log[- ]?in|verification|security|confirmation|one[- ]time|access|auth(entication)?|2fa) code\b"#,
        #"\b\d{4,8} is your\b"#, #"\bcode( is)?:?\s+\d{4,8}\b"#,
        #"\bpassword (reset|was changed|changed)\b"#, #"\breset your password\b"#, #"\bchange your password\b"#,
        #"\bsecurity (alert|notice|notification)\b"#, #"\bnew (sign[- ]?in|login|device)\b"#,
        #"\b(sign[- ]?in|login) attempt\b"#, #"\bsuspicious\b"#, #"\bunusual (sign|login|activity)\b"#,
        #"\bverify your (email|account|identity|device)\b"#, #"\bconfirm your email\b"#,
        #"\b(two[- ]factor|2-step|2fa|mfa)\b"#, #"\bnew (ssh|gpg|api|personal access) (key|token)\b"#, #"\bmagic link\b"#,
    ])

    static let securityCodePatterns = regexes([#"\bcode( is)?:?\s+\d{4,8}\b"#, #"\b\d{4,8} is your (verification |sign[- ]?in |login |security )?code\b"#])

    static let receiptPatterns = regexes([
        #"\breceipt\b"#, #"\binvoice\b"#, #"\border (confirmation|confirmed|#|no\.|number|\d)"#,
        #"\byour (\S+ )?order\b"#, #"\bpayment (received|confirmation|successful|processed|failed)\b"#,
        #"\byour (\w+ )*(trip|ride) with\b"#, #"\bsubscription (renewed|renewal|confirmation)\b"#,
        #"\byour .{0,30}subscription\b"#, #"\b(has|have) shipped\b"#, #"\bout for delivery\b"#,
        #"\b(billing )?statement is (ready|available)\b"#, #"\bthanks for your (order|purchase)\b"#,
        #"\b(booking|reservation) (confirmed|confirmation)\b"#, #"\bpurchase confirmation\b"#,
    ])

    static let receiptBodyPatterns = regexes([#"\bthanks for your (purchase|order)\b"#, #"\bamount paid\b"#, #"\border total\b"#])

    static let newsletterPatterns = regexes([
        #"\bnewsletter\b"#, #"\bissue\s*#?\d+"#, #"\bdigest\b"#, #"\bweekly\b"#, #"\bedition\b"#, #"\broundup\b"#,
    ])

    static let promotionPatterns = regexes([
        #"\d+\s?% off\b"#, #"\bsale\b"#, #"\bdeals?\b"#, #"\bdiscount\b"#, #"\bfree shipping\b"#,
        #"\bends (tonight|today|soon)\b"#, #"\blimited time\b"#, #"\bnew arrivals\b"#, #"\bback in stock\b"#,
        #"\bcoupon\b"#, #"\bpromo code\b"#, #"\bshop now\b"#, #"\bsave \$\d"#, #"\bwhat'?s new in\b"#,
        #"\bideas for your next\b"#, #"\byou might like\b"#, #"\bis here\b"#, #"\bspecial offer\b"#,
    ])

    static let requestPatterns = regexes([
        #"\b(can|could|would|will) you\b"#, #"\bplease\b"#, #"\blet me know\b"#, #"\bany (thoughts|update|chance)\b"#,
        #"\bwhat do you think\b"#, #"\b(can|should) we\b"#, #"\bare you (free|around|available|able|ok)\b"#,
        #"\bdo you (have|know|want|mind|need)\b"#, #"\bwaiting (on|for) (you|your)\b"#, #"\bneed your\b"#,
        #"\bsign[- ]?off\b"#, #"\bapprov(e|al)\b"#, #"\bconfirm\b"#, #"\brsvp\b"#, #"\bget back to me\b"#,
        #"\bwhen (can|could|will|would)\b"#,
    ])

    static let urgentPatterns = regexes([#"\burgent\b"#, #"\basap\b"#, #"\bimmediately\b"#, #"\b(eod|end of day)\b"#, #"\bby today\b"#])

    private static func regexes(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    static func matches(_ patterns: [NSRegularExpression], _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    // MARK: Loading and writing

    private static func classifyChunk(_ db: Database, _ keys: [ThreadKey], context: Context, now: Date) throws -> Int {
        let (values, arguments) = keyValues(keys)
        var inputs: [ThreadKey: Input] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT accountId, id, messageCount, subject, labelIds, isStarred, lastDate FROM thread t
            WHERE (t.accountId, t.id) IN (VALUES \(values))
            """, arguments: arguments) {
            let key = ThreadKey(accountId: row["accountId"], threadId: row["id"])
            let labels = (try? JSONDecoder().decode([String].self, from: Data((row["labelIds"] as String).utf8))) ?? []
            inputs[key] = Input(
                key: key, accountEmail: context.accountEmails[key.accountId] ?? key.accountId.lowercased(),
                messageCount: row["messageCount"], subject: row["subject"], labelIds: Set(labels), isStarred: row["isStarred"],
                lastDate: Date(timeIntervalSince1970: row["lastDate"]), hasCalendarPart: false, messages: [])
        }
        guard !inputs.isEmpty else { return 0 }

        for row in try Row.fetchAll(db, sql: """
            SELECT m.accountId, m.threadId, m.date, m.fromEmail, m.toList, m.subject, m.snippet,
              substr(m.bodyText, 1, 2000) AS bodyHead, m.isFromMe, m.listUnsubscribe IS NOT NULL AS hasList
            FROM message m WHERE (m.accountId, m.threadId) IN (VALUES \(values)) AND m.isDraft = 0
            ORDER BY m.date
            """, arguments: arguments) {
            let key = ThreadKey(accountId: row["accountId"], threadId: row["threadId"])
            let to = (try? JSONDecoder().decode([Participant].self, from: Data((row["toList"] as String).utf8))) ?? []
            let body: String? = row["bodyHead"]
            inputs[key]?.messages.append(Input.Message(
                fromEmail: row["fromEmail"], to: to, subject: row["subject"],
                text: body.flatMap { $0.isEmpty ? nil : $0 } ?? row["snippet"], isFromMe: row["isFromMe"],
                date: Date(timeIntervalSince1970: row["date"]), hasListUnsubscribe: row["hasList"]))
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT DISTINCT m.accountId, m.threadId FROM message m
            JOIN attachment a ON a.accountId = m.accountId AND a.messageId = m.id
            WHERE (m.accountId, m.threadId) IN (VALUES \(values))
              AND (a.mimeType LIKE 'text/calendar%' OR lower(a.filename) LIKE '%.ics')
            """, arguments: arguments) {
            inputs[ThreadKey(accountId: row[0], threadId: row[1])]?.hasCalendarPart = true
        }

        var existing: [ThreadKey: ThreadAI] = [:]
        for ai in try ThreadAI.fetchAll(db, sql: """
            SELECT * FROM thread_ai WHERE (accountId, threadId) IN (VALUES \(values))
            """, arguments: arguments) {
            existing[ThreadKey(accountId: ai.accountId, threadId: ai.threadId)] = ai
        }

        var written = 0
        for (key, input) in inputs where !input.messages.isEmpty {
            let messageCount = input.messageCount
            let previous = existing[key]
            if let previous, previous.source != source, previous.messageCount >= messageCount { continue }
            let verdict = verdict(for: input, context: context, now: now)
            if let previous, previous.source == source, previous.messageCount == messageCount,
               previous.category == verdict.category, previous.needsReply == verdict.needsReply,
               previous.priority == verdict.priority {
                continue
            }
            let summary = previous?.messageCount == messageCount ? previous?.summary : nil
            try ThreadAI(
                accountId: key.accountId, threadId: key.threadId, category: verdict.category,
                needsReply: verdict.needsReply, priority: verdict.priority, summary: summary, source: source,
                messageCount: messageCount, classifiedAt: now
            ).upsert(db)
            written += 1
        }
        return written
    }

    private static func keyValues(_ keys: [ThreadKey]) -> (String, StatementArguments) {
        var arguments: StatementArguments = []
        for key in keys { _ = arguments.append(contentsOf: [key.accountId, key.threadId]) }
        return (keys.map { _ in "(?, ?)" }.joined(separator: ", "), arguments)
    }
}

fileprivate extension Array {
    func chunked(by size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
