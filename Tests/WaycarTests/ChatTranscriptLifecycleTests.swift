import Foundation
import Testing

@testable import Waycar

/// Characterization through the pre-conversion public API; no new owner seams.
@MainActor
@Suite("Chat transcript lifecycle characterization")
struct ChatTranscriptLifecycleTests {
    @Test func stoppingAnAnsweredPromptKeepsItDisabledUntilRestartReadsAfresh() async throws {
        let host = ChatLifecycleHost()
        let store = host.store(status: .blocked)
        defer { store.stop() }
        store.start()
        try await waitUntil { store.canAnswerBlocked }
        await store.allow()
        #expect(store.isAnsweringBlocked)
        store.stop()
        #expect(store.blockedScreen == host.screen)
        #expect(store.isAnsweringBlocked)
        #expect(!store.canAnswerBlocked)
        host.screen = "Another question?"
        store.start()
        #expect(!store.isAnsweringBlocked && store.blockedScreen == nil)
        try await waitUntil { store.blockedScreen == "Another question?" && store.canAnswerBlocked }
        #expect(host.keys == [["enter"]])
    }

    @Test func aFailedStructuredReadRetainsTheCardsAndRetryClearsOnlyTheFailure() async throws {
        let host = ChatLifecycleHost()
        let request = Self.command
        host.requests = [request]
        let store = host.store(status: .blocked, structured: true)
        defer { store.stop() }
        store.start()
        host.updates.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil { store.requests == [request] && store.canAnswerRequests }
        host.requestReadFails = true
        await store.refresh()
        try await waitUntil { store.requestsUnreadable }
        #expect(store.requests == [request])
        // Unreadable keeps the last-known cards, not a new admission rule.
        #expect(store.canAnswerRequests)
        host.requestReadFails = false
        store.retryBlockedScreen()
        #expect(!store.requestAnswerFailed)
        try await waitUntil { host.requestReads >= 3 && !store.requestsUnreadable }
        #expect(store.requests == [request])
    }

    @Test func formsAreSingleFlightAndResolvedElsewhereIsNotASendFailure() async throws {
        let host = ChatLifecycleHost()
        let form = AgentPendingRequest(id: "form", kind: .questions(.init(body: "", questions: [])))
        host.requests = [form]
        var release: CheckedContinuation<Void, Never>?
        host.beforeAnswer = { await withCheckedContinuation { release = $0 } }
        host.answerError = TransportError.apiRejected(code: "agent_request_resolved", message: "Already answered")
        let store = host.store(status: .blocked, structured: true)
        defer { store.stop() }
        store.start()
        host.updates.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil { store.canAnswerRequests && store.requests == [form] }
        let first = Task { await store.answer(form, with: .answers(["q": ["Keep it"]])) }
        try await waitUntil { release != nil }
        await store.answer(form, with: .cancel)
        #expect(host.answers == [.answers(["q": ["Keep it"]])])
        host.requests = []
        release?.resume()
        await first.value
        #expect(store.requests.isEmpty && !store.requestAnswerFailed)
        #expect(!store.isAnsweringBlocked)
        #expect(host.keys.isEmpty && host.queued.isEmpty)
    }

    @Test func structuredAnswerAdmissionLastsThroughItsTranscriptRefresh() async throws {
        let host = ChatLifecycleHost()
        let next = AgentPendingRequest(id: "next", kind: .questions(.init(body: "", questions: [])))
        host.requests = [Self.command, next]
        let store = host.store(status: .blocked, structured: true)
        defer { store.stop() }
        store.start()
        host.updates.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil { store.canAnswerRequests && store.requests.count == 2 && store.availability == .ready }
        var release: CheckedContinuation<Void, Never>?
        host.beforeRead = { await withCheckedContinuation { release = $0 } }
        host.beforeAnswer = { [weak host] in host?.requests = [next] }
        let first = Task { await store.answer(Self.command, with: .allow) }
        try await waitUntil { release != nil && store.requests == [next] }
        #expect(store.isAnsweringBlocked && !store.canAnswerRequests)
        await store.answer(next, with: .answers([:]))
        #expect(host.answers == [.allow])
        host.beforeRead = nil
        release?.resume()
        await first.value
        #expect(!store.isAnsweringBlocked && store.canAnswerRequests)
    }

    @Test func reconnectRelistsLiveOnlyRequestsWithoutReplayingAnOldAnswer() async throws {
        let host = ChatLifecycleHost()
        host.requests = [Self.command]
        var release: CheckedContinuation<Void, Never>?
        host.beforeAnswer = { await withCheckedContinuation { release = $0 } }
        host.answerError = TransportError.timedOut
        let store = host.store(status: .blocked, structured: true)
        defer { store.stop() }
        store.start()
        host.updates.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil { store.canAnswerRequests && !store.requests.isEmpty }
        let old = Task { await store.answer(Self.command, with: .allow) }
        try await waitUntil { release != nil }
        store.stop()
        store.start()
        let replacement = AgentPendingRequest(id: "next", kind: .command(command: "pwd", cwd: nil, reason: nil))
        host.requests = [replacement]
        host.updates.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil { store.canAnswerRequests && store.requests == [replacement] }
        release?.resume()
        await old.value
        #expect(store.requests == [replacement] && !store.requestAnswerFailed)
        #expect(host.answers == [.allow] && host.queued.isEmpty)
        host.updates.yield(.init(status: .blocked, liveUpdatesAvailable: false))
        try await waitUntil { !store.canAnswerRequests }
        host.requests = [] // A request was answered while the live-only stream was gone.
        host.updates.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil { store.requests.isEmpty && store.canAnswerRequests }
        #expect(host.answers == [.allow])
    }

