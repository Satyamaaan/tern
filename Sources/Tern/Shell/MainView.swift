import AppKit
import SwiftUI
import TernCore

/// The main window, list first: the title bar's tabs over the list, the sidebar behind a toggle, and the
/// open thread over the list (or beside it with the reading pane, ⌘\). Settings (⌘,) covers all of it.
/// Palette and sheets on top.
///
/// The open sidebar runs the full height of the window, traffic lights at its top, and the title bar
/// moves over to sit above the list only.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let palette: PaletteController

    static let sidebarWidth: CGFloat = 232
    static let listMinWidth: CGFloat = 340
    static let readerMinWidth: CGFloat = 420

    var body: some View {
        ZStack {
            mail
                .allowsHitTesting(model.settings == nil)
                .accessibilityHidden(model.settings != nil)
            // Settings lies over the mail like a thread over the list; the mail stays in the tree, so the
            // list's scroll and the open thread are as they were when it closes.
            if let settings = model.settings {
                SettingsPage(state: settings)
                    .transition(.opacity)
            }
        }
        .background(Color(Theme.bg))
        .tint(Color(Theme.ink))
        .ignoresSafeArea()
        .overlay(alignment: .top) { overlays }
        .overlay(alignment: .bottom) { chordHUD }
        .animation(paneAnimation, value: model.prefs.sidebarOpen)
        .animation(paneAnimation, value: model.prefs.readingPane)
        .animation(paneAnimation, value: model.readerExpanded)
        .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.14), value: model.settings != nil)
        .sheet(item: projectEditorBinding) { draft in
            ProjectEditor(draft: draft).environment(model)
        }
        .sheet(isPresented: snoozePickerShown) {
            SnoozeDateSheet().environment(model).environment(model.services)
        }
    }

    /// The sidebar, the title bar and the list with the reader.
    private var mail: some View {
        HStack(spacing: 0) {
            if model.prefs.sidebarOpen {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        WindowDragArea().frame(height: MainWindow.headerHeight)
                        SidebarView()
                    }
                    .frame(width: Self.sidebarWidth)
                    .background(Color(Theme.sidebar))
                    Hairline(vertical: true)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                TitleBar()
                GeometryReader { geometry in
                    content(available: geometry.size.width)
                }
            }
        }
    }

    /// The list and the reader. Both keep one place in the view tree in every layout, so the table (and
    /// its scroll position) and the reader's page survive ⌘\ and opening a thread: without the pane the
    /// reader lies over the list, transparent until a thread opens.
    private func content(available: CGFloat) -> some View {
        let pane = model.prefs.readingPane
        let listWidth = pane ? clampedListWidth(available: available) : available
        let readerShown = model.readerVisible
        return ZStack(alignment: .topLeading) {
            ListColumn()
                .frame(width: listWidth)
                .allowsHitTesting(pane || !model.readerExpanded)
                .accessibilityHidden(!pane && model.readerExpanded)
            if pane {
                ColumnDivider(width: listWidth, available: available)
                    .offset(x: listWidth)
            }
            ReaderColumn(besideList: pane, onBack: pane ? nil : { model.back() })
                .frame(width: pane ? max(available - listWidth - 1, 0) : available)
                .offset(x: pane ? listWidth + 1 : (readerShown || reduceMotion ? 0 : 12))
                .opacity(readerShown ? 1 : 0)
                .allowsHitTesting(readerShown)
                .accessibilityHidden(!readerShown)
        }
        .frame(width: available, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .bottom) {
            ToastStack()
                .padding(.bottom, model.readerExpanded || pane ? 24 : 24 + BottomBar.height + 12)
                .frame(width: pane ? listWidth : available)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Pane changes spring; with Reduce Motion they crossfade.
    private var paneAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.32, dampingFraction: 0.86)
    }

    private func clampedListWidth(available: CGFloat) -> CGFloat {
        let maximum = max(Self.listMinWidth, available - Self.readerMinWidth)
        return min(max(model.prefs.listWidth, Self.listMinWidth), maximum)
    }

    // MARK: Overlays

    @ViewBuilder private var overlays: some View {
        ZStack(alignment: .top) {
            if model.palette != nil || model.showsShortcuts {
                Color.black.opacity(0.001)
                    .onTapGesture { palette.close(); model.showsShortcuts = false }
            }
            if model.palette != nil {
                PaletteView(controller: palette)
                    .padding(.top, 96)
                    .transition(.scale(scale: 0.98, anchor: .top).combined(with: .opacity))
            }
            if model.showsShortcuts {
                ShortcutSheet()
                    .padding(.top, 72)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.palette != nil)
        .animation(.easeOut(duration: 0.12), value: model.showsShortcuts)
    }

    @ViewBuilder private var chordHUD: some View {
        if let chord = model.chordHUD {
            HStack(spacing: 8) {
                Keycap(text: chord)
                Text("then a key · i inbox · r needs reply · s starred · d drafts")
                    .font(.ui(12))
                    .foregroundStyle(Color(Theme.text2))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.overlay, style: .continuous).fill(Color(Theme.raised)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.overlay, style: .continuous).strokeBorder(Color(Theme.hairline), lineWidth: 1))
            .overlayShadow()
            .padding(.bottom, 80)
            .transition(.opacity)
        }
    }

    private var projectEditorBinding: Binding<ProjectDraft?> {
        Binding(get: { model.projectEditor }, set: { model.projectEditor = $0 })
    }

    private var snoozePickerShown: Binding<Bool> {
        Binding(get: { model.snoozeDateFor != nil }, set: { if !$0 { model.snoozeDateFor = nil } })
    }
}

