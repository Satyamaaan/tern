import AppKit
import SwiftUI
import TernCore

/// The title bar row: traffic lights, the list's tabs, then the accounts and compose at the right. With the
/// sidebar open the traffic lights sit in the sidebar, so the tabs start at the list's edge.
struct TitleBar: View {
    @Environment(AppModel.self) private var model

    /// Room for the close / minimize / zoom buttons.
    static let trafficLightsWidth: CGFloat = 84

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: model.prefs.sidebarOpen ? 4 : Self.trafficLightsWidth - 8)
            TabBar()
                .frame(maxWidth: .infinity, alignment: .leading)
            AccountStack()
            ComposeButton()
        }
        .padding(.trailing, 12)
        .frame(height: MainWindow.headerHeight)
        .background(WindowDragArea())
    }
}

// MARK: - Tabs

/// All, Needs reply, Gmail's tabs and pinned tabs; what doesn't fit moves into `…`. The tab of an
/// open mailbox or search that isn't a tab shows at the end while it is open.
struct TabBar: View {
    @Environment(AppModel.self) private var model

    /// `+` and `…` after the tabs.
    private static let trailingControls: CGFloat = 2 * (28 + 2)

    var body: some View {
        GeometryReader { geometry in
            let fit = TabFit(tabs: displayed, active: model.activeTab, width: geometry.size.width - Self.trailingControls) { tab in
                TabButton.width(title: model.title(for: tab), count: model.count(for: tab))
            }
            HStack(spacing: 2) {
                ForEach(fit.visible) { tab in
                    TabButton(tab: tab)
                }
                AddTabButton()
                MoreTabsButton(hidden: fit.hidden)
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: 28)
        .clipped()
    }

    private var displayed: [ListTab] {
        let tabs = model.tabs
        let active = model.activeTab
        return tabs.contains(active) ? tabs : tabs + [active]
    }
}

/// Which tabs fit in the bar; the active tab always does.
struct TabFit {
    var visible: [ListTab] = []
    var hidden: [ListTab] = []

    init(tabs: [ListTab], active: ListTab, width: CGFloat, measure: (ListTab) -> CGFloat) {
        var used: CGFloat = 0
        for tab in tabs {
            let next = used + measure(tab) + (visible.isEmpty ? 0 : 2)
            if next <= width, hidden.isEmpty { visible.append(tab); used = next } else { hidden.append(tab) }
        }
        if let index = hidden.firstIndex(of: active) {
            hidden.remove(at: index)
            var free = width - used
            while let last = visible.last, free < measure(active) + 2 {
                visible.removeLast()
                hidden.insert(last, at: 0)
                free += measure(last) + 2
            }
            visible.append(active)
        }
    }
}

struct TabButton: View {
    @Environment(AppModel.self) private var model
    let tab: ListTab
    @State private var hovering = false

    static let titleFont = Theme.ui(13, .medium)
    static let maxTitle: CGFloat = 160

    /// The tab's width, measured the way it draws (so the bar can tell what fits without a layout pass).
    static func width(title: String, count: Int?) -> CGFloat {
        let text = min(ceil((title as NSString).size(withAttributes: [.font: titleFont]).width), maxTitle)
        let number = count.map { 6 + ceil(("\($0)" as NSString).size(withAttributes: [.font: Theme.numeric(12)]).width) } ?? 0
        // Two points of slack so a tab never gets squeezed by rounding in text layout.
        return 8 + 14 + 6 + text + number + 10 + 2
    }

