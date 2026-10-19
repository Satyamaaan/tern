import Foundation
import GRDB
import Testing
@testable import TernAI
import TernCore

// Real CLI timing for triage on a COPY of a fake mailbox (never the real database). It uses the owner's
// subscription, so it only runs with TERN_BENCH_AI=1 and TERN_BENCH_DB=<copy of a fake mailbox>.
//
//   TERN_BENCH_PROVIDER  claude | codex (default claude)
//   TERN_BENCH_THREADS   how many candidate threads, inbox first, newest first (default 45)
//   TERN_BENCH_BATCH     threads per call (default: the queue's batch size for the provider)
//   TERN_BENCH_PARALLEL  calls at once (default 1)
//   TERN_BENCH_EXTRA     extra CLI arguments, space-separated, e.g. "--effort low"
//   TERN_BENCH_CHILD_ENV extra child environment, comma-separated K=V, e.g. "RUST_LOG=debug"
//   TERN_BENCH_KEEP_STDERR=1  writes each call's stderr to TERN_BENCH_OUT (fake mail only)
//   TERN_BENCH_CLAUDE_PROXY=1 passes this shell's ANTHROPIC_BASE_URL/AUTH_TOKEN/DEFAULT_HAIKU_MODEL to Claude
//   TERN_BENCH_TRIVIAL=1 one tiny call with no mail, to time the fixed cost of a call
//   TERN_BENCH_DRY=1     no calls: print prompt sizes and write the prompts to TERN_BENCH_OUT
//   TERN_BENCH_OUT       directory for calls.jsonl, verdicts.json and prompts (default /tmp/tern-bench)
//   TERN_BENCH_QUEUE=1   instead: run the real TriageQueue on a writable copy, the newest 25 inbox rows on
//                        screen, and time the screen and the whole pass (TERN_BENCH_WINDOW_HOURS bounds it)

private let env = ProcessInfo.processInfo.environment
private let benchEnabled = env["TERN_BENCH_AI"] == "1" && env["TERN_BENCH_DB"] != nil

@Test(.enabled(if: benchEnabled && env["TERN_BENCH_QUEUE"] == "1")) func benchTriageQueue() async throws {
    let providerId = env["TERN_BENCH_PROVIDER"] ?? "claude"
    let source = try #require(env["TERN_BENCH_DB"])
    #expect(!source.contains("Application Support"), "Benchmarks run on a copy of a fake mailbox only.")
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("tern-bench-\(UUID().uuidString).sqlite")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
    defer { try? FileManager.default.removeItem(at: copy) }
    let database = try AppDatabase.open(at: copy)
    try await database.writer.write { db in try AISettings(enabled: true, provider: providerId).write(db) }

    let (now, screen) = try await database.reader.read { db -> (Date, [ThreadKey]) in
        let newest = try Double.fetchOne(db, sql: "SELECT max(lastDate) FROM thread") ?? 0
        let screen = try Row.fetchAll(db, sql: """
            SELECT t.accountId, t.id FROM thread t WHERE EXISTS (SELECT 1 FROM thread_label i
              WHERE i.accountId = t.accountId AND i.threadId = t.id AND i.labelId = 'INBOX')
            ORDER BY t.lastDate DESC LIMIT 25
            """).map { ThreadKey(accountId: $0[0], threadId: $0[1]) }
        return (Date(timeIntervalSince1970: newest + 3_600), screen)
    }
    let window = (Double(env["TERN_BENCH_WINDOW_HOURS"] ?? "") ?? 14) * 3_600
    let needing = try await database.reader.read { db in
        try TriageQueue.candidates(db, since: now.addingTimeInterval(-window), limit: 25, keys: screen).map(\.key)
    }
    let total = try await database.reader.read { db in
        try TriageQueue.candidates(db, since: now.addingTimeInterval(-window), limit: 5_000).count
    }
    let provider: any AIProvider = providerId == "codex"
        ? CodexCLIProvider(environment: benchEnvironment) : ClaudeCLIProvider(environment: benchEnvironment)
    let triage = TriageQueue(database: database, providers: AIProviders([provider]), window: window, now: { now })
    print("bench queue \(providerId): \(needing.count) of 25 rows on screen need AI, \(total) threads in all")

    await triage.prioritize(screen)
    let started = Date()
    let pass = Task { await triage.runPass() }
    var screenSeconds: TimeInterval?
    while screenSeconds == nil {
        let sorted = try await database.reader.read { db in
            try needing.filter { key in
                try String.fetchOne(db, sql: "SELECT source FROM thread_ai WHERE accountId = ? AND threadId = ?",
                                    arguments: [key.accountId, key.threadId]) == providerId
            }.count
        }
        if sorted == needing.count { screenSeconds = Date().timeIntervalSince(started) } else { try await Task.sleep(for: .milliseconds(100)) }
        if Date().timeIntervalSince(started) > 300 { break }
    }
    await pass.value
    let elapsed = Date().timeIntervalSince(started)
    let status = await triage.currentStatus
    print("bench queue \(providerId): screen sorted in \(String(format: "%.1f", screenSeconds ?? -1)) s; \(status.classified) of \(total) threads in \(String(format: "%.1f", elapsed)) s = \(String(format: "%.0f", Double(status.classified) / elapsed * 60)) threads/min; state \(status.state)")
    #expect(status.state == .idle)
}

