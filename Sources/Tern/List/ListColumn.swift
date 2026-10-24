import AppKit
import SwiftUI
import TernCore

/// The list: a centred column of one-line rows under the title bar's tabs, the search field above it
/// while searching, and the floating bottom bar.
struct ListColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let column = ListLayout.column(width: geometry.size.width)
            VStack(spacing: 0) {
                if model.searchShown {
                    SearchField()
                        .frame(width: column.width)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                }
                ZStack {
                    MessageListView(model: model)
                    if model.listLoaded && model.snapshot.isEmpty {
                        // Emptied by triage, it fades in over the end of the collapse; any other empty list is just there.
                        EmptyListView()
                            .background(Color(Theme.bg))
                            .transition(model.emptiedByTriage ? .opacity : .identity)
                    }
                }
                .animation(emptyAnimation, value: model.snapshot.isEmpty)
            }
            .overlay(alignment: .top) {
                if model.showsSuggestions {
                    SearchSuggestions()
                        .frame(width: column.width)
                        .padding(.top, 4 + SearchField.height + 4)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if model.prefs.readingPane || !model.readerExpanded || model.readerInPanel {
                    BottomBar()
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
        }
        .background(Color(Theme.bg))
        .animation(reduceMotion ? Motion.reduced : .easeOut(duration: Motion.overlay), value: model.searchShown)
        .animation(.easeOut(duration: 0.09), value: model.showsSuggestions)
    }
}

/// Where the list's centred column sits: full width with small margins in a narrow list, at most
/// `maxColumn` wide on a big window. Rows, headers, the search field and empty states all use it.
enum ListLayout {
    static let maxColumn: CGFloat = 1040

    static func margin(for width: CGFloat) -> CGFloat { width >= 760 ? 28 : 8 }

    static func column(width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let margin = margin(for: width)
        let inner = max(min(width - 2 * margin, maxColumn), 0)
        return (floor((width - inner) / 2), inner)
    }

    static func column(in bounds: CGRect) -> CGRect {
        let column = column(width: bounds.width)
        return CGRect(x: bounds.minX + column.x, y: bounds.minY, width: column.width, height: bounds.height)
    }
}

extension ListColumn {
    private var emptyAnimation: Animation? {
        guard model.emptiedByTriage, model.snapshot.isEmpty else { return nil }
        return reduceMotion ? Motion.reduced : InboxZeroView.arrival
    }
}

// MARK: - Search field

/// The search field, revealed above the list by `/`, ⌘F or the bottom bar; Esc hides it again.
struct SearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    static let height: CGFloat = 36

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            IconView(icon: .search, size: 16, color: Color(Theme.text3))
            TextField("Search mail", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text1))
                .focused($focused)
            if model.isSearching, !model.isPinned(model.activeTab) {
                Button("Pin") { model.pin(model.activeTab) }
                    .buttonStyle(TernButtonStyle(.quiet, size: .small))
                    .help("Pin this search as a tab")
            }
            Button { model.endSearch(restoreFocus: true) } label: {
                Text("esc")
                    .font(.ui(11))
                    .foregroundStyle(Color(Theme.text3))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .help("Close search  Esc")
                .accessibilityLabel("Close search")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.overlay, style: .continuous).fill(Color(Theme.hover)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.overlay, style: .continuous)
            .strokeBorder(Color(focused ? Theme.hairlineStrong : .clear), lineWidth: 1))
        .onAppear {
            // The field appears because search began; take the keyboard once it is in the window.
            DispatchQueue.main.async { if model.searchFieldFocused { focused = true } }
        }
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

/// The dropdown under the search field. ↑↓ move, Tab completes, Return picks, Esc closes.
struct SearchSuggestions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.suggestionItems
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                // The highlight follows the pointer and ↑↓; pressing shows at once, choosing waits for mouse-up.
                Button { model.choose(item) } label: {
                    SuggestionRow(item: item, asking: model.askingAI)
                }
                .buttonStyle(PressFillStyle(radius: Theme.Radius.row, rest: model.suggestionIndex == index ? Theme.selected : nil,
                                            hover: nil, pressed: Theme.selectedFocus))
                .onHover { inside in if inside { model.suggestionIndex = index } }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface()
    }
}

private struct SuggestionRow: View {
    let item: AppModel.SuggestionItem
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
                IconView(icon: .sparkles, size: 14, color: Color(Theme.text2))
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
    }

    private static func icon(_ kind: SearchSuggestion.Kind) -> Icon {
        switch kind {
        case .contact, .account: .person
        case .label: .label
        case .project: .folder
        case .category: .inbox
        case .operator: .command
        case .recent: .snoozed
        }
    }
}

// MARK: - Toasts

/// New toasts rise from the bottom; old ones fade where they are (the oldest is on top, so sliding it down
/// would cross the newer ones). Reduce Motion: a short crossfade both ways.
struct ToastStack: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { toast in
                ToastPill(toast: toast)
                    .transition(transition)
            }
        }
        .padding(.bottom, 24)
        .animation(reduceMotion ? Motion.reduced : Motion.ease(Motion.enter), value: model.toasts)
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.97)).animation(.easeOut(duration: Motion.exit)))
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
                if let shortcut = model.registry?["undo"]?.shortcutText, !shortcut.isEmpty {
                    Keycap(text: shortcut, inverted: true)
                }
            }
        }
        .font(.ui(13))
        .foregroundStyle(Color(Theme.bg))
        .padding(.leading, 14)
        .padding(.trailing, toast.undo == nil ? 14 : 8)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.overlay, style: .continuous).fill(Color(Theme.ink)))
        .overlayShadow()
    }
}

// MARK: - Menus from SwiftUI

/// An icon button that pops up an AppKit menu (so items show their real shortcuts).
struct MenuButton: View {
    let icon: Icon
    var help = ""
    var size: CGFloat = 28
    var onTrackingChange: ((Bool) -> Void)? = nil
    let menu: () -> NSMenu
    @State private var menuAnchor = MenuAnchor.AnchorView()

    var body: some View {
        IconButton(icon: icon, size: size, help: help) {
            menuAnchor.popUp(menu(), onTrackingChange: onTrackingChange)
        }
        .background(MenuAnchor(view: menuAnchor).accessibilityHidden(true))
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

    /// An item showing `command`'s key as it is now, the way the menu bar does.
    convenience init(_ title: String, shortcut command: Command?, enabled: Bool = true, _ handler: @escaping @MainActor () -> Void) {
        let key = command?.menuKey
        self.init(title, key: key?.keyEquivalent ?? "", modifiers: key?.menuModifiers ?? [], enabled: enabled, handler)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { MainActor.assumeIsolated { handler() } }
}
