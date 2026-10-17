import AppKit
import SwiftUI
import TernCore

/// The middle column: header with the Flock, search pill, split tabs, the list, toasts.
struct ListColumn: View {
    @Environment(AppModel.self) private var model
    /// Leaves room for the traffic lights when the sidebar is hidden.
    var leadingInset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ListHeader(leadingInset: leadingInset)
            SearchPill()
                .padding(.horizontal, 12)
            if model.showsSplits {
                SplitTabs()
            } else {
                Spacer().frame(height: 10)
                Hairline()
            }
            ZStack {
                MessageListView(model: model)
                if model.listLoaded && model.snapshot.isEmpty {
                    EmptyListView()
                        .background(Color(Theme.bg))
                }
            }
        }
        .background(Color(Theme.bg))
        .overlay(alignment: .bottom) { ToastStack() }
        .overlay(alignment: .top) {
            if model.showsSuggestions {
                SearchSuggestions()
                    .padding(.top, MainWindow.headerHeight + 32 + 6)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.09), value: model.showsSuggestions)
    }
}

// MARK: - Header

struct ListHeader: View {
    @Environment(AppModel.self) private var model
    var leadingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            Text(model.title)
                .font(.ui(15, .semibold))
                .foregroundStyle(Color(Theme.text1))
                .lineLimit(1)
            if let count = model.flockCount, count > 0 {
                FlockView(count: count)
            }
            Spacer(minLength: 8)
            MenuButton(icon: .ellipsis, help: "List options") { listMenu() }
        }
        .padding(.leading, 18 + leadingInset)
        .padding(.trailing, 14)
        .frame(height: MainWindow.headerHeight)
        .background(WindowDragArea())
    }

    private func listMenu() -> NSMenu {
        let model = self.model
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Mark All as Read", enabled: !model.snapshot.isEmpty) { model.markAllRead() })
        menu.addItem(ClosureMenuItem("Select All", key: "a", modifiers: .command, enabled: !model.snapshot.isEmpty) { model.selectAll() })
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
        let split = ClosureMenuItem("Split Inbox") { model.setSplitInbox(!model.prefs.splitInbox) }
        split.state = model.prefs.splitInbox ? .on : .off
        menu.addItem(split)
        let sort = NSMenuItem(title: "Sort: Newest First", action: nil, keyEquivalent: "")
        sort.isEnabled = false
        menu.addItem(sort)
        return menu
    }
}

/// One accent dot per thread that needs you (max 12, then "+n"). Each triage action lifts a dot away.
struct FlockView: View {
    let count: Int
    @State private var lifts: [UUID] = []

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<min(count, 12), id: \.self) { _ in
                Circle().fill(Color(Theme.accent)).frame(width: 6, height: 6)
            }
            if count > 12 {
                Text("+\(count - 12)")
                    .font(.mono(12))
                    .foregroundStyle(Color(Theme.text3))
                    .lineLimit(1)
                    .padding(.leading, 3)
            }
        }
        .fixedSize()
        .overlay(alignment: .leading) {
            ForEach(lifts, id: \.self) { id in
                LiftingDot(offsetX: CGFloat(max(min(count, 12), 0)) * 11) { lifts.removeAll { $0 == id } }
            }
        }
        .onChange(of: count) { old, new in
            guard new < old else { return }
            lifts.append(UUID())
        }
    }
}

/// A dot that drifts 6 px up and fades in 180 ms.
private struct LiftingDot: View {
    let offsetX: CGFloat
    let done: () -> Void
    @State private var lifted = false

    var body: some View {
        Circle()
            .fill(Color(Theme.accent))
            .frame(width: 6, height: 6)
            .offset(x: offsetX, y: lifted ? -6 : 0)
            .opacity(lifted ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.18)) { lifted = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
            }
    }
}

// MARK: - Search pill

struct SearchPill: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            IconView(icon: .search, size: 15, color: Color(Theme.text3))
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text1))
                .focused($focused)
            if !model.searchText.isEmpty {
                Button { model.endSearch(restoreFocus: true) } label: {
                    Text("esc").font(.mono(11)).foregroundStyle(Color(Theme.text3))
                        .padding(.horizontal, 5).frame(height: 20)
                }
                .buttonStyle(.plain)
            } else if !focused {
                Keycap(text: "/")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(Capsule().fill(Color(Theme.hover)))
        .onChange(of: focused) { _, value in
            if model.searchFieldFocused != value { model.searchFieldFocused = value }
            if value {
                model.suggestionsDismissed = false
                model.refreshSuggestions()
            }
        }
        .onChange(of: model.searchFieldFocused) { _, value in
            if focused != value { focused = value }
        }
    }
}

