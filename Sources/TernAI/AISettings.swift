import Foundation
import GRDB
import TernCore

/// AI settings, stored in the `setting` table. Booleans are written "true"/"false"; "1"/"0" also read.
public struct AISettings: Hashable, Sendable {
    /// Master switch: nothing is sent to a CLI while this is off.
    public static let enabledKey = "ai.enabled"
    /// "codex" or "claude". Unset picks the first installed and signed-in one.
    public static let providerKey = "ai.provider"
    /// Model id or alias for the provider. Unset uses its fast default.
    public static let modelKey = "ai.model"
    /// Let the classifier put threads in projects (`thread_project` source `.ai`).
    public static let autoProjectsKey = "ai.autoProjects"

    public var enabled = false
    public var provider: String?
    public var model: String?
    public var autoProjects = false

    public init(enabled: Bool = false, provider: String? = nil, model: String? = nil, autoProjects: Bool = false) {
        self.enabled = enabled
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
            enabled: flag(values[enabledKey]),
            provider: values[providerKey].flatMap { $0.isEmpty ? nil : $0.lowercased() },
            model: values[modelKey].flatMap { $0.isEmpty ? nil : $0 },
            autoProjects: flag(values[autoProjectsKey]))
    }

    public func write(_ db: Database) throws {
        try Setting(key: Self.enabledKey, value: enabled ? "true" : "false").upsert(db)
        try Setting(key: Self.autoProjectsKey, value: autoProjects ? "true" : "false").upsert(db)
        for (key, value) in [(Self.providerKey, provider), (Self.modelKey, model)] {
            if let value { try Setting(key: key, value: value).upsert(db) } else { _ = try Setting.deleteOne(db, key: key) }
        }
    }

    private static func flag(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["true", "1", "yes", "on"].contains(value.lowercased())
    }
}

/// The installed providers, and which one the settings select.
public struct AIProviders: Sendable {
    public static let shared = AIProviders([CodexCLIProvider(), ClaudeCLIProvider()])

    public let all: [any AIProvider]

    public init(_ providers: [any AIProvider]) {
        all = providers
    }

    public func provider(id: String) -> (any AIProvider)? {
        all.first { $0.id == id }
    }

    /// The provider the settings name, or the first ready one. Throws when AI is off or nothing is usable.
    public func resolve(_ settings: AISettings) async throws -> any AIProvider {
        guard settings.enabled else { throw AIError.disabled }
        if let id = settings.provider, let provider = provider(id: id) {
            switch await provider.availability(refresh: false) {
            case .ready: return provider
            case .notInstalled: throw AIError.notInstalled(provider: provider.displayName)
            case .signedOut: throw AIError.notSignedIn(provider: provider.displayName)
            }
        }
        for provider in all where await provider.availability(refresh: false) == .ready {
            return provider
        }
        throw AIError.notInstalled(provider: "Codex or Claude Code")
    }
}
