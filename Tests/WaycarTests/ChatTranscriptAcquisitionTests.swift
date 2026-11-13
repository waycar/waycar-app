import Foundation
import Testing

@testable import Waycar

/// Pins transcript acquisition and recovery in `ChatTranscriptStore`
/// (CHAT-03) through its own API: the two read coalescers, full-read
/// replacement, reads while stopped, and the retry and plugin budgets.
@MainActor
@Suite("Chat transcript acquisition")
struct ChatTranscriptAcquisitionTests {
    @MainActor
    private final class Host {
        var respond: @MainActor (String?) throws -> ChatTranscriptSnapshot = { _ in .init(header: .acquisition(), messages: []) }
        var beforeRead: (@MainActor () async -> Void)?
        var beforeScreen: (@MainActor () async -> Void)?
        var screen = "Allow this command?"
        private(set) var afters: [String?] = []
        private(set) var screenReads = 0
        var updates: AsyncStream<ConsoleStore.AgentStatusUpdate>.Continuation?

        func store(status: AgentStatus = .idle, retryDelays: [Duration] = [.seconds(3600)]) -> ChatTranscriptStore {
            ChatTranscriptStore(
                read: { [self] after in
                    afters.append(after)
                    await beforeRead?()
                    return try respond(after)
                },
                readScreen: { [self] in
                    screenReads += 1
                    await beforeScreen?()
                    return screen
                },
                sendKeys: { _ in },
                initialStatus: status,
                statusUpdateSource: { [self] in
                    let pair = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
                    updates = pair.continuation
                    return pair.stream
                },
                retryDelays: retryDelays, workingPollInterval: .seconds(3600),
                blockedRecheckDelay: .seconds(3600))
        }
    }

    private static func message(_ id: String) -> ChatTranscriptMessage {
        .init(id: id, role: .assistant, text: id, timestamp: nil)
    }

    @Test func aRefreshWhileStoppedReadsButNeverRetries() async throws {
        let host = Host()
        host.respond = { _ in .init(header: .acquisition(status: .notFound), messages: []) }
        let store = host.store(retryDelays: [.milliseconds(5)])
        await store.refresh()
        #expect(store.availability == .waitingForConversation)
        try await Task.sleep(for: .milliseconds(60))
        #expect(host.afters == [nil])

        // Until a full read lands, every read is in full.
        host.respond = { _ in .init(header: .acquisition(), messages: [Self.message("a1")]) }
        await store.refresh()
        await store.refresh()
        #expect(host.afters == [nil, nil, "a1"])
    }

    @Test func aMovedTranscriptAndAJoinedRefreshShareOneFullReread() async throws {
        let host = Host()
        var path = "/one.jsonl"
        host.respond = { after in
            .init(header: .acquisition(transcript: path),
                  messages: after == nil ? [Self.message(path)] : [])
        }
        let store = host.store()
        await store.refresh()
        #expect(host.afters == [nil])

        var release: CheckedContinuation<Void, Never>?
        host.beforeRead = { await withCheckedContinuation { release = $0 } }
        path = "/two.jsonl"
        let first = Task { await store.refresh() }
        try await waitUntil { release != nil }
        var joined = false
        let second = Task {
            joined = true
            await store.refresh()
        }
        try await waitUntil { joined }
        host.beforeRead = nil
        release?.resume()
        await first.value
        await second.value
        #expect(host.afters == [nil, "/one.jsonl", nil])
        #expect(store.messages.map(\.id) == ["/two.jsonl"])
    }

    @Test func overlappingBlockedScreenReadsRunOneReread() async throws {
        let host = Host()
        var release: CheckedContinuation<Void, Never>?
        let store = host.store(status: .blocked)
        host.beforeScreen = { await withCheckedContinuation { release = $0 } }
        store.start()
        defer { store.stop() }
        try await waitUntil { release != nil }
        await store.refresh()
        await store.refresh()
        #expect(host.screenReads == 1)
        host.beforeScreen = nil
        release?.resume()
        try await waitUntil { host.screenReads == 2 && store.blockedScreen != nil }
        try await Task.sleep(for: .milliseconds(30))
        #expect(host.screenReads == 2)
    }