@Test(.enabled(if: benchEnabled && env["TERN_BENCH_QUEUE"] != "1")) func benchTriage() async throws {
    let providerId = env["TERN_BENCH_PROVIDER"] ?? "claude"
    let count = Int(env["TERN_BENCH_THREADS"] ?? "") ?? 45
    let batchSize = Int(env["TERN_BENCH_BATCH"] ?? "") ?? TriageQueue.batchSize(for: providerId)
    let parallel = Int(env["TERN_BENCH_PARALLEL"] ?? "") ?? 1
    let extra = (env["TERN_BENCH_EXTRA"] ?? "").split(separator: " ").map(String.init)
    let out = URL(fileURLWithPath: env["TERN_BENCH_OUT"] ?? "/tmp/tern-bench", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let path = try #require(env["TERN_BENCH_DB"])
    #expect(!path.contains("Application Support"), "Benchmarks run on a copy of a fake mailbox only.")
    var configuration = Configuration()
    configuration.readonly = true
    let queue = try DatabaseQueue(path: path, configuration: configuration)

    let runner = BenchRunner(extra: extra)
    let gate = CLIGate(limit: max(1, parallel))
    let provider: any AIProvider = providerId == "codex"
        ? CodexCLIProvider(runner: runner, gate: gate, environment: benchEnvironment)
        : ClaudeCLIProvider(runner: runner, gate: gate, environment: benchEnvironment)

    if env["TERN_BENCH_TRIVIAL"] == "1" {
        let started = Date()
        let answer = try await provider.complete(AIRequest(instructions: "Answer with the single word: ok", input: "ping"))
        print("bench trivial \(providerId): \(String(format: "%.2f", Date().timeIntervalSince(started))) s, answer \(answer.prefix(20))")
        try runner.save(to: out.appendingPathComponent("calls.jsonl"), label: "trivial")
        return
    }

    let (batches, today) = try await queue.read { db -> ([BenchBatch], Date) in
        let newest = try Double.fetchOne(db, sql: "SELECT max(lastDate) FROM thread") ?? Date().timeIntervalSince1970
        let today = Date(timeIntervalSince1970: newest + 3_600)
        let keys = try TriageQueue.candidates(db, since: today.addingTimeInterval(-30 * 86_400), limit: count).map(\.key)
        let threads = try PromptData.threads(db, keys: keys, messages: TriageQueue.messagesPerThread, characters: TriageQueue.charactersPerMessage)
        let owner = try String.fetchAll(db, sql: "SELECT email FROM account ORDER BY sortOrder, email")
        let batches = stride(from: 0, to: threads.count, by: batchSize).map { start -> BenchBatch in
            let slice = Array(threads[start..<min(start + batchSize, threads.count)])
            let refs = slice.indices.map { String($0 - start + 1) }
            return BenchBatch(threads: slice, refs: refs, request: Prompts.triage(slice, refs: refs, owner: owner, projects: nil, today: today))
        }
        return (batches, today)
    }
    let bytes = batches.map { $0.request.instructions.utf8.count + $0.request.input.utf8.count + ($0.request.schema?.utf8.count ?? 0) }
    let threadBytes = batches.flatMap(\.threads).map { Prompts.render($0, ref: "10").utf8.count }
    print("bench \(providerId): \(batches.flatMap(\.threads).count) threads in \(batches.count) calls of \(batchSize), \(parallel) at once, today \(today)")
    print("bench prompt bytes per call \(bytes), per thread avg \(threadBytes.reduce(0, +) / max(1, threadBytes.count)) max \(threadBytes.max() ?? 0)")
    if env["TERN_BENCH_DRY"] == "1" {
        for (index, batch) in batches.enumerated() {
            try (batch.request.instructions + "\n\n" + batch.request.input).write(
                to: out.appendingPathComponent("prompt-\(index + 1).txt"), atomically: true, encoding: .utf8)
        }
        return
    }

    let started = Date()
    let verdicts = try await withThrowingTaskGroup(of: [String: [String: String]].self) { group in
        for batch in batches {
            group.addTask {
                let answer = try await provider.complete(batch.request)
                let parsed = TriageVerdict.parse(answer, refs: Set(batch.refs), projects: []) ?? []
                let byRef = Dictionary(uniqueKeysWithValues: zip(batch.refs, batch.threads))
                var rows: [String: [String: String]] = [:]
                for verdict in parsed {
                    guard let thread = byRef[verdict.ref] else { continue }
                    rows[thread.key.description] = [
                        "category": verdict.category.rawValue, "needsReply": String(verdict.needsReply),
                        "priority": String(verdict.priority), "summary": verdict.summary ?? "",
                    ]
                }
                return rows
            }
        }
        return try await group.reduce(into: [String: [String: String]]()) { $0.merge($1) { a, _ in a } }
    }
    let elapsed = Date().timeIntervalSince(started)
    let total = batches.flatMap(\.threads).count
    print("bench \(providerId): \(verdicts.count) of \(total) verdicts in \(String(format: "%.1f", elapsed)) s = \(String(format: "%.0f", Double(verdicts.count) / elapsed * 60)) threads/min")
    let label = env["TERN_BENCH_LABEL"] ?? "\(providerId)-b\(batchSize)-p\(parallel)"
    try runner.save(to: out.appendingPathComponent("calls.jsonl"), label: label)
    let data = try JSONSerialization.data(withJSONObject: verdicts, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: out.appendingPathComponent("verdicts-\(label).json"))
}

private struct BenchBatch: Sendable {
    var threads: [PromptThread]
    var refs: [String]
    var request: AIRequest
}

/// What a GUI app launched by launchd would see: no IDE session variables, no shell PATH.
/// TERN_BENCH_CLAUDE_CONFIG_DIR points Claude Code at a signed-in config directory other than ~/.claude.
private var benchEnvironment: [String: String] {
    var environment = env.filter { name, _ in
        !(name.hasPrefix("CLAUDE") || name.hasPrefix("ANTHROPIC") || name.hasPrefix("CODEX") || name.hasPrefix("TERN_") || name == "PATH")
    }.merging(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]) { $1 }
    environment["CLAUDE_CONFIG_DIR"] = env["TERN_BENCH_CLAUDE_CONFIG_DIR"]
    if env["TERN_BENCH_CLAUDE_PROXY"] == "1" {
        for name in ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_DEFAULT_HAIKU_MODEL"] { environment[name] = env[name] }
    }
    return environment
}

