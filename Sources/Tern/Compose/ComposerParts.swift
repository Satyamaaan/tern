import AppKit
import SwiftUI
import TernCore

// MARK: - Under the text: signature, quote, attachments

/// Laid out right under the body text, in the same scrolling document.
struct ComposerAccessory: View {
    let model: ComposerModel

    var body: some View {
        let files = model.attachments.filter { $0.contentId == nil }
        VStack(alignment: .leading, spacing: 12) {
            if let signature = model.signatureHtml {
                SignatureBlock(text: RichText.plainText(fromHTML: signature), remove: model.removeSignature)
            }
            if model.quoteHtml != nil {
                QuoteBlock(model: model)
            }
            if !files.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(files, id: \.self) { file in
                        AttachmentChip(attachment: file) { model.removeAttachment(file) }
                    }
                }
            }
            if model.attachmentBytes > ComposerModel.gmailLimit {
                Text("Attachments are over Gmail's 25 MB limit and may not send.")
                    .font(.ui(12, .medium))
                    .foregroundStyle(Color(Theme.ink))
            }
        }
        .padding(.horizontal, model.mode == .window ? 20 : 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The account signature as quiet text; × on hover removes it from this draft.
struct SignatureBlock: View {
    let text: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.ui(13))
                .lineSpacing(5)
                .foregroundStyle(Color(Theme.text3))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: remove) {
                IconView(icon: .close, size: 12, color: Color(Theme.text3))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(IconButtonStyle())
            .opacity(hovering ? 1 : 0)
            .help("Remove signature from this message")
        }
        .onHover { hovering = $0 }
    }
}

/// `•••` for the quoted original (or the forwarded message); click to read it here.
struct QuoteBlock: View {
    let model: ComposerModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { model.quoteExpanded.toggle() } label: {
                    IconView(icon: .ellipsis, size: 16, color: Color(hovering ? Theme.text1 : Theme.text2))
                        .frame(width: 32, height: 18)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(Color(hovering ? Theme.hairlineStrong : Theme.pill)))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(model.quoteExpanded ? "Hide quoted text" : "Show quoted text")
                if model.kind == .forward {
                    Text("Forwarded message").font(.ui(12)).foregroundStyle(Color(Theme.text3))
                }
            }
            if model.quoteExpanded {
                Text(model.quotePreview)
                    .font(.ui(12))
                    .lineSpacing(4)
                    .foregroundStyle(Color(Theme.text2))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
            }
        }
    }
}

struct AttachmentChip: View {
    let attachment: DraftAttachment
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            IconView(icon: Self.icon(for: attachment.mimeType), size: 14, color: Color(Theme.text2))
            Text(attachment.filename)
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text1))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                .font(.numeric(12))
                .foregroundStyle(Color(Theme.text3))
            Button(action: remove) {
                IconView(icon: .close, size: 12, color: Color(Theme.text3))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(IconButtonStyle())
            .opacity(hovering ? 1 : 0)
            .help("Remove")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: Theme.Control.regular)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color(Theme.pill)))
        .onHover { hovering = $0 }
        .help(attachment.needsFetch ? "\(attachment.filename) — from the original message" : attachment.filename)
    }

    static func icon(for mimeType: String) -> Icon {
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.contains("zip") || mimeType.contains("compressed") { return .zip }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("audio/") { return .audio }
        return .file
    }
}

/// Lays children left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + lineHeight)
    }
}

// MARK: - Bottom: AI instruction, Send, attach, AI, discard

struct ComposerBottomArea: View {
    @Bindable var model: ComposerModel

    var body: some View {
        VStack(spacing: 0) {
            if model.aiInstruction != nil { AIInstructionBar(model: model) }
            HStack(spacing: 4) {
                SendButton(model: model)
                    .padding(.trailing, 6)
                ComposerIconButton(icon: .paperclip, help: "Attach files  ⌘⇧A") { model.attach() }
                if model.aiAvailable {
                    let open = model.aiInstruction != nil
                    let color = Color(open ? Theme.text1 : Theme.text2)
                    Button { model.toggleAI() } label: {
                        HStack(spacing: 6) {
                            IconView(icon: .sparkles, size: 16, color: color)
                            if model.mode == .window { Text("Write with AI").font(.ui(13)) }
                        }
                        .foregroundStyle(color)
                        .padding(.horizontal, model.mode == .window ? 8 : 6)
                        .frame(height: Theme.Control.regular)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Color(Theme.selected).opacity(open ? 1 : 0)))
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Write with AI  ⌘J")
                }
                Spacer(minLength: 8)
                if let notice = model.notice {
                    Text(notice)
                        .font(.ui(12, .medium))
                        .foregroundStyle(Color(Theme.ink))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if model.confirmingDiscard {
                    Text("Discard this draft?").font(.ui(12)).foregroundStyle(Color(Theme.text2))
                    Button("Keep") { model.confirmingDiscard = false }
                        .buttonStyle(TernButtonStyle(.quiet, size: .small))
                    Button("Discard") { model.discard() }
                        .buttonStyle(TernButtonStyle(.secondary, size: .small))
                } else {
                    ComposerIconButton(icon: .trash, help: "Discard draft  ⌘⇧D") { model.requestDiscard() }
                }
            }
            .padding(.horizontal, model.mode == .window ? 14 : 10)
            .frame(height: model.mode == .window ? 56 : 48)
        }
    }
}

