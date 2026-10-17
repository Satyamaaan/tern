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
                    .font(.ui(12))
                    .foregroundStyle(Color(Theme.accentInk))
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
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(Theme.text3))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
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
                    Text("•••")
                        .font(.ui(11, .semibold))
                        .foregroundStyle(Color(hovering ? Theme.text1 : Theme.text2))
                        .frame(width: 32, height: 18)
                        .background(Capsule().fill(Color(Theme.pill)))
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
            Image(systemName: Self.symbol(for: attachment.mimeType))
                .font(.system(size: 12))
                .foregroundStyle(Color(Theme.text2))
            Text(attachment.filename)
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text1))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                .font(.mono(12))
                .foregroundStyle(Color(Theme.text3))
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(Theme.text3))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Remove")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color(Theme.pill)))
        .onHover { hovering = $0 }
        .help(attachment.needsFetch ? "\(attachment.filename) — from the original message" : attachment.filename)
    }

    static func symbol(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType.contains("spreadsheet") || mimeType.contains("excel") || mimeType == "text/csv" { return "tablecells" }
        if mimeType.contains("zip") || mimeType.contains("compressed") { return "doc.zipper" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        return "doc"
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

// MARK: - Bottom: ✦ instruction, Send, attach, AI, discard

struct ComposerBottomArea: View {
    @Bindable var model: ComposerModel

    var body: some View {
        VStack(spacing: 0) {
            if model.aiInstruction != nil { AIInstructionBar(model: model) }
            HStack(spacing: 4) {
                SendButton(model: model)
                    .padding(.trailing, 6)
                IconButton(symbol: "paperclip", help: "Attach files  ⌘⇧A") { model.attach() }
                if model.aiAvailable {
                    Button { model.toggleAI() } label: {
                        HStack(spacing: 5) {
                            Text("✦").font(.ui(13))
                            if model.mode == .window { Text("Write with AI").font(.ui(13)) }
                        }
                        .foregroundStyle(Color(model.aiInstruction != nil ? Theme.text1 : Theme.text2))
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverFillStyle())
                    .help("Write with AI  ⌘J")
                }
                Spacer(minLength: 8)
                if let notice = model.notice {
                    Text(notice)
                        .font(.ui(12))
                        .foregroundStyle(Color(Theme.accentInk))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if model.confirmingDiscard {
                    Text("Discard this draft?").font(.ui(12)).foregroundStyle(Color(Theme.text2))
                    Button("Keep") { model.confirmingDiscard = false }
                        .buttonStyle(.plain).font(.ui(12, .medium)).foregroundStyle(Color(Theme.text2)).padding(.horizontal, 6)
                    Button("Discard") { model.discard() }
                        .buttonStyle(.plain).font(.ui(12, .medium)).foregroundStyle(Color(Theme.accentInk))
                } else {
                    IconButton(symbol: "trash", help: "Discard draft  ⌘⇧D") { model.requestDiscard() }
                }
            }
            .padding(.horizontal, model.mode == .window ? 14 : 10)
            .frame(height: model.mode == .window ? 56 : 48)
        }
    }
}

/// The primary pill: Send, and a chevron for Send and archive / Send later.
struct SendButton: View {
    @Bindable var model: ComposerModel
    @State private var hoveringSend = false
    @State private var hoveringMenu = false

    var body: some View {
        HStack(spacing: 0) {
            Button { model.send() } label: {
                Text("Send")
                    .font(.ui(13, .semibold))
                    .foregroundStyle(Color(Theme.onAccent))
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .frame(height: 30)
                    .background(Color.white.opacity(hoveringSend ? 0.08 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringSend = $0 }
            .help("Send  ⌘↵")
            Rectangle().fill(Color(Theme.onAccent).opacity(0.28)).frame(width: 1, height: 16)
            Button { model.sendLaterOpen.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(Theme.onAccent))
                    .frame(width: 26, height: 30)
                    .background(Color.white.opacity(hoveringMenu ? 0.08 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringMenu = $0 }
            .help("Send later  ⌘⇧L")
            .popover(isPresented: $model.sendLaterOpen, arrowEdge: .top) {
                SendLaterPopover(model: model)
            }
        }
        .background(Capsule().fill(Color(Theme.primaryFill)))
        .clipShape(Capsule())
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
            Text("SEND LATER")
                .font(.ui(11, .medium))
                .tracking(0.6)
                .foregroundStyle(Color(Theme.text3))
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
                        .buttonStyle(.plain)
                        .font(.ui(13, .semibold))
                        .foregroundStyle(Color(Theme.onAccent))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(Color(Theme.primaryFill)))
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

/// One popover row: title, detail in mono at the right, optional keycap.
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
                if let detail { Text(detail).font(.mono(12)).foregroundStyle(Color(Theme.text3)) }
                if let key {
                    Text(key)
                        .font(.mono(11))
                        .foregroundStyle(Color(Theme.text3))
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(Theme.hairlineStrong)))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle())
    }
}

/// "✦ Tell AI how to reply…" above the bottom bar; Return runs it.
struct AIInstructionBar: View {
    let model: ComposerModel

    var body: some View {
        HStack(spacing: 8) {
            Text("✦").font(.ui(13)).foregroundStyle(Color(Theme.accentInk))
            ComposerTextField(
                model: model, field: .ai, text: model.aiInstruction ?? "",
                placeholder: model.kind == .reply || model.kind == .replyAll ? "Tell AI how to reply…" : "Describe the email to write…",
                onChange: { model.aiInstruction = $0 }, onSubmit: { model.runAI() })
                .frame(height: 18)
            if model.aiBusy {
                Text("Writing…").font(.ui(12)).foregroundStyle(Color(Theme.text3))
            } else {
                Text("↵").font(.mono(12)).foregroundStyle(Color(Theme.text3))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color(Theme.hover)))
        .padding(.horizontal, model.mode == .window ? 16 : 10)
        .padding(.top, 4)
    }
}

/// A 28 pt icon button that fills on hover.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color(Theme.text2))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle())
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

struct HoverFillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverFill(configuration: configuration)
    }

    private struct HoverFill: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row)
                    .fill(Color(configuration.isPressed ? Theme.selected : hovering ? Theme.hover : .clear)))
                .onHover { hovering = $0 }
        }
    }
}
