import AppKit
import Testing
@testable import Tern
@testable import TernCore

private typealias Block = RichText.Block
private typealias Run = RichText.Run

@MainActor
@Test func attributedStringRoundTripsRichText() {
    let text = RichText([
        Block(.paragraph, [Run("Hi "), Run("Maya", style: .bold), Run(", see "), Run("this", style: [.italic, .underline], link: "https://x.dev")]),
        Block(.paragraph),
        Block(.bullet, [Run("one")]),
        Block(.bullet, [Run("two")]),
        Block(.numbered, [Run("first")]),
        Block(.quote, [Run("quoted\u{2028}two lines")]),
        Block(.paragraph, [Run("end")]),
    ])
    #expect(RichTextBridge.richText(RichTextBridge.attributedString(text)) == text)
}

@MainActor
@Test func editorFormatsListsAndQuotesFromTyping() {
    let editor = BodyEditorController(insets: NSSize(width: 16, height: 10), minTextHeight: 60)
    let textView = editor.textView
    textView.insertText("- ", replacementRange: textView.selectedRange())
    textView.insertText("milk", replacementRange: textView.selectedRange())
    textView.insertNewline(nil)
    textView.insertText("eggs", replacementRange: textView.selectedRange())
    textView.insertNewline(nil)
    // Return on an empty item leaves the list.
    textView.insertNewline(nil)
    textView.insertText("> ", replacementRange: textView.selectedRange())
    textView.insertText("cited", replacementRange: textView.selectedRange())
    #expect(editor.richText.blocks.map(\.kind) == [.bullet, .bullet, .quote])
    #expect(editor.richText.plainText == "• milk\n• eggs\n> cited")
}

@MainActor
@Test func editorTogglesEmphasisOnSelectionAndTyping() {
    let editor = BodyEditorController(insets: NSSize(width: 16, height: 10), minTextHeight: 60)
    editor.richText = RichText(plainText: "make this bold")
    editor.textView.setSelectedRange(NSRange(location: 10, length: 4))
    editor.toggle(.bold)
    #expect(editor.richText.blocks[0].runs == [Run("make this "), Run("bold", style: .bold)])
    editor.toggle(.bold)
    #expect(editor.richText.blocks[0].runs == [Run("make this bold")])

    editor.textView.setSelectedRange(NSRange(location: 14, length: 0))
    editor.toggle(.italic)
    editor.textView.insertText("!", replacementRange: editor.textView.selectedRange())
    #expect(editor.richText.blocks[0].runs.last == Run("!", style: .italic))
}

@MainActor
@Test func pasteKeepsLinksAndEmphasisOnly() {
    let editor = BodyEditorController(insets: NSSize(width: 16, height: 10), minTextHeight: 60)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("tern-test-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString(#"<meta charset="utf-8"><span style="font-family:Comic Sans;color:red;font-size:30px">Big <b>deal</b> <a href="https://a.dev">here</a></span>"#, forType: .html)
    pasteboard.setString("Big deal here", forType: .string)
    editor.textView.pasteContents(of: pasteboard)
    #expect(editor.richText.blocks == [Block(.paragraph, [Run("Big "), Run("deal", style: .bold), Run(" "), Run("here", link: "https://a.dev")])])
    let font = editor.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(font?.pointSize == EditorStyle.fontSize)
}

@MainActor
@Test func inlineImagesRoundTripThroughTheEditor() throws {
    let picture = NSImage(size: NSSize(width: 800, height: 400))
    let text = RichText([
        Block(.paragraph, [Run("See "), .image("cid:chart"), Run(" and "), .image("cid:missing", link: "https://x.dev")]),
        Block(.bullet, [.image("cid:chart")]),
    ])
    let attributed = RichTextBridge.attributedString(text, images: { $0 == "cid:chart" ? picture : nil })
    #expect(RichTextBridge.richText(attributed) == text)
    let chart = try #require(attributed.attribute(.attachment, at: 4, effectiveRange: nil) as? NSTextAttachment)
    #expect(chart.image === picture && chart.bounds.size == NSSize(width: 360, height: 180), "scaled to fit")
    let missing = try #require(attributed.attribute(.attachment, at: 10, effectiveRange: nil) as? NSTextAttachment)
    #expect(missing.image === InlineImages.placeholder)

    let editor = BodyEditorController(insets: NSSize(width: 16, height: 10), minTextHeight: 60)
    editor.imageSource = { $0 == "cid:chart" ? picture : nil }
    editor.richText = text
    editor.textView.setSelectedRange(NSRange(location: 0, length: editor.textView.string.utf16.count))
    editor.toggle(.bold)
    editor.setBlock(.quote)
    #expect(editor.richText.blocks.flatMap(\.runs).compactMap(\.image) == ["cid:chart", "cid:missing", "cid:chart"],
            "formatting keeps the images")

    editor.imageSource = { _ in picture }
    editor.reloadImages()
    let reloaded = try #require(editor.textView.textStorage?.attribute(.attachment, at: 10, effectiveRange: nil) as? NSTextAttachment)
    #expect(reloaded.image === picture)
}
