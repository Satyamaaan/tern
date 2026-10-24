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
        SegmentedTrack(options: options, selection: $selection) { option, chosen in
            Text(title(option))
                .font(.ui(12, .medium))
                .foregroundStyle(Color(chosen ? Theme.text1 : Theme.text2))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// The track behind every segmented control (`SegmentedPicker`, `AIProviderSegments`): a 28 pt `selected`
/// track whose raised segment slides to the chosen option (180 ms, house curve) while the labels' colours
/// crossfade. With Reduce Motion the segment crossfades in place over 80 ms.
struct SegmentedTrack<Value: Hashable, Label: View>: View {
    let options: [Value]
    @Binding var selection: Value
    @ViewBuilder let label: (Value, Bool) -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let chosen = selection == option
                label(option, chosen)
                    .padding(.horizontal, 10)
                    .frame(height: Theme.Control.small)
                    .background { segment(chosen) }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option }
                    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color(Theme.selected)))
        .animation(Motion.or(reduced: reduceMotion, Motion.ease(Motion.slide)), value: selection)
    }

    @ViewBuilder private func segment(_ chosen: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
        let raised = shape.fill(Color(Theme.raised))
            .overlay(shape.strokeBorder(Color(Theme.hairlineStrong), lineWidth: 1))
        if reduceMotion {
            raised.opacity(chosen ? 1 : 0)
        } else if chosen {
            raised.matchedGeometryEffect(id: "thumb", in: thumb)
        }
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
    @State private var menuAnchor = MenuAnchor.AnchorView()

    var body: some View {
        Button {
            menuAnchor.popUp(menu())
        } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                IconView(icon: .chevronDown, size: 12, color: Color(Theme.text3))
            }
        }
        .buttonStyle(TernButtonStyle(kind, size: size))
        .background(MenuAnchor(view: menuAnchor).accessibilityHidden(true))
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
