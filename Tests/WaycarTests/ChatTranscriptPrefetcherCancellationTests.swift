import Foundation
import Testing

@testable import Waycar

@MainActor
struct ChatTranscriptPrefetcherCancellationTests {
    @Test func cancelledReaderUnavailableDoesNotCoolDownTheHost() async throws {
        let host = UUID()
        func agent(_ pane: String) -> ConsoleAgent {
            ConsoleAgent(
                hostID: host, hostName: "host",
                agent: Agent(terminalID: pane, kind: "claude", title: "Task", status: .done,
                             workspaceID: "w", tabID: "tab", paneID: pane, cwd: "/", revision: 1),
                workspaceLabel: nil, repositoryCheckout: nil)
        }
        var agents = [agent("old")]
        var continuation: CheckedContinuation<Void, Never>?
        var returned = false
        var failureObserved = false
        var fetched: [String] = []
        let prefetcher = ChatTranscriptPrefetcher(source: .init(
            isActive: { true }, agents: { agents }, canRead: { _ in true }, savedAt: { _ in nil },
            fetch: { agent in
                fetched.append(agent.agent.paneID)
                if agent.agent.paneID == "old" {
                    await withCheckedContinuation { continuation = $0 }
                    returned = true
                    // Some SSH readers report their own error after cancellation.
                    throw ChatTranscriptError.readerUnavailable
                }
            },
            now: {
                // Both implementations read the clock when handling the
                // reader error, after fetch returns. Wait for that boundary,
                // not merely the callback returning on another Task.
                if returned { failureObserved = true }
                return Date(timeIntervalSince1970: 1_800_000_000)
            },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
        defer { prefetcher.cancel(); continuation?.resume() }
        prefetcher.update()
        try await waitUntil("prefetch suspended") { continuation != nil }
        prefetcher.cancel()
        let held = continuation
        continuation = nil
        held?.resume()
        try await waitUntil("cancelled reader failure handled") { failureObserved }
        agents = [agent("new")]
        prefetcher.update()
        try await waitUntil("same Host remains readable") { fetched == ["old", "new"] }
    }
}
