import Foundation

/// OpenAI Codex CLI (`codex exec`), signed in with the user's ChatGPT account.
///
/// Each call runs ephemerally in an empty temp directory with a read-only sandbox, the user's config,
/// rules and hooks ignored, shell and other tools switched off, and the prompt on stdin.
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

    public func complete(_ request: AIRequest) async throws -> String {
        let flags = await backend.flags()
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
        let arguments = Self.arguments(
            model: model, effort: request.effort, workDirectory: directory.work.path,
            schemaPath: schemaPath, answerPath: answerPath, flags: flags)
        let stdin = Self.stdin(for: request, schemaEnforced: schemaPath != nil)

        let result = try await backend.runModel(arguments, stdin: stdin, directory: directory.work.path, timeout: request.timeout)
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

    /// Features that give the agent tools. Unknown names are ignored by `-c`, so older and newer
    /// versions both accept the list.
    static let disabledFeatures = [
        "shell_tool", "unified_exec", "apps", "plugins", "hooks", "image_generation", "browser_use",
        "computer_use", "view_image", "memories", "web_search_request",
    ]

    static func arguments(
        model: String?, effort: AIRequest.Effort, workDirectory: String, schemaPath: String?,
        answerPath: String, flags: Set<String>
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
        ]
        for feature in disabledFeatures { arguments += ["-c", "features.\(feature)=false"] }
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