    @Test func aStopDuringAScreenReadDropsItAndAStartReadsAfresh() async throws {
        let host = Host()
        var release: CheckedContinuation<Void, Never>?
        let store = host.store(status: .blocked)
        host.beforeScreen = { await withCheckedContinuation { release = $0 } }
        store.start()
        try await waitUntil { release != nil }
        store.stop()
        host.beforeScreen = nil
        host.screen = "Fresh prompt?"
        store.start()
        defer { store.stop() }
        try await waitUntil { store.blockedScreen?.contains("Fresh") == true }
        host.screen = "Stale prompt?"
        release?.resume()
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.blockedScreen?.contains("Fresh") == true)
        #expect(host.screenReads == 2)
    }

    /// Codex X25: with `thread/turns/list` and `thread/read` both refused the
    /// read fails, keeps the list and is retried, and a refresh reads again.
    @Test func aRefusedReadIsRetriedAndRefreshStillReads() async throws {
        let host = Host()
        var refuse = true
        host.respond = { _ in
            if refuse { throw TransportError.apiRejected(code: "-32601", message: "list_turns is not supported yet") }
            return .init(header: .acquisition(), messages: [Self.message("a1")])
        }
        let store = host.store(retryDelays: [.milliseconds(5)])
        store.start()
        defer { store.stop() }
        try await waitUntil { host.afters.count >= 3 }
        guard case .failed = store.availability else {
            Issue.record("expected a failure, got \(store.availability)")
            return
        }
        refuse = false
        await store.refresh()
        try await waitUntil { store.availability == .ready }
        #expect(store.messages.map(\.id) == ["a1"])
        let reads = host.afters.count
        try await Task.sleep(for: .milliseconds(60))
        #expect(host.afters.count == reads, "a read that found the transcript ends the retries")
    }

    @Test func aFailureWhileARetryWaitsReplacesItWithTheNextDelay() async throws {
        let host = Host()
        host.respond = { _ in throw TransportError.timedOut }
        let store = host.store(retryDelays: [.seconds(3600), .milliseconds(5), .seconds(3600)])
        store.start()
        defer { store.stop() }
        try await waitUntil { host.afters.count == 1 }
        // The first retry waits an hour; a refresh failing meanwhile re-arms
        // it with the second delay, which is quick.
        await store.refresh()
        try await waitUntil { host.afters.count == 3 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(host.afters.count == 3)
    }

    @Test func thePluginRecheckBudgetOutlivesAFoundRead() async throws {
        let host = Host()
        var reads = 0
        // Only the fourth read finds the transcript; every other is outdated.
        host.respond = { _ in
            reads += 1
            guard reads == 4 else { throw ChatTranscriptError.readerUnavailable }
            return .init(header: .acquisition(), messages: [Self.message("a1")])
        }
        let store = host.store(retryDelays: [.milliseconds(5), .milliseconds(5)])
        store.start()
        defer { store.stop() }
        try await waitUntil { store.availability == .pluginOutdated }
        #expect(host.afters.count == 1)

        // A recheck while stopped does nothing.
        store.stop()
        store.recheckPlugin()
        #expect(host.afters.count == 1)
        store.start()
        try await waitUntil { host.afters.count == 2 && store.availability == .pluginOutdated }

        // The recheck's budget is two retries; the outdated third read spends
        // one, the fourth finds the transcript.
        store.recheckPlugin()
        try await waitUntil { store.availability == .ready }
        #expect(host.afters.count == 4)
        // The one retry left survives the found read: the refresh's outdated
        // answer is retried once, then believed.
        await store.refresh()
        try await waitUntil { host.afters.count >= 6 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(host.afters.count == 6)
        #expect(store.availability == .pluginOutdated)
    }
}

private extension ChatTranscriptHeader {
    static func acquisition(status: Status = .ok, transcript: String? = nil) -> Self {
        .init(kind: "claude", status: status, transcript: transcript, activity: nil,
              turnOpen: false, truncated: false, error: nil)
    }
}
