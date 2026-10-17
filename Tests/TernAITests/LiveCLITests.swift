import Foundation
import Testing
@testable import TernAI

// Real CLI calls with a tiny made-up prompt. They use the owner's subscription, so they only run with
// TERN_LIVE_AI=1 (and TERN_LIVE_AI_PROVIDER=codex|claude to pick one).

private let live = ProcessInfo.processInfo.environment["TERN_LIVE_AI"] == "1"
private let only = ProcessInfo.processInfo.environment["TERN_LIVE_AI_PROVIDER"]

/// What a GUI app launched by launchd would see: no IDE session variables, no shell PATH.
private var appEnvironment: [String: String] {
    ProcessInfo.processInfo.environment.filter { name, _ in
        !(name.hasPrefix("CLAUDE") || name.hasPrefix("ANTHROPIC") || name.hasPrefix("CODEX") || name == "PATH")
    }.merging(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]) { $1 }
}

private let fakeThreads = """
    <thread ref="1">
    Subject: Lunch tomorrow?
    <message from="Sam Rivera <sam@example.com>" to="owner@example.com" date="2026-10-16 12:00">
    Are you free for lunch tomorrow at noon?
    </message>
    </thread>
    <thread ref="2">
    Subject: [acme/app] Build failed on main
    <message from="CI <ci-bot@example.com>" to="owner@example.com" date="2026-10-16 12:05">
    The build failed. View the logs.
    </message>
    </thread>
    """

private func check(_ provider: any AIProvider) async throws {
    #expect(await provider.availability(refresh: true) == .ready)
    let request = Prompts.triage([], refs: [], owner: ["owner@example.com"], projects: nil, today: Date())
    let answer = try await provider.complete(AIRequest(instructions: request.instructions, input: fakeThreads, schema: request.schema))
    let verdicts = try #require(TriageVerdict.parse(answer, refs: ["1", "2"], projects: []))
    let byRef = Dictionary(uniqueKeysWithValues: verdicts.map { ($0.ref, $0) })
    #expect(byRef["1"]?.category == .people)
    #expect(byRef["1"]?.needsReply == true)
    #expect(byRef["2"]?.category == .notification)
    print("live \(provider.id):", answer)
}

@Test(.enabled(if: live && (only == nil || only == "codex"))) func liveCodexTriage() async throws {
    try await check(CodexCLIProvider(environment: appEnvironment))
}

@Test(.enabled(if: live && (only == nil || only == "claude"))) func liveClaudeTriage() async throws {
    try await check(ClaudeCLIProvider(environment: appEnvironment))
}
