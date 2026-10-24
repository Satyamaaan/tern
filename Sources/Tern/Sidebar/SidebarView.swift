import AppKit
import SwiftUI
import TernCore
import UniformTypeIdentifiers

/// The sidebar behind the bottom bar's toggle (⌃⌘S): mailboxes, projects, accounts, the sync line,
/// the light/dark switch and Settings.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) { mailboxes }
                    VStack(alignment: .leading, spacing: 2) { projects }
                    if model.accounts.count > 1 {
                        VStack(alignment: .leading, spacing: 2) { accounts }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            SyncStatusLine()
        }
    }

    // MARK: Mailboxes

    @ViewBuilder private var mailboxes: some View {
        let counts = model.counts
        row(.inbox, "Inbox", .inbox, count: counts.inboxUnread, countColor: Theme.text1)
        row(.needsReply, "Needs reply", .needsReply, count: counts.needsReply, countColor: Theme.ink, countWeight: .medium)
        if counts.ledgerEnabled {
            row(.due, "Due", .due, count: counts.due, countColor: Theme.ink, countWeight: .medium)
        }
        row(.snoozed, "Snoozed", .snoozed, count: counts.snoozed)
        row(.starred, "Starred", .starred)
        row(.drafts, "Drafts", .drafts, count: counts.drafts)
        row(.sent, "Sent", .sent)
        row(.archive, "Archive", .archive)
        row(.allMail, "All mail", .allMail)
        SidebarRow(title: "More", selected: false, titleColor: Theme.text2) {
            IconView(icon: model.prefs.moreExpanded ? .chevronDown : .ellipsis, size: 16)
        } action: {
            withAnimation(reduceMotion ? Motion.reduced : Motion.ease(Motion.reveal)) { model.prefs.moreExpanded.toggle() }
        }
        if model.prefs.moreExpanded {
            Group {
                row(.spam, "Spam", .spam)
                row(.trash, "Trash", .trash)
                ForEach(model.labels, id: \.id) { label in
                    LabelRow(label: label)
                }
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
        }
    }

    private func row(
        _ kind: Mailbox.Kind, _ title: String, _ icon: Icon, count: Int = 0, countColor: NSColor = Theme.text3,
        countWeight: Theme.Weight = .regular
    ) -> some View {
        SidebarRow(
            title: title, count: count > 0 ? count : nil, countColor: countColor, countWeight: countWeight,
            selected: model.kind == kind && !model.isSearching
        ) {
            IconView(icon: icon, size: 16)
        } action: {
            model.show(kind)
        }
    }

    // MARK: Accounts

    @ViewBuilder private var accounts: some View {
        if model.accounts.count > 1 {
            Text("Accounts")
                .font(.ui(12, .medium))
                .foregroundStyle(Color(Theme.text2))
                .padding(.leading, 10)
                .frame(height: 24)
                .padding(.bottom, 4)
            SidebarRow(title: "All accounts", selected: model.scope == .all) {
                IconView(icon: .inbox, size: 16)
            } action: {
                model.setScope(.all)
            }
            ForEach(model.accounts) { account in
                SidebarRow(title: model.accountTitle(account), selected: model.scope == .account(account.id)) {
                    AccountAvatar(account: account, size: 16)
                } action: {
                    model.setScope(.account(account.id))
                }
            }
        }
    }

    // MARK: Projects

    @ViewBuilder private var projects: some View {
        ProjectsHeader()
            .padding(.bottom, 4)
        ForEach(model.projects) { project in
            ProjectRow(project: project)
        }
        if model.projects.isEmpty {
            Text("Group mail by client or product across accounts.")
                .font(.ui(12))
                .foregroundStyle(Color(Theme.text3))
                .padding(.horizontal, 10)
                .padding(.top, 2)
        }
    }
}

