import AppKit
import SwiftUI
import TernCore

/// The main window: sidebar 232 · list (resizable) · reader, with the palette and sheets on top.
struct MainView: View {
    @Environment(AppModel.self) private var model
    let palette: PaletteController

    static let sidebarWidth: CGFloat = 232
    static let listMinWidth: CGFloat = 340
    static let readerMinWidth: CGFloat = 420

    var body: some View {
        GeometryReader { geometry in
            let sidebar = model.prefs.sidebarCollapsed ? 0 : Self.sidebarWidth + 1
            let available = geometry.size.width - sidebar
            let listWidth = clampedListWidth(available: available)
            HStack(spacing: 0) {
                if !model.prefs.sidebarCollapsed {
                    SidebarView()
                        .frame(width: Self.sidebarWidth)
                        .transition(.move(edge: .leading))
                    Hairline(vertical: true)
                }
                if model.listOnly {
                    if model.readerExpanded {
                        ReaderColumn()
                    } else {
                        ListColumn(leadingInset: model.prefs.sidebarCollapsed ? 64 : 0)
                    }
                } else {
                    ListColumn(leadingInset: model.prefs.sidebarCollapsed ? 64 : 0)
                        .frame(width: listWidth)
                    ColumnDivider(width: listWidth, available: available)
                    ReaderColumn()
                }
            }
        }
        .background(Color(Theme.bg))
        .ignoresSafeArea()
        .overlay(alignment: .top) { overlays }
        .overlay(alignment: .bottom) { chordHUD }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.prefs.sidebarCollapsed)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.listOnly)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.readerExpanded)
        .sheet(item: projectEditorBinding) { draft in
            ProjectEditor(draft: draft).environment(model)
        }
        .sheet(isPresented: snoozePickerShown) {
            SnoozeDateSheet().environment(model).environment(model.services)
        }
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
                    .onTapGesture { model.palette = nil; model.showsShortcuts = false }
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
            .background(Capsule().fill(Color(Theme.raised)))
            .overlay(Capsule().strokeBorder(Color(Theme.hairline), lineWidth: 1))
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

/// The reader column: the reader lane's view, or a quiet summary when several threads are selected.
struct ReaderColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.checked.count > 1 {
                MultiSelectionView(count: model.checked.count)
            } else {
                ReaderView(key: model.readerKey)
            }
        }
        .frame(minWidth: MainView.readerMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(Theme.raised))
        .simultaneousGesture(TapGesture().onEnded { model.focus = .reader })
    }
}

private struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        VStack(spacing: 10) {
            Text("\(count) conversations selected")
                .font(.serif(22, italic: true))
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
                    .buttonStyle(PillButtonStyle(primary: false))
                Button("Snooze") {
                    let keys = model.snoozeDateFor ?? []
                    model.snoozeDateFor = nil
                    model.perform(.snooze(until: date), on: keys)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PillButtonStyle(primary: true))
            }
        }
        .padding(24)
        .background(Color(Theme.raised))
    }
}
