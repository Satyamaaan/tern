import Foundation

/// OpenAI Codex CLI (`codex exec`), signed in with the user's ChatGPT account.
///
/// Each call runs ephemerally in an empty temp directory with a read-only sandbox, the user's config
/// (and so its MCP servers), rules and hooks ignored, every tool-giving feature this version reports
/// switched off (plugins and apps included), Codex's coding-agent instructions and usage analytics
/// replaced or switched off, and the prompt on stdin.
public struct CodexCLIProvider: AIProvider {
    public let id = "codex"
    public let displayName = "Codex"
    let backend: CLIBackend

    public init(
        binaryPath: String? = nil, runner: any ProcessRunner = SystemProcessRunner(), locator: CLILocator? = nil,
        gate: CLIGate = .shared, environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let locator = locator ?? CLILocator(environment: environment, runner: runner)
        backend = CLIBackend(
            config: .init(name: "codex", displayName: "Codex", helpArguments: ["exec", "--help"], extraPaths: binaryPath.map { [$0] } ?? []),
            locator: locator, runner: runner, gate: gate, environment: environment)
    }

    public func availability(refresh: Bool) async -> AIAvailability {
        if !refresh, let cached = await backend.cachedAvailability() { return cached }
        let value: AIAvailability
        if await backend.binary() == nil {
            value = .notInstalled
        } else if let result = try? await backend.runCheck(["login", "status"]) {
            let output = (result.stdoutText + result.stderrText).lowercased()
            value = result.exitCode == 0 && !output.contains("not logged in") ? .ready : .signedOut
        } else {
            // The check itself failed; let the next call report what is wrong.
            value = .ready
        }
        await backend.remember(value)
        return value
    }

    /// Visible models from `codex debug models`, the fast one first.
    public func models() async -> [String] {
        await backend.memoized("models") {
            guard let result = try? await backend.runCheck(["debug", "models"], timeout: 20), result.exitCode == 0 else { return [] }
            return Self.models(fromCatalog: result.stdout)
        }
    }

    /// Features this version has switched on, from `codex features list`, read once.
    func enabledFeatures() async -> [String] {
        await backend.memoized("features") {
            guard let result = try? await backend.runCheck(["features", "list"]), result.exitCode == 0 else { return [] }
            return Self.enabledFeatures(inList: result.stdoutText)
        }
    }

    public func complete(_ request: AIRequest) async throws -> String {
        let flags = await backend.flags()
        let enabled = await enabledFeatures()
        var model = request.model
        if model == nil { model = await models().first }
        let directory = try CallDirectory()
        defer { directory.remove() }

        var schemaPath: String?
        if let schema = request.schema, flags.isEmpty || flags.contains("--output-schema") {
            let url = directory.file("schema.json")
            try Data(schema.utf8).write(to: url)
            schemaPath = url.path
        }
        let answerPath = directory.file("answer.txt").path
        let instructionsURL = directory.file("instructions.md")
        try Data(Self.baseInstructions.utf8).write(to: instructionsURL)
        let arguments = Self.arguments(
            model: model, effort: request.effort, workDirectory: directory.work.path, schemaPath: schemaPath,
            answerPath: answerPath, instructionsPath: instructionsURL.path, flags: flags, enabledFeatures: enabled)
        let stdin = Self.stdin(for: request, schemaEnforced: schemaPath != nil)

        let result = try await backend.runModel(
            arguments, stdin: stdin, directory: directory.work.path, timeout: request.timeout, background: request.isBackground)
        guard result.exitCode == 0 else {
            let error = CLIFailure.error(provider: displayName, exitCode: result.exitCode, output: result.stderrText + "\n" + result.stdoutText)
            if case .notSignedIn = error { await backend.invalidate() }
            throw error
        }
        let answer = ((try? String(contentsOfFile: answerPath, encoding: .utf8)) ?? result.stdoutText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw AIError.invalidOutput("Codex returned an empty answer.") }
        return answer
    }

    // MARK: Command line

    /// Features that give the agent tools, always switched off. Unknown names are ignored by `-c`, so
    /// older and newer versions both accept the list. Mail is untrusted input: a prompt-injected email
    /// must not get a shell, a browser, files, plugins or other agents. `--sandbox read-only` stops
    /// writes, not reads, so tools are switched off rather than sandboxed.
    static let disabledFeatures = [
        "shell_tool", "unified_exec", "unified_exec_tty", "apps", "plugins", "remote_plugin", "plugin_sharing",
        "hooks", "image_generation", "browser_use", "browser_use_external", "browser_use_full_cdp_access",
        "browser_annotation_api", "computer_use", "view_image", "memories", "web_search_request", "code_mode",
        "code_mode_host", "multi_agent", "multi_agent_v2", "in_app_browser", "in_app_local_automation",
        "workspace_dependencies", "skill_search", "skill_mcp_dependency_install", "tool_suggest",
        "tool_call_mcp_elicitation", "goals", "sleep_tool", "shell_snapshot", "worktrees",
        "standalone_web_search", "request_permissions_tool",
    ]