/// A 32 pt sidebar row with a continuous selection wash and a quiet count capsule.
struct SidebarRow<Leading: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    let title: String
    var count: Int?
    var countColor: NSColor = Theme.text3
    var countWeight: Theme.Weight = .regular
    let selected: Bool
    var titleColor: NSColor = Theme.text1
    var dropTargeted = false
    var trailing: AnyView?
    var menuOpen = false
    @ViewBuilder let leading: () -> Leading
    let action: () -> Void

    @State private var hovering = false
    @FocusState private var rowFocused: Bool
    @FocusState private var trailingFocused: Bool
    @AccessibilityFocusState private var trailingAccessibilityFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading()
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.ui(13, selected ? .semibold : .regular))
                    .foregroundStyle(Color(selected ? Theme.text1 : titleColor))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count, trailing == nil || !showsTrailing {
                    Text(count.formatted())
                        .font(.numeric(11, selected ? .medium : countWeight))
                        .foregroundStyle(Color(selected ? Theme.text1 : countColor))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 20)
                        .background(Capsule().fill(Color(Theme.ink).opacity(selected ? 0.06 : 0.04)))
                        .fixedSize()
                } else if trailing != nil, showsTrailing {
                    Color.clear.frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
        }
        .buttonStyle(PressFillStyle(
            radius: 12,
            rest: filled ? (contrast == .increased ? Theme.selectedFocus : Theme.ink.withAlphaComponent(0.08)) : nil,
            hover: filled ? nil : Theme.ink.withAlphaComponent(0.06),
            pressed: Theme.ink.withAlphaComponent(0.12)
        ))
        .focused($rowFocused)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.20 : 0.85),
                            Color(Theme.hairlineStrong).opacity(0.55)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
                .opacity(filled ? 1 : 0)
                .allowsHitTesting(false)
        }
        // Keep the menu outside the row button so its clicks stay its own.
        .overlay(alignment: .trailing) {
            if let trailing {
                trailing
                    .focused($trailingFocused)
                    .accessibilityFocused($trailingAccessibilityFocused)
                    .opacity(showsTrailing ? 1 : 0)
                    .allowsHitTesting(showsTrailing)
                    .padding(.trailing, 10)
            }
        }
        .onHover { hovering = $0 }
    }

    private var filled: Bool { selected || dropTargeted }
    private var showsTrailing: Bool { hovering || rowFocused || trailingFocused || trailingAccessibilityFocused || menuOpen }
}

private struct LabelRow: View {
    @Environment(AppModel.self) private var model
    let label: MailLabel
    @State private var targeted = false

    var body: some View {
        SidebarRow(title: label.name, selected: model.kind == .label(label.id) && !model.isSearching, dropTargeted: targeted) {
            IconView(icon: .label, size: 16)
        } action: {
            model.show(.label(label.id))
        }
        .onDrop(of: [.plainText, .utf8PlainText], isTargeted: $targeted) { _ in
            guard !model.draggedKeys.isEmpty else { return false }
            model.dropDragged(onLabel: label)
            return true
        }
    }
}

// MARK: - Projects

private struct ProjectsHeader: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack {
            Text("Projects")
                .font(.ui(12, .medium))
                .foregroundStyle(Color(Theme.text2))
            Spacer()
            IconButton(icon: .plus, size: 24, iconSize: 14,
                       help: model.registry?.hint("New project", "newProject") ?? "New project") { model.newProject() }
                .hoverReveal(hovering)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var targeted = false
    @State private var menuOpen = false

    var body: some View {
        let unread = model.counts.projectUnread[project.id] ?? 0
        SidebarRow(
            title: project.name, count: unread > 0 ? unread : nil,
            selected: model.kind == .project(project.id) && !model.isSearching,
            dropTargeted: targeted,
            trailing: AnyView(MenuButton(icon: .ellipsis, help: "Options for \(project.name)", size: 24,
                                         onTrackingChange: { menuOpen = $0 }) { menu() }),
            menuOpen: menuOpen
        ) {
            ProjectGlyph(project: project)
        } action: {
            model.show(.project(project.id))
        }
        .onDrop(of: [.plainText, .utf8PlainText], isTargeted: $targeted) { _ in
            guard !model.draggedKeys.isEmpty else { return false }
            model.dropDragged(onProject: project.id)
            return true
        }
        .contextMenu {
            Button("Rename…") { model.editProject(project) }
            Menu("Colour") {
                ForEach(Theme.projectHues.indices, id: \.self) { index in
                    Button(Theme.projectColorNames[index]) { model.setProjectColor(project, index) }
                }
            }
            Button("Rules…") { model.editProject(project) }
            Divider()
            Button("Delete Project…") { confirmDelete() }
        }
    }

