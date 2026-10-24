import AppKit
import Observation
import SwiftUI
import TernCore

/// One row in the palette.
struct PaletteItem: Identifiable {
    enum Leading {
        case none
        case icon(Icon)
        case project(Project)
        case dot(NSColor)
        case check(Bool)
    }

    let id: String
    var title: String
    var subtitle: String?
    var shortcut: String?
    var leading: Leading = .none
    var run: @MainActor () -> Void
}

struct PaletteSection: Identifiable {
    var id: String { title }
    var title: String
    var items: [PaletteItem]
}

/// What the palette lists for the current mode and query. Recomputed on each change; the registry is
/// small enough that this stays well under a frame.
@MainActor
@Observable
final class PaletteController {
    let model: AppModel
    let registry: CommandRegistry
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            selectionUsesPointer = false
            selection = 0
            searchThreads()
        }
    }
    var selection = 0
    private(set) var selectionUsesPointer = false
    @ObservationIgnored private var pointerPosition: NSPoint?
    private(set) var threadRows: [ThreadRow] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(model: AppModel, registry: CommandRegistry) {
        self.model = model
        self.registry = registry
    }

    var mode: PaletteMode { model.palette ?? .commands }

    var placeholder: String {
        switch mode {
        case .commands: "Type a command or search…"
        case .label: "Label…"
        case .project, .goToProject: "Project…"
        case .snooze: "Snooze until…"
        case .goToLabel: "Go to label…"
        }
    }

    var sections: [PaletteSection] {
        let raw = rawSections
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return raw.filter { !$0.items.isEmpty } }
        return raw.compactMap { section in
            if section.title == CommandGroup.threads.rawValue { return section.items.isEmpty ? nil : section }
            let ranked = section.items
                .compactMap { item in Fuzzy.best(q, title: item.title, aliases: aliases[item.id] ?? []).map { (item, $0) } }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
            return ranked.isEmpty ? nil : PaletteSection(title: section.title, items: Array(ranked.prefix(8)))
        }
    }

    var flatItems: [PaletteItem] { sections.flatMap(\.items) }

    // MARK: Keys

    /// Pointer-driven selection, with the screen position supplied by the row's tracking callback.
    func hover(_ position: Int, at point: NSPoint) {
        guard point != pointerPosition else { return }
        pointerPosition = point
        selectionUsesPointer = true
        selection = position
    }

    func handle(_ key: KeyRouter.PaletteKey) -> Bool {
        selectionUsesPointer = false
        let items = flatItems
        switch key {
        case .up: selection = max(0, selection - 1)
        case .down: selection = min(max(items.count - 1, 0), selection + 1)
        case .run, .runOnSelection:
            guard items.indices.contains(selection) else { return true }
            run(items[selection])
        case .close: close()
        }
        return true
    }

    func run(_ item: PaletteItem) {
        if case .commands = mode, registry[item.id] != nil { model.prefs.noteRecent(item.id) }
        model.palette = nil
        query = ""
        item.run()
    }

    func close() {
        model.palette = nil
        query = ""
    }

    /// Every opening starts from an empty query with the first row highlighted.
    func reset() {
        query = ""
        pointerPosition = NSEvent.mouseLocation
        selectionUsesPointer = false
        selection = 0
    }

    // MARK: Items

    @ObservationIgnored private var aliases: [String: [String]] = [:]

    private var rawSections: [PaletteSection] {
        switch mode {
        case .commands: commandSections
        case .label(let keys): [PaletteSection(title: "Labels", items: labelItems(keys))]
        case .project(let keys): [PaletteSection(title: "Projects", items: projectItems(keys))]
        case .snooze(let keys): [PaletteSection(title: "Snooze", items: snoozeItems(keys))]
        case .goToLabel: [PaletteSection(title: "Labels", items: model.labels.map(goToLabelItem))]
        case .goToProject: [PaletteSection(title: "Projects", items: model.projects.map(goToProjectItem))]
        }
    }

    private var commandSections: [PaletteSection] {
        let m = model
        var byGroup: [CommandGroup: [PaletteItem]] = [:]
        var recentItems: [PaletteItem] = []
        aliases = [:]
        let available = registry.commands.filter { !$0.hiddenInPalette && $0.isVisible() && registry.canRun($0) }
        for command in available {
            aliases[command.id] = command.aliases
            let item = PaletteItem(
                id: command.id, title: command.displayTitle, shortcut: command.shortcutText,
                leading: Self.icons[command.id].map { .icon($0) } ?? .none, run: { [registry] in registry.run(command.id) })
            byGroup[command.group, default: []].append(item)
        }
        if query.isEmpty {
            let ids = Set(available.map(\.id))
            for id in m.prefs.recentCommands where ids.contains(id) {
                if let command = registry[id] {
                    recentItems.append(PaletteItem(id: "recent.\(id)", title: command.displayTitle, shortcut: command.shortcutText,
                                                   leading: Self.icons[id].map { .icon($0) } ?? .none,
                                                   run: { [registry] in registry.run(id) }))
                }
            }
        }
        // Projects, labels, accounts and threads change what the mail shows, so like the mail commands they
        // aren't offered while the settings page covers it.
        if !m.settingsOpen {
            byGroup[.projects, default: []] += m.projects.map(goToProjectItem)
            byGroup[.labels, default: []] += m.labels.map(goToLabelItem)
            for (index, account) in m.accounts.enumerated() {
                let id = "account.\(account.id)"
                aliases[id] = [account.email]
                byGroup[.accounts, default: []].append(PaletteItem(
                    id: id, title: m.accountTitle(account), subtitle: account.email,
                    shortcut: index < 9 ? "⌘\(index + 1)" : nil, leading: .dot(Theme.accountColor(account.colorIndex)),
                    run: { m.setScope(.account(account.id)) }))
            }
            byGroup[.threads] = threadRows.prefix(6).map(threadItem)
        }

        var sections: [PaletteSection] = []
        if !recentItems.isEmpty { sections.append(PaletteSection(title: "Recent", items: Array(recentItems.prefix(4)))) }
        for group in CommandGroup.allCases {
            sections.append(PaletteSection(title: group.rawValue, items: byGroup[group] ?? []))
        }
        return sections
    }

    private static let icons: [String: Icon] = [
        "archive": .archive, "snooze": .snoozed, "trash": .trash, "discardDraft": .trash, "spam": .spam, "moveToInbox": .inbox,
        "commitmentDone": .done, "commitmentDismiss": .close, "go.due": .calendar,
        "star": .star, "needsReply": .needsReply, "label": .label, "project": .folder, "unread": .unread,
        "mute": .mute, "undo": .undo, "reply": .reply, "replyAll": .replyAll, "forward": .forward,
        "compose": .compose, "search": .search, "summarize": .sparkles, "print": .print, "quickLook": .eye,
        "find": .search, "markAllRead": .done, "palette": .command,
        "go.inbox": .inbox, "go.needsReply": .needsReply, "go.snoozed": .snoozed, "go.starred": .starred,
        "go.drafts": .drafts, "go.sent": .sent, "go.archive": .archive, "go.allMail": .allMail, "go.spam": .spam, "go.trash": .trash,
        "go.label": .label, "go.project": .folder, "newProject": .plus, "addAccount": .plus,
        "settings": .settings, "shortcuts": .keyboard, "toggleSidebar": .sidebar, "listOnly": .readingPane,
        "readerOverlay": .panelClose, "readerWide": .expand,
        "splitInbox": .inbox, "appearance.toggle": .sun,
        "moveToTab.primary": .tab(.primary), "moveToTab.promotions": .tab(.promotions), "moveToTab.social": .tab(.social),
        "moveToTab.updates": .tab(.updates), "moveToTab.forums": .tab(.forums),
    ]

    private func threadItem(_ row: ThreadRow) -> PaletteItem {
        let m = model
        let query = self.query
        return PaletteItem(
            id: "thread.\(row.id)", title: row.thread.subject.isEmpty ? "(no subject)" : row.thread.subject,
            subtitle: RowFormat.senders(row.thread).text, shortcut: RowFormat.compactTime(row.thread.lastDate),
            leading: .dot(Theme.accountColor(m.account(row.thread.accountId)?.colorIndex ?? 0)),
            run: { m.revealSearchResult(query: query, key: row.id) })
    }

    private func goToProjectItem(_ project: Project) -> PaletteItem {
        let m = model
        let unread = m.counts.projectUnread[project.id] ?? 0
        return PaletteItem(id: "project.\(project.id)", title: project.name, subtitle: unread > 0 ? "\(unread) unread" : nil,
                           leading: .project(project), run: { m.show(.project(project.id)) })
    }

    private func goToLabelItem(_ label: MailLabel) -> PaletteItem {
        let m = model
        return PaletteItem(id: "label.\(label.id)", title: label.name, leading: .icon(.label), run: { m.show(.label(label.id)) })
    }

    private func labelItems(_ keys: [ThreadKey]) -> [PaletteItem] {
        let m = model
        return (m.labelsForTargets() ?? []).map { label in
            let all = keys.allSatisfy { m.row($0)?.thread.labelIds.contains(label.id) ?? false }
            return PaletteItem(id: "apply.\(label.id)", title: label.name, leading: .check(all),
                               run: { m.toggleLabel(label, on: keys) })
        }
    }

    private func projectItems(_ keys: [ThreadKey]) -> [PaletteItem] {
        let m = model
        var items = m.projects.map { project in
            let all = keys.allSatisfy { m.row($0)?.projectIds.contains(project.id) ?? false }
            return PaletteItem(id: "assign.\(project.id)", title: project.name, subtitle: all ? "Remove" : nil,
                               leading: .project(project), run: { m.toggleProject(project.id, on: keys) })
        }
        items.append(PaletteItem(id: "assign.new", title: "New project…", leading: .icon(.plus), run: { m.newProject() }))
        return items
    }

    private func snoozeItems(_ keys: [ThreadKey]) -> [PaletteItem] {
        let m = model
        var items = SnoozeOption.presets().map { option in
            PaletteItem(id: "snooze.\(option.id)", title: option.title, shortcut: option.detail, leading: .icon(.snoozed),
                        run: { m.perform(.snooze(until: option.date), on: keys) })
        }
        items.append(PaletteItem(id: "snooze.pick", title: "Pick date…", leading: .icon(.snoozed), run: { m.snoozeDateFor = keys }))
        return items
    }

    // MARK: Live thread search

    private func searchThreads() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard case .commands = mode, text.count >= 2, !model.settingsOpen else {
            if !threadRows.isEmpty { threadRows = [] }
            return
        }
        let search = model.services.search
        let accountId = model.scope.accountId
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.searchDebounce)
            guard !Task.isCancelled else { return }
            let rows = await Task.detached(priority: .userInitiated) {
                (try? search.search(text, accountId: accountId, limit: 6)) ?? []
            }.value
            guard let self, !Task.isCancelled else { return }
            self.threadRows = rows
        }
    }
}

