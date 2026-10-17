import Foundation
import Testing
@testable import TernAI

private let codexHelp = """
    Usage: codex exec [OPTIONS] [PROMPT]
      -c, --config <key=value>
      -m, --model <MODEL>
      -s, --sandbox <SANDBOX_MODE>
      -C, --cd <DIR>
          --skip-git-repo-check
          --ephemeral
          --ignore-user-config
          --ignore-rules
          --output-schema <FILE>
          --color <COLOR>
      -o, --output-last-message <FILE>
    """

private let claudeHelp = """
    Usage: claude [options] [command] [prompt]
      --disable-slash-commands
      --json-schema <schema>
      --model <model>
      --no-session-persistence
      --output-format <format>
      -p, --print
      --setting-sources <sources>
      --settings <file-or-json>
      --strict-mcp-config
      --system-prompt <prompt>
      --tools <tools...>
    Commands:
      auth                                  Manage authentication
      doctor                                Check the health
    """

private let catalog = """
    {"models":[
      {"slug":"big-model","visibility":"list","priority":1,"description":"Latest workhorse model."},
      {"slug":"old-fast","visibility":"list","priority":9,"description":"Older fast and efficient model."},
      {"slug":"quick-model","visibility":"list","priority":4,"description":"Fast and affordable model for easier tasks."},
      {"slug":"hidden","visibility":"hide","priority":2,"description":"Fast internal model."}
    ]}
    """

private let userEnvironment: [String: String] = [
    "HOME": "/Users/test", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
    "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "sdk-ts", "CLAUDE_CODE_SESSION_ID": "abc",
    "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/s", "CLAUDE_PID": "42", "CLAUDE_AGENT_SDK_VERSION": "1",
    "CLAUDE_CODE_USE_BEDROCK": "1", "ANTHROPIC_API_KEY": "kept", "CODEX_SANDBOX": "seatbelt", "CODEX_HOME": "/Users/test/.codex",
]

private func locator(_ runner: FakeRunner, installed: Set<String>) -> CLILocator {
    CLILocator(
        home: "/Users/test", environment: userEnvironment, isExecutable: { installed.contains($0) },
        listDirectory: { _ in [] }, runner: runner)
}

private func directoryIsEmpty(_ path: String) -> Bool {
    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? ["missing"]).isEmpty
}

@Test func codexArgumentsAreExact() {
    let arguments = CodexCLIProvider.arguments(
        model: "quick-model", effort: .fast, workDirectory: "/tmp/x/work", schemaPath: "/tmp/x/schema.json",
        answerPath: "/tmp/x/answer.txt", flags: CLIBackend.flags(in: codexHelp))
    var expected: [String] = [
        "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
        "--sandbox", "read-only", "--color", "never", "--cd", "/tmp/x/work", "--model", "quick-model",
        "-c", #"model_reasoning_effort="low""#, "-c", #"approval_policy="never""#, "-c", #"web_search="disabled""#,
        "-c", "tools.web_search=false", "-c", "tools.view_image=false",
    ]
    for feature in CodexCLIProvider.disabledFeatures { expected += ["-c", "features.\(feature)=false"] }
    expected += ["--output-schema", "/tmp/x/schema.json", "--output-last-message", "/tmp/x/answer.txt", "-"]
    #expect(arguments == expected)
    // An older version without the optional flags still gets the sandbox and stdin prompt.
    let old = CodexCLIProvider.arguments(
        model: nil, effort: .careful, workDirectory: "/w", schemaPath: nil, answerPath: "/a",
        flags: ["--sandbox", "--cd", "--model", "--config", "--color"])
    #expect(!old.contains("--ephemeral") && !old.contains("--output-last-message") && !old.contains("--model"))
    #expect(old.contains(#"model_reasoning_effort="medium""#))
    #expect(old.last == "-")
}

