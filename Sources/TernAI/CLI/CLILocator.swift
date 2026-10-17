import Foundation

/// Finds a CLI binary. A GUI app doesn't get the user's shell PATH, so this searches the usual
/// install locations first and asks a login shell only as a last resort.
public struct CLILocator: Sendable {
    public var home: String
    public var environment: [String: String]
    public var isExecutable: @Sendable (String) -> Bool
    public var listDirectory: @Sendable (String) -> [String]
    public var runner: any ProcessRunner

    public init(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        listDirectory: @escaping @Sendable (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
        runner: any ProcessRunner = SystemProcessRunner()
    ) {
        self.home = home
        self.environment = environment
        self.isExecutable = isExecutable
        self.listDirectory = listDirectory
        self.runner = runner
    }

    /// Directories where package managers put CLIs, in search order.
    public func searchDirectories() -> [String] {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
            "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.yarn/bin", "\(home)/Library/pnpm",
            "\(home)/.local/share/pnpm", "\(home)/.asdf/shims", "\(home)/.local/share/mise/shims",
            "\(home)/.cargo/bin", "/opt/local/bin",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        let versions = listDirectory(nvm).filter { $0.hasPrefix("v") }.sorted { Self.isNewer($0, than: $1) }
        directories += versions.map { "\(nvm)/\($0)/bin" }
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Absolute path of `name`, or nil when it isn't installed. `extraPaths` are checked first.
    public func locate(_ name: String, extraPaths: [String] = []) async -> String? {
        for path in extraPaths + searchDirectories().map({ "\($0)/\(name)" }) where isExecutable(path) {
            return path
        }
        return await loginShellLookup(name)
    }

    /// PATH for the child: the binary's own directory (node shims need their `node`), the known
    /// install locations, then the inherited PATH.
    public func childPath(for binary: String) -> String {
        let own = URL(fileURLWithPath: binary).deletingLastPathComponent().path
        var seen = Set<String>()
        return ([own] + searchDirectories() + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private func loginShellLookup(_ name: String) async -> String? {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let invocation = ProcessInvocation(
            executable: "/bin/zsh", arguments: ["-lc", "command -v \(name)"],
            environment: ["HOME": home, "USER": environment["USER"] ?? "", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        guard let result = try? await runner.run(invocation, timeout: 5), result.exitCode == 0 else { return nil }
        let path = result.stdoutText.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return path.hasPrefix("/") && isExecutable(path) ? path : nil
    }

    /// "v20.11.1" is newer than "v18.19.0".
    private static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (s: String) in s.dropFirst().split(separator: ".").map { Int($0) ?? 0 } }
        return parse(b).lexicographicallyPrecedes(parse(a))
    }
}

/// The environment a CLI child gets: the user's own, minus the variables that make Claude Code or
/// Codex think they are running nested inside another agent session.
public enum CLIEnvironment {
    /// Claude Code settings that select a provider or credentials; every other CLAUDE_CODE_* variable
    /// describes a running session and is dropped.
    static let keptClaudeCodeVariables: Set<String> = [
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_SKIP_BEDROCK_AUTH", "CLAUDE_CODE_SKIP_VERTEX_AUTH", "CLAUDE_CODE_SKIP_FOUNDRY_AUTH",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_CLIENT_CERT", "CLAUDE_CODE_CLIENT_KEY",
        "CLAUDE_CODE_CLIENT_KEY_PASSPHRASE", "CLAUDE_CODE_API_KEY_HELPER_TTL_MS",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_MAX_OUTPUT_TOKENS",
    ]

    /// Session markers set by a parent Claude Code or Codex process.
    static let droppedVariables: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_AGENT_SDK_VERSION",
        "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_THREAD_ID",
    ]

    public static func child(of base: [String: String], path: String) -> [String: String] {
        var environment = base.filter { name, _ in
            if droppedVariables.contains(name) { return false }
            if name.hasPrefix("CLAUDE_CODE_") { return keptClaudeCodeVariables.contains(name) }
            return true
        }
        environment["PATH"] = path
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        return environment
    }
}
