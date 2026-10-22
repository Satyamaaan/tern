import AppKit
import SwiftUI
import TernCore
import UniformTypeIdentifiers

/// The sidebar behind the bottom bar's toggle (⌃⌘S): mailboxes, projects, accounts, the sync line,
/// the light/dark switch and Settings.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    mailboxes
                    projects
                    accounts
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            SyncStatusLine()
        }
        .background(Color(Theme.sidebar))
    }

    // MARK: Mailboxes

    @ViewBuilder private var mailboxes: some View {
        let counts = model.counts
        row(.inbox, "Inbox", .inbox, count: counts.inboxUnread, countColor: Theme.text1)
        row(.needsReply, "Needs reply", .needsReply, count: counts.needsReply, countColor: Theme.ink, countWeight: .medium)
        if counts.waitingOn > 0 {
            row(.waitingOn, "Waiting on", .waitingOn, count: counts.waitingOn, countColor: Theme.ink, countWeight: .medium)
        }
        row(.iOwe, "I owe", .needsReply, count: counts.iOwe, countColor: Theme.ink, countWeight: .medium)
        row(.snoozed, "Snoozed", .snoozed, count: counts.snoozed)
        row(.starred, "Starred", .starred)
        row(.drafts, "Drafts", .drafts, count: counts.drafts)
        row(.sent, "Sent", .sent)
        row(.archive, "Archive", .archive)
        row(.allMail, "All mail", .allMail)
        SidebarRow(title: "More", selected: false, titleColor: Theme.text2) {
            IconView(icon: model.prefs.moreExpanded ? .chevronDown : .ellipsis, size: 16)
        } action: {
            withAnimation(.easeOut(duration: 0.15)) { model.prefs.moreExpanded.toggle() }
        }
        if model.prefs.moreExpanded {
            row(.spam, "Spam", .spam)
            row(.trash, "Trash", .trash)
            ForEach(model.labels, id: \.id) { label in
                LabelRow(label: label)
            }
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
            CapsLabel(text: "Accounts")
                .padding(.leading, 8)
                .frame(height: 22)
                .padding(.top, 16)
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
            .padding(.top, 16)
            .padding(.bottom, 4)
        ForEach(model.projects) { project in
            ProjectRow(project: project)
        }
        if model.projects.isEmpty {
            Text("Group mail by client or product across accounts.")
                .font(.ui(12))
                .foregroundStyle(Color(Theme.text3))
                .padding(.horizontal, 8)
                .padding(.top, 2)
        }
    }
}

/// A 28 px sidebar row: icon, title, count. `selected` fill when current, `hover` fill under the pointer.
struct SidebarRow<Leading: View>: View {
    let title: String
    var count: Int?
    var countColor: NSColor = Theme.text3
    var countWeight: Theme.Weight = .regular
    let selected: Bool
    var titleColor: NSColor = Theme.text1
    var dropTargeted = false
    var trailing: AnyView?
    @ViewBuilder let leading: () -> Leading
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            leading()
                .frame(width: 16, height: 16)
            Text(title)
                .font(.ui(13, selected ? .medium : .regular))
                .foregroundStyle(Color(titleColor))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailing, hovering {
                trailing
            } else if let count {
                Text(count.formatted())
                    .font(.numeric(12, countWeight))
                    .foregroundStyle(Color(countColor))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row)
                .fill(Color(selected || dropTargeted ? Theme.selected : Theme.hover).opacity(selected || dropTargeted || hovering ? 1 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
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
            CapsLabel(text: "Projects")
            Spacer()
            IconButton(icon: .plus, size: 20, iconSize: 14, help: "New project  ⇧⌘P") { model.newProject() }
                .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var targeted = false

    var body: some View {
        let unread = model.counts.projectUnread[project.id] ?? 0
        SidebarRow(
            title: project.name, count: unread > 0 ? unread : nil,
            selected: model.kind == .project(project.id) && !model.isSearching,
            dropTargeted: targeted,
            trailing: AnyView(MenuButton(icon: .ellipsis, help: "Project options") { menu() }.frame(width: 20, height: 20).scaleEffect(0.8))
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

    var body: some View {
        HStack(spacing: 7) {
            content
            Spacer(minLength: 0)
            Button { model.prefs.appearance = AppearanceMode.flipped } label: {
                IconView(icon: colorScheme == .dark ? .sun : .moon, size: 15, color: Color(Theme.text2))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(IconButtonStyle())
            .help(model.registry?.hint(colorScheme == .dark ? "Switch to Light Appearance" : "Switch to Dark Appearance", "appearance.toggle") ?? "")
            Button { model.registry?.run("settings") } label: {
                IconView(icon: .settings, size: 15, color: Color(model.settingsOpen ? Theme.text1 : Theme.text2))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(IconButtonStyle())
            .help(model.registry?.hint("Settings", "settings") ?? "Settings")
        }
        .font(.ui(12))
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 44)
        .overlay(alignment: .top) { Hairline() }
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
