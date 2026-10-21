import AppKit
import SwiftUI
import TernCore

/// The list: a centred column of one-line rows under the title bar's tabs, the search field above it
/// while searching, and the floating bottom bar.
struct ListColumn: View {
    @Environment(AppModel.self) private var model

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
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
                ZStack {
                    MessageListView(model: model)
                    if model.listLoaded && model.snapshot.isEmpty {
                        EmptyListView()
                            .background(Color(Theme.bg))
                    }
                }
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
        .animation(.easeOut(duration: 0.12), value: model.searchShown)
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
            Button { model.endSearch(restoreFocus: true) } label: { Keycap(text: "esc") }
                .buttonStyle(.plain)
                .help("Close search  Esc")
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
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(highlighted ? Color(Theme.selected) : .clear))
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

    /// An item showing `command`'s key as it is now, the way the menu bar does.
    convenience init(_ title: String, shortcut command: Command?, enabled: Bool = true, _ handler: @escaping @MainActor () -> Void) {
        let key = command?.menuKey
        self.init(title, key: key?.keyEquivalent ?? "", modifiers: key?.menuModifiers ?? [], enabled: enabled, handler)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { MainActor.assumeIsolated { handler() } }
}
