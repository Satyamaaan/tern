import AppKit
import GRDB
import Testing
import TernAI
@testable import Tern
@testable import TernCore

struct GroqLiveVerification {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_GROQ_LIVE"] == "1"))
    func qwenSummaryJSON() async throws {
        let provider = GroqProvider(key: { GroqCredential.read() })
        let result = try await provider.complete(AIRequest(
            instructions: "Summarize this email in one short sentence. Return JSON.",
            input: "Maya asks us to approve the revised launch plan by Friday.",
            schema: #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"],"additionalProperties":false}"#,
            model: GroqProvider.defaultModel, effort: .careful, timeout: 60))
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: String])
        #expect(object["summary"]?.isEmpty == false)
    }
}

@MainActor
struct ListHeadlineSnapshots {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_HEADLINE_SHOTS"] == "1"))
    func renderBothModes() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Theme.registerFonts()
        let database = try AppDatabase.inMemory()
        try FakeMailbox.populate(database, options: .init(messages: 4_000, seed: 7))
        let rows = try database.reader.read { try MailStore.fetchThreadRows($0, in: .unifiedInbox, limit: 6, before: nil) }
        #expect(!rows.isEmpty)
        let directory = URL(fileURLWithPath: "/tmp/tern-shots/groq-headlines")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for headline in [true, false] {
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 1100, height: rows.count * 56))
            container.wantsLayer = true
            let window = NSWindow(contentRect: container.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = container
            window.appearance?.performAsCurrentDrawingAppearance {
                container.layer?.backgroundColor = Theme.bg.cgColor
            }
            for (index, original) in rows.enumerated() {
                var row = original
                row.summary = headline ? "Approve the revised launch plan by Friday" : nil
                let view = ThreadRowView(frame: CGRect(x: 0, y: index * 56, width: 1100, height: 56))
                var model = RowModel(row: row, style: .twoLines)
                model.avatar = .letters("MC")
                view.model = model
                container.addSubview(view)
            }
            container.layoutSubtreeIfNeeded()
            let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            window.appearance?.performAsCurrentDrawingAppearance { container.cacheDisplay(in: container.bounds, to: bitmap) }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(headline ? "summary-light.png" : "subject-light.png"))
            window.close()
        }
    }
}

struct PrimarySummaryLiveVerification {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_PRIMARY_SUMMARY_LIVE"] == "1"))
    func oneDisposableFakeSummary() async throws {
        let path = "/tmp/tern-real-mail-fixes-live.sqlite"
        try #require(ProcessInfo.processInfo.environment["TERN_DB"] == path)
        try #require(ProcessInfo.processInfo.environment["TERN_FAKE"] == "1")
        let database = try AppDatabase.open(at: URL(fileURLWithPath: path))
        try await database.writer.write { db in
            try AISettings(enabled: true, provider: "groq").write(db)
        }
        let providers = AIProviders([GroqProvider(key: { GroqCredential.read() })])
        let assistant = MailAssistant(database: database, providers: providers)
        let queue = PrimarySummaryQueue(database: database, assistant: assistant, providers: providers, dailyLimit: 1)
        #expect(try await queue.processNext())
        print("LIVE PRIMARY SUMMARY: completed one fake-mail queue job; DB=\(path)")
    }
}
