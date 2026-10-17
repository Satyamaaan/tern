import Foundation

/// Shared plumbing for one CLI: finding the binary, reading which flags this version supports,
/// caching availability, and launching calls through the gate in an empty temp directory.
actor CLIBackend {
    struct Config: Sendable {
        /// Binary name, e.g. "codex".
        var name: String
        var displayName: String
        /// Arguments that print the help listing the flags we may use.
        var helpArguments: [String]
        /// Checked before the search directories, e.g. an explicit path from settings.
        var extraPaths: [String] = []
    }

    let config: Config
    let locator: CLILocator
    let runner: any ProcessRunner
    let gate: CLIGate
    let baseEnvironment: [String: String]

    /// How long a checked availability is trusted.
    var readyLifetime: TimeInterval = 600
    var unavailableLifetime: TimeInterval = 30

    private var resolved: String??
    private var help: String?
    private var availability: (value: AIAvailability, at: Date)?
    private var memo: [String: [String]] = [:]

    init(config: Config, locator: CLILocator, runner: any ProcessRunner, gate: CLIGate, environment: [String: String]) {
        self.config = config
        self.locator = locator
        self.runner = runner
        self.gate = gate
        self.baseEnvironment = environment
    }

    func binary() async -> String? {
        if let resolved { return resolved }
        let path = await locator.locate(config.name, extraPaths: config.extraPaths)
        resolved = .some(path)
        if path == nil { aiLog.info("\(self.config.name, privacy: .public) not found") }
        return path
    }

    func requireBinary() async throws -> String {
        guard let path = await binary() else { throw AIError.notInstalled(provider: config.displayName) }
        return path
    }

    /// The help text of this CLI version, read once. Empty when it can't be read.
    func helpText() async -> String {
        if let help { return help }
        guard let path = await binary() else { return "" }
        let result = try? await runner.run(invocation(path, config.helpArguments, stdin: nil, directory: nil), timeout: 15)
        let text = result.map { $0.stdoutText + "\n" + $0.stderrText } ?? ""
        help = text
        return text
    }

    /// Long flags this version lists, e.g. "--output-schema".
    func flags() async -> Set<String> {
        Self.flags(in: await helpText())
    }

    func cachedAvailability() -> AIAvailability? {
        guard let availability else { return nil }
        let lifetime = availability.value == .ready ? readyLifetime : unavailableLifetime
        return Date().timeIntervalSince(availability.at) < lifetime ? availability.value : nil
    }

    func remember(_ value: AIAvailability) {
        availability = (value, Date())
        if value == .notInstalled { resolved = nil }
    }

    /// Forget the binary and sign-in state, e.g. after a call reported a sign-out.
    func invalidate() {
        availability = nil
        resolved = nil
        help = nil
        memo = [:]
    }

    /// Computed once until `invalidate()`, including an empty answer (e.g. a version without the command).
    func memoized(_ key: String, _ make: () async -> [String]) async -> [String] {
        if let value = memo[key] { return value }
        let value = await make()
        memo[key] = value
        return value
    }

    /// A quick non-model command such as a login check; does not take a gate slot.
    func runCheck(_ arguments: [String], timeout: TimeInterval = 15) async throws -> ProcessResult {
        let path = try await requireBinary()
        return try await runner.run(invocation(path, arguments, stdin: nil, directory: nil), timeout: timeout)
    }

    /// A model call: waits for a gate slot, runs in `directory`, sends `stdin`.
    func runModel(_ arguments: [String], stdin: String, directory: String, timeout: TimeInterval) async throws -> ProcessResult {
        let path = try await requireBinary()
        let invocation = invocation(path, arguments, stdin: Data(stdin.utf8), directory: directory)
        let runner = runner
        let started = Date()
        let result = try await gate.withSlot { try await runner.run(invocation, timeout: timeout) }
        aiLog.info("\(self.config.name, privacy: .public) exited \(result.exitCode) after \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
        return result
    }

    func invocation(_ path: String, _ arguments: [String], stdin: Data?, directory: String?) -> ProcessInvocation {
        ProcessInvocation(
            executable: path, arguments: arguments,
            environment: CLIEnvironment.child(of: baseEnvironment, path: locator.childPath(for: path)),
            currentDirectory: directory ?? FileManager.default.temporaryDirectory.path, stdin: stdin)
    }

    static func flags(in help: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"--[a-z][a-z0-9-]+"#)
        let range = NSRange(help.startIndex..., in: help)
        return Set(pattern.matches(in: help, range: range).compactMap { Range($0.range, in: help).map { String(help[$0]) } })
    }
}

/// A fresh temp directory per call: `work` stays empty and is the CLI's working directory; schema and
/// answer files sit next to it.
struct CallDirectory {
    let root: URL
    var work: URL { root.appendingPathComponent("work", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tern-ai", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Turns CLI failure output into an `AIError` without echoing anything that might be mail. Codex
/// echoes the prompt on stderr, so error lines are preferred over the whole output.
enum CLIFailure {
    static func error(provider: String, exitCode: Int32, output: String) -> AIError {
        let lines = errorLines(in: output)
        let lower = (lines.isEmpty ? output : lines.joined(separator: "\n")).lowercased()
        if ["not logged in", "/login", "codex login", "invalid api key", "401", "unauthorized", "authenticate",
            "authentication", "session expired", "token has expired", "not authenticated", "logged out"]
            .contains(where: lower.contains) {
            return .notSignedIn(provider: provider)
        }
        if ["usage limit", "rate limit", "rate_limit", "429", "quota", "too many requests", "limit reached", "overloaded"]
            .contains(where: lower.contains) {
            return .rateLimited(lines.first ?? "")
        }
        if let line = lines.first { return .failed("\(provider): \(line)") }
        return .failed("\(provider) stopped with exit code \(exitCode).")
    }

    /// Lines that read like error messages, shortened.
    static func errorLines(in output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            guard lower.hasPrefix("error") || lower.hasPrefix("fatal") || lower.hasPrefix("stream error") else { return nil }
            return String(trimmed.prefix(200))
        }
    }
}
