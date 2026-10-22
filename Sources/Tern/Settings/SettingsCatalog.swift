import SwiftUI

/// Every setting the page shows, in display order: a section lists its own, and the search field above
/// the sections finds them across all of them.
enum SettingsItem: String, CaseIterable, Identifiable {
    case accounts, googleClient
    case ledgerTracking
    case markRead, afterTriage, imagesInMail, remoteImages, undoSend, signatures, sendFrom
    case theme, density, dimRead, senderLogos
    case readingPane, readerOverlay, sidebar, splitInbox, pinnedTabs
    case notifications, notifyImportant
    case aiAbout, aiProvider, groqKey, aiSorting, aiModel, aiProjects, ledgerAI, primarySummaries
    case shortcuts
    case updates, database, searchIndex, demoMail

    var id: String { rawValue }

    var section: SettingsSection {
        switch self {
        case .accounts, .googleClient: .accounts
        case .ledgerTracking, .markRead, .afterTriage, .imagesInMail, .remoteImages, .undoSend, .signatures, .sendFrom: .mail
        case .theme, .density, .dimRead, .senderLogos: .appearance
        case .readingPane, .readerOverlay, .sidebar, .splitInbox, .pinnedTabs: .layout
        case .notifications, .notifyImportant: .notifications
        case .aiAbout, .aiProvider, .aiSorting, .aiModel, .aiProjects, .groqKey, .ledgerAI, .primarySummaries: .ai
        case .shortcuts: .shortcuts
        case .updates, .database, .searchIndex, .demoMail: .advanced
        }
    }

    /// The small caps the item sits under in its section.
    var group: String? {
        switch self {
        case .ledgerTracking: "Follow-ups"
        case .markRead, .afterTriage, .imagesInMail, .remoteImages: "Reading"
        case .undoSend, .signatures, .sendFrom: "Writing"
        case .readingPane, .readerOverlay, .sidebar: "Window"
        case .splitInbox, .pinnedTabs: "Tabs"
        default: nil
        }
    }

    /// What search matches: the row's title and the words someone might type for it.
    var searchText: String {
        let words: String = switch self {
        case .accounts: "accounts gmail add remove sign in workspace name rename colour color personal work"
        case .googleClient: "google client oauth id secret cloud"
        case .ledgerTracking: "follow up waiting reminder ledger commitments tracking days"
        case .markRead: "mark as read unread open delay"
        case .afterTriage: "after archive delete trash snooze next previous auto advance"
        case .imagesInMail: "images in mail remote pictures logos load automatically ask first block privacy tracking pixels trackers"
        case .remoteImages: "remote images always load trusted senders allowed pictures"
        case .undoSend: "undo send delay cancel"
        case .signatures: "signature"
        case .sendFrom: "send new mail from default account compose"
        case .theme: "theme light dark appearance mode"
        case .density: "density compact comfortable rows"
        case .dimRead: "dim old read mail fade"
        case .senderLogos: "sender logos avatars icons favicons"
        case .readingPane: "reading pane split view side by side"
        case .readerOverlay: "open conversations slide over panel drawer full width reader right"
        case .sidebar: "sidebar mailboxes projects"
        case .splitInbox: "inbox tabs split inbox categories gmail primary promotions social updates forums"
        case .pinnedTabs: "pinned tabs pin unpin reorder"
        case .notifications: "notifications new mail banners alerts"
        case .notifyImportant: "only important notifications"
        case .aiAbout: "ai privacy provider"
        case .aiProvider: "ai provider groq claude code codex"
        case .groqKey: "groq api key secure credential remove replace"
        case .aiSorting: "ai sorting classify triage progress status paused"
        case .aiModel: "ai model"
        case .aiProjects: "suggest projects ai"
        case .primarySummaries: "Summarise Primary mail automatically summaries background inbox"
        case .ledgerAI: "find promises requests commitments mail ledger owe waiting uncertain maybe"
        case .shortcuts: "shortcuts keys"
        case .updates: "update version automatically check"
        case .database: "database finder"
        case .searchIndex: "search index rebuild"
        case .demoMail: "demo mail reset"
        }
        return "\(words) \(section.title)".lowercased()
    }

