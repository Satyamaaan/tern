import Foundation
import GRDB
import TernCore

/// AI settings, stored in the `setting` table. Booleans are written "true"/"false"; "1"/"0" also read.
public struct AISettings: Hashable, Sendable {
    /// Master switch: an explicit false prevents all model calls.
    public static let enabledKey = "ai.enabled"
    /// Provider id. Unset prefers Groq with a key, then the first ready CLI.
    public static let providerKey = "ai.provider"
    /// Model id or alias for the provider. Unset uses its fast default.
    public static let modelKey = "ai.model"
    /// Let the classifier put threads in projects (`thread_project` source `.ai`).
    public static let autoProjectsKey = "ai.autoProjects"

    /// Nil means the master switch has never been saved. A Groq key then enables AI.
    public var explicitEnabled: Bool?
    /// Explicit switch value, or false when unset. Use `isEnabled(groqKeyPresent:)` for runtime policy.
    public var enabled: Bool {
        get { explicitEnabled ?? false }
        set { explicitEnabled = newValue }
    }

    /// Resolves the unsaved master switch without accessing credentials in the database layer.
    public func isEnabled(groqKeyPresent: Bool) -> Bool { explicitEnabled ?? groqKeyPresent }
    public var provider: String?
    public var model: String?
    public var autoProjects = false

    public init(enabled: Bool? = nil, provider: String? = nil, model: String? = nil, autoProjects: Bool = false) {
        self.explicitEnabled = enabled
        self.provider = provider
        self.model = model
        self.autoProjects = autoProjects
    }

    public static func read(_ db: Database) throws -> AISettings {
        var values: [String: String] = [:]
        for setting in try Setting.filter([enabledKey, providerKey, modelKey, autoProjectsKey].contains(Column("key"))).fetchAll(db) {
            values[setting.key] = setting.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return AISettings(
            enabled: values[enabledKey].map { flag($0) },
            provider: values[providerKey].flatMap { $0.isEmpty ? nil : $0.lowercased() },
            model: values[modelKey].flatMap { $0.isEmpty ? nil : $0 },
            autoProjects: flag(values[autoProjectsKey]))
    }

    public func write(_ db: Database) throws {
        if let explicitEnabled {
            try Setting(key: Self.enabledKey, value: explicitEnabled ? "true" : "false").upsert(db)
        } else { _ = try Setting.deleteOne(db, key: Self.enabledKey) }
        try Setting(key: Self.autoProjectsKey, value: autoProjects ? "true" : "false").upsert(db)
        for (key, value) in [(Self.providerKey, provider), (Self.modelKey, model)] {
            if let value { try Setting(key: key, value: value).upsert(db) } else { _ = try Setting.deleteOne(db, key: key) }
        }
    }

    /// `model` only applies to the provider it was picked for.
    public func model(for provider: any AIProvider) -> String? {
        self.provider == provider.id ? model : nil
    }

    private static func flag(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["true", "1", "yes", "on"].contains(value.lowercased())
    }
}

/// The installed providers, and which one the settings select.
public struct AIProviders: Sendable {
    public static let shared = AIProviders([GroqProvider(), CodexCLIProvider(), ClaudeCLIProvider()])

    public let all: [any AIProvider]

    public init(_ providers: [any AIProvider]) {
        all = providers
    }

    public func provider(id: String) -> (any AIProvider)? {
        all.first { $0.id == id }
    }

    /// Applies the default only when no explicit enabled value was saved.
    public func isEnabled(_ settings: AISettings) async -> Bool {
        if let explicit = settings.explicitEnabled { return explicit }
        let ready = await provider(id: "groq")?.availability(refresh: false) == .ready
        return settings.isEnabled(groqKeyPresent: ready)
    }

    /// An explicit provider wins; otherwise prefer Groq, then the first ready CLI.
    public func resolve(_ settings: AISettings) async throws -> any AIProvider {
        guard await isEnabled(settings) else { throw AIError.disabled }
        if let id = settings.provider {
            guard let provider = provider(id: id) else { throw AIError.failed("The selected AI provider is unavailable.") }
            switch await provider.availability(refresh: false) {
            case .ready: return provider
            case .notInstalled: throw AIError.notInstalled(provider: provider.displayName)
            case .signedOut: throw AIError.notSignedIn(provider: provider.displayName)
            }
        }
        let ordered = all.filter { $0.id == "groq" } + all.filter { $0.id != "groq" }
        for provider in ordered where await provider.availability(refresh: false) == .ready {
            return provider
        }
        throw AIError.notInstalled(provider: "Codex or Claude Code")
    }
}
