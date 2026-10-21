import AppKit
import SwiftUI
import TernCore

// The slide-over's own pieces: its expand button, the people in the conversation and its attachments in the
// top bar, and Reply and Forward at the foot.

/// The slide-over panel's expand button: the open conversation over the whole list, or back in the panel.
struct ReaderPanelControls {
    /// The conversation covers the whole list for now.
    let wide: Bool
    /// The button's tooltip with its shortcut.
    var help: String?
    /// Room the bar leaves at its left for the window's traffic lights, when the panel reaches under them.
    var trafficLights: CGFloat = 0
    let toggle: () -> Void
}

/// Up to three senders of the conversation as small overlapping rounded squares, newest on the left.
struct ReaderParticipants: View {
    let people: [Participant]
    @Environment(\.colorScheme) private var colorScheme

    static let size: CGFloat = 22
    /// Each picture covers this much of the one after it.
    static let overlap: CGFloat = 7

    var body: some View {
        let shown = Array(people.prefix(3))
        HStack(spacing: -Self.overlap) {
            ForEach(Array(shown.enumerated()), id: \.offset) { offset, person in
                Image(nsImage: picture(person))
                    .resizable()
                    .frame(width: Self.size, height: Self.size)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    // A ring of the panel's surface keeps each picture's edge where the next one covers it.
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(Theme.bg), lineWidth: 1.5).padding(-0.75))
                    .zIndex(Double(shown.count - offset))
            }
        }
        // Initials and rings are drawn for one appearance; a switch draws them again.
        .id(colorScheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(people.map { $0.displayName }.joined(separator: ", "))
        .help(people.map { $0.displayName }.joined(separator: ", "))
    }

    /// The sender's logo, else their initials, drawn as the list draws them, for the appearance showing now.
    private func picture(_ person: Participant) -> NSImage {
        let side = Self.size
        let logo = SenderLogos.shared.logo(forEmail: person.email)
        let letters = Avatar.initials(name: person.name, email: person.email)
        let image = NSImage(size: NSSize(width: side, height: side))
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            image.lockFocusFlipped(true)
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            if let logo {
                Avatar.drawLogo(logo, in: rect, shape: .square)
            } else {
                Avatar.drawLetters(letters, tint: nil, in: rect, shape: .square)
            }
            image.unlockFocus()
        }
        return image
    }
}

/// The paperclip and how many files the conversation has; its menu opens one.
struct ReaderAttachmentPill: View {
    let attachments: [MailAttachment]
    let open: (MailAttachment) -> Void

    var body: some View {
        Menu {
            ForEach(attachments, id: \.id) { attachment in
                Button(attachment.filename.isEmpty ? "Attachment" : attachment.filename) { open(attachment) }
            }
        } label: {
            Label {
                Text("\(attachments.count)")
            } icon: {
                // The clip leans right, as on a desk.
                Image(nsImage: Icon.clip.image(size: 14))
                    .rotationEffect(.degrees(45))
            }
            .labelStyle(.titleAndIcon)
            .font(.numeric(12))
            .foregroundStyle(Color(Theme.text1).opacity(0.85))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 7)
        .frame(height: 21)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(Theme.text1).opacity(0.07)))
        .help("Attachments")
        .accessibilityLabel("\(attachments.count) attachments")
    }
}

/// Reply and Forward at the foot of the slide-over, each with its key.
struct ReaderPanelActions: View {
    let model: ReaderModel
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        HStack(spacing: 10) {
            ReaderPanelAction(icon: .reply, title: "Reply", key: key("reply"), help: hint("Reply", "reply")) { model.reply(all: false) }
            ReaderPanelAction(icon: .forward, title: "Forward", key: key("forward"), help: hint("Forward", "forward")) { model.forward() }
            Spacer(minLength: 0)
        }
        // In line with the pictures and bodies of the page above.
        .padding(.leading, 9)
    }

    private func hint(_ title: String, _ id: String) -> String { app?.registry?.hint(title, id) ?? title }

    /// A bare letter shows as the capital on its keycap, as keyboards print it.
    private func key(_ id: String) -> String? {
        guard let text = app?.registry?[id]?.shortcutText else { return nil }
        return text.count == 1 ? text.uppercased() : text
    }
}

private struct ReaderPanelAction: View {
    let icon: Icon
    let title: String
    let key: String?
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                IconView(icon: icon, size: 14, color: Color(Theme.text2))
                Text(title)
                    .font(.ui(13))
                    .foregroundStyle(Color(Theme.text1))
                if let key {
                    Text(key)
                        .font(.numeric(10))
                        .foregroundStyle(Color(Theme.text3))
                        .frame(minWidth: 16, minHeight: 16)
                        .padding(.horizontal, key.count > 1 ? 3 : 0)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color(Theme.hairlineStrong), lineWidth: 1))
                        .padding(.leading, 1)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, key == nil ? 10 : 5)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(Theme.text1).opacity(hovering ? 0.11 : 0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
