import Foundation
import TernCore

// Usage: tern-seed [--out PATH] [--messages N] [--seed N]
var arguments = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let url = value("--out").map { URL(fileURLWithPath: $0) } ?? AppDatabase.defaultURL(name: "Tern-Fake")
let count = value("--messages").flatMap(Int.init) ?? 50_000
let seed = value("--seed").flatMap(UInt64.init) ?? 7

for suffix in ["", "-wal", "-shm"] {
    try? FileManager.default.removeItem(atPath: url.path + suffix)
}
let database = try AppDatabase.open(at: url)
let summary = try FakeMailbox.populate(database, options: .init(messages: count, seed: seed, ledgerGold: value("--ledger-gold").flatMap(Int.init) ?? 0))
print("Wrote \(summary.messages) messages in \(summary.threads) threads to \(url.path) in \(String(format: "%.1f", summary.seconds)) s")

if let aiGold = value("--ledger-ai-gold").flatMap(Int.init), aiGold > 0 {
    let gold = try FakeMailbox.populateLedgerAIGold(database, count: aiGold)
    let sidecar = url.deletingPathExtension().appendingPathExtension("ledger-gold.json")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(gold).write(to: sidecar)
    print("Added \(gold.count) AI ledger gold threads; labels at \(sidecar.path)")
}
