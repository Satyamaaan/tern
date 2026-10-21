import AppKit
import SwiftUI
import TernCore

// Settings → Layout: the reading pane and how conversations open without it, the sidebar (⌘\ and ⌃⌘S), the
// inbox tabs and the pinned tabs.

struct ReadingPaneItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsRow(title: "Reading pane", detail: "Show the open conversation beside the list instead of over it.") {
            InkToggle(isOn: Binding(get: { model.prefs.readingPane }, set: { if $0 != model.prefs.readingPane { model.toggleReadingPane() } }))
        }
    }
}

/// Without the reading pane: the open conversation over the whole list, or in a panel from the right.
struct ReaderOverlayItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(title: "Open conversations", detail: "Without the reading pane: over the whole list, or sliding in from the right beside it.") {
            SegmentedPicker(options: ReaderOverlay.allCases, selection: $prefs.readerOverlay) { $0.title }
        }
    }
}

struct SidebarItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(title: "Sidebar", detail: "Mailboxes, projects and accounts beside the list.") {
            InkToggle(isOn: $prefs.sidebarOpen)
        }
    }
}

struct SplitInboxItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsRow(title: "Inbox tabs", detail: "Primary, Promotions, Social, Updates and Forums, like Gmail.") {
            InkToggle(isOn: Binding(get: { model.prefs.splitInbox }, set: { model.setSplitInbox($0) }))
        }
    }
}

/// The pinned tabs in their order, each with Move and Unpin on hover, and "Pin a tab".
struct PinnedTabsItem: View {
    @Environment(AppModel.self) private var model
    /// Every account's labels: pinned labels show only while their account is in scope, so the title bar
    /// can't name them all.
    @State private var labels: [(account: Account, labels: [MailLabel])] = []

    var body: some View {
        let pinned = model.prefs.pinnedTabs.compactMap(ListTab.init(pinKey:))
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Pinned tabs", detail: pinned.isEmpty
                ? "None yet. A pinned project, label or search stays in the title bar."
                : "After the inbox tabs in the title bar, in this order.") {
                MenuPickerButton(title: "Pin a tab") { pinMenu() }
            }
            ForEach(Array(pinned.enumerated()), id: \.element) { offset, tab in
                PinnedTabRow(tab: tab, title: title(tab), kind: kind(tab), first: offset == 0, last: offset == pinned.count - 1)
            }
        }
        .onAppear(perform: loadLabels)
    }

    private func loadLabels() {
        labels = model.accounts.map { account in
            let all = (try? model.store.labels(accountId: account.id)) ?? []
            return (account, all.filter { $0.type == "user" && !$0.hidden })
        }
    }

    private func label(_ id: String) -> (account: Account, label: MailLabel)? {
        for entry in labels {
            if let label = entry.labels.first(where: { $0.id == id }) { return (entry.account, label) }
        }
        return nil
    }

    private func title(_ tab: ListTab) -> String? {
        switch tab {
        case .project(let id): model.project(id)?.name
        case .label(let id): label(id)?.label.name
        case .search(let query): query
        default: model.title(for: tab)
        }
    }

    private func kind(_ tab: ListTab) -> String {
        switch tab {
        case .project: "Project"
        case .label(let id): label(id).map { "Label · \(model.accountTitle($0.account))" } ?? "Label"
        case .search: "Search"
        default: ""
        }
    }

    private func pinMenu() -> NSMenu {
        let model = self.model
        let menu = NSMenu()
        menu.autoenablesItems = false
        let projects = NSMenu()
        for project in model.projects {
            let tab = ListTab.project(project.id)
            let item = ClosureMenuItem(project.name, enabled: !model.isPinned(tab)) { model.pin(tab) }
            item.image = Icon.project(project.icon).tinted(Theme.projectColor(project.colorIndex), size: 14)
            projects.addItem(item)
        }
        if model.projects.isEmpty { projects.addItem(ClosureMenuItem("No projects yet", enabled: false) {}) }
        let projectsItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
        projectsItem.image = Icon.folder.image(size: 14)
        projectsItem.submenu = projects
        menu.addItem(projectsItem)
        for entry in labels {
            let submenu = NSMenu()
            for label in entry.labels {
                let tab = ListTab.label(label.id)
                submenu.addItem(ClosureMenuItem(label.name, enabled: !model.isPinned(tab)) { model.pin(tab) })
            }
            if entry.labels.isEmpty { submenu.addItem(ClosureMenuItem("No labels", enabled: false) {}) }
            let title = labels.count > 1 ? "Label in \(model.accountTitle(entry.account))" : "Label"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = Icon.label.image(size: 14)
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("To pin a search, search, then press Pin", enabled: false) {})
        return menu
    }
}

private struct PinnedTabRow: View {
    @Environment(AppModel.self) private var model
    let tab: ListTab
    /// Nil when the project or label is gone.
    let title: String?
    let kind: String
    let first: Bool
    let last: Bool
    @State private var hovering = false

    var body: some View {
        let style = tab.style(in: model)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconView(icon: style.icon, size: 14, color: Color(style.color))
                Text(title ?? "No longer exists")
                    .font(.ui(13))
                    .foregroundStyle(Color(title == nil ? Theme.text3 : Theme.text1))
                    .lineLimit(1)
                Text(kind)
                    .font(.ui(12))
                    .foregroundStyle(Color(Theme.text3))
                    .lineLimit(1)
                Spacer(minLength: 12)
                HStack(spacing: 2) {
                    IconButton(icon: .chevronUp, size: Theme.Control.small, iconSize: 14, help: "Move up") { model.movePinnedTab(tab, by: -1) }
                        .disabled(first)
                    IconButton(icon: .chevronDown, size: Theme.Control.small, iconSize: 14, help: "Move down") { model.movePinnedTab(tab, by: 1) }
                        .disabled(last)
                    IconButton(icon: .close, size: Theme.Control.small, iconSize: 14, help: "Unpin") { model.unpin(tab) }
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .padding(.leading, 2)
            .frame(height: 36)
            Hairline()
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
