import Foundation
import Testing
@testable import Tern
import TernAI

// Settings → AI: the line that says what AI sorting is doing.

private func sorting(_ state: TriageQueue.State, progress: TriageQueue.Progress? = nil) -> AISorting {
    AISorting(status: TriageQueue.Status(state: state, classified: 0, lastError: nil, progress: progress))
}

@Test func aiSortingLineSaysHowFarItGot() {
    #expect(sorting(.working, progress: .init(done: 120, total: 800)).line() == "Sorting 120 of 800")
    #expect(sorting(.working, progress: .init(done: 1_200, total: 4_500)).line() == "Sorting \(1_200.formatted()) of \(4_500.formatted())")
    #expect(sorting(.working).line() == "Sorting")
    #expect(sorting(.idle).line() == "Up to date")
    #expect(!sorting(.off).isShown && sorting(.idle).isShown)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let paused = sorting(.waiting(until: now.addingTimeInterval(300), reason: "Usage limit reached"))
    #expect(paused.line(now: now).hasPrefix("Paused until "))
    #expect(paused.line(now: now.addingTimeInterval(400)) == "Resuming")
    #expect(paused.reason == "Usage limit reached")
    #expect(sorting(.unavailable("Codex isn't signed in.")).reason == "Codex isn't signed in.")
}
