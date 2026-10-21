import AppKit
import SwiftUI

/// A provider as a selectable card (onboarding): mark, name, what pays for it, and its live status.
/// Selected: a 1.5 px `ink` border and a filled radio mark.
struct AIProviderCard: View {
    let provider: AIProvider
    let status: AIStatus?
    var isChecking = false
    let selected: Bool
    let select: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                if let logo = provider.logo { BrandLogoView(logo: logo, size: 30) }
                Spacer()
                RadioMark(selected: selected)
            }
            Text(provider.title)
                .font(.ui(14, .semibold))
                .foregroundStyle(Color(Theme.text1))
                .padding(.top, 14)
            Text(provider.tagline)
                .font(.ui(12))
                .foregroundStyle(Color(Theme.text2))
                .padding(.top, 2)
            Spacer(minLength: 14)
            AIStatusLine(provider: provider, status: status, isChecking: isChecking)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Color(Theme.bg)))
        .overlay(shape.strokeBorder(Color(selected ? Theme.ink : Theme.hairlineStrong), lineWidth: selected ? 1.5 : 1))
        .contentShape(shape)
        .onTapGesture(perform: select)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(provider.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A 16 pt radio mark: hollow when off, an `ink` disc with a check when chosen.
struct RadioMark: View {
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color(Theme.hairlineStrong), lineWidth: selected ? 0 : 1.5)
            if selected {
                Circle().fill(Color(Theme.ink))
                IconView(icon: .done, size: 11, color: Color(Theme.onInk), weight: 1.4)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// A provider's live status: Ready; Not signed in, then the command that signs in with a copy button;
/// Not installed, then a link to the official install page. `recheck` adds a quiet "Check again".
/// Shows nothing until a check has answered or is running.
struct AIStatusLine: View {
    let provider: AIProvider
    let status: AIStatus?
    var isChecking = false
    var recheck: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Checking… → Ready / Not signed in crossfades, and what comes under it fades in (150 ms; 80 ms with
        // Reduce Motion).
        if status != nil || isChecking {
            line
                .animation(Motion.or(reduced: reduceMotion, .easeOut(duration: 0.15)), value: status)
                .animation(Motion.or(reduced: reduceMotion, .easeOut(duration: 0.15)), value: isChecking)
        }
    }

    private var line: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                marker.frame(width: 14, height: 14)
                Text(label)
                    .font(.ui(12, status == .ready ? .medium : .regular))
                    .foregroundStyle(Color(status == .ready ? Theme.text1 : status == nil ? Theme.text3 : Theme.text2))
                    .contentTransition(.opacity)
                if let recheck, status != nil, status != .ready {
                    Text("·").font(.ui(12)).foregroundStyle(Color(Theme.text3))
                    Button(isChecking ? "Checking…" : "Check again", action: recheck)
                        .buttonStyle(LinkButtonStyle())
                        .font(.ui(12, .medium))
                        .disabled(isChecking)
                }
            }
            switch status {
            case .signedOut:
                if let command = provider.signInCommand { CommandChip(command: command).padding(.leading, 20) }
            case .notInstalled:
                if let url = provider.installURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        HStack(spacing: 4) {
                            Text("Install \(provider.title)")
                            IconView(icon: .external, size: 12, color: Color(Theme.ink))
                        }
                    }
                    .buttonStyle(LinkButtonStyle())
                    .font(.ui(12, .medium))
                    .padding(.leading, 20)
                    .help(url.absoluteString)
                }
            case .ready, nil:
                EmptyView()
            }
        }
    }

    private var label: String {
        switch status {
        case .ready: "Ready"
        case .signedOut: "Not signed in"
        case .notInstalled: "Not installed"
        case nil: "Checking…"
        }
    }

    @ViewBuilder private var marker: some View {
        switch status {
        case .ready: IconView(icon: .done, size: 14, color: Color(Theme.text1))
        case .signedOut, .notInstalled: Dot(color: Theme.text3, size: 7, ring: true)
        case nil: Dot(color: Theme.hairlineStrong, size: 7, ring: true)
        }
    }
}

/// A Terminal command in a 22 pt chip, with a button that copies it.
struct CommandChip: View {
    let command: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    var body: some View {
        HStack(spacing: 2) {
            Text(command)
                .font(.ui(12, .medium))
                .foregroundStyle(Color(Theme.text1))
                .textSelection(.enabled)
                .padding(.leading, 8)
            Button(action: copy) {
                // Copy → check: the icons swap with a small scale and blur (150 ms; a plain fade with Reduce Motion).
                ZStack {
                    IconView(icon: copied ? .done : .copy, size: 13, color: Color(copied ? Theme.text1 : Theme.text2))
                        .id(copied)
                        .transition(reduceMotion ? .opacity : .iconSwap)
                }
                .frame(width: 22, height: 22)
                .animation(Motion.or(reduced: reduceMotion, .easeOut(duration: 0.15)), value: copied)
            }
            .buttonStyle(IconButtonStyle())
            .help("Copy")
        }
        .padding(.trailing, 1)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Color(Theme.hover)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Color(Theme.hairline), lineWidth: 1))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// Settings → AI's provider choice: a segmented track whose segments carry the providers' marks.
struct AIProviderSegments: View {
    @Binding var selection: AIProvider

    var body: some View {
        SegmentedTrack(options: AIProvider.allCases, selection: $selection) { option, chosen in
            HStack(spacing: 6) {
                if let logo = option.logo { BrandLogoView(logo: logo, size: 14) }
                Text(option.title)
                    .font(.ui(12, .medium))
                    .foregroundStyle(Color(chosen ? Theme.text1 : Theme.text2))
            }
        }
    }
}

/// Settings → AI's provider row: the choice on the right; under the title, the chosen provider's live
/// status with "Check again" when it isn't ready.
struct AIProviderRow: View {
    @Binding var selection: AIProvider
    let board: AIStatusBoard
    let recheck: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Provider").font(.ui(13)).foregroundStyle(Color(Theme.text1))
                    if selection == .off {
                        Text("AI features are off.").font(.ui(12)).foregroundStyle(Color(Theme.text3))
                    } else {
                        AIStatusLine(provider: selection, status: board.statuses[selection], isChecking: board.isChecking, recheck: recheck)
                    }
                }
                Spacer(minLength: 12)
                AIProviderSegments(selection: $selection)
            }
            .padding(.vertical, 12)
            Hairline()
        }
    }
}

extension AnyTransition {
    /// One icon giving way to another: 80 % scale, opacity and a 2 pt blur.
    static var iconSwap: AnyTransition {
        .scale(scale: 0.8).combined(with: .opacity).combined(with: .modifier(active: IconBlur(radius: 2), identity: IconBlur(radius: 0)))
    }
}

private struct IconBlur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}
