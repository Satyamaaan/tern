import Foundation
import Testing
@testable import TernAI

// The system runner against tiny shell commands (no model CLIs).

@Test func systemRunnerPipesStdinAndCapturesOutput() async throws {
    let runner = SystemProcessRunner()
    let input = String(repeating: "mail line ✉︎\n", count: 20_000)
    let echoed = try await runner.run(ProcessInvocation(executable: "/bin/cat", arguments: [], stdin: Data(input.utf8)), timeout: 10)
    #expect(echoed.exitCode == 0)
    #expect(echoed.stdoutText == input)

    let failing = try await runner.run(ProcessInvocation(
        executable: "/bin/sh", arguments: ["-c", "echo \"$GREETING from $(pwd)\"; echo oops >&2; exit 3"],
        environment: ["GREETING": "hi"], currentDirectory: "/private/tmp"), timeout: 10)
    #expect(failing.exitCode == 3)
    #expect(failing.stdoutText == "hi from /private/tmp\n")
    #expect(failing.stderrText == "oops\n")
}

@Test func systemRunnerSurvivesAChildThatIgnoresStdin() async throws {
    let result = try await SystemProcessRunner().run(ProcessInvocation(
        executable: "/usr/bin/true", arguments: [], stdin: Data(repeating: 65, count: 1_000_000)), timeout: 10)
    #expect(result.exitCode == 0)
}

@Test func systemRunnerTimesOutAndKills() async throws {
    let started = Date()
    await #expect(throws: AIError.timedOut) {
        try await SystemProcessRunner().run(ProcessInvocation(executable: "/bin/sleep", arguments: ["30"]), timeout: 0.3)
    }
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func systemRunnerCancellationKills() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("tern-runner-\(UUID().uuidString)").path
    let task = Task {
        try await SystemProcessRunner().run(ProcessInvocation(
            executable: "/bin/sh", arguments: ["-c", "sleep 2; touch \(marker)"]), timeout: 30)
    }
    try await Task.sleep(for: .milliseconds(200))
    let started = Date()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(started) < 1)
    try await Task.sleep(for: .seconds(2.5))
    #expect(!FileManager.default.fileExists(atPath: marker))
}

@Test func systemRunnerReportsLaunchFailure() async throws {
    await #expect(throws: AIError.self) {
        try await SystemProcessRunner().run(ProcessInvocation(executable: "/nonexistent/codex", arguments: []), timeout: 5)
    }
}

private actor Counter {
    var current = 0
    var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

@Test func gateRunsAtMostTwoAtOnce() async throws {
    let gate = CLIGate(limit: 2)
    let counter = Counter()
    try await withThrowingTaskGroup(of: Int.self) { group in
        for index in 0..<6 {
            group.addTask {
                try await gate.withSlot {
                    await counter.enter()
                    try await Task.sleep(for: .milliseconds(40))
                    await counter.leave()
                    return index
                }
            }
        }
        var finished = 0
        for try await _ in group { finished += 1 }
        #expect(finished == 6)
    }
    #expect(await counter.peak == 2)
}

@Test func gateDropsCancelledWaiters() async throws {
    let gate = CLIGate(limit: 1)
    let holder = Task { try await gate.withSlot { try await Task.sleep(for: .milliseconds(300)) } }
    // Step on the gate's own state, not on sleeps that race on a busy machine.
    for _ in 0..<200 where await gate.occupancy.running == 0 { try await Task.sleep(for: .milliseconds(5)) }
    let waiter = Task { try await gate.withSlot { "ran" } }
    for _ in 0..<200 where await gate.occupancy.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    try await holder.value
    #expect(try await gate.withSlot { "free" } == "free")
}

@Test func providerPassesTimeoutAndPropagatesCancellation() async throws {
    let runner = FakeRunner { invocation in
        if invocation.arguments.contains("--help") { return ProcessResult(exitCode: 0, stdout: "--output-format --model -p") }
        try await Task.sleep(for: .seconds(30))
        return ProcessResult(exitCode: 0, stdout: "late")
    }
    let gate = CLIGate(limit: 1)
    let provider = ClaudeCLIProvider(
        runner: runner,
        locator: CLILocator(home: "/Users/test", environment: [:], isExecutable: { $0 == "/opt/homebrew/bin/claude" }, listDirectory: { _ in [] }, runner: runner),
        gate: gate, environment: [:])
    let call = Task { try await provider.complete(AIRequest(instructions: "", input: "x", timeout: 7)) }
    // Cancel only once the call has reached the runner; a fixed sleep races on a busy machine.
    for _ in 0..<200 where runner.timeouts.last != 7 { try await Task.sleep(for: .milliseconds(10)) }
    call.cancel()
    await #expect(throws: CancellationError.self) { try await call.value }
    #expect(runner.timeouts.last == 7)
    // The slot was released.
    #expect(try await gate.withSlot { 1 } == 1)
}
