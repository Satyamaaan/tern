import Foundation

/// Claude Code (`claude -p`), signed in with the user's Claude subscription.
///
/// Each call runs in print mode in an empty temp directory with every tool, MCP server, slash command,
/// hook and settings file switched off, no saved session, and the prompt on stdin.
public struct ClaudeCLIProvider: AIProvider {
    public let id = "claude"
    public let displayName = "Claude Code"
    /// Haiku-class: fast and cheap on the subscription.
    public static let defaultModel = "haiku"
    let backend: CLIBackend

    public init(
        binaryPath: String? = nil, runner: any ProcessRunner = SystemProcessRunner(), locator: CLILocator? = nil,
        gate: CLIGate = .shared, environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let locator = locator ?? CLILocator(environment: environment, runner: runner)
        // The old per-user installer put the binary here.
        let extraPaths = (binaryPath.map { [$0] } ?? []) + ["\(locator.home)/.claude/local/claude"]
        backend = CLIBackend(
            config: .init(name: "claude", displayName: "Claude Code", helpArguments: ["--help"], extraPaths: extraPaths),
            locator: locator, runner: runner, gate: gate, environment: environment)
    }

    public func availability(refresh: Bool) async -> AIAvailability {
        if !refresh, let cached = await backend.cachedAvailability() { return cached }
        let value: AIAvailability
        if await backend.binary() == nil {
            value = .notInstalled
        } else if Self.hasAuthCommand(await backend.helpText()),
                  let result = try? await backend.runCheck(["auth", "status", "--json"]),
                  let status = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
                  let loggedIn = status["loggedIn"] as? Bool {
            value = loggedIn ? .ready : .signedOut
        } else {
            // Older versions have no cheap status command (and would start a session if asked);
            // the first call reports a sign-out instead.
            value = .ready
        }
        await backend.remember(value)
        return value
    }

    public func models() async -> [String] {
        ["haiku", "sonnet", "opus"]
    }

    public func complete(_ request: AIRequest) async throws -> String {
        let flags = await backend.flags()
        let directory = try CallDirectory()
        defer { directory.remove() }
        let arguments = Self.arguments(for: request, flags: flags)
        let stdin = Self.stdin(for: request, flags: flags)
        let result = try await backend.runModel(
            arguments, stdin: stdin, directory: directory.work.path, timeout: request.timeout, background: request.isBackground)
        do {
            return try Self.answer(from: result, provider: displayName)
        } catch AIError.notSignedIn(let provider) {
            await backend.invalidate()
            throw AIError.notSignedIn(provider: provider)
        }
    }

    // MARK: Command line

    static func arguments(for request: AIRequest, flags: Set<String>) -> [String] {
        // An unreadable help text means an unknown version: assume today's flags.
        let has = { (flag: String) in flags.isEmpty || flags.contains(flag) }
        var arguments = ["-p", "--model", request.model ?? defaultModel, "--output-format", "json"]
        if let schema = request.schema, has("--json-schema") { arguments += ["--json-schema", schema] }
        if has("--tools") {
            arguments += ["--tools", ""]
        } else {
            arguments += ["--disallowedTools", "Bash Edit Write MultiEdit NotebookEdit Read Glob Grep WebFetch WebSearch Task TodoWrite"]
        }
        if has("--strict-mcp-config") { arguments.append("--strict-mcp-config") }
        if has("--no-session-persistence") { arguments.append("--no-session-persistence") }
        if has("--disable-slash-commands") { arguments.append("--disable-slash-commands") }
        if has("--setting-sources") { arguments += ["--setting-sources", ""] }
        if has("--settings") { arguments += ["--settings", #"{"disableAllHooks":true}"#] }
        if !request.instructions.isEmpty, has("--system-prompt") { arguments += ["--system-prompt", request.instructions] }
        return arguments
    }

    static func stdin(for request: AIRequest, flags: Set<String>) -> String {
        let has = { (flag: String) in flags.isEmpty || flags.contains(flag) }
        var parts: [String] = []
        if !request.instructions.isEmpty, !has("--system-prompt") { parts.append(request.instructions) }
        if let schema = request.schema, !has("--json-schema") {
            parts.append("Answer with JSON only, matching this JSON Schema:\n\(schema)")
        }
        parts.append(request.input)
        return parts.joined(separator: "\n\n")
    }

    /// Reads `--output-format json`: the structured output when a schema was given, else the text.
    static func answer(from result: ProcessResult, provider: String) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            if result.exitCode != 0 {
                throw CLIFailure.error(provider: provider, exitCode: result.exitCode, output: result.stdoutText + "\n" + result.stderrText)
            }
            let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AIError.invalidOutput("\(provider) returned an empty answer.") }
            return text
        }
        let message = object["result"] as? String ?? ""
        if object["is_error"] as? Bool == true || result.exitCode != 0 {
            let status = (object["api_error_status"] as? Int).map { " \($0)" } ?? ""
            throw CLIFailure.error(provider: provider, exitCode: result.exitCode, output: "Error\(status): \(message.prefix(300))")
        }
        if let structured = object["structured_output"], !(structured is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.invalidOutput("\(provider) returned an empty answer.") }
        return text
    }

    static func hasAuthCommand(_ help: String) -> Bool {
        help.range(of: #"(?m)^\s+auth\b"#, options: .regularExpression) != nil
    }
}