private let codexFeatures = """
    apps                                     stable             true
    api_key_model_discovery                  stable             true
    brand_new_agent_tool                     stable             true
    code_mode_host                           stable             true
    enable_request_compression               stable             true
    goals                                    stable             true
    memories                                 stable             false
    multi_agent                              stable             true
    sqlite                                   removed            true
    shiny_preview_tool                       under development  true
    some.odd=name                            stable             true
    """

@Test func codexSwitchesOffEveryEnabledFeatureOutsideTheAllowList() {
    let enabled = CodexCLIProvider.enabledFeatures(inList: codexFeatures)
    #expect(enabled == ["apps", "api_key_model_discovery", "brand_new_agent_tool", "code_mode_host",
                        "enable_request_compression", "goals", "multi_agent", "shiny_preview_tool"])
    let arguments = CodexCLIProvider.arguments(
        model: nil, effort: .fast, workDirectory: "/w", schemaPath: nil, answerPath: "/a",
        flags: CLIBackend.flags(in: codexHelp), enabledFeatures: enabled)
    let disabled = Set(stride(from: 0, to: arguments.count - 1, by: 1).compactMap { index -> String? in
        guard arguments[index] == "-c", arguments[index + 1].hasPrefix("features."), arguments[index + 1].hasSuffix("=false") else { return nil }
        return String(arguments[index + 1].dropFirst("features.".count).dropLast("=false".count))
    })
    for name in ["brand_new_agent_tool", "shiny_preview_tool", "code_mode_host", "multi_agent", "goals", "apps"] {
        #expect(disabled.contains(name), "\(name) stays on")
    }
    #expect(!disabled.contains("api_key_model_discovery") && !disabled.contains("enable_request_compression"))
    #expect(!disabled.contains("sqlite"), "removed features do nothing")
    #expect(!arguments.contains { $0.contains("some.odd") })
    #expect(disabled.isSuperset(of: CodexCLIProvider.disabledFeatures), "the static list is a floor")
    #expect(CodexCLIProvider.arguments(
        model: nil, effort: .fast, workDirectory: "/w", schemaPath: nil, answerPath: "/a", flags: [], enabledFeatures: enabled
    ).filter { $0.hasPrefix("features.") }.count == disabled.count, "same list whatever the help text says")
}

