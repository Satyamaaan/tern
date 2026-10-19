import AppKit
import TernCore

// Triage. Every action updates the screen first (rows collapse, the next row is selected in the same
// frame), then writes on the serial `writes` queue. The list observation catches up a moment later;
// threads stay hidden until it does, so nothing flickers back.
extension AppModel {
    /// Runs a mail action with a toast and undo. `toast: nil` runs silently (mark read on open).
    func perform(_ action: MailAction, on keys: [ThreadKey], toast: String? = "") {
        // Rows for drafts Gmail has no copy of aren't threads; mail actions pass them by.
        let keys = keys.filter { MailThread.localDraftId(in: $0) == nil }
        guard !keys.isEmpty else { return }
        let leaving = keys.filter { leavesList(action) && snapshot.rows[$0] != nil }
        if !leaving.isEmpty { hide(leaving) }
        if action.removesFromInbox, case .inbox = kind { prefs.clearedToday += keys.count }

        let store = self.store
        let result = WriteResult<UndoToken>()
        let entry = UndoEntry(change: .mail(action, result), threads: keys)
        if let toast { showToast(toast.isEmpty ? Self.toastTitle(action, count: keys.count) : toast, undo: entry) }
        writes.async {
            do {
                result.value = try store.perform(action, on: keys)
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.writeFailed(error, unhide: leaving, entry: entry) } }
                return
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.committed(leaving) } }
        }
    }

    /// The Archive list is on screen: its threads are archived already, so archive buttons move them back to
    /// the inbox instead.
    var inArchive: Bool { kind == .archive && !isSearching }

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
             (.spam, .notSpam), (.spam, .moveToInbox), (.archive, .moveToInbox), (.archive, .snooze):
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

    /// "Send and archive": archives like `e` (the row leaves in the same frame, the next one is selected)
    /// but without a toast, since the send notice carries the undo. Returns the undo token once written.
    func archiveSent(_ key: ThreadKey) async -> UndoToken? {
        if leavesList(.archive), snapshot.rows[key] != nil { hide([key]) }
        if case .inbox = kind { prefs.clearedToday += 1 }
        let store = self.store
        return await withCheckedContinuation { continuation in
            writes.async {
                let token = try? store.perform(.archive, on: [key])
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.committed([key])
                        continuation.resume(returning: token)
                    }
                }
            }
        }
    }

    // MARK: Hiding triaged rows

    func hide(_ keys: [ThreadKey]) {
        for key in keys { hidden[key] = .writing }
        markReadTimer?.invalidate()
        rebuildSnapshot(.collapse)
    }

    func committed(_ keys: [ThreadKey]) {
        // A row the list no longer reads needs no hiding; dropping the mark now means a later undo
        // from outside the shell (a cancelled send-and-archive) shows the row again.
        let listed = Set((isSearching ? searchRows : rawRows).map(\.id))
        for key in keys where hidden[key] == .writing { hidden[key] = listed.contains(key) ? .committed : nil }
        // Search results are a one-off read; read them again so stars, read state and flags update.
        if isSearching { refreshSearch() }
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

    private func writeFailed(_ error: Error, unhide keys: [ThreadKey], entry: UndoEntry) {
        undoStack.removeAll { $0.id == entry.id }
        toasts.removeAll { $0.undo?.id == entry.id }
        for key in keys { hidden[key] = nil }
        rebuildSnapshot(.none)
        showToast("Couldn't save that change", undo: nil)
        NSLog("Tern: action failed: \(error)")
    }

    // MARK: Undo

    func showToast(_ title: String, undo: UndoEntry?, duration: TimeInterval = 4) {
        if let undo {
            undoStack.append(undo)
            if undoStack.count > 30 { undoStack.removeFirst() }
        }
        let toast = Toast(title: title, undo: undo)
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                self?.toasts.removeAll { $0.id == toast.id }
                if let undo { self?.undoStack.removeAll { $0.id == undo.id && $0.expires } }
            }
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
        if case .custom(let run) = entry.change {
            run()
            return
        }
        pendingCursor = entry.threads.first
        let store = self.store
        let change = entry.change
        writes.async {
            do {
                switch change {
                case .mail(_, let result): if let token = result.value { try store.undo(token) }
                case .needsReply(let result): if let previous = result.value { try store.restoreNeedsReply(previous) }
                case .project(let id, let keys, let assigned): try store.setProject(id, on: keys, assigned: !assigned)
                case .custom: break
                }
            } catch {
                NSLog("Tern: undo failed: \(error)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for key in entry.threads { self.hidden[key] = nil }
                    self.rebuildSnapshot(.none)
                    if self.isSearching { self.refreshSearch() }
                }
            }
        }
        if case .mail(let action, _) = change, action.removesFromInbox, case .inbox = kind {
            prefs.clearedToday = max(0, prefs.clearedToday - entry.threads.count)
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

    /// m: archives the threads and keeps their later replies out of the inbox. Without sync it just archives.
    func mute() {
        let keys = targets
        guard !keys.isEmpty else { return }
        let title = keys.count > 1 ? "Muted \(keys.count)" : "Muted"
        guard let muteThreads = services.muteThreads else {
            perform(.archive, on: keys, toast: title)
            return
        }
        let leaving = keys.filter { leavesList(.archive) && snapshot.rows[$0] != nil }
        if !leaving.isEmpty { hide(leaving) }
        let result = WriteResult<UndoToken>()
        let entry = UndoEntry(change: .mail(.archive, result), threads: keys)
        showToast(title, undo: entry)
        // On the serial write queue, so a z right after finds the undo token there.
        writes.async {
            do {
                result.value = try muteThreads(keys)
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.writeFailed(error, unhide: leaving, entry: entry) } }
                return
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.committed(leaving) } }
        }
    }

    /// ⇧R: flags or clears "needs reply".
    func toggleNeedsReply() {
        let keys = targets
        guard !keys.isEmpty else { return }
        let flag = !keys.allSatisfy { row($0)?.needsReply ?? false }
        if !flag, !isSearching, case .needsReply = kind { hide(keys) }
        let store = self.store
        let result = WriteResult<NeedsReplyUndo>()
        showToast(flag ? "Marked needs reply" : "Cleared needs reply", undo: UndoEntry(change: .needsReply(result), threads: keys))
        writes.async {
            result.value = try? store.setNeedsReply(flag, on: keys)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.committed(keys.filter { self.hidden[$0] != nil }) }
            }
        }
    }

    /// Adds threads to a project, or removes them when all of them are in it already.
    func toggleProject(_ projectId: String, on targets: [ThreadKey]) {
        func isIn(_ key: ThreadKey) -> Bool { row(key)?.projectIds.contains(projectId) ?? false }
        let assigned = !targets.allSatisfy(isIn)
        // Only the threads that change, so undo leaves the others where they were.
        let keys = targets.filter { isIn($0) != assigned }
        guard !keys.isEmpty else { return }
        let name = project(projectId)?.name ?? "project"
        if !assigned, !isSearching, case .project(let id) = kind, id == projectId { hide(keys) }
        let store = self.store
        showToast(assigned ? "Added to \(name)" : "Removed from \(name)",
                  undo: UndoEntry(change: .project(projectId, keys, assigned: assigned), threads: keys))
        writes.async {
            do { try store.setProject(projectId, on: keys, assigned: assigned) } catch { NSLog("Tern: project change failed: \(error)") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.committed(keys.filter { self.hidden[$0] != nil }) }
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

    /// r / a: answers inline in the reader when it shows the thread, else in a composer window.
    func reply(all: Bool) {
        guard let key = readerKey else { return }
        if openInReader(key) {
            services.reader.reply(all: all)
        } else if let gmailDraft = try? services.drafts.gmailReplyDraft(inThread: key) {
            services.openDraftMessage(gmailDraft)
        } else {
            services.compose(.reply(key, all: all))
        }
    }

    /// f: forwards inline in the reader when it shows the thread, else in a composer window.
    func forward() {
        guard let key = readerKey else { return }
        if openInReader(key) { services.reader.forward() } else { services.compose(.forward(key)) }
    }

    /// Whether the reader is on screen with `key` open, so replies can go inline. Moves focus there.
    private func openInReader(_ key: ThreadKey) -> Bool {
        let readerShown = !listOnly || readerExpanded
        guard readerShown, services.reader.model?.key == key else { return false }
        focus = .reader
        return true
    }

    func markAllRead() {
        let unread = snapshot.order.filter { (row($0)?.thread.unreadCount ?? 0) > 0 }
        perform(.markRead, on: unread, toast: unread.count == 1 ? "Marked read" : "Marked \(unread.count) read")
    }
}
