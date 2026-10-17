import AppKit
import GRDB
import TernCore
import UserNotifications

/// Banners for new inbox mail while Tern isn't the active app. "Only important" limits them to people,
/// needs reply, calendar and security. At most one banner every 10 seconds: mail that arrives in
/// between is summed up in the next one. Banners group by account in Notification Center, and clicking
/// one opens its thread.
@MainActor
final class MailNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let services: AppServices
    private let prefs: Preferences
    private var planner = NotificationPlanner(since: Date())
    private var observation: AnyDatabaseCancellable?
    private var flushTimer: Timer?

    init(services: AppServices, prefs: Preferences) {
        self.services = services
        self.prefs = prefs
    }

    func start() {
        // UserNotifications needs a bundle; a bare `swift run` binary has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if prefs.notificationsEnabled {
            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { NSLog("Tern: notification permission failed: \(error)") }
            }
        }
        observation = ValueObservation
            .tracking { db in try MailStore.fetchThreadRows(db, in: .unifiedInbox, limit: 40, before: nil) }
            .removeDuplicates()
            .startRestarting(in: services.store.database.reader, scheduling: .async(onQueue: .main),
                   onError: { NSLog("Tern: notification observation failed, restarting it: \($0)") },
                   onChange: { [weak self] rows in MainActor.assumeIsolated { self?.receive(rows) } })
    }

    func stop() {
        observation = nil
        flushTimer?.invalidate()
    }

    private func receive(_ rows: [ThreadRow]) {
        planner.consider(rows, appActive: NSApp.isActive, enabled: prefs.notificationsEnabled, onlyImportant: prefs.notifyOnlyImportant)
        flush()
    }

    private func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        let now = Date()
        if let banner = planner.next(now: now) { post(banner) }
        if let wait = planner.nextAllowed(now: now) {
            flushTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    private func post(_ banner: NotificationPlanner.Banner) {
        let content = UNMutableNotificationContent()
        content.title = banner.title
        if let subtitle = banner.subtitle { content.subtitle = subtitle }
        content.body = banner.body
        content.sound = .default
        content.threadIdentifier = banner.thread.accountId
        content.userInfo = ["accountId": banner.thread.accountId, "threadId": banner.thread.threadId]
        let request = UNNotificationRequest(identifier: "\(banner.thread.description)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Tern: posting a notification failed: \(error)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let accountId = info["accountId"] as? String, let threadId = info["threadId"] as? String {
            let key = ThreadKey(accountId: accountId, threadId: threadId)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.services.showThread(key) } }
        }
        completionHandler()
    }
}

/// Decides which new mail gets a banner, and when. Pure, so the self-check can drive it.
struct NotificationPlanner {
    struct Banner: Equatable {
        var title: String
        var subtitle: String?
        var body: String
        /// The thread a click opens (the newest one in a summary).
        var thread: ThreadKey
    }

    /// Only mail newer than this notifies, so what was there at launch never does.
    var since: Date
    static let spacing: TimeInterval = 10

    private var seen: [ThreadKey: Date] = [:]
    private var pending: [ThreadRow] = []
    private var lastBanner: Date?

    init(since: Date) {
        self.since = since
    }

    /// Queues unread inbox threads with new mail. Mail that arrives while Tern is active, or with banners
    /// off, is marked seen and never notifies later. With "only important", unclassified threads wait
    /// until the classifier has seen them.
    mutating func consider(_ rows: [ThreadRow], appActive: Bool, enabled: Bool, onlyImportant: Bool) {
        for row in rows where row.thread.unreadCount > 0 && row.thread.lastDate > since {
            let date = row.thread.lastDate
            if let last = seen[row.id], last >= date { continue }
            if appActive || !enabled {
                seen[row.id] = date
                continue
            }
            if onlyImportant, !Self.isImportant(row) {
                if row.category != nil { seen[row.id] = date }
                continue
            }
            seen[row.id] = date
            pending.removeAll { $0.id == row.id }
            pending.append(row)
        }
    }

    /// People, needs reply, calendar and security.
    static func isImportant(_ row: ThreadRow) -> Bool {
        if row.needsReply { return true }
        guard let category = row.category else { return false }
        return [.people, .calendar, .security].contains(category)
    }

    /// The banner to post now: one thread, or a summary of everything queued since the last banner.
    /// Nil when nothing is queued or the last banner was under 10 seconds ago.
    mutating func next(now: Date) -> Banner? {
        guard !pending.isEmpty else { return nil }
        if let lastBanner, now.timeIntervalSince(lastBanner) < Self.spacing { return nil }
        lastBanner = now
        let rows = pending.sorted { $0.thread.lastDate > $1.thread.lastDate }
        pending = []
        let newest = rows[0]
        if rows.count == 1 {
            let subject = newest.thread.subject.isEmpty ? nil : newest.thread.subject
            return Banner(title: RowFormat.senders(newest.thread).text, subtitle: subject,
                          body: newest.thread.snippet.replacingOccurrences(of: "\n", with: " "), thread: newest.id)
        }
        var names: [String] = []
        for row in rows {
            let name = RowFormat.senders(row.thread).text
            if !names.contains(name) { names.append(name) }
        }
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
        return Banner(title: "\(rows.count) new conversations", subtitle: nil, body: shown, thread: newest.id)
    }

    /// Seconds until queued mail may be posted, or nil when nothing waits.
    func nextAllowed(now: Date) -> TimeInterval? {
        guard !pending.isEmpty, let lastBanner else { return nil }
        return max(0.1, Self.spacing - now.timeIntervalSince(lastBanner))
    }
}