@Test func codexCallRunsInEmptyDirectoryWithPromptOnStdin() async throws {
    let runner = FakeRunner { invocation in
        switch invocation.arguments.first {
        case "exec" where invocation.arguments == ["exec", "--help"]:
            return ProcessResult(exitCode: 0, stdout: codexHelp)
        case "debug":
            return ProcessResult(exitCode: 0, stdout: catalog)
        case "features":
            return ProcessResult(exitCode: 0, stdout: codexFeatures)
        default:
            let arguments = invocation.arguments
            #expect(directoryIsEmpty(try #require(invocation.currentDirectory)))
            let schemaPath = arguments[try #require(arguments.firstIndex(of: "--output-schema")) + 1]
            #expect(try String(contentsOfFile: schemaPath, encoding: .utf8) == #"{"type":"object"}"#)
            let answerPath = arguments[try #require(arguments.firstIndex(of: "--output-last-message")) + 1]
            try #"{"ok":true}"#.write(toFile: answerPath, atomically: true, encoding: .utf8)
            return ProcessResult(exitCode: 0, stdout: "ignored", stderr: "user\nsecret mail text")
        }
    }
    let provider = CodexCLIProvider(runner: runner, locator: locator(runner, installed: ["/opt/homebrew/bin/codex"]), gate: CLIGate(limit: 2), environment: userEnvironment)
    let answer = try await provider.complete(AIRequest(
        instructions: "Classify.", input: "SECRET MAIL BODY", schema: #"{"type":"object"}"#, timeout: 42))
    #expect(answer == #"{"ok":true}"#)

    let call = try #require(runner.invocations.last)
    #expect(call.executable == "/opt/homebrew/bin/codex")
    #expect(call.arguments.contains("quick-model"))
    #expect(call.arguments.contains("features.brand_new_agent_tool=false"), "features the installed version reports are switched off")
    #expect(!call.arguments.joined(separator: " ").contains("SECRET"))
    #expect(String(decoding: try #require(call.stdin), as: UTF8.self) == "Classify.\n\nSECRET MAIL BODY")
    #expect(runner.timeouts.last == 42)
    #expect(!FileManager.default.fileExists(atPath: try #require(call.currentDirectory)))
}

@Test func childEnvironmentDropsSessionMarkers() async throws {
    let runner = FakeRunner { _ in ProcessResult(exitCode: 0, stdout: "Logged in using ChatGPT") }
    let provider = CodexCLIProvider(runner: runner, locator: locator(runner, installed: ["/Users/test/.bun/bin/codex"]), environment: userEnvironment)
    #expect(await provider.availability(refresh: true) == .ready)
    let environment = try #require(runner.invocations.first).environment
    for dropped in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET",
                    "CLAUDE_PID", "CLAUDE_AGENT_SDK_VERSION", "CODEX_SANDBOX"] {
        #expect(environment[dropped] == nil, "\(dropped)")
    }
    #expect(environment["CLAUDE_CODE_USE_BEDROCK"] == "1")
    #expect(environment["ANTHROPIC_API_KEY"] == "kept")
    #expect(environment["CODEX_HOME"] == "/Users/test/.codex")
    #expect(environment["HOME"] == "/Users/test")
    #expect(environment["NO_COLOR"] == "1")
    let path = try #require(environment["PATH"]).split(separator: ":").map(String.init)
    #expect(path.first == "/Users/test/.bun/bin")
    #expect(path.contains("/opt/homebrew/bin") && path.contains("/usr/bin"))
}

@Test func codexAvailabilityIsCachedAndDetectsSignOut() async throws {
    let runner = FakeRunner { _ in ProcessResult(exitCode: 1, stdout: "", stderr: "Not logged in") }
    let provider = CodexCLIProvider(runner: runner, locator: locator(runner, installed: ["/usr/local/bin/codex"]), environment: userEnvironment)
    #expect(await provider.availability(refresh: false) == .signedOut)
    #expect(await provider.availability(refresh: false) == .signedOut)
    #expect(runner.invocations.count == 1)
    #expect(runner.invocations[0].arguments == ["login", "status"])

    let missing = CodexCLIProvider(runner: runner, locator: locator(runner, installed: []), environment: userEnvironment)
    #expect(await missing.availability(refresh: true) == .notInstalled)
    await #expect(throws: AIError.notInstalled(provider: "Codex")) {
        try await missing.complete(AIRequest(instructions: "", input: "x"))
    }
}

@Test func codexModelsPutTheFastOneFirst() {
    #expect(CodexCLIProvider.models(fromCatalog: Data(catalog.utf8)) == ["quick-model", "big-model", "old-fast"])
}

@Test func codexFailuresMapToErrorsWithoutMail() async throws {
    let outputs = [
        "user\nplease unsubscribe me 401\nERROR: unexpected status 429 Too Many Requests: usage limit reached",
        "user\nhello\nERROR: unexpected status 401 Unauthorized",
        "user\nrate limit in the mail body\nERROR: stream disconnected",
    ]
    var errors: [AIError] = []
    for output in outputs {
        let runner = FakeRunner { invocation in
            invocation.arguments.contains("--help") ? ProcessResult(exitCode: 0, stdout: codexHelp)
                : ProcessResult(exitCode: 1, stdout: "", stderr: output)
        }
        let provider = CodexCLIProvider(runner: runner, locator: locator(runner, installed: ["/opt/homebrew/bin/codex"]), environment: userEnvironment)
        do {
            _ = try await provider.complete(AIRequest(instructions: "", input: "x", model: "m"))
        } catch let error as AIError {
            errors.append(error)
        }
    }
    #expect(errors == [
        .rateLimited("ERROR: unexpected status 429 Too Many Requests: usage limit reached"),
        .notSignedIn(provider: "Codex"),
        .failed("Codex: ERROR: stream disconnected"),
    ])
}

