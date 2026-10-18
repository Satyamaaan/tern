import AppKit
import SwiftUI

/// Settings as a page of the main window, over the mail the way an open thread lies over the list: the
/// sections where the sidebar goes (traffic lights at its top), and on the right a title bar with the
/// way back over the chosen section's rows in a centred column. Esc, ⌘[ or ← go back to the mail as it was.
struct SettingsPage: View {
    @Bindable var state: SettingsState

    /// The content column at most; narrower windows give it what's left.
    static let columnWidth: CGFloat = 680

    var body: some View {
        HStack(spacing: 0) {
            SettingsNav(state: state)
                .frame(width: MainView.sidebarWidth)
                .background(Color(Theme.sidebar))
            Hairline(vertical: true)
            VStack(spacing: 0) {
                SettingsTitleBar(state: state)
                SettingsContent(state: state)
            }
            .frame(maxWidth: .infinity)
            .background(Color(Theme.bg))
        }
        .background(SettingsKeyView(state: state))
        .tint(Color(Theme.ink))
    }
}

/// The section list, with the search field over it. While searching, sections without a match fade.
private struct SettingsNav: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: SettingsState
    @FocusState private var searchFocused: Bool

    var body: some View {
        let searching = !state.query.trimmingCharacters(in: .whitespaces).isEmpty
        let matched = Set(SettingsCatalog.results(for: state.query, model: model).map(\.section)
            + (SettingsCatalog.commands(for: state.query, registry: model.registry).isEmpty ? [] : [.shortcuts]))
        VStack(alignment: .leading, spacing: 0) {
            WindowDragArea().frame(height: MainWindow.headerHeight)
            SettingsField(placeholder: "Search settings", text: $state.query, focused: $searchFocused)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            VStack(spacing: 1) {
                ForEach(SettingsSection.allCases) { section in
                    let selected = !searching && state.section == section
                    SidebarRow(title: section.title, selected: selected,
                               titleColor: searching && !matched.contains(section) ? Theme.text3 : Theme.text1) {
                        IconView(icon: section.icon, size: 16, color: Color(selected ? Theme.text1 : Theme.text2))
                    } action: {
                        state.show(section)
                        state.takeKeyboard()
                    }
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .onChange(of: searchFocused) { _, value in if state.searchFocused != value { state.searchFocused = value } }
        .onChange(of: state.searchFocused) { _, value in if searchFocused != value { searchFocused = value } }
    }
}

/// Where you are, with the quiet way back.
private struct SettingsTitleBar: View {
    let state: SettingsState

    var body: some View {
        HStack(spacing: 6) {
            IconButton(icon: .back, help: "Back to mail  esc") { state.close() }
            Text("Settings")
                .font(.ui(13, .medium))
                .foregroundStyle(Color(Theme.text2))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: MainWindow.headerHeight)
        .background(WindowDragArea())
    }
}

/// The section's title and rows, or the search results, in the centred column.
private struct SettingsContent: View {
    @Environment(AppModel.self) private var model
    let state: SettingsState

    var body: some View {
        let query = state.query.trimmingCharacters(in: .whitespaces)
        GeometryReader { geometry in
            let margin: CGFloat = geometry.size.width >= 760 ? 28 : 20
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(query.isEmpty ? state.section.title : "Results")
                        .font(.display(22))
                        .tracking(-0.3)
                        .foregroundStyle(Color(Theme.text1))
                        .padding(.bottom, 12)
                    if query.isEmpty {
                        SettingsItemList(items: SettingsItem.items(in: state.section, model: model), state: state)
                    } else {
                        SettingsResults(query: query, state: state)
                    }
                }
                .frame(maxWidth: SettingsPage.columnWidth, alignment: .leading)
                .padding(.horizontal, margin)
                .padding(.top, 12)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            // A new section starts at the top, at once.
            .id(query.isEmpty ? state.section.rawValue : "results")
            .transaction(value: state.section) { $0.animation = nil }
        }
    }
}

/// Settings that match the search, under their sections' names, then matching shortcuts.
private struct SettingsResults: View {
    @Environment(AppModel.self) private var model
    let query: String
    let state: SettingsState

    var body: some View {
        let items = SettingsCatalog.results(for: query, model: model)
        let commands = Array(SettingsCatalog.commands(for: query, registry: model.registry).prefix(8))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SettingsSection.allCases) { section in
                let found = items.filter { $0.section == section }
                if !found.isEmpty {
                    SettingsGroupHeader(title: section.title, first: section == items.first?.section)
                    SettingsItemList(items: found, state: state, showsGroups: false)
                }
            }
            if !commands.isEmpty {
                SettingsGroupHeader(title: SettingsSection.shortcuts.title, first: items.isEmpty)
                ForEach(commands) { command in ShortcutRow(command: command, state: state) }
            }
            if items.isEmpty && commands.isEmpty {
                Text("Nothing matches “\(query)”.")
                    .font(.display(16))
                    .foregroundStyle(Color(Theme.text2))
                    .padding(.top, 8)
            }
        }
    }
}

/// Holds the keyboard while no field on the page has it, so keys reach the router and nothing beeps; a
/// click on an empty part of the page takes the keyboard back and stops a recording.
private struct SettingsKeyView: NSViewRepresentable {
    let state: SettingsState

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.state = state
        state.keyView = view
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.state = state
        state.keyView = view
    }

    final class KeyView: NSView {
        weak var state: SettingsState?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The page just opened: take the keyboard from the list or the reader underneath.
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {}

        override func mouseDown(with event: NSEvent) {
            MainActor.assumeIsolated {
                state?.cancelRecording()
                state?.takeKeyboard()
            }
        }
    }
}
