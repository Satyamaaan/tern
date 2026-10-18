// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tern",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Tern", targets: ["Tern"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0"),
        // Auto-update: signed downloads (EdDSA + code signature checks) and an atomic replace and relaunch of
        // the running app. Tern draws its own update window (see Updates/).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Models, SQLite schema, local store, search, fake mailbox. No networking, no UI.
        .target(
            name: "TernCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Google sign-in, Gmail API client, sync engine, pending-action queue.
        .target(
            name: "TernSync",
            dependencies: ["TernCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Classification, summaries and reply drafts through the local Codex / Claude CLI.
        .target(name: "TernAI", dependencies: ["TernCore"]),
        // The Mac app.
        .executableTarget(
            name: "Tern",
            dependencies: ["TernCore", "TernSync", "TernAI", .product(name: "Sparkle", package: "Sparkle")]
        ),
        // Writes a fake mailbox database for UI work and speed tests.
        .executableTarget(name: "tern-seed", dependencies: ["TernCore"]),
        .testTarget(name: "TernCoreTests", dependencies: ["TernCore"]),
        .testTarget(name: "TernSyncTests", dependencies: ["TernSync"]),
        .testTarget(name: "TernAITests", dependencies: ["TernAI"]),
        // Composer editor tests and offscreen snapshots (TERN_SHOTS=1); needs the app module.
        .testTarget(name: "TernComposeTests", dependencies: ["Tern", "TernCore"]),
    ],
    swiftLanguageModes: [.v5]
)
