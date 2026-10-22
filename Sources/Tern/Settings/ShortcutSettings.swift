import AppKit
import SwiftUI

/// Settings → Shortcuts: every command with its keys, grouped like the palette. Click a key to record a
/// new one; + adds one; a changed command has a quiet dot and a reset button on hover.
struct ShortcutSettings: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: SettingsState
    @FocusState private var filterFocused: Bool

    var body: some View {
        let registry = model.registry
        let commands = registry.map(ShortcutTable.editable) ?? []
        let words = state.shortcutFilter.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let shown = commands.filter { command in
            let text = ShortcutTable.searchText(command)
            return words.allSatisfy { SettingsCatalog.matches($0, in: text) }
        }
        let groups = Dictionary(grouping: shown, by: \.group)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SettingsField(placeholder: "Filter shortcuts", text: $state.shortcutFilter, focused: $filterFocused)
                    .frame(maxWidth: 260)
                Spacer(minLength: 12)
                Button("Reset All") { registry?.resetAllKeys() }
                    .buttonStyle(TernButtonStyle(.quiet, size: .small))
                    .disabled(registry?.overrides.isEmpty ?? true)
            }
            Text("Click a shortcut to change it. While you're typing, only ⌘ and ⌃ keys that don't act on mail work.")
                .font(.ui(12))
                .foregroundStyle(Color(Theme.text3))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            ForEach(CommandGroup.allCases, id: \.self) { group in
                if let items = groups[group], !items.isEmpty {
                    SettingsGroupHeader(title: group.rawValue)
                    ForEach(items) { command in
                        ShortcutRow(command: command, state: state)
                        if command.id == "scope.all" { AccountSlotsRow() }
                    }
                }
            }
            if shown.isEmpty {
                Text("No shortcut matches “\(state.shortcutFilter)”.")
                    .font(.display(16))
                    .foregroundStyle(Color(Theme.text2))
                    .padding(.top, 28)
            }
        }
        .onChange(of: filterFocused) { _, value in if state.filterFocused != value { state.filterFocused = value } }
        .onChange(of: state.filterFocused) { _, value in if filterFocused != value { filterFocused = value } }
    }
}

/// One command: its title, then a keycap per key. While recording, the key being replaced (or the new
/// one) shows the recorder, and a line under the row says what happens next.
struct ShortcutRow: View {
    @Environment(AppModel.self) private var model
    let command: Command
    let state: SettingsState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let registry = model.registry
        let recording = state.recording.flatMap { $0.commandId == command.id ? $0 : nil }
        let locked = ShortcutRules.isLocked(command.id)
        let customized = registry?.isCustomized(command.id) ?? false
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(ShortcutTable.title(command))
                    .font(.ui(13))
                    .foregroundStyle(Color(Theme.text1))
                    .lineLimit(1)
                if customized {
                    Dot(color: Theme.text3, size: 5).help("Changed")
                }
                Spacer(minLength: 12)
                let tools = hovering && recording == nil
                if customized {
                    IconButton(icon: .undo, size: Theme.Control.small, iconSize: 14, help: resetHelp) { registry?.resetKeys(for: command.id) }
                        .hoverReveal(tools)
                        .allowsHitTesting(tools)
                }
                if !locked, recording == nil {
                    IconButton(icon: .plus, size: Theme.Control.small, iconSize: 14, help: "Add a shortcut") {
                        state.startRecording(command.id, slot: nil)
                    }
                    .hoverReveal(tools)
                    .allowsHitTesting(tools)
                }
                ForEach(Array(command.keys.enumerated()), id: \.offset) { slot, key in
                    if recording?.slot == slot {
                        RecorderCap(recording: recording)
                    } else {
                        KeyCap(text: key.display, editable: !locked) { state.startRecording(command.id, slot: slot) }
                            .help(locked ? lockedHelp : "Change \(key.display)")
                    }
                }
                if let chord = command.chord {
                    KeyCap(text: chord, editable: false) {}
                        .help("The g shortcuts can't be changed. Add another key with +.")
                }
                if let recording, recording.slot == nil {
                    RecorderCap(recording: recording)
                }
            }
            .frame(minHeight: 36)
            if let recording {
                RecorderHint(recording: recording, state: state)
                    .padding(.bottom, 10)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
            }
            Hairline()
        }
        .background(alignment: .top) {
            if recording != nil {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Color(Theme.hover))
                    .padding(.horizontal, -10)
                    .padding(.bottom, 1)
                    .transition(.opacity)
            }
        }
        // Recording grows the row for its hint line (160 ms, house curve) and the fill fades with it.
        .animation(Motion.or(reduced: reduceMotion, Motion.ease(0.16)), value: recording != nil)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var resetHelp: String {
        let keys = model.registry?.defaultKeys[command.id] ?? []
        return keys.isEmpty ? "Reset to no shortcut" : "Reset to \(keys.map(\.display).joined(separator: " "))"
    }

    private var lockedHelp: String {
        command.id == "settings" ? "Settings always opens with ⌘," : "Follows the order of your accounts"
    }
}