    @MainActor
    func isShown(in model: AppModel) -> Bool {
        switch self {
        case .sendFrom: model.accounts.count > 1
        // The always-load list only matters while images wait for a click.
        case .remoteImages: model.prefs.imagesInMail == .ask
        case .demoMail: model.isFake
        case .ledgerAI, .primarySummaries: model.services.ai != nil
        case .aiSorting: model.services.aiSorting?.isShown ?? false
        default: true
        }
    }

    @MainActor
    static func items(in section: SettingsSection, model: AppModel) -> [SettingsItem] {
        allCases.filter { $0.section == section && $0.isShown(in: model) }
    }
}

/// Search across sections: every word must match.
enum SettingsCatalog {
    @MainActor
    static func results(for query: String, model: AppModel) -> [SettingsItem] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        return SettingsItem.allCases.filter { item in
            item != .shortcuts && item.isShown(in: model) && words.allSatisfy { matches(String($0), in: item.searchText) }
        }
    }

    /// A word matches when a word of `text` starts with it; keys and symbols ("⇧r", "⌘k") match anywhere.
    static func matches(_ word: String, in text: String) -> Bool {
        guard word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return text.contains(word) }
        return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(word) }
    }

    /// Commands whose title or keys match, for the Shortcuts part of the results.
    @MainActor
    static func commands(for query: String, registry: CommandRegistry?) -> [Command] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, let registry else { return [] }
        return ShortcutTable.editable(registry).filter { command in
            let text = ShortcutTable.searchText(command)
            return words.allSatisfy { matches($0, in: text) }
        }
    }
}

/// One item as its section shows it.
struct SettingsItemView: View {
    let item: SettingsItem
    let state: SettingsState

    var body: some View {
        switch item {
        case .accounts: AccountsItem(state: state)
        case .googleClient: GoogleClientSection(startEditing: state.editsGoogleClient).padding(.top, 16)
        case .ledgerTracking: LedgerTrackingItem()
        case .ledgerAI: LedgerAIItem()
        case .primarySummaries: PrimarySummariesItem()
        case .markRead: MarkReadItem()
        case .afterTriage: AfterTriageItem()
        case .imagesInMail: ImagesInMailItem()
        case .remoteImages: RemoteImagesItem(state: state)
        case .undoSend: UndoSendItem(state: state)
        case .signatures: SignaturesItem(state: state)
        case .sendFrom: SendFromItem(state: state)
        case .groqKey: GroqKeyItem(state: state)
        case .theme: ThemeItem()
        case .density: DensityItem()
        case .dimRead: DimReadItem()
        case .senderLogos: SenderLogoSettingsRow()
        case .readingPane: ReadingPaneItem()
        case .readerOverlay: ReaderOverlayItem()
        case .sidebar: SidebarItem()
        case .splitInbox: SplitInboxItem()
        case .pinnedTabs: PinnedTabsItem()
        case .notifications: NotificationsItem()
        case .notifyImportant: NotifyImportantItem()
        case .aiAbout: AIAboutItem()
        case .aiProvider: AIProviderItem(state: state)
        case .aiSorting: AISortingItem()
        case .aiModel: AIModelItem(state: state)
        case .aiProjects: AIProjectsItem(state: state)
        case .shortcuts: ShortcutSettings(state: state)
        case .updates: UpdateSettingsRows(updater: state.updater)
        case .database: DatabaseItem()
        case .searchIndex: SearchIndexItem(state: state)
        case .demoMail: DemoMailItem(state: state)
        }
    }
}

/// A list of items with their group caps.
struct SettingsItemList: View {
    let items: [SettingsItem]
    let state: SettingsState
    /// Results across sections show no group caps; the section heads them.
    var showsGroups = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { offset, item in
                if showsGroups, let group = item.group, offset == 0 || items[offset - 1].group != group {
                    SettingsGroupHeader(title: group, first: offset == 0)
                }
                SettingsItemView(item: item, state: state)
            }
        }
    }
}