// MARK: - Search suggestions

/// The dropdown under the search pill. ↑↓ move, Tab completes, Return picks, Esc closes.
struct SearchSuggestions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.suggestionItems
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                SuggestionRow(item: item, highlighted: model.suggestionIndex == index, asking: model.askingAI)
                    .contentShape(Rectangle())
                    .onTapGesture { model.choose(item) }
                    .onHover { inside in if inside { model.suggestionIndex = index } }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(Theme.raised)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color(Theme.hairline), lineWidth: 1))
        .overlayShadow()
    }
}

private struct SuggestionRow: View {
    let item: AppModel.SuggestionItem
    let highlighted: Bool
    let asking: Bool

    var body: some View {
        HStack(spacing: 10) {
            switch item {
            case .suggestion(let suggestion):
                IconView(icon: Self.icon(suggestion.kind), size: 14, color: Color(Theme.text3))
                    .frame(width: 16)
                Text(suggestion.title)
                    .font(.ui(13))
                    .foregroundStyle(Color(Theme.text1))
                    .lineLimit(1)
                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.ui(12))
                        .foregroundStyle(Color(Theme.text3))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
            case .ask(let text):
                Text("✦")
                    .font(.ui(12))
                    .foregroundStyle(Color(Theme.accentInk))
                    .frame(width: 16)
                (Text("Ask: ").foregroundStyle(Color(Theme.text2)) + Text(text).foregroundStyle(Color(Theme.text1)))
                    .font(.ui(13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if asking {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(highlighted ? Color(Theme.hover) : .clear))
    }

    private static func icon(_ kind: SearchSuggestion.Kind) -> Icon {
        switch kind {
        case .contact, .account: .person
        case .label, .project: .label
        case .category: .inbox
        case .operator: .search
        case .recent: .snoozed
        }
    }
}

// MARK: - Split tabs

struct SplitTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ForEach(InboxSplit.allCases) { split in
                let active = split == model.split
                Button { model.showSplit(split) } label: {
                    HStack(spacing: 4) {
                        Text(split.title)
                            .font(.ui(13, active ? .medium : .regular))
                            .foregroundStyle(Color(active ? Theme.text1 : Theme.text2))
                        let count = model.unreadCount(split)
                        if count > 0 {
                            Text("\(count)").font(.mono(12)).foregroundStyle(Color(Theme.text3))
                        }
                    }
                    .fixedSize()
                    .padding(.bottom, 9)
                    .overlay(alignment: .bottom) {
                        if active { Rectangle().fill(Color(Theme.text1)).frame(height: 2) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 18)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .bottomLeading)
        .clipped()
        .overlay(alignment: .bottom) { Hairline() }
    }
}

// MARK: - Toasts

struct ToastStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { toast in
                ToastPill(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 24)
        .animation(.easeOut(duration: 0.16), value: model.toasts)
    }
}

private struct ToastPill: View {
    @Environment(AppModel.self) private var model
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.title)
            if let undo = toast.undo {
                Text("·").opacity(0.6)
                Button("Undo") { model.undo(undo) }
                    .buttonStyle(.plain)
                Keycap(text: "z", inverted: true)
            }
        }
        .font(.ui(13))
        .foregroundStyle(Color(Theme.bg))
        .padding(.leading, 16)
        .padding(.trailing, toast.undo == nil ? 16 : 8)
        .frame(height: 36)
        .background(Capsule().fill(Color(Theme.text1).opacity(0.92)))
        .overlayShadow()
    }
}

// MARK: - Menus from SwiftUI

/// An icon button that pops up an AppKit menu (so items show their real shortcuts).
struct MenuButton: View {
    let icon: Icon
    var help = ""
    let menu: () -> NSMenu

    var body: some View {
        IconButton(icon: icon, help: help) {
            guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
            let point = view.convert(event.locationInWindow, from: nil)
            menu().popUp(positioning: nil, at: NSPoint(x: point.x - 8, y: point.y - 14), in: view)
        }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], enabled: Bool = true, _ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { MainActor.assumeIsolated { handler() } }
}
