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
    var runner = SystemProcessRunner()
    runner.killGrace = 10
    let task = Task {
        try await runner.run(ProcessInvocation(
            executable: "/bin/sh", arguments: ["-c", "sleep 2; touch \(marker)"]), timeout: 30)
    }
    try await Task.sleep(for: .milliseconds(200))
    let started = Date()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    // SIGTERM was enough: the answer came once the group was gone, long before SIGKILL was due.
    #expect(Date().timeIntervalSince(started) < 2)
    try await Task.sleep(for: .seconds(2.5))
    #expect(!FileManager.default.fileExists(atPath: marker))
}

@Test func systemRunnerStopsTheWholeProcessGroupBeforeAnswering() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-group-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pids = directory.appendingPathComponent("pids").path
    // A fake CLI that starts a helper which ignores SIGTERM and keeps running.
    let script = """
        sh -c 'trap "" TERM; echo $$ >> "\(pids)"; while :; do sleep 0.05; done' &
        echo $$ >> "\(pids)"
        wait
        """
    var runner = SystemProcessRunner()
    runner.killGrace = 0.3
    let gate = CLIGate(limit: 1)
    let call = Task {
        try await gate.withSlot {
            try await runner.run(ProcessInvocation(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"]), timeout: 30)
        }
    }
    var found: [pid_t] = []
    for _ in 0..<300 where found.count < 2 {
        try await Task.sleep(for: .milliseconds(10))
        found = ((try? String(contentsOfFile: pids, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
    }
    #expect(found.count == 2)
    let leader = try #require(found.last)

    let stopped = Date()
    call.cancel()
    await #expect(throws: CancellationError.self) { try await call.value }
    // The answer waited for SIGKILL to take the helper that ignored SIGTERM.
    #expect(Date().timeIntervalSince(stopped) >= 0.3)
    for pid in found { #expect(kill(pid, 0) == -1 && errno == ESRCH, "process \(pid) survived") }
    #expect(kill(-leader, 0) == -1 && errno == ESRCH, "something of the group survived")
    // And the CLI slot was free only then.
    #expect(await gate.occupancy.running == 0)
}

@Test func systemRunnerTimesOutTheWholeProcessGroup() async throws {
    var runner = SystemProcessRunner()
    runner.killGrace = 0.2
    let started = Date()
    // The helper ignores SIGTERM and holds stdout open, so only stopping the whole group ends the call.
    await #expect(throws: AIError.timedOut) {
        try await runner.run(ProcessInvocation(
            executable: "/bin/sh", arguments: ["-c", "sh -c 'trap \"\" TERM; while :; do sleep 0.05; done' & wait"],
            environment: ["PATH": "/usr/bin:/bin"]), timeout: 0.3)
    }
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func systemRunnerReportsLaunchFailure() async throws {
    await #expect(throws: AIError.self) {
        try await SystemProcessRunner().run(ProcessInvocation(executable: "/nonexistent/codex", arguments: []), timeout: 5)
    }
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
    // The holder keeps its slot long enough that a loaded machine still cancels the waiter first.
    let holder = Task { try await gate.withSlot { try await Task.sleep(for: .milliseconds(1500)) } }
    // Step on the gate's own state, not on sleeps that race on a busy machine.
    for _ in 0..<200 where await gate.occupancy.running == 0 { try await Task.sleep(for: .milliseconds(5)) }
    let waiter = Task { try await gate.withSlot { "ran" } }
    for _ in 0..<200 where await gate.occupancy.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    try await holder.value
    #expect(try await gate.withSlot { "free" } == "free")
}

@Test func gateKeepsASlotForOnDemandCalls() async throws {
    let gate = CLIGate(limit: 2, backgroundLimit: 1)
    let latch = Latch()
    let holder = Task { try await gate.withSlot(background: true) { await latch.wait() } }
    for _ in 0..<200 where await gate.occupancy.running == 0 { try await Task.sleep(for: .milliseconds(5)) }
    let waiting = Task { try await gate.withSlot(background: true) { "background" } }
    for _ in 0..<200 where await gate.occupancy.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
    // A second background call waits for the first; an on-demand call doesn't wait for either.
    let occupancy = await gate.occupancy
    #expect(occupancy.running == 1 && occupancy.waiting == 1)
    #expect(try await gate.withSlot { "on demand" } == "on demand")
    await latch.release()
    try await holder.value
    #expect(try await waiting.value == "background")
}

@Test func gateServesWaitingOnDemandCallsFirst() async throws {
    let gate = CLIGate(limit: 1)
    let latch = Latch()
    let order = Recorder()
    let holder = Task { try await gate.withSlot(background: true) { await latch.wait() } }
    for _ in 0..<200 where await gate.occupancy.running == 0 { try await Task.sleep(for: .milliseconds(5)) }
    let background = Task { try await gate.withSlot(background: true) { await order.add("background") } }
    for _ in 0..<200 where await gate.occupancy.waiting < 1 { try await Task.sleep(for: .milliseconds(5)) }
    let onDemand = Task { try await gate.withSlot { await order.add("on demand") } }
    for _ in 0..<200 where await gate.occupancy.waiting < 2 { try await Task.sleep(for: .milliseconds(5)) }
    await latch.release()
    try await holder.value
    try await background.value
    try await onDemand.value
    #expect(await order.items == ["on demand", "background"])
}

@Test func backgroundCallsRunAtUtilityPriority() async throws {
    let runner = FakeRunner { invocation in
        if invocation.arguments == ["--help"] { return ProcessResult(exitCode: 0, stdout: "--output-format --model -p --settings") }
        return ProcessResult(exitCode: 0, stdout: #"{"is_error":false,"result":"ok"}"#)
    }
    let provider = ClaudeCLIProvider(
        runner: runner,
        locator: CLILocator(home: "/Users/test", environment: [:], isExecutable: { $0 == "/opt/homebrew/bin/claude" }, listDirectory: { _ in [] }, runner: runner),
        gate: CLIGate(limit: 2, backgroundLimit: 1), environment: [:])
    _ = try await provider.complete(AIRequest(instructions: "", input: "x", isBackground: true))
    #expect(runner.invocations.last?.qualityOfService == .utility)
    _ = try await provider.complete(AIRequest(instructions: "", input: "x"))
    #expect(runner.invocations.last?.qualityOfService == .default)
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