@Test func claudeArgumentsAreExact() {
    let request = AIRequest(instructions: "Sort these.", input: "mail", schema: #"{"type":"object"}"#)
    #expect(ClaudeCLIProvider.arguments(for: request, flags: CLIBackend.flags(in: claudeHelp)) == [
        "-p", "--model", "haiku", "--output-format", "json", "--json-schema", #"{"type":"object"}"#,
        "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands",
        "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#, "--system-prompt", "Sort these.",
    ])
    #expect(ClaudeCLIProvider.stdin(for: request, flags: CLIBackend.flags(in: claudeHelp)) == "mail")

    let old = ["-p", "--print", "--model", "--output-format", "--disallowedTools"]
    let oldArguments = ClaudeCLIProvider.arguments(for: request, flags: Set(old))
    #expect(oldArguments.contains("--disallowedTools") && !oldArguments.contains("--tools"))
    let oldStdin = ClaudeCLIProvider.stdin(for: request, flags: Set(old))
    #expect(oldStdin.hasPrefix("Sort these.") && oldStdin.contains("JSON Schema") && oldStdin.hasSuffix("mail"))
}

@Test func claudeReadsStructuredOutputAndErrors() async throws {
    let ok = ProcessResult(exitCode: 0, stdout: #"{"type":"result","is_error":false,"result":"text","structured_output":{"items":[1]}}"#)
    #expect(try ClaudeCLIProvider.answer(from: ok, provider: "Claude Code") == #"{"items":[1]}"#)
    let plain = ProcessResult(exitCode: 0, stdout: #"{"type":"result","is_error":false,"result":"  hi  "}"#)
    #expect(try ClaudeCLIProvider.answer(from: plain, provider: "Claude Code") == "hi")

    let limited = ProcessResult(exitCode: 1, stdout: #"{"is_error":true,"result":"Claude AI usage limit reached|1800000000"}"#)
    #expect(throws: AIError.rateLimited("Error: Claude AI usage limit reached|1800000000")) {
        try ClaudeCLIProvider.answer(from: limited, provider: "Claude Code")
    }
    for message in ["Invalid API key · Please run /login", "Failed to authenticate: OAuth session expired and could not be refreshed"] {
        let signedOut = ProcessResult(exitCode: 1, stdout: Data(#"{"is_error":true,"result":"\#(message)"}"#.utf8))
        #expect(throws: AIError.notSignedIn(provider: "Claude Code")) {
            try ClaudeCLIProvider.answer(from: signedOut, provider: "Claude Code")
        }
    }
}

@Test func claudeCallAndAvailability() async throws {
    let runner = FakeRunner { invocation in
        switch invocation.arguments {
        case ["--help"]: return ProcessResult(exitCode: 0, stdout: claudeHelp)
        case ["auth", "status", "--json"]: return ProcessResult(exitCode: 0, stdout: #"{"loggedIn":true,"authMethod":"claude.ai"}"#)
        default: return ProcessResult(exitCode: 0, stdout: #"{"is_error":false,"result":"","structured_output":{"bullets":["a"]}}"#)
        }
    }
    let provider = ClaudeCLIProvider(runner: runner, locator: locator(runner, installed: ["/Users/test/.local/bin/claude"]), environment: userEnvironment)
    #expect(await provider.availability(refresh: true) == .ready)
    let answer = try await provider.complete(AIRequest(instructions: "Summarize.", input: "MAIL", schema: "{}", model: "sonnet"))
    #expect(answer == #"{"bullets":["a"]}"#)
    let call = try #require(runner.invocations.last)
    #expect(call.arguments[0...2] == ["-p", "--model", "sonnet"])
    #expect(String(decoding: try #require(call.stdin), as: UTF8.self) == "MAIL")
    #expect(call.environment["CLAUDECODE"] == nil && call.environment["CLAUDE_CODE_ENTRYPOINT"] == nil)

    // Without an auth command in the help, availability is not probed (it would start a session).
    let oldRunner = FakeRunner { _ in ProcessResult(exitCode: 0, stdout: "Usage: claude [options]") }
    let old = ClaudeCLIProvider(runner: oldRunner, locator: locator(oldRunner, installed: ["/Users/test/.claude/local/claude"]), environment: userEnvironment)
    #expect(await old.availability(refresh: true) == .ready)
    #expect(oldRunner.invocations.map(\.arguments) == [["--help"]])
}

@Test func locatorSearchOrderAndShellFallback() async throws {
    let runner = FakeRunner { invocation in
        #expect(invocation.executable == "/bin/zsh")
        #expect(invocation.arguments == ["-lc", "command -v codex"])
        return ProcessResult(exitCode: 0, stdout: "Welcome banner\n/Users/test/tools/codex\n")
    }
    var finder = CLILocator(
        home: "/Users/test", environment: ["PATH": "/custom/bin:/usr/bin"], isExecutable: { $0 == "/Users/test/tools/codex" },
        listDirectory: { $0 == "/Users/test/.nvm/versions/node" ? ["v18.19.0", "v20.11.1", "v9.0.0"] : [] }, runner: runner)
    #expect(await finder.locate("codex") == "/Users/test/tools/codex")

    let directories = finder.searchDirectories()
    #expect(directories.prefix(3) == ["/custom/bin", "/usr/bin", "/opt/homebrew/bin"])
    let nvm = directories.filter { $0.contains(".nvm") }
    #expect(nvm == ["/Users/test/.nvm/versions/node/v20.11.1/bin", "/Users/test/.nvm/versions/node/v18.19.0/bin", "/Users/test/.nvm/versions/node/v9.0.0/bin"])

    let installed: Set<String> = ["/Users/test/.nvm/versions/node/v20.11.1/bin/codex", "/Users/test/.volta/bin/codex"]
    finder.isExecutable = { installed.contains($0) }
    #expect(await finder.locate("codex") == "/Users/test/.volta/bin/codex")
    #expect(runner.invocations.count == 1)
    #expect(await finder.locate("bad name;rm") == nil)
}

@Test func providersResolveFromSettings() async throws {
    let codex = FakeProvider(id: "codex", availability: .signedOut) { _, _ in "" }
    let claude = FakeProvider(id: "claude") { _, _ in "" }
    let providers = AIProviders([codex, claude])
    await #expect(throws: AIError.disabled) { try await providers.resolve(AISettings(enabled: false)) }
    await #expect(throws: AIError.notSignedIn(provider: "codex")) { try await providers.resolve(AISettings(enabled: true, provider: "codex")) }
    #expect(try await providers.resolve(AISettings(enabled: true)).id == "claude")
    #expect(try await providers.resolve(AISettings(enabled: true, provider: "claude")).id == "claude")
    #expect(AISettings(enabled: true, provider: "claude", model: "sonnet").model(for: claude) == "sonnet")
    #expect(AISettings(enabled: true, provider: "codex", model: "gpt-x").model(for: claude) == nil)
}

@Test func settingsRoundTrip() throws {
    let database = try makeDatabase([], settings: nil)
    #expect(try database.reader.read { db in try AISettings.read(db) } == AISettings())
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('ai.enabled', '1'), ('ai.provider', 'Claude'), ('ai.model', ' ')")
    }
    #expect(try database.reader.read { db in try AISettings.read(db) } == AISettings(enabled: true, provider: "claude"))
    let settings = AISettings(enabled: true, provider: "codex", model: "quick-model", autoProjects: true)
    try database.writer.write { db in try settings.write(db) }
    #expect(try database.reader.read { db in try AISettings.read(db) } == settings)
}