/// The primary button: Send, and a chevron for Send and archive / Send later. One `ink` block with
/// two halves that each step lighter under the pointer and while pressed.
struct SendButton: View {
    @Bindable var model: ComposerModel

    var body: some View {
        HStack(spacing: 0) {
            Button { model.send() } label: {
                Text("Send")
                    .font(.ui(13, .medium))
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
            }
            .buttonStyle(SendHalfStyle())
            .help("Send  ⌘↵")
            Rectangle().fill(Color(Theme.onInk).opacity(0.22)).frame(width: 1, height: 14)
            Button { model.sendLaterOpen.toggle() } label: {
                IconView(icon: .chevronDown, size: 14, color: Color(Theme.onInk))
                    .frame(width: 26)
            }
            .buttonStyle(SendHalfStyle())
            .help("Send later  ⌘⇧L")
            .popover(isPresented: $model.sendLaterOpen, arrowEdge: .top) {
                SendLaterPopover(model: model)
            }
        }
        .background(Color(Theme.ink))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

/// One half of `SendButton`: `onInk` label, a lighter `ink` step on hover and press.
private struct SendHalfStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Half(configuration: configuration)
    }

    private struct Half: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Color(Theme.onInk))
                .frame(height: Theme.Control.regular)
                .background(Color(configuration.isPressed ? Theme.inkPressed : hovering ? Theme.inkHover : Theme.ink))
                .overlay(Rectangle().strokeBorder(Color(Theme.onInk).opacity(isFocused ? 0.6 : 0), lineWidth: 1.5))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 && isEnabled }
        }
    }
}

/// Send and archive, the send-later presets (1–4), or a date of your own.
struct SendLaterPopover: View {
    let model: ComposerModel
    @State private var picking = false
    @State private var date = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    private let presets = SnoozeOption.presets()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.threadKey != nil {
                MenuRow(title: "Send and archive", detail: "⌘⇧↵") { model.send(archive: true) }
                Hairline().padding(.vertical, 4)
            }
            CapsLabel(text: "Send later")
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)
            ForEach(Array(presets.enumerated()), id: \.element.id) { index, option in
                MenuRow(title: option.title, detail: option.detail, key: "\(index + 1)") { model.scheduleSend(at: option.date) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
            }
            MenuRow(title: "Pick date & time…", detail: nil) { picking.toggle() }
            if picking {
                DatePicker("", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(.horizontal, 6)
                HStack {
                    Spacer()
                    Button("Schedule") { model.scheduleSend(at: date) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(TernButtonStyle(.primary, size: .small))
                }
                .padding(.horizontal, 8)
            }
            Text("Tern needs to be open at that time to send it.")
                .font(.ui(11))
                .foregroundStyle(Color(Theme.text3))
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(width: 270)
    }
}

/// One popover row: title, detail in tabular figures at the right, optional keycap.
struct MenuRow: View {
    let title: String
    let detail: String?
    var key: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.ui(13)).foregroundStyle(Color(Theme.text1))
                Spacer(minLength: 12)
                if let detail { Text(detail).font(.numeric(12)).foregroundStyle(Color(Theme.text3)) }
                if let key {
                    Text(key)
                        .font(.numeric(11))
                        .foregroundStyle(Color(Theme.text3))
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).strokeBorder(Color(Theme.hairlineStrong)))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .buttonStyle(IconButtonStyle())
    }
}

/// "Tell AI how to reply…" with the sparkles glyph above the bottom bar; Return runs it.
struct AIInstructionBar: View {
    let model: ComposerModel

    var body: some View {
        HStack(spacing: 8) {
            IconView(icon: .sparkles, size: 16, color: Color(Theme.text2))
            ComposerTextField(
                model: model, field: .ai, text: model.aiInstruction ?? "",
                placeholder: model.kind == .reply || model.kind == .replyAll ? "Tell AI how to reply…" : "Describe the email to write…",
                onChange: { model.aiInstruction = $0 }, onSubmit: { model.runAI() })
                .frame(height: 18)
            if model.aiBusy {
                Text("Writing…").font(.ui(12)).foregroundStyle(Color(Theme.text3))
            } else {
                Text("↵").font(.numeric(12)).foregroundStyle(Color(Theme.text3))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color(Theme.hover)))
        .padding(.horizontal, model.mode == .window ? 16 : 10)
        .padding(.top, 4)
    }
}

/// A 28 pt icon button that fills on hover.
struct ComposerIconButton: View {
    let icon: Icon
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: 16, color: Color(Theme.text2))
                .frame(width: Theme.Control.regular, height: Theme.Control.regular)
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
        .accessibilityLabel(help.components(separatedBy: "  ").first ?? help)
    }
}

extension View {
    /// Files dropped anywhere on the composer become attachments.
    func acceptsFileDrops(_ model: ComposerModel) -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.addFiles([url]) }
                }
            }
            return !providers.isEmpty
        }
    }
}