/// ⌘1–⌘9: one row for the account slots, which follow the account order and can't change.
private struct AccountSlotsRow: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Account 1–9").font(.ui(13)).foregroundStyle(Color(Theme.text1))
                Spacer(minLength: 12)
                KeyCap(text: "⌘1–⌘9", editable: false) {}
                    .help("Follows the order of your accounts")
            }
            .frame(minHeight: 36)
            Hairline()
        }
    }
}

/// A key as a small keycap; editable ones take a click.
struct KeyCap: View {
    let text: String
    var editable = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        Text(text)
            .font(.numeric(11.5, .medium))
            .foregroundStyle(Color(editable ? Theme.text2 : Theme.text3))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(shape.fill(Color(hovering && editable ? Theme.selected : Theme.hover)))
            .overlay(shape.strokeBorder(Color(hovering && editable ? Theme.hairlineStrong : Theme.hairline), lineWidth: 1))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .onTapGesture { if editable { action() } }
            .accessibilityAddTraits(editable ? .isButton : [])
    }
}

/// The keycap while recording: "Type a shortcut", or the key just pressed when it can't be used.
/// A key that can't be used shakes the cap (240 ms); with Reduce Motion its border flashes to full `ink` instead.
private struct RecorderCap: View {
    let recording: ShortcutRecording?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rejections = 0

    private struct Rejection {
        var x: CGFloat = 0
        var flash: Double = 0
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        let travel: CGFloat = reduceMotion ? 0 : 1
        let flash: Double = reduceMotion ? 1 : 0
        Text(pressed ?? "Type a shortcut")
            .font(pressed == nil ? .ui(11.5, .medium) : .numeric(11.5, .medium))
            .foregroundStyle(Color(pressed == nil ? Theme.text2 : Theme.text1))
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(shape.fill(Color(Theme.bg)))
            .overlay(shape.strokeBorder(Color(Theme.ink).opacity(0.55), lineWidth: 1.5))
            .keyframeAnimator(initialValue: Rejection(), trigger: rejections) { content, value in
                content
                    .overlay(shape.strokeBorder(Color(Theme.ink).opacity(value.flash), lineWidth: 1.5))
                    .offset(x: value.x)
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    LinearKeyframe(-4 * travel, duration: 0.06)
                    LinearKeyframe(4 * travel, duration: 0.06)
                    LinearKeyframe(-2 * travel, duration: 0.06)
                    LinearKeyframe(0, duration: 0.06)
                }
                KeyframeTrack(\.flash) {
                    LinearKeyframe(flash, duration: 0.08)
                    LinearKeyframe(0, duration: 0.08)
                }
            }
            .onChange(of: recording?.problem) { _, problem in if problem != nil { rejections += 1 } }
    }

    private var pressed: String? {
        switch recording?.problem {
        case .reserved(let key, _), .taken(let key, _): key.display
        default: nil
        }
    }
}

/// The line under a row being recorded: how to cancel, or why the key can't be used, with Replace.
private struct RecorderHint: View {
    @Environment(AppModel.self) private var model
    let recording: ShortcutRecording
    let state: SettingsState

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.ui(12, recording.problem == nil ? .regular : .medium))
                .foregroundStyle(Color(recording.problem == nil ? Theme.text3 : Theme.text1))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if case .taken = recording.problem {
                Button("Replace") { state.replace() }.buttonStyle(TernButtonStyle(.secondary, size: .small))
            }
            if recording.problem != nil {
                Button("Cancel") { state.cancelRecording() }.buttonStyle(TernButtonStyle(.quiet, size: .small))
            }
        }
    }

    private var message: String {
        switch recording.problem {
        case nil:
            recording.slot == nil ? "Press the new shortcut. esc cancels." : "Press the new shortcut. esc cancels, ⌫ removes this one."
        case .unsupported:
            "That key can't be used. Try another, or press esc."
        case .reserved(let key, let owner):
            "\(key.display) is reserved for \(owner)."
        case .taken(let key, let ids):
            "\(key.display) is used by \(ids.compactMap { model.registry?[$0].map(ShortcutTable.title) }.joined(separator: " and "))."
        }
    }
}
