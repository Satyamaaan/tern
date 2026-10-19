import Foundation
import TernCore

/// A tab in the title bar: a slice of the inbox, something the user pinned, or the mailbox or search
/// that is open right now.
enum ListTab: Hashable, Identifiable {
    /// The whole inbox.
    case all
    case needsReply
    /// One of Gmail's tabs of the inbox (inbox tabs on).
    case category(InboxTab)
    case project(String)
    /// A Gmail label of the account in scope.
    case label(String)
    case search(String)
    /// A mailbox opened from the sidebar, a chord or ⌘K (Sent, Starred…), shown while it is open.
    case mailbox(Mailbox.Kind)

    var id: String {
        switch self {
        case .all: "all"
        case .needsReply: "needsReply"
        case .category(let tab): "tab:\(tab.rawValue)"
        case .project(let id): "project:\(id)"
        case .label(let id): "label:\(id)"
        case .search(let query): "search:\(query)"
        case .mailbox(let kind): "mailbox:\(kind)"
        }
    }

    /// How a pinned tab is stored in preferences; nil for tabs that can't be pinned.
    var pinKey: String? {
        switch self {
        case .project, .label, .search: id
        default: nil
        }
    }

    init?(pinKey: String) {
        let parts = pinKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "project": self = .project(parts[1])
        case "label": self = .label(parts[1])
        case "search": self = .search(parts[1])
        default: return nil
        }
    }

    var isPinnable: Bool { pinKey != nil }
}

extension AppModel {
    /// The tabs in order: All, Needs reply, Gmail's tabs (inbox tabs on), then pinned tabs that still exist.
    /// A Gmail tab other than Primary shows only while the scope's inbox has mail in it, or while it is open.
    /// Labels show only while their account is in scope.
    var tabs: [ListTab] {
        var tabs: [ListTab] = [.all, .needsReply]
        if prefs.splitInbox {
            tabs += InboxTab.allCases
                .filter { $0 == .primary || counts.tabThreads[$0, default: 0] > 0 || (kind == .inbox && inboxTab == $0) }
                .map(ListTab.category)
        }
        for key in prefs.pinnedTabs {
            guard let tab = ListTab(pinKey: key) else { continue }
            switch tab {
            case .project(let id) where project(id) == nil: continue
            case .label(let id) where !labels.contains(where: { $0.id == id }): continue
            default: tabs.append(tab)
            }
        }
        return tabs
    }

    /// The tab that matches what the list shows.
    var activeTab: ListTab {
        if isSearching { return .search(trimmedSearch) }
        switch kind {
        case .inbox: return inboxTab.map(ListTab.category) ?? .all
        case .needsReply: return .needsReply
        case .project(let id): return .project(id)
        case .label(let id): return .label(id)
        default: return .mailbox(kind)
        }
    }

    /// Shows a tab's list.
    func select(_ tab: ListTab) {
        switch tab {
        case .all: showInboxTab(nil)
        case .needsReply: show(.needsReply)
        case .category(let tab): showInboxTab(tab)
        case .project(let id): show(.project(id))
        case .label(let id): show(.label(id))
        case .mailbox(let kind): show(kind)
        case .search(let query):
            guard trimmedSearch != query else { return }
            searchText = query
            suggestionsDismissed = true
            recordSearch()
            focusResults(open: false)
        }
    }

    /// Tab / ⇧Tab: the next or previous tab, wrapping.
    func cycleTab(_ step: Int) {
        let all = tabs
        guard !all.isEmpty else { return }
        let index = all.firstIndex(of: activeTab) ?? (step > 0 ? -1 : 0)
        select(all[(index + step + all.count) % all.count])
    }

    func pin(_ tab: ListTab) {
        guard let key = tab.pinKey, !prefs.pinnedTabs.contains(key) else { return }
        prefs.pinnedTabs.append(key)
    }

    func unpin(_ tab: ListTab) {
        guard let key = tab.pinKey else { return }
        prefs.pinnedTabs.removeAll { $0 == key }
    }

    func isPinned(_ tab: ListTab) -> Bool { tab.pinKey.map(prefs.pinnedTabs.contains) ?? false }

    /// Moves a pinned tab one place left (-1) or right (+1) among the pinned tabs.
    func movePinnedTab(_ tab: ListTab, by step: Int) {
        guard let key = tab.pinKey, let index = prefs.pinnedTabs.firstIndex(of: key),
              prefs.pinnedTabs.indices.contains(index + step) else { return }
        prefs.pinnedTabs.swapAt(index, index + step)
    }

    /// The number next to a tab: unread threads, or what waits on you. With inbox tabs on, All and Primary
    /// show none, like Gmail: their unread mail is the list itself (and the sidebar's Inbox count).
    func count(for tab: ListTab) -> Int? {
        let value: Int
        switch tab {
        case .all where prefs.splitInbox, .category(.primary): return nil
        case .all: value = counts.inboxUnread
        case .needsReply: value = counts.needsReply
        case .category(let tab): value = counts.tabUnread[tab, default: 0]
        case .project(let id): value = counts.projectUnread[id] ?? 0
        case .mailbox(.snoozed): value = counts.snoozed
        case .mailbox(.drafts): value = counts.drafts
        default: return nil
        }
        return value > 0 ? value : nil
    }

    func title(for tab: ListTab) -> String {
        switch tab {
        case .all: "All"
        case .needsReply: "Needs reply"
        case .category(let tab): tab.title
        case .project(let id): project(id)?.name ?? "Project"
        case .label(let id): labels.first { $0.id == id }?.name ?? "Label"
        case .search(let query): query
        case .mailbox(let kind): kind.title
        }
    }
}
