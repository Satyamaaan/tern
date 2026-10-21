import SwiftUI

/// A flat settings row: title (+ detail) on the left, control on the right, hairline below. An icon,
/// when given, sits before the title on its first line.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var icon: Icon?
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let icon {
                        // Centred on the title's x-height.
                        IconView(icon: icon, size: 16, color: Color(Theme.text2))
                            .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4.5 }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.ui(13)).foregroundStyle(Color(Theme.text1))
                        if let detail {
                            Text(detail).font(.ui(12)).foregroundStyle(Color(Theme.text3)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.vertical, 12)
            Hairline()
        }
    }
}

/// Small caps over a group of rows inside a section ("Reading", "Writing").
struct SettingsGroupHeader: View {
    let title: String
    var first = false

    var body: some View {
        CapsLabel(text: title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, first ? 8 : 28)
            .padding(.bottom, 2)
    }
}

/// Segmented choice: a 28 pt track in `selected`; the chosen option sits on a raised segment with a
/// hairline border.
struct SegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let chosen = selection == option
                Text(title(option))
                    .font(.ui(12, .medium))
                    .foregroundStyle(Color(chosen ? Theme.text1 : Theme.text2))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(height: Theme.Control.small)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
                            .fill(Color(Theme.raised).opacity(chosen ? 1 : 0))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
                                .strokeBorder(Color(Theme.hairlineStrong).opacity(chosen ? 1 : 0), lineWidth: 1)))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option }
                    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color(Theme.selected)))
    }
}

/// An on/off switch in `ink`.
struct InkToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color(Theme.ink))
            .labelsHidden()
    }
}

/// A button, small and secondary unless told otherwise, that opens an `NSMenu` under itself (the account
/// to send from, the tab to pin, the client to sign in with).
struct MenuPickerButton: View {
    let title: String
    var kind: TernButtonStyle.Kind = .secondary
    var size: TernButtonStyle.Size = .small
    let menu: () -> NSMenu

    var body: some View {
        Button {
            guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
            let point = view.convert(event.locationInWindow, from: nil)
            menu().popUp(positioning: nil, at: NSPoint(x: point.x - 12, y: point.y - 12), in: view)
        } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                IconView(icon: .chevronDown, size: 12, color: Color(Theme.text3))
            }
        }
        .buttonStyle(TernButtonStyle(kind, size: size))
    }
}

/// A field on the page: `bg` fill with a hairline that strengthens while it has the keyboard.
struct SettingsField: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var icon: Icon = .search

    var body: some View {
        HStack(spacing: 7) {
            IconView(icon: icon, size: 14, color: Color(Theme.text3))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text1))
                .focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    IconView(icon: .close, size: 12, color: Color(Theme.text3)).frame(width: 18, height: 18)
                }
                .buttonStyle(IconButtonStyle())
                .help("Clear")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: Theme.Control.regular)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color(Theme.bg)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(Color(focused.wrappedValue ? Theme.hairlineStrong : Theme.hairline), lineWidth: 1))
    }
}
