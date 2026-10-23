import AppKit
import GRDB
import SwiftUI
import Testing
@testable import Tern
@testable import TernCore

@Suite("Login assistance integration")
struct LoginAssistanceIntegrationTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func mail(_ id: String, account: String = "me@example.com", age: Double = 5,
                      labels: [String] = ["INBOX", "UNREAD"], fromMe: Bool = false) -> MailMessage {
        MailMessage(accountId: account, id: id, threadId: "t-\(id)", date: now.addingTimeInterval(-age),
            fromName: "Acme", fromEmail: "login@acme.com", subject: "Your sign-in code",
            bodyText: "Your verification code is 038271. It expires in 10 minutes.",
            bodyState: .full, labelIds: labels, isFromMe: fromMe)
    }

    @Test func arrivalQueryExcludesHistoricalReadAndUnsafeMail() throws {
        let store = MailStore(try AppDatabase.inMemory())
        try store.upsertAccount(Account(email: "me@example.com"))
        try store.upsertMessages([
            mail("new"), mail("old", age: 400), mail("read", labels: ["INBOX"]),
            mail("archived", labels: ["UNREAD"]), mail("spam", labels: ["INBOX", "UNREAD", "SPAM"]),
            mail("trash", labels: ["INBOX", "UNREAD", "TRASH"]), mail("sent", fromMe: true),
        ])
        let arrivals = try store.database.reader.read {
            try LoginArrival.fetch($0, since: now.addingTimeInterval(-30), now: now)
        }
        #expect(arrivals.map(\.message.messageId) == ["new"])
        #expect(arrivals.first?.credentials == [.code("038271")])
    }

    @Test func popupIsOptInAndDoesNotReplayAfterReobservation() throws {
        let first = try #require(LoginArrival(mail("a"), now: now))
        let second = try #require(LoginArrival(mail("b", age: 3), now: now))
        let otherAccount = try #require(LoginArrival(mail("b", account: "work@example.com", age: 2), now: now))
        var planner = LoginArrivalPlanner(since: now.addingTimeInterval(-30))
        #expect(planner.next([first], enabled: false, now: now) == nil)
        #expect(planner.next([first], enabled: true, now: now) == nil)
        #expect(planner.next([first, second], enabled: true, now: now)?.message == second.message)
        #expect(planner.next([], enabled: true, now: now) == nil)
        #expect(planner.next([second], enabled: true, now: now) == nil, "reading then marking unread must not repeat the popup")
        #expect(planner.next([otherAccount], enabled: true, now: now)?.message == otherAccount.message)
        #expect(planner.next([first], enabled: true, now: now.addingTimeInterval(1_300)) == nil)
    }

    @MainActor @Test func copiedCodesUsePrivateTransientPasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        LoginActions.copy("038271", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "038271")
        #expect(pasteboard.types?.contains(.init("org.nspasteboard.ConcealedType")) == true)
        #expect(pasteboard.types?.contains(.init("org.nspasteboard.TransientType")) == true)
    }

    @MainActor @Test func popupPreferenceDefaultsOffAndIsSearchable() throws {
        let name = "tern-login-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        #expect(!preferences.showLoginPopups)
        preferences.showLoginPopups = true
        #expect(Preferences(defaults: defaults).showLoginPopups)
        #expect(SettingsItem.loginPopups.section == .notifications)
        #expect(SettingsCatalog.matches("otp", in: SettingsItem.loginPopups.searchText))
        #expect(SettingsCatalog.matches("magic", in: SettingsItem.loginPopups.searchText))
    }

    @MainActor @Test func readerFollowsFreshCredentialsAndClearsOnNavigation() throws {
        _ = NSApplication.shared
        let store = MailStore(try AppDatabase.inMemory())
        try store.upsertAccount(Account(email: "me@example.com"))
        var codeMail = mail("reader")
        codeMail.date = Date()
        try store.upsertMessages([codeMail])
        let services = AppServices(store: store)
        let reader = ReaderModel()
        reader.attach(services)
        reader.show(ThreadKey(accountId: codeMail.accountId, threadId: codeMail.threadId))
        #expect(reader.loginCredentials == [.code("038271")])
        var oldMail = mail("expired")
        oldMail.date = Date().addingTimeInterval(-1_201)
        var sentMail = mail("outgoing", fromMe: true)
        sentMail.date = Date()
        try store.upsertMessages([oldMail, sentMail])
        reader.show(ThreadKey(accountId: oldMail.accountId, threadId: oldMail.threadId))
        #expect(reader.loginCredentials.isEmpty)
        reader.show(ThreadKey(accountId: sentMail.accountId, threadId: sentMail.threadId))
        #expect(reader.loginCredentials.isEmpty)
        reader.show(nil)
        #expect(reader.loginCredentials.isEmpty)
    }

    /// Optional offscreen artifacts with fictional mail. Set CFFIXED_USER_HOME to an isolated scratch home.
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_LOGIN_SHOTS"] != nil))
    func snapshots() throws {
        try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil,
                     "Snapshots must not change the user's preferences")
        _ = NSApplication.shared
        Theme.registerFonts()
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TERN_LOGIN_SHOTS"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let link = try #require(URL(string: "https://accounts.acme.com/sign-in?token=fictional-demo-token"))
        let services = AppServices(store: MailStore(try AppDatabase.inMemory()))
        let model = AppModel(services: services, isFake: true, databaseURL: URL(fileURLWithPath: "/dev/null"))
        let popupsBefore = model.prefs.showLoginPopups
        // Offscreen renders can't draw Liquid Glass; the card shows its solid surface.
        LoginCard.drawsGlass = false
        defer { LoginCard.drawsGlass = true }
        defer { model.prefs.showLoginPopups = popupsBefore }
        for dark in [false, true] {
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            let suffix = dark ? "dark" : "light"
            try render(LoginPopupView(sender: "Acme", account: "alex@northwind.studio", credentials: [.code("038271")],
                perform: { _ in }, dismiss: {}), width: 360, appearance: appearance, to: output.appendingPathComponent("popup-code-\(suffix).png"))
            try render(LoginPopupView(sender: "Northwind account security", account: "alex@northwind.studio",
                credentials: [.magicLink(link)], perform: { _ in }, dismiss: {}), width: 360, appearance: appearance,
                to: output.appendingPathComponent("popup-link-\(suffix).png"))
            try render(ReaderLoginActions(credentials: [.code("038271"), .magicLink(link)], perform: { _ in }).padding(16),
                width: 540, appearance: appearance, to: output.appendingPathComponent("reader-actions-\(suffix).png"))
            try render(LoginPopupView(sender: "An exceptionally long account-security sender name that must truncate",
                account: "a-very-long-work-account-address@northwind-studio.example.com", credentials: [.code("038271"), .magicLink(link)],
                perform: { _ in }, dismiss: {}), width: 320, appearance: appearance,
                to: output.appendingPathComponent("popup-both-narrow-\(suffix).png"))
            for enabled in [false, true] {
                model.prefs.showLoginPopups = enabled
                try render(LoginPopupItem().environment(model).padding(20), width: 680, appearance: appearance,
                    to: output.appendingPathComponent("setting-\(enabled ? "on" : "off")-\(suffix).png"))
            }
        }
    }

    @MainActor private func render<V: View>(_ view: V, width: CGFloat, appearance: NSAppearance, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: width).background(Color(Theme.raised)))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer { window.close() }
        window.setContentSize(host.fittingSize)
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