    /// Features left on when this version reports them enabled: how Codex reaches the model and signs
    /// in. Every other enabled feature is switched off, so a new tool in a later version starts off.
    static let allowedFeatures: Set<String> = [
        "api_key_cyber_access_programs", "api_key_model_discovery", "auth_elicitation", "compaction_image_budget",
        "content_item_kinds", "enable_request_compression", "fast_mode", "ultrafast_mode", "instant_interrupt",
        "respect_system_proxy", "secret_auth_storage", "system_proxy_fallback", "unbounded_connection_retries",
    ]

    /// Names marked `true` in `codex features list` ("name  stage  true|false" per line), except
    /// removed features, which no longer do anything.
    static func enabledFeatures(inList text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count >= 3, words.last == "true", !words.dropFirst().dropLast().contains("removed") else { return nil }
            let name = words[0]
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
            return String(name)
        }
    }

    /// The static floor plus every enabled feature that isn't allowed, in a stable order.
    static func featuresToDisable(enabled: [String]) -> [String] {
        var names = disabledFeatures
        var seen = Set(names)
        for name in enabled.sorted() where !allowedFeatures.contains(name) && seen.insert(name).inserted {
            names.append(name)
        }
        return names
    }

    /// Replaces Codex's own coding-agent instructions, about 3,500 tokens on every call that a mail
    /// request doesn't need. The request's instructions still lead the prompt, so a version that doesn't
    /// know `model_instructions_file` (it ignores unknown settings) gets the same rules.
    static let baseInstructions = """
        You answer requests from the Tern mail app. Follow the instructions in the user message exactly and \
        answer only in the format it asks for. You have no tools.
        """

    static func arguments(
        model: String?, effort: AIRequest.Effort, workDirectory: String, schemaPath: String?,
        answerPath: String, instructionsPath: String? = nil, flags: Set<String>, enabledFeatures: [String] = []
    ) -> [String] {
        // An unreadable help text means an unknown version: assume today's flags.
        let has = { (flag: String) in flags.isEmpty || flags.contains(flag) }
        var arguments = ["exec"]
        for flag in ["--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules"] where has(flag) {
            arguments.append(flag)
        }
        arguments += ["--sandbox", "read-only", "--color", "never", "--cd", workDirectory]
        if let model { arguments += ["--model", model] }
        arguments += [
            "-c", "model_reasoning_effort=\"\(effort == .fast ? "low" : "medium")\"",
            "-c", "approval_policy=\"never\"",
            "-c", "web_search=\"disabled\"",
            "-c", "tools.web_search=false",
            "-c", "tools.view_image=false",
            // Usage analytics and metrics go out when the process exits and add a second or more to every call.
            "-c", "analytics.enabled=false",
            "-c", "otel.metrics_exporter=\"none\"",
            // No sandbox or shell description: there are no tools to describe.
            "-c", "include_permissions_instructions=false",
            "-c", "include_environment_context=false",
        ]
        if let instructionsPath { arguments += ["-c", "model_instructions_file=\"\(instructionsPath)\""] }
        for feature in featuresToDisable(enabled: enabledFeatures) { arguments += ["-c", "features.\(feature)=false"] }
        if let schemaPath { arguments += ["--output-schema", schemaPath] }
        if has("--output-last-message") { arguments += ["--output-last-message", answerPath] }
        arguments.append("-")
        return arguments
    }

    /// Codex has no separate system prompt in exec mode, so instructions lead the stdin text.
    static func stdin(for request: AIRequest, schemaEnforced: Bool) -> String {
        var parts: [String] = []
        if !request.instructions.isEmpty { parts.append(request.instructions) }
        if let schema = request.schema, !schemaEnforced {
            parts.append("Answer with JSON only, matching this JSON Schema:\n\(schema)")
        }
        parts.append(request.input)
        return parts.joined(separator: "\n\n")
    }

    /// Slugs of listed models, fastest-looking first, then by the catalog's own priority.
    static func models(fromCatalog data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let entries = ((root as? [String: Any])?["models"] as? [[String: Any]]) ?? (root as? [[String: Any]]) ?? []
        struct Entry { var slug: String; var priority: Int; var fast: Bool }
        let listed: [Entry] = entries.compactMap { entry in
            guard let slug = entry["slug"] as? String, (entry["visibility"] as? String ?? "list") == "list" else { return nil }
            let text = ((entry["description"] as? String ?? "") + " " + slug).lowercased()
            let fast = (text.contains("fast") || text.contains("mini")) && !text.contains("older") && !text.contains("previous")
            return Entry(slug: slug, priority: entry["priority"] as? Int ?? 999, fast: fast)
        }
        return listed.sorted { ($0.fast ? 0 : 1, $0.priority) < ($1.fast ? 0 : 1, $1.priority) }.map(\.slug)
    }
}