    /// Safety net for deferred CHAT-03: overlapping refreshes are coalesced,
    /// and the queued read uses the cursor produced by the first one.
    @Test func overlappingRefreshesPerformOneIncrementalReread() async throws {
        let host = ChatLifecycleHost()
        var release: CheckedContinuation<Void, Never>?
        host.beforeRead = { await withCheckedContinuation { release = $0 } }
        host.snapshot = .init(header: .lifecycleOK, messages: [.init(id: "u1", role: .user, text: "hello", timestamp: nil)])
        let store = host.store(status: .idle)
        let first = Task { await store.refresh() }
        try await waitUntil { release != nil }
        var joined = 0
        let second = Task { joined += 1; await store.refresh() }
        let third = Task { joined += 1; await store.refresh() }
        try await waitUntil { joined == 2 }
        host.beforeRead = nil
        release?.resume()
        await first.value
        await second.value
        await third.value
        #expect(host.afters == [nil, "u1"])
        #expect(store.messages.map(\.id) == ["u1"])
    }

    /// A cancelled old read may still return a snapshot. It must not replace
    /// the cache reconciled by the restarted full read.
    @Test func aStoppedReadCannotPublishOverTheRestartedConversation() async throws {
        let host = ChatLifecycleHost()
        var release: CheckedContinuation<Void, Never>?
        host.beforeRead = { await withCheckedContinuation { release = $0 } }
        let store = host.store(status: .idle)
        let old = Task { await store.refresh() }
        try await waitUntil { release != nil }
        store.stop()
        host.beforeRead = nil
        host.snapshot = .init(header: .lifecycleOK, messages: [.init(id: "new", role: .user, text: "new conversation", timestamp: nil)])
        store.start()
        defer { store.stop() }
        try await waitUntil { store.messages.map(\.id) == ["new"] }
        host.snapshot = .init(header: .lifecycleOK, messages: [.init(id: "old", role: .user, text: "old conversation", timestamp: nil)])
        release?.resume()
        await old.value
        #expect(store.messages.map(\.id) == ["new"])
        #expect(host.afters == [nil, nil])
    }

    @Test func aLocalFollowKeepsItsAssistantBaselineAcrossStopAndRestart() async throws {
        let host = ChatLifecycleHost()
        host.snapshot = .init(header: .lifecycleOK, messages: [.init(id: "old", role: .assistant, text: "Existing reply", timestamp: nil)])
        let store = host.store(status: .idle, pollInterval: .milliseconds(5))
        store.start()
        defer { store.stop() }
        try await waitUntil { store.messages.count == 1 }
        store.followLocalSend()
        store.stop()
        store.start()
        try await waitUntil { host.afters.count >= 4 }
        host.snapshot = .init(header: .lifecycleOK, messages: [.init(id: "new", role: .assistant, text: "New reply", timestamp: nil)])
        try await waitUntil { store.messages.contains { $0.id == "new" } }
        #expect(!store.showsTypingIndicator)
    }

    private static var command: AgentPendingRequest {
        .init(id: "approval", kind: .command(command: "make test", cwd: nil, reason: nil))
    }
}

@MainActor
private final class ChatLifecycleHost {
    var updates: AsyncStream<ConsoleStore.AgentStatusUpdate>.Continuation
    var screen = "Allow this command?"
    var snapshot = ChatTranscriptSnapshot(header: .lifecycleOK, messages: [])
    var requests: [AgentPendingRequest] = []
    var requestReadFails = false
    var answerError: (any Error)?
    var beforeRead: (@MainActor () async -> Void)?
    var beforeAnswer: (@MainActor () async -> Void)?
    var afters: [String?] = []
    var requestReads = 0
    var keys: [[String]] = []
    var answers: [AgentRequestAnswer] = []
    var queued: [PendingBlockedAnswer] = []

    init() {
        let pair = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        updates = pair.continuation
    }

    func store(status: AgentStatus, structured: Bool = false, pollInterval: Duration = .seconds(3600)) -> ChatTranscriptStore {
        let pendingRequests: (@MainActor () async throws -> [AgentPendingRequest]) = { [self] in
            requestReads += 1
            if requestReadFails { throw TransportError.timedOut }
            return requests
        }
        let answerRequest: (@MainActor (String, AgentRequestAnswer) async throws -> Void) = { [self] _, answer in
            answers.append(answer)
            await beforeAnswer?()
            if let answerError { throw answerError }
        }
        return ChatTranscriptStore(
            read: { [self] after in
                afters.append(after)
                await beforeRead?()
                return snapshot
            },
            readScreen: { [self] in screen },
            sendKeys: { [self] in keys.append($0) },
            queueAnswer: { [self] in queued.append($0) },
            initialStatus: status,
            pendingRequests: structured ? pendingRequests : nil,
            answerRequest: structured ? answerRequest : nil,
            statusUpdateSource: { [self] in
                let pair = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
                updates = pair.continuation
                return pair.stream
            },
            retryDelays: [.seconds(3600)], workingPollInterval: pollInterval,
            blockedRecheckDelay: .seconds(3600))
    }
}

private extension ChatTranscriptHeader {
    static var lifecycleOK: Self {
        .init(kind: "claude", status: .ok, transcript: nil, activity: nil,
              turnOpen: false, truncated: false, error: nil)
    }
}
