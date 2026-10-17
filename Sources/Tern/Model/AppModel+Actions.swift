import AppKit
import TernCore

// Triage. Every action updates the screen first (rows collapse, the next row is selected in the same
// frame), then writes on the serial `writes` queue. The list observation catches up a moment later;
// threads stay hidden until it does, so nothing flickers back.
extension AppModel {
    /// Runs a mail action with a toast and undo. `toast: nil` runs silently (mark read on open).
    func perform(_ action: MailAction, on keys: [ThreadKey], toast: String? = "") {
        guard !keys.isEmpty else { return }
        let leaving = keys.filter { leavesList(action) && snapshot.rows[$0] != nil }
        if !leaving.isEmpty { hide(leaving) }
        if action.removesFromInbox, case .inbox = kind { prefs.clearedToday += keys.count }

        let store = self.store
        let title = toast.map { $0.isEmpty ? Self.toastTitle(action, count: keys.count) : $0 }
        writes.async {
            let token: UndoToken
            do { token = try store.perform(action, on: keys) } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.writeFailed(error, unhide: leaving) } }
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.committed(leaving)
                    guard let title else { return }
                    self.showToast(title, undo: UndoEntry(change: .mail(token), threads: keys))
                }
            }
        }
    }

    /// Whether the action takes threads out of the list on screen.
    func leavesList(_ action: MailAction) -> Bool {
        if isSearching { return false }
        switch (kind, action) {
        case (_, .trash), (_, .markSpam):
            if case .trash = kind { return false }
            if case .spam = kind, case .markSpam = action { return false }
            return true
        case (.inbox, .archive), (.inbox, .snooze), (.inbox, .moveToLabel),
             (.category, .archive), (.category, .snooze), (.category, .moveToLabel),
             (.needsReply, .archive), (.needsReply, .snooze), (.needsReply, .moveToLabel):
            return true
        case (.starred, .unstar), (.snoozed, .unsnooze), (.trash, .untrash), (.trash, .moveToInbox),
             (.spam, .notSpam), (.spam, .moveToInbox):
            return true
        case (.label(let id), .removeLabel(let removed)):
            return id == removed
        default:
            return false
        }
    }

    static func toastTitle(_ action: MailAction, count: Int) -> String {
        let suffix = count > 1 ? " \(count)" : ""
        switch action {
        case .archive: return "Archived" + suffix
        case .moveToInbox: return "Moved to Inbox"
        case .trash: return "Moved to Trash"
        case .untrash: return "Restored"
        case .markRead: return "Marked read"
        case .markUnread: return "Marked unread"
        case .star: return "Starred"
        case .unstar: return "Unstarred"
        case .markSpam: return "Reported spam"
        case .notSpam: return "Not spam"
        case .addLabel: return "Labeled"
        case .removeLabel: return "Label removed"
        case .moveToLabel: return "Moved"
        case .snooze(let until): return "Snoozed until \(SnoozeOption.detailText(until))"
        case .unsnooze: return "Unsnoozed"
        }
    }

    // MARK: Hiding triaged rows

    func hide(_ keys: [ThreadKey]) {
        for key in keys { hidden[key] = .writing }
        markReadTimer?.invalidate()
        rebuildSnapshot(.collapse)
    }

    private func committed(_ keys: [ThreadKey]) {
        for key in keys where hidden[key] == .writing { hidden[key] = .committed }
        // If the write left a thread in this list after all (no change reached the observation),
        // show it again once the observation has had time to catch up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let present = Set((self.isSearching ? self.searchRows : self.rawRows).map(\.id))
                let stale = keys.filter { self.hidden[$0] == .committed && present.contains($0) }
                guard !stale.isEmpty else { return }
                for key in stale { self.hidden[key] = nil }
                self.rebuildSnapshot(.none)
            }
        }
    }

    private func writeFailed(_ error: Error, unhide keys: [ThreadKey]) {
        for key in keys { hidden[key] = nil }
        rebuildSnapshot(.none)
        showToast("Couldn't save that change", undo: nil)
        NSLog("Tern: action failed: \(error)")
    }

    // MARK: Undo

    func showToast(_ title: String, undo: UndoEntry?) {
        if let undo {
            undoStack.append(undo)
            if undoStack.count > 30 { undoStack.removeFirst() }
        }
        let toast = Toast(title: title, undo: undo)
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated { self?.toasts.removeAll { $0.id == toast.id } }
        }
    }

    /// z: puts back the last action.
    func undoLast() {
        guard let entry = undoStack.popLast() else { return }
        undo(entry)
    }

    func undo(_ entry: UndoEntry) {
        undoStack.removeAll { $0.id == entry.id }
        toasts.removeAll { $0.undo?.id == entry.id }
        pendingCursor = entry.threads.first
        let store = self.store
        let change = entry.change
        writes.async {
            do {
                switch change {
                case .mail(let token): try store.undo(token)
                case .needsReply(let previous): try store.restoreNeedsReply(previous)
                case .project(let id, let keys, let assigned): try store.setProject(id, on: keys, assigned: !assigned)
                }
            } catch {
                NSLog("Tern: undo failed: \(error)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for key in entry.threads { self.hidden[key] = nil }
                    self.rebuildSnapshot(.none)
                }
            }
        }
        if case .mail(let token) = change, token.action.removesFromInbox, case .inbox = kind {
            prefs.clearedToday = max(0, prefs.clearedToday - token.threads.count)
        }
    }

    // MARK: Toggles

    func toggleStar() {
        let keys = targets
        let allStarred = keys.allSatisfy { row($0)?.thread.isStarred ?? false }
        perform(allStarred ? .unstar : .star, on: keys)
    }

    func toggleUnread() {
        let keys = targets
        let anyUnread = keys.contains { (row($0)?.thread.unreadCount ?? 0) > 0 }
        markReadTimer?.invalidate()
        perform(anyUnread ? .markRead : .markUnread, on: keys)
    }

    /// m: Gmail mute keeps a thread out of the inbox for good. Until sync supports it, mute archives.
    func mute() {
        perform(.archive, on: targets, toast: targets.count > 1 ? "Muted \(targets.count)" : "Muted")
    }

    /// ⇧R: flags or clears "needs reply".
    func toggleNeedsReply() {
        let keys = targets
        guard !keys.isEmpty else { return }
        let flag = !keys.allSatisfy { row($0)?.needsReply ?? false }
        if !flag, case .needsReply = kind { hide(keys) }
        let store = self.store
        writes.async {
            let previous = (try? store.setNeedsReply(flag, on: keys)) ?? [:]
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.committed(keys.filter { self.hidden[$0] != nil })
                    self.showToast(flag ? "Marked needs reply" : "Cleared needs reply",
                                   undo: UndoEntry(change: .needsReply(previous), threads: keys))
                }
            }
        }
    }

    /// Adds threads to a project, or removes them when all of them are in it already.
    func toggleProject(_ projectId: String, on keys: [ThreadKey]) {
        guard !keys.isEmpty else { return }
        let assigned = !keys.allSatisfy { row($0)?.projectIds.contains(projectId) ?? false }
        let name = project(projectId)?.name ?? "project"
        if !assigned, case .project(let id) = kind, id == projectId { hide(keys) }
        let store = self.store
        writes.async {
            do { try store.setProject(projectId, on: keys, assigned: assigned) } catch { NSLog("Tern: project change failed: \(error)") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.committed(keys.filter { self.hidden[$0] != nil })
                    self.showToast(assigned ? "Added to \(name)" : "Removed from \(name)",
                                   undo: UndoEntry(change: .project(projectId, keys, assigned: assigned), threads: keys))
                }
            }
        }
    }

    /// Adds a label to threads, or removes it when all of them have it already.
    func toggleLabel(_ label: MailLabel, on keys: [ThreadKey]) {
        let keys = keys.filter { $0.accountId == label.accountId }
        guard !keys.isEmpty else { return }
        let hasIt = keys.allSatisfy { row($0)?.thread.labelIds.contains(label.id) ?? false }
        perform(hasIt ? .removeLabel(label.id) : .addLabel(label.id), on: keys,
                toast: hasIt ? "Removed \(label.name)" : "Labeled \(label.name)")
    }

    /// Files dragged rows onto a sidebar project or label.
    func dropDragged(onProject projectId: String) {
        let keys = draggedKeys
        draggedKeys = []
        guard !keys.isEmpty else { return }
        let missing = keys.filter { !(row($0)?.projectIds.contains(projectId) ?? false) }
        toggleProject(projectId, on: missing.isEmpty ? keys : missing)
    }

    func dropDragged(onLabel label: MailLabel) {
        let keys = draggedKeys.filter { $0.accountId == label.accountId }
        draggedKeys = []
        guard !keys.isEmpty else { return }
        perform(.addLabel(label.id), on: keys, toast: "Labeled \(label.name)")
    }

    // MARK: Compose

    func compose() { services.compose(.new(accountId: scope.accountId)) }

    func reply(all: Bool) {
        guard let key = readerKey else { return }
        services.compose(.reply(key, all: all))
    }

    func forward() {
        guard let key = readerKey else { return }
        services.compose(.forward(key))
    }

    func markAllRead() {
        let unread = snapshot.order.filter { (row($0)?.thread.unreadCount ?? 0) > 0 }
        perform(.markRead, on: unread, toast: unread.count == 1 ? "Marked read" : "Marked \(unread.count) read")
    }
}