    var body: some View {
        let active = model.activeTab == tab
        let style = tab.style(in: model)
        Button { model.select(tab) } label: {
            HStack(spacing: 6) {
                IconView(icon: style.icon, size: 14, color: Color(style.color))
                Text(model.title(for: tab))
                    .font(.ui(13, active ? .medium : .regular))
                    .foregroundStyle(Color(active ? Theme.text1 : Theme.text2))
                    .lineLimit(1)
                    .frame(maxWidth: Self.maxTitle, alignment: .leading)
                    .fixedSize()
                if let count = model.count(for: tab) {
                    Text("\(count)")
                        .font(.numeric(12))
                        .foregroundStyle(Color(Theme.text3))
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Color(active ? Theme.selected : Theme.hover).opacity(active || hovering ? 1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(help)
        .contextMenu {
            if model.isPinned(tab) {
                Button("Unpin Tab") { model.unpin(tab) }
            } else if tab.isPinnable {
                Button("Pin as Tab") { model.pin(tab) }
            }
        }
    }

    private var help: String {
        let title = model.title(for: tab)
        switch tab {
        case .all: return model.registry?.hint(title, "tab.all") ?? title
        case .needsReply: return model.registry?.hint(title, "tab.needsReply") ?? title
        case .category(let tab): return model.registry?.hint(title, "tab.\(tab.rawValue)") ?? title
        default: return title
        }
    }
}

extension ListTab {
    /// The tab's icon and its small colour. Only tab and tag icons carry hue; needs reply stays ink.
    @MainActor
    func style(in model: AppModel) -> (icon: Icon, color: NSColor) {
        switch self {
        case .all: (.inbox, Theme.text2)
        case .needsReply: (.needsReply, Theme.ink)
        case .category(let tab): (Icon.tab(tab), Theme.tabColor(tab))
        case .project(let id):
            model.project(id).map { (Icon.project($0.icon), Theme.projectColor($0.colorIndex)) } ?? (.folder, Theme.text2)
        case .label: (.label, Theme.text2)
        case .search: (.savedSearch, Theme.text2)
        case .mailbox(let kind): (kind.icon, Theme.text2)
        }
    }
}

extension Mailbox.Kind {
    var icon: Icon {
        switch self {
        case .inbox: .inbox
        case .needsReply: .needsReply
        case .snoozed: .snoozed
        case .starred: .starred
        case .drafts: .drafts
        case .sent: .sent
        case .allMail: .allMail
        case .archive: .archive
        case .spam: .spam
        case .trash: .trash
        case .important: .important
        case .label: .label
        case .project: .folder
        case .category(let category): Icon.category(category)
        }
    }
}

/// `+`: pin a project, a label or the current search as a tab.
private struct AddTabButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MenuButton(icon: .plus, help: "Pin a tab") { menu() }
    }

    private func menu() -> NSMenu {
        let model = self.model
        let menu = NSMenu()
        menu.autoenablesItems = false
        if model.isSearching {
            let tab = model.activeTab
            let item = ClosureMenuItem("Pin Search “\(model.trimmedSearch)”", enabled: !model.isPinned(tab)) { model.pin(tab) }
            item.image = Icon.savedSearch.image(size: 14)
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let projects = NSMenu()
        for project in model.projects {
            let tab = ListTab.project(project.id)
            let item = ClosureMenuItem(project.name, enabled: !model.isPinned(tab)) { model.pin(tab) }
            item.image = Icon.project(project.icon).tinted(Theme.projectColor(project.colorIndex), size: 14)
            projects.addItem(item)
        }
        if model.projects.isEmpty { projects.addItem(ClosureMenuItem("No projects yet", enabled: false) {}) }
        projects.addItem(.separator())
        projects.addItem(ClosureMenuItem("New Project…", shortcut: model.registry?["newProject"]) { model.newProject() })
        let projectsItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
        projectsItem.image = Icon.folder.image(size: 14)
        projectsItem.submenu = projects
        menu.addItem(projectsItem)

        let labelsItem = NSMenuItem(title: model.scope.accountId == nil ? "Label (choose an account first)" : "Label", action: nil, keyEquivalent: "")
        labelsItem.image = Icon.label.image(size: 14)
        if model.scope.accountId != nil {
            let labels = NSMenu()
            for label in model.labels {
                let tab = ListTab.label(label.id)
                labels.addItem(ClosureMenuItem(label.name, enabled: !model.isPinned(tab)) { model.pin(tab) })
            }
            if model.labels.isEmpty { labels.addItem(ClosureMenuItem("No labels", enabled: false) {}) }
            labelsItem.submenu = labels
        } else {
            labelsItem.isEnabled = false
        }
        menu.addItem(labelsItem)
        if !model.isSearching {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Search, then Pin the Search…") { model.beginSearch() })
        }
        return menu
    }
}

/// `…`: tabs that didn't fit, then the list's options.
private struct MoreTabsButton: View {
    @Environment(AppModel.self) private var model
    let hidden: [ListTab]

    var body: some View {
        MenuButton(icon: .ellipsis, help: "More tabs and list options") { menu() }
    }

    private func menu() -> NSMenu {
        let model = self.model
        let menu = NSMenu()
        menu.autoenablesItems = false
        for tab in hidden {
            let style = tab.style(in: model)
            let item = ClosureMenuItem(model.title(for: tab)) { model.select(tab) }
            item.image = style.icon.tinted(style.color, size: 14)
            item.state = model.activeTab == tab ? .on : .off
            menu.addItem(item)
        }
        if !hidden.isEmpty { menu.addItem(.separator()) }
        let active = model.activeTab
        if model.isPinned(active) {
            menu.addItem(ClosureMenuItem("Unpin “\(model.title(for: active))”") { model.unpin(active) })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Mark All as Read", shortcut: model.registry?["markAllRead"], enabled: !model.snapshot.isEmpty) { model.markAllRead() })
        menu.addItem(ClosureMenuItem("Select All", shortcut: model.registry?["selectAll"], enabled: !model.snapshot.isEmpty) { model.selectAll() })
        menu.addItem(.separator())
        let density = NSMenu()
        for option in Density.allCases {
            let item = ClosureMenuItem(option.title) { model.prefs.density = option }
            item.state = model.prefs.density == option ? .on : .off
            density.addItem(item)
        }
        let densityItem = NSMenuItem(title: "Density", action: nil, keyEquivalent: "")
        densityItem.submenu = density
        menu.addItem(densityItem)
        let split = ClosureMenuItem("Inbox Tabs") { model.setSplitInbox(!model.prefs.splitInbox) }
        split.state = model.prefs.splitInbox ? .on : .off
        menu.addItem(split)
        let pane = ClosureMenuItem("Reading Pane", shortcut: model.registry?["readingPane"]) { model.toggleReadingPane() }
        pane.state = model.prefs.readingPane ? .on : .off
        menu.addItem(pane)
        return menu
    }
}

extension Icon {
    /// The icon drawn in one colour, for menus that should keep a tab's hue.
    func tinted(_ color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            self.draw(in: rect, color: color)
            return true
        }
    }
}

// MARK: - Accounts and compose

/// Overlapping account avatars and "3 accounts" (or the account in scope). Opens the scope menu.
struct AccountStack: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let shown = model.scopedAccount.map { [$0] } ?? Array(model.accounts.prefix(3))
        Button(action: showMenu) {
            HStack(spacing: 8) {
                HStack(spacing: -6) {
                    ForEach(shown) { account in
                        AccountAvatar(account: account, size: 20)
                            .overlay(Circle().strokeBorder(Color(Theme.bg), lineWidth: 2).padding(-2))
                    }
                }
                .padding(.leading, 2)
                Text(title)
                    .font(.ui(13, .medium))
                    .foregroundStyle(Color(Theme.text1))
                    .lineLimit(1)
                    .frame(maxWidth: 180)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Color(Theme.hover).opacity(hovering ? 1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Switch account  \(model.registry?["scope.all"]?.shortcutText.map { "\($0), " } ?? "")⌘1–⌘9")
        .opacity(model.accounts.isEmpty ? 0 : 1)
    }

    private var title: String {
        if let account = model.scopedAccount { return model.accountTitle(account) }
        return model.accounts.count == 1 ? "1 account" : "\(model.accounts.count) accounts"
    }

    private func showMenu() {
        guard let event = NSApp.currentEvent, let view = event.window?.contentView, let registry = model.registry else { return }
        let menu = AccountMenu.make(model: model, registry: registry)
        let origin = view.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: origin.x - 40, y: origin.y - 12), in: view)
    }
}

/// The scope menu: All accounts ⌘0, each account ⌘1…⌘9, Add account…, Settings…
@MainActor
enum AccountMenu {
    static func make(model: AppModel, registry: CommandRegistry) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = MenuTarget.shared
        target.registry = registry
        func add(_ id: String, title: String, image: NSImage? = nil, on: Bool = false) {
            guard let command = registry[id] else { return }
            let key = command.menuKey
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.run(_:)), keyEquivalent: key?.keyEquivalent ?? "")
            item.keyEquivalentModifierMask = key?.modifiers ?? []
            item.target = target
            item.representedObject = id
            item.image = image
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        add("scope.all", title: "All accounts", on: model.scope == .all)
        for (index, account) in model.accounts.prefix(9).enumerated() {
            add("scope.\(index + 1)", title: model.accountTitle(account), image: AccountAvatar.image(account, size: 16),
                on: model.scope == .account(account.id))
        }
        menu.addItem(.separator())
        add("addAccount", title: "Add account…")
        add("settings", title: "Settings…")
        return menu
    }
}

/// An account's round letter avatar in its own hue.
struct AccountAvatar: View {
    let account: Account
    var size: CGFloat = 20

    var body: some View {
        let tint = Theme.accountTint(account.colorIndex)
        Circle()
            .fill(Color(tint.fill))
            .overlay(Text(Avatar.initials(name: account.displayName, email: account.email, letters: 1))
                .font(.ui(size * 0.48, .semibold))
                .foregroundStyle(Color(tint.text)))
            .frame(width: size, height: size)
    }

    @MainActor
    static func image(_ account: Account, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            Avatar.drawLetters(Avatar.initials(name: account.displayName, email: account.email, letters: 1),
                               tint: Theme.accountTint(account.colorIndex), in: rect)
            return true
        }
        return image
    }
}

/// New message: the one ink icon in the title bar.
private struct ComposeButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.compose() } label: {
            IconView(icon: .compose, size: 16, color: Color(Theme.ink))
                .frame(width: Theme.Control.regular, height: Theme.Control.regular)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Color(Theme.hairlineStrong), lineWidth: 1))
        }
        .buttonStyle(IconButtonStyle())
        .help(model.registry?.hint("New message", "compose") ?? "New message")
    }
}