/// The hairline between list and reader, with a wider invisible handle for dragging.
private struct ColumnDivider: View {
    @Environment(AppModel.self) private var model
    let width: CGFloat
    let available: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Hairline(vertical: true)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let origin = start ?? width
                                start = origin
                                let maximum = max(MainView.listMinWidth, available - MainView.readerMinWidth)
                                model.prefs.listWidth = min(max(origin + value.translation.width, MainView.listMinWidth), maximum)
                            }
                            .onEnded { _ in start = nil }
                    )
            }
    }
}

/// The reader column: the open thread, or a quiet summary when several threads are selected. While it is off
/// screen the reader stays in the tree but does no work.
struct ReaderColumn: View {
    @Environment(AppModel.self) private var model
    /// Beside the list the column is `raised`; over it, `bg`.
    var besideList = true
    /// The ← button, shown while the reader covers the list.
    var onBack: (() -> Void)?

    var body: some View {
        Group {
            if model.checked.count > 1 {
                MultiSelectionView(count: model.checked.count)
            } else {
                ReaderView(key: model.readerKey, prefetch: model.readerNeighbours, position: model.readerPosition, onBack: onBack,
                           active: model.readerVisible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(besideList ? Theme.raised : Theme.bg))
        .simultaneousGesture(TapGesture().onEnded { model.focus = .reader })
        // The click above has Return or o on the keyboard; VoiceOver gets it as an action of the column.
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move Keyboard to Conversation") {
            model.focus = .reader
            model.services.reader.focus()
        }
    }
}

private struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        VStack(spacing: 10) {
            Text("\(count) conversations selected")
                .font(.display(20))
                .tracking(-0.3)
                .foregroundStyle(Color(Theme.text1))
            HStack(spacing: 14) {
                hint("e", "archive")
                hint("h", "snooze")
                hint("#", "trash")
                hint("esc", "clear")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Keycap(text: key)
            Text(title).font(.ui(12)).foregroundStyle(Color(Theme.text3))
        }
    }
}

/// "Pick date…" for snooze.
struct SnoozeDateSheet: View {
    @Environment(AppModel.self) private var model
    @State private var date = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date()))!
        .addingTimeInterval(8 * 3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Snooze until")
                .font(.ui(15, .semibold))
                .foregroundStyle(Color(Theme.text1))
            DatePicker("", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { model.snoozeDateFor = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(TernButtonStyle(.secondary))
                Button("Snooze") {
                    let keys = model.snoozeDateFor ?? []
                    model.snoozeDateFor = nil
                    model.perform(.snooze(until: date), on: keys)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(TernButtonStyle(.primary))
            }
        }
        .padding(24)
        .background(Color(Theme.raised))
    }
}