extension AppModel {
    /// Shows a palette thread result in the list: runs the same search and selects that thread.
    func revealSearchResult(query: String, key: ThreadKey) {
        pendingCursor = key
        focus = .list
        searchText = query
        searchFieldFocused = false
    }
}

// MARK: - View

/// The ⌘K palette: 640 px, floating glass, grouped results with keycaps on the right.
struct PaletteView: View {
    @Bindable var controller: PaletteController
    @FocusState private var focused: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconView(icon: .search, size: 16, color: Color(Theme.text3))
                TextField(controller.placeholder, text: $controller.query)
                    .textFieldStyle(.plain)
                    .font(.ui(16))
                    .foregroundStyle(Color(Theme.text1))
                    .focused($focused)
                scopeChip
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Hairline()
            results
        }
        .frame(width: 640)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .glassSurface()
        .onAppear {
            controller.reset()
            focused = true
        }
        .onChange(of: model.palette) { _, mode in
            guard mode != nil else { return }
            controller.reset()
            focused = true
        }
    }

    private var scopeChip: some View {
        let title = model.scopedAccount.map(model.accountTitle) ?? "All accounts"
        return Text(title)
            .font(.ui(12, .medium))
            .foregroundStyle(Color(Theme.text2))
            .padding(.horizontal, 8)
            .frame(height: Theme.Control.small)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Color(Theme.hover)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Color(Theme.hairline), lineWidth: 1))
    }

    private var results: some View {
        let sections = controller.sections
        var index = 0
        let indexed: [(PaletteSection, [(Int, PaletteItem)])] = sections.map { section in
            let items = section.items.map { item -> (Int, PaletteItem) in
                defer { index += 1 }
                return (index, item)
            }
            return (section, items)
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sections.isEmpty {
                        Text("No matches")
                            .font(.display(17))
                            .tracking(-0.2)
                            .foregroundStyle(Color(Theme.text2))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }
                    ForEach(indexed, id: \.0.id) { section, items in
                        CapsLabel(text: section.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .frame(height: 30, alignment: .bottom)
                            .padding(.bottom, 4)
                        ForEach(items, id: \.1.id) { position, item in
                            Button { controller.run(item) } label: {
                                PaletteRow(item: item, selected: position == controller.selection)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .accessibilityAddTraits(position == controller.selection ? .isSelected : [])
                            .id(position)
                            .onContinuousHover { phase in
                                if case .active = phase { controller.hover(position, at: NSEvent.mouseLocation) }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: controller.selection) { _, selection in
                if !controller.selectionUsesPointer { proxy.scrollTo(selection) }
            }
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            leading.frame(width: 18)
            Text(item.title)
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text1))
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.ui(12)).foregroundStyle(Color(selected ? Theme.text2 : Theme.text3)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut).font(.numeric(12)).foregroundStyle(Color(selected ? Theme.text2 : Theme.text3))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(Color(Theme.selectedFocus).opacity(selected ? 1 : 0)))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var leading: some View {
        switch item.leading {
        case .none: Color.clear.frame(width: 1, height: 1)
        case .icon(let icon): IconView(icon: icon, size: 14, color: Color(Theme.text2))
        case .project(let project): ProjectGlyph(project: project, size: 16)
        case .dot(let color): Dot(color: color, size: 8)
        case .check(let on):
            if on { IconView(icon: .done, size: 14, color: Color(Theme.ink)) } else { Color.clear.frame(width: 1, height: 1) }
        }
    }
}