/// Runs the real CLI, adds `extra` arguments to model calls, and keeps each call's timing and the
/// CLI's own accounting (Claude's duration and usage; Codex's token count). Never stores the prompt.
private final class BenchRunner: ProcessRunner, @unchecked Sendable {
    private let inner = SystemProcessRunner()
    private let extra: [String]
    private let lock = NSLock()
    private var calls: [[String: Any]] = []

    init(extra: [String]) {
        self.extra = extra
    }

    func run(_ invocation: ProcessInvocation, timeout: TimeInterval) async throws -> ProcessResult {
        guard invocation.stdin != nil else { return try await inner.run(invocation, timeout: timeout) }
        var invocation = invocation
        if invocation.arguments.last == "-" {
            invocation.arguments.insert(contentsOf: extra, at: invocation.arguments.count - 1)
        } else {
            invocation.arguments += extra
        }
        for pair in (env["TERN_BENCH_CHILD_ENV"] ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { invocation.environment[parts[0]] = parts[1] }
        }
        let started = Date()
        let result = try await inner.run(invocation, timeout: timeout)
        if env["TERN_BENCH_KEEP_STDERR"] == "1", let out = env["TERN_BENCH_OUT"] {
            try? result.stderr.write(to: URL(fileURLWithPath: out).appendingPathComponent("stderr-\(UUID().uuidString.prefix(8)).txt"))
        }
        var call: [String: Any] = [
            "wall": Date().timeIntervalSince(started), "exit": Int(result.exitCode),
            "stdinBytes": invocation.stdin?.count ?? 0, "started": started.timeIntervalSince1970,
        ]
        if let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] {
            for key in ["duration_ms", "duration_api_ms", "num_turns", "usage", "total_cost_usd", "is_error"] {
                call[key] = object[key]
            }
        }
        if let range = result.stderrText.range(of: #"tokens used\s*\n?\s*[\d,]+"#, options: .regularExpression) {
            call["codexTokens"] = result.stderrText[range].filter(\.isNumber)
        }
        lock.withLock { calls.append(call) }
        print("bench call: \(String(format: "%.2f", call["wall"] as? Double ?? 0)) s exit \(result.exitCode)")
        return result
    }

    func save(to url: URL, label: String) throws {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for var call in lock.withLock({ calls }) {
            call["label"] = label
            let data = try JSONSerialization.data(withJSONObject: call, options: [.sortedKeys])
            text += String(decoding: data, as: UTF8.self) + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// The queue against a fake provider that answers after the per-call times measured on the fake mailbox
// (seconds = fixed + perThread × threads), sped up TERN_BENCH_SIM_SCALE times (default 20: the queue's own
// few milliseconds per call stay small). No CLI runs. TERN_BENCH_SIM=1; TERN_BENCH_SIM_ONLY=<name part> picks setups.
@Test(.enabled(if: env["TERN_BENCH_SIM"] == "1")) func benchTriageSimulated() async throws {
    struct Setup {
        var name: String
        var fixed: TimeInterval
        var perThread: TimeInterval
        var batchSize: Int
        var concurrency: Int
        var prioritizes: Bool
    }
    let scale = Double(env["TERN_BENCH_SIM_SCALE"] ?? "") ?? 20
    let setups = [
        // Codex before: 9.1-9.3 s per 15 threads, 6.3-8.2 s for a one-word answer.
        Setup(name: "codex old", fixed: 5.5, perThread: 0.25, batchSize: 15, concurrency: 1, prioritizes: false),
        // Codex now: 4.0 s for a one-word answer, 11.5 s for 30 threads.
        Setup(name: "codex new", fixed: 4.0, perThread: 0.25, batchSize: 30, concurrency: 3, prioritizes: true),
        // Claude before: 87-150 s per 15 threads with thinking (mean 114 s).
        Setup(name: "claude old", fixed: 0, perThread: 114.0 / 15, batchSize: 15, concurrency: 1, prioritizes: false),
        // Claude now: 8.0-8.9 s per 15 threads, 2 s for a one-word answer.
        Setup(name: "claude new", fixed: 1.5, perThread: 0.45, batchSize: 15, concurrency: 3, prioritizes: true),
    ]
    for setup in setups where env["TERN_BENCH_SIM_ONLY"].map(setup.name.contains) ?? true {
        for screenAt in [0, 200] {
            let database = try makeDatabase((0..<500).map { TestMail(id: "m\($0)", thread: "t\($0)", daysAgo: Double($0) * 0.05) })
            let provider = FakeProvider { request, index in
                let threads = Double(refsIn(request.input).count)
                let jitter = 0.9 + 0.2 * Double((index * 7_919) % 100) / 100
                try await Task.sleep(for: .seconds((setup.fixed + setup.perThread * threads) * jitter / scale))
                return triageAnswer(request)
            }
            let triage = TriageQueue(
                database: database, providers: AIProviders([provider]), batchSize: setup.batchSize,
                concurrency: setup.concurrency, now: { testNow })
            // Fourteen threads on screen: the top of the inbox, or a tab or scroll position further down.
            let screen = (screenAt..<screenAt + 14).map { ThreadKey(accountId: me.id, threadId: "t\($0)") }
            if setup.prioritizes { await triage.prioritize(screen) }
            let started = Date()
            let pass = Task { await triage.runPass() }
            var screenSeconds: TimeInterval?
            while screenSeconds == nil {
                let rows = try aiRows(database)
                if screen.allSatisfy({ rows[$0.threadId] != nil }) { screenSeconds = Date().timeIntervalSince(started) * scale }
                else { try await Task.sleep(for: .milliseconds(1)) }
            }
            await pass.value
            let seconds = Date().timeIntervalSince(started) * scale
            #expect(try aiRows(database).count == 500)
            print("bench sim \(setup.name): screen at row \(screenAt) sorted in \(String(format: "%.0f", screenSeconds ?? 0)) s; 500 threads in \(String(format: "%.0f", seconds)) s = \(String(format: "%.0f", 500 / seconds * 60)) threads/min, \(provider.requests.count) calls")
        }
    }
}
