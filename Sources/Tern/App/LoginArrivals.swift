import AppKit
import GRDB
import Observation
import TernCore

/// A transient result from one inbound message. Credentials are never stored separately from mail.
struct LoginArrival: Equatable {
    let message: MessageKey
    let date: Date
    let sender: String
    let credentials: [LoginCredential]

    init?(_ message: MailMessage, now: Date) {
        guard !message.isFromMe, !message.isDraft,
              !message.labelIds.contains(SystemLabel.spam), !message.labelIds.contains(SystemLabel.trash),
              LoginAssistance.isFresh(date: message.date, now: now) else { return nil }
        let credentials = LoginAssistance.extract(subject: message.subject,
            text: message.bodyText.flatMap { $0.isEmpty ? nil : $0 } ?? message.snippet, html: message.bodyHtml)
        guard !credentials.isEmpty else { return nil }
        self.message = message.key
        date = message.date
        sender = message.fromName.isEmpty ? message.fromEmail : message.fromName
        self.credentials = credentials
    }

    /// Indexed and bounded; runs inside a background database observation, never while painting a row.
    static func fetch(_ db: Database, since: Date, now: Date) throws -> [LoginArrival] {
        try MailMessage.fetchAll(db, sql: """
            SELECT * FROM message WHERE date > ? AND date >= ? AND isFromMe = 0 AND isDraft = 0
              AND isUnread = 1
              AND EXISTS (SELECT 1 FROM json_each(message.labelIds) WHERE value = 'INBOX')
              AND NOT EXISTS (SELECT 1 FROM json_each(message.labelIds) WHERE value IN ('SPAM', 'TRASH'))
            ORDER BY date DESC LIMIT 40
            """, arguments: [since.timeIntervalSince1970, now.addingTimeInterval(-1_200).timeIntervalSince1970])
            .compactMap { LoginArrival($0, now: now) }
    }
}

/// Only new, unread inbox mail may interrupt. Re-observation and body hydration do not repeat a popup.
struct LoginArrivalPlanner {
    let since: Date
    private var seen: [MessageKey: Date] = [:]

    init(since: Date) { self.since = since }

    mutating func next(_ arrivals: [LoginArrival], enabled: Bool, now: Date) -> LoginArrival? {
        seen = seen.filter { LoginAssistance.isFresh(date: $0.value, now: now) }
        var selected: LoginArrival?
        for arrival in arrivals.sorted(by: { $0.date > $1.date }) {
            guard arrival.date > since, LoginAssistance.isFresh(date: arrival.date, now: now),
                  seen[arrival.message] == nil else { continue }
            seen[arrival.message] = arrival.date
            if enabled, selected == nil { selected = arrival }
        }
        return selected
    }
}

/// Independent of system banners and AI. Turning it off immediately dismisses the transient panel.
@MainActor
final class LoginArrivals {
    private let services: AppServices
    private let prefs: Preferences
    private let popup = LoginPopup()
    private var planner = LoginArrivalPlanner(since: Date())
    private var observation: AnyDatabaseCancellable?
    private var shown: MessageKey?
    private var stopped = false

    init(services: AppServices, prefs: Preferences) {
        self.services = services
        self.prefs = prefs
    }

    func start() {
        stopped = false
        watchPreference()
        let since = planner.since
        observation = ValueObservation.tracking { db in
            try LoginArrival.fetch(db, since: since, now: Date())
        }
        .removeDuplicates()
        .startRestarting(in: services.store.database.reader, scheduling: .async(onQueue: .main),
            onError: { _ in NSLog("Tern: login arrival observation failed; restarting") },
            onChange: { [weak self] arrivals in MainActor.assumeIsolated { self?.receive(arrivals) } })
    }

    func stop() {
        stopped = true
        observation = nil
        popup.dismiss()
    }

    private func watchPreference() {
        withObservationTracking { _ = prefs.showLoginPopups } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if !self.prefs.showLoginPopups { self.popup.dismiss() }
                self.watchPreference()
            }
        }
    }

    private func receive(_ arrivals: [LoginArrival]) {
        if let shown, !arrivals.contains(where: { $0.message == shown }) {
            popup.dismiss()
            self.shown = nil
        }
        guard let arrival = planner.next(arrivals, enabled: prefs.showLoginPopups, now: Date()) else { return }
        let account = services.account(arrival.message.accountId)?.email ?? arrival.message.accountId
        shown = arrival.message
        popup.show(sender: arrival.sender, account: account, credentials: arrival.credentials) { credential in
            guard LoginAssistance.isFresh(date: arrival.date, now: Date()) else { return }
            LoginActions.perform(credential)
        }
    }
}