    private func menu() -> NSMenu {
        let model = self.model
        let project = self.project
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Rename…") { model.editProject(project) })
        let colours = NSMenu()
        for index in Theme.projectHues.indices {
            let item = ClosureMenuItem(Theme.projectColorNames[index]) { model.setProjectColor(project, index) }
            item.image = Theme.swatch(Theme.projectColor(index))
            item.state = project.colorIndex == index ? .on : .off
            colours.addItem(item)
        }
        let colourItem = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        colourItem.submenu = colours
        menu.addItem(colourItem)
        menu.addItem(ClosureMenuItem("Rules…") { model.editProject(project) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete Project…") { confirmDelete() })
        return menu
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete “\(project.name)”?"
        alert.informativeText = "Its conversations stay in your mailboxes."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.deleteProject(project) }
    }
}

// MARK: - Sync status

/// One quiet line pinned to the bottom: "Up to date", "Syncing 1,204 of 8,330", "Offline — changes will
/// sync", or a "Sign in again" link, then the light/dark switch and Settings.
struct SyncStatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            // One state crossfades into the next; the figures within a state (Syncing 1,204 of 8,330) just change.
            ZStack(alignment: .leading) {
                HStack(spacing: 7) { content }
                    .lineLimit(2)
                    .id(state)
                    .transition(.opacity)
            }
            .animation(reduceMotion ? Motion.reduced : .easeOut(duration: Motion.reveal), value: state)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button { model.prefs.appearance = AppearanceMode.flipped } label: {
                    IconView(icon: colorScheme == .dark ? .sun : .moon, size: 15, color: Color(Theme.text2))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PressFillStyle(radius: 14, hover: Theme.ink.withAlphaComponent(0.06), pressed: Theme.ink.withAlphaComponent(0.12)))
                .help(model.registry?.hint(colorScheme == .dark ? "Switch to Light Appearance" : "Switch to Dark Appearance", "appearance.toggle") ?? "Change appearance")
                Button { model.registry?.run("settings") } label: {
                    IconView(icon: .settings, size: 15, color: Color(model.settingsOpen ? Theme.text1 : Theme.text2))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PressFillStyle(
                    radius: 14, rest: model.settingsOpen ? Theme.ink.withAlphaComponent(0.08) : nil,
                    hover: Theme.ink.withAlphaComponent(0.06), pressed: Theme.ink.withAlphaComponent(0.12)
                ))
                .help(model.registry?.hint("Settings", "settings") ?? "Settings")
            }
            .padding(2)
            .background(Capsule().fill(Color(Theme.ink).opacity(0.04)))
            .fixedSize()
        }
        .font(.ui(12))
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(height: 44)
        .overlay(alignment: .top) { Hairline().padding(.horizontal, 20) }
    }

    /// Which line shows, without its figures.
    private var state: String {
        let services = model.services
        let accounts = model.accounts
        if accounts.contains(where: { $0.syncState == .needsAuth }) { return "needsAuth" }
        if services.isOffline { return "offline" }
        if let line = services.syncLine { return "line:\(line.tone):" + line.text.filter { !$0.isNumber } }
        if services.syncProgress != nil { return "progress" }
        if accounts.isEmpty { return model.isSeeding ? "seeding" : "noAccounts" }
        if accounts.contains(where: { $0.syncState == .error }) { return "error" }
        if accounts.contains(where: { $0.syncState == .new || $0.syncState == .backfilling }) { return "syncing" }
        return "upToDate"
    }

    @ViewBuilder private var content: some View {
        let services = model.services
        let accounts = model.accounts
        if let account = accounts.first(where: { $0.syncState == .needsAuth }) {
            Dot(color: Theme.ink, size: 6)
            Button("Sign in again") {
                Task { try? await services.reauthAccount(account) }
            }
            .buttonStyle(LinkButtonStyle())
            .font(.ui(12, .medium))
        } else if services.isOffline {
            Dot(color: Theme.text3, size: 6)
            Text("Offline — changes will sync").foregroundStyle(Color(Theme.text3))
        } else if let line = services.syncLine {
            Dot(color: line.tone == .attention ? Theme.ink : Theme.text3, size: 6)
            if let url = line.url {
                Button { NSWorkspace.shared.open(url) } label: {
                    Text(line.text).underline().foregroundStyle(Color(Theme.text2)).lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help(line.detail ?? line.text)
            } else {
                Text(line.text).foregroundStyle(Color(Theme.text3)).lineLimit(1).truncationMode(.tail)
                    .help(line.detail ?? line.text)
            }
        } else if let progress = services.syncProgress {
            Dot(color: Theme.text3, size: 6)
            Text("Syncing \(progress.done.formatted()) of \(progress.total.formatted())").foregroundStyle(Color(Theme.text3))
        } else if accounts.isEmpty {
            Text(model.isSeeding ? "Preparing demo mail…" : "No accounts yet").foregroundStyle(Color(Theme.text3))
        } else if accounts.contains(where: { $0.syncState == .error }) {
            Dot(color: Theme.ink, size: 6)
            Text("Couldn't sync — retrying").foregroundStyle(Color(Theme.text3))
        } else if accounts.contains(where: { $0.syncState == .new || $0.syncState == .backfilling }) {
            Dot(color: Theme.text3, size: 6)
            Text("Syncing…").foregroundStyle(Color(Theme.text3))
        } else {
            Dot(color: Theme.text3, size: 6, ring: true)
            Text(model.isFake ? "Demo mail · Up to date" : "Up to date").foregroundStyle(Color(Theme.text3))
        }
    }
}
