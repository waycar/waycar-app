import Foundation
import Observation
import Testing

@testable import Waycar

@MainActor
@Suite("Watch bridge")
struct WatchBridgeTests {
    // MARK: Fakes

    /// `WCSession` as the bridge sees it.
    @MainActor
    final class FakeChannel: WatchSessionChannel {
        var canPublish = true
        var isReachable = false
        var failsLiveMessages = false
        /// What the system kept from the last publish, by any run.
        var lastApplicationContext: Data?
        private(set) var activations = 0
        private(set) var contexts: [WatchState] = []
        private(set) var liveEvents: [WatchEvent] = []
        private(set) var queuedEvents: [WatchEvent] = []

        /// Every event, however it went.
        var events: [WatchEvent] { liveEvents + queuedEvents }

        func activate() { activations += 1 }

        func updateApplicationContext(_ state: Data) throws {
            contexts.append(try WatchWireCodec.decode(WatchState.self, from: state))
        }

        func sendMessageData(_ event: Data, onFailure: @escaping @MainActor @Sendable () -> Void) {
            if failsLiveMessages {
                onFailure()
                return
            }
            liveEvents.append(try! WatchWireCodec.decode(WatchEvent.self, from: event))
        }

        func transferUserInfo(_ event: Data) {
            queuedEvents.append(try! WatchWireCodec.decode(WatchEvent.self, from: event))
        }
    }

    /// The Console, actions and app the bridge drives. Observable, so the
    /// bridge's source observer sees `source` change once publishing starts.
    @MainActor @Observable
    final class Harness {
        var source: WatchStateSource
        var now: Date
        var keychainReadable = true
        /// The transcript's last reply, as `lastReply` reads it.
        var lastReply: String?
        /// How often the bridge asked for the transcript.
        var replyReads = 0
        /// The transcript read never returns on its own (a slow SSH read).
        var replyStalls = false
        /// The transcript read returns only on `releaseReads()`, cancelled
        /// or not (a read stuck in a call that ignores cancellation).
        var replyParks = false
        private var parkedReads: [CheckedContinuation<Void, Never>] = []
        /// How many transcript reads have returned to the bridge.
        var readsReturned = 0
        var snapshot: BlockedPromptSnapshot?
        var blockedError: (any Error)?
        var answerOutcome: AgentActionService.AnswerOutcome = .sent
        /// The answer never returns on its own (a stalled `sendKeys`).
        var answerStalls = false
        /// The answer returns only on `releaseAnswers()`.
        var answerParks = false
        private var parkedAnswers: [CheckedContinuation<Void, Never>] = []
        var sendOutcome: AgentActionService.SendOutcome = .sent
        var holdsSends = false
        private(set) var sent: [String] = []
        private(set) var answers: [Bool] = []
        private(set) var holds = 0
        private(set) var releases = 0
        var onRelease: (@MainActor () -> Void)?
        /// Each hold's background-time expiration, in order.
        private(set) var expirations: [@MainActor @Sendable () -> Void] = []
        private var heldSends: [CheckedContinuation<Void, Never>] = []

        init(source: WatchStateSource, now: Date) {
            self.source = source
            self.now = now
        }

        func send(_ text: String) async -> AgentActionService.SendOutcome {
            sent.append(text)
            if holdsSends { await withCheckedContinuation { heldSends.append($0) } }
            return sendOutcome
        }

        func releaseSends() {
            holdsSends = false
            let held = heldSends
            heldSends = []
            held.forEach { $0.resume() }
        }

        /// Parks one transcript read until `releaseReads()`.
        func parkRead() async {
            await withCheckedContinuation { parkedReads.append($0) }
        }

        /// Lets every parked transcript read return.
        func releaseReads() {
            replyParks = false
            let parked = parkedReads
            parkedReads = []
            parked.forEach { $0.resume() }
        }

        func answer(_ allow: Bool) async -> AgentActionService.AnswerOutcome {
            answers.append(allow)
            if answerStalls { try? await Task.sleep(for: .seconds(30)) }
            if answerParks { await withCheckedContinuation { parkedAnswers.append($0) } }
            return answerOutcome
        }

        /// Lets every parked answer return.
        func releaseAnswers() {
            answerParks = false
            let parked = parkedAnswers
            parkedAnswers = []
            parked.forEach { $0.resume() }
        }

        func hold(_ onExpiration: @escaping @MainActor @Sendable () -> Void) {
            holds += 1
            expirations.append(onExpiration)
        }

        func release() {
            onRelease?()
            releases += 1
        }
    }

    struct ScriptedTranscriber: AudioFileTranscribing {
        /// What transcribing does.
        enum Behavior: Sendable {
            /// Returns these words.
            case words(String)
            /// Throws.
            case fails
            /// Never finishes on its own (a model download that hangs).
            case stalls
        }

        let behavior: Behavior

        func transcribe(fileAt url: URL, locale: Locale) async throws -> String {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DictationEngineError.captureFailed("missing")
            }
            switch behavior {
            case .words(let transcript):
                return transcript
            case .fails:
                throw DictationEngineError.captureFailed("unreadable")
            case .stalls:
                try await Task.sleep(for: .seconds(30))
                return "too late"
            }
        }
    }

    /// The replies one request got.
    @MainActor
    final class Replies {
        var values: [WatchReply] = []
    }

    // MARK: Fixture

    private let studio = Host.fixture(name: "studio")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let transcript = "Looks good, ship it."
    /// What a timeout test waits instead of the real deadline.
    private static let short: Duration = .milliseconds(150)

    /// The real deadlines, but for the Host poll and the publish coalescing:
    /// only the timeout tests shorten one, through `adjust`.
    private static func timing(
        _ adjust: (inout WatchBridge.Timing) -> Void = { _ in }
    ) -> WatchBridge.Timing {
        var timing = WatchBridge.Timing(hostPoll: .milliseconds(10), publishCoalescing: .zero)
        adjust(&timing)
        return timing
    }

    private func agent(_ paneID: String = "codex", _ status: AgentStatus = .done) -> ConsoleAgent {
        ConsoleAgent(
            hostID: studio.id, hostName: studio.displayName,
            agent: Agent(.fixture(paneID: paneID, status: status, kind: "codex", name: "codex")),
            workspaceLabel: "site", repositoryCheckout: nil)
    }

    /// An Agent with an Agent Summary written a minute ago in `status`,
    /// and the Host's live agent session when `session` is set.
    private func summarized(
        _ status: AgentStatus = .done, summary: String = "Shipped.", session: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: studio.id, hostName: studio.displayName,
            agent: Agent(
                terminalID: "term_codex", kind: "codex", title: "Task", status: status,
                workspaceID: "w1", tabID: "w1:t1", paneID: "codex", cwd: "/work/w1", revision: 1,
                name: "codex",
                agentSession: session.map {
                    AgentSessionInfo(agent: "codex", kind: .id, source: "herdr:codex", value: $0)
                }),
            workspaceLabel: "site", repositoryCheckout: nil,
            summary: AgentSummary(
                paneID: "codex", status: status, text: summary,
                timestamp: Int64((now.timeIntervalSince1970 - 60) * 1000)))
    }

    private func shell() -> ConsoleAgent {
        ConsoleAgent(
            hostID: studio.id, hostName: studio.displayName,
            agent: Agent(.fixture(paneID: "shell", status: .idle, kind: Agent.shellKind)),
            workspaceLabel: "site", repositoryCheckout: nil)
    }

    private var agentID: WatchAgentID { WatchAgentID(hostID: studio.id, paneID: "codex") }

    private func connectedSource(
        _ status: EventsSessionStatus = .connected, agents: [ConsoleAgent]? = nil
    ) -> WatchStateSource {
        WatchStateSource(
            agents: agents ?? [agent()], hosts: [studio], statuses: [studio.id: status],
            awaitingSnapshot: [], chatModeAgents: [], voiceTranscription: true)
    }

    private func make(
        source: WatchStateSource? = nil,
        transcriber: ScriptedTranscriber.Behavior? = .words(Self.transcript),
        timing: WatchBridge.Timing = Self.timing()
    ) -> (WatchBridge, FakeChannel, Harness) {
        let harness = Harness(source: source ?? connectedSource(), now: now)
        let channel = FakeChannel()
        let dependencies = WatchBridge.Dependencies(
            source: { harness.source },
            keychainReadable: { harness.keychainReadable },
            lastReply: { _ in
                harness.replyReads += 1
                if harness.replyStalls { try? await Task.sleep(for: .seconds(30)) }
                if harness.replyParks { await harness.parkRead() }
                harness.readsReturned += 1
                return harness.lastReply
            },
            blockedPrompt: { _ in
                if let error = harness.blockedError { throw error }
                return harness.snapshot
            },
            answer: { allow, _, _ in await harness.answer(allow) },
            send: { text, _ in await harness.send(text) },
            transcriber: transcriber.map { ScriptedTranscriber(behavior: $0) },
            hold: { onExpiration in harness.hold(onExpiration) },
            release: { harness.release() },
            now: { harness.now })
        let bridge = WatchBridge(channel: channel, dependencies: dependencies, timing: timing)
        bridge.activate()
        return (bridge, channel, harness)
    }

    private func request(_ request: WatchRequest, to bridge: WatchBridge) throws -> Replies {
        try receive(WatchWireCodec.encode(request), by: bridge)
    }

    private func receive(_ data: Data, by bridge: WatchBridge) -> Replies {
        let replies = Replies()
        bridge.receive(messageData: data) { data in
            replies.values.append(try! WatchWireCodec.decode(WatchReply.self, from: data))
        }
        return replies
    }

    /// Lets the bridge's tasks run until `condition` holds, up to the shared ceiling.
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .waitCeiling
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Lets every task the bridge has ready run, without a real sleep.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// A recording in its own temporary directory; the caller removes the
    /// directory with `removeRecordings(at:)`.
    private func recording() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "WatchBridgeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "voice.m4a")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    private func removeRecordings(at urls: URL...) {
        for url in urls {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func metadata(_ messageID: UUID) throws -> Data {
        try WatchWireCodec.encode(WatchVoiceFile(messageID: messageID, agentID: agentID, duration: 6))
    }

    private func permission() throws -> BlockedPromptSnapshot {
        try #require(
            BlockedPromptSnapshot(kind: "claude", fullScreen: TmuxScreenDetectorTests.claudePermission))
    }

    /// Reads the Agent's Blocked prompt as the watch does; its prompt id.
    private func shownPromptID(_ bridge: WatchBridge) async throws -> UUID {
        let read = try request(.blockedPrompt(agentID), to: bridge)
        #expect(await eventually { !read.values.isEmpty })
        var shown: WatchBlockedPrompt?
        if case .blockedPrompt(let prompt?) = read.values.first { shown = prompt }
        return try #require(shown, "expected a prompt, got \(read.values)").promptID
    }

    // MARK: Wire

    @Test func anotherWireVersionAsksForAnUpdate() async {
        let (bridge, _, _) = make()
        let replies = receive(Data(#"{"v":2,"body":{"type":"refresh"}}"#.utf8), by: bridge)
        #expect(replies.values == [.failure("Update Waycar on your iPhone")])
    }

    @Test func refreshRepliesWithTheWatchState() throws {
        let (bridge, _, harness) = make()
        let replies = try request(.refresh, to: bridge)
        guard case .state(let state) = replies.values.first else {
            Issue.record("expected a state, got \(replies.values)")
            return
        }
        #expect(state.rows.map(\.title) == ["site · codex"])
        #expect(state.hosts.map(\.condition) == [.confirmed])
        #expect(harness.holds == harness.releases)
    }

    /// A refresh while the Host is not confirmed keeps the rows it built
    /// last, so the watch's list does not empty out.
    @Test func aRefreshWhileConnectingKeepsTheLastRows() throws {
        let (bridge, _, harness) = make()
        _ = try request(.refresh, to: bridge)
        harness.source = connectedSource(.connecting, agents: [])

        let replies = try request(.refresh, to: bridge)

        guard case .state(let state) = replies.values.first else {
            Issue.record("expected a state, got \(replies.values)")
            return
        }
        #expect(state.rows.map(\.title) == ["site · codex"])
        #expect(state.hosts.map(\.condition) == [.connecting])
    }

    /// A cold-launched phone has built nothing yet: it keeps the rows of the
    /// Watch State the system kept from its last run.
    @Test func aColdLaunchKeepsTheRowsLastPublished() throws {
        let (earlier, _, _) = make()
        guard case .state(let published) = try request(.refresh, to: earlier).values.first else {
            Issue.record("expected a state")
            return
        }
        let (bridge, channel, _) = make(source: connectedSource(.connecting, agents: []))
        channel.lastApplicationContext = try WatchWireCodec.encode(published)
        bridge.sessionDidActivate(isReachable: false)

        let replies = try request(.refresh, to: bridge)

        guard case .state(let state) = replies.values.first else {
            Issue.record("expected a state, got \(replies.values)")
            return
        }
        #expect(state.rows == published.rows)
        #expect(state.hosts.map(\.condition) == [.connecting])
    }

    /// Nothing is published while the Console is suspended; publishing
    /// resumes with it.
    @Test func publishingWaitsOutASuspendedConsole() async {
        var suspended = connectedSource()
        suspended.isSuspended = true
        let (bridge, channel, harness) = make(source: suspended)
        bridge.startPublishing()
        await settle()
        #expect(channel.contexts.isEmpty)

        harness.source = connectedSource()

        #expect(await eventually { channel.contexts.count == 1 })
        #expect(channel.contexts.first?.hosts.map(\.condition) == [.confirmed])
    }

    @Test func publishesTheStateOnceStarted() async {
        let (bridge, channel, _) = make()
        bridge.startPublishing()
        #expect(await eventually { channel.contexts.count == 1 })
        #expect(channel.contexts.first?.rows.count == 1)
    }

    /// A stale estimate's row does not depend on the clock, so a Console
    /// change the watch cannot see does not resend the Watch State.
    @Test func anUnseenChangeDoesNotResendAStaleEstimate() async throws {
        let steps = try #require(AgentProgress(steps: .init(done: 2, total: 5), phase: nil))
        func working(_ text: String) -> ConsoleAgent {
            ConsoleAgent(
                hostID: studio.id, hostName: studio.displayName,
                agent: Agent(.fixture(paneID: "codex", status: .working, kind: "codex", name: "codex")),
                workspaceLabel: "site", repositoryCheckout: nil,
                summary: AgentSummary(
                    paneID: "codex", status: .blocked, text: text,
                    timestamp: Int64(now.timeIntervalSince1970 * 1000), progress: steps),
                hostReportsProgress: true)
        }
        let (bridge, channel, harness) = make(source: connectedSource(agents: [working("Reading.")]))
        bridge.startPublishing()
        #expect(await eventually { channel.contexts.count == 1 })
        #expect(channel.contexts.first?.rows.first?.progress?.staleAfter == .distantPast)

        harness.now = now.addingTimeInterval(60)
        harness.source = connectedSource(agents: [working("Still reading.")])
        try await Task.sleep(for: .milliseconds(200))
        #expect(channel.contexts.count == 1)

        // A change the watch does see is still sent: the observer was live.
        harness.source = connectedSource(agents: [agent()])
        #expect(await eventually { channel.contexts.count == 2 })
    }

    // MARK: Send

    @Test func sendAcknowledgesBeforeDelivering() async throws {
        let (bridge, channel, harness) = make()
        harness.holdsSends = true
        let id = UUID()
        let replies = try request(.send(messageID: id, agentID, text: "ship it"), to: bridge)
        #expect(replies.values == [.received])
        #expect(await eventually { harness.sent == ["ship it"] })
        #expect(channel.events.isEmpty)
        harness.releaseSends()
        #expect(
            await eventually {
                channel.events == [.delivery(messageID: id, agentID, .sent(text: "ship it"))]
            })
        #expect(harness.holds == harness.releases)
    }

    @Test func aRepeatedMessageIsNotSentTwice() async throws {
        let (bridge, channel, harness) = make()
        harness.holdsSends = true
        let id = UUID()
        _ = try request(.send(messageID: id, agentID, text: "ship it"), to: bridge)
        let whileInFlight = try request(.send(messageID: id, agentID, text: "ship it"), to: bridge)
        #expect(whileInFlight.values == [.received])
        harness.releaseSends()
        #expect(await eventually { channel.events.count == 1 })

        let afterwards = try request(.send(messageID: id, agentID, text: "ship it"), to: bridge)
        #expect(afterwards.values == [.received])
        #expect(await eventually { channel.events.count == 2 })
        #expect(channel.events[0] == channel.events[1])
        #expect(harness.sent == ["ship it"])
    }

    @Test(arguments: [
        (AgentActionService.SendOutcome.keptAsDraft(.blocked), WatchDelivery.keptAsDraft(reason: .blocked)),
        (.keptAsDraft(.signInRequired), .keptAsDraft(reason: .signInRequired)),
        (.keptAsDraft(.folderTrustRequired), .keptAsDraft(reason: .folderTrustRequired)),
        (.unknown, .unknown),
        (.notSent(reason: "Host isn't connected"), .notSent(reason: "Host isn't connected")),
    ])
    func sendOutcomesMapToDeliveries(
        outcome: AgentActionService.SendOutcome, delivery: WatchDelivery
    ) async throws {
        let (bridge, channel, harness) = make()
        harness.sendOutcome = outcome
        let id = UUID()
        _ = try request(.send(messageID: id, agentID, text: "next"), to: bridge)
        #expect(await eventually { channel.events == [.delivery(messageID: id, agentID, delivery)] })
    }

    @Test func aDefiniteNotSentIsRetriedWithTheSameID() async throws {
        let (bridge, channel, harness) = make()
        harness.sendOutcome = .notSent(reason: "Host isn't connected")
        let id = UUID()
        _ = try request(.send(messageID: id, agentID, text: "next"), to: bridge)
        #expect(await eventually { channel.events.count == 1 })
        harness.sendOutcome = .sent
        _ = try request(.send(messageID: id, agentID, text: "next"), to: bridge)
        #expect(await eventually { channel.events.count == 2 })
        #expect(harness.sent == ["next", "next"])
        #expect(channel.events.last == .delivery(messageID: id, agentID, .sent(text: "next")))
    }

    /// A send that never returns (a stalled Host transport) may still have
    /// gone out: past the deadline it reads as unknown, never retryable, and
    /// stops holding the app.
    @Test func aSendThatOutrunsItsDeadlineIsUnknown() async throws {
        let (bridge, channel, harness) = make(timing: Self.timing { $0.readDeadline = Self.short })
        harness.holdsSends = true
        let id = UUID()
        _ = try request(.send(messageID: id, agentID, text: "next"), to: bridge)
        #expect(await eventually { channel.events == [.delivery(messageID: id, agentID, .unknown)] })
        #expect(await eventually { harness.holds == harness.releases })
        #expect(harness.sent == ["next"])
        harness.releaseSends()
    }

    @Test func aHostStillConnectingFailsTheSendWithoutTryingIt() async throws {
        let (bridge, channel, harness) = make(
            source: connectedSource(.connecting), timing: Self.timing { $0.hostDeadline = Self.short })
        let id = UUID()
        _ = try request(.send(messageID: id, agentID, text: "next"), to: bridge)
        #expect(
            await eventually {
                channel.events
                    == [.delivery(messageID: id, agentID, .notSent(reason: "studio is still connecting"))]
            })
        #expect(harness.sent.isEmpty)
    }

    @Test func aLockedPhoneAsksToBeUnlockedAndSendsNothing() async throws {
        let (bridge, channel, harness) = make()
        harness.snapshot = try permission()
        let promptID = try await shownPromptID(bridge)
        harness.keychainReadable = false
        let replies = try request(.send(messageID: UUID(), agentID, text: "next"), to: bridge)
        #expect(replies.values == [.failure("Unlock your iPhone")])
        #expect(try request(.latest(agentID), to: bridge).values == [.failure("Unlock your iPhone")])
        let answer = try request(.answer(agentID, promptID: promptID, .allow), to: bridge)
        #expect(answer.values == [.failure("Unlock your iPhone")])
        #expect(harness.sent.isEmpty)
        #expect(harness.answers.isEmpty)
        #expect(channel.events.isEmpty)
    }

    @Test func outcomesGoLiveWhileReachableAndQueuedOtherwise() async throws {
        let (bridge, channel, _) = make()
        channel.isReachable = true
        _ = try request(.send(messageID: UUID(), agentID, text: "one"), to: bridge)
        #expect(await eventually { channel.liveEvents.count == 1 })
        channel.isReachable = false
        _ = try request(.send(messageID: UUID(), agentID, text: "two"), to: bridge)
        #expect(await eventually { channel.queuedEvents.count == 1 })
        channel.isReachable = true
        channel.failsLiveMessages = true
        _ = try request(.send(messageID: UUID(), agentID, text: "three"), to: bridge)
        #expect(await eventually { channel.queuedEvents.count == 2 })
    }

    // MARK: Only listed Agents

    /// A Shell, or a pane the watch never listed, is neither read nor sent
    /// to, whatever id the request names: on tmux a Shell would run the text.
    @Test(arguments: ["shell", "nope"])
    func anUnlistedPaneGetsNothing(paneID: String) async throws {
        let (bridge, channel, harness) = make(source: connectedSource(agents: [agent(), shell()]))
        harness.lastReply = "Shipped."
        harness.snapshot = try permission()
        let target = WatchAgentID(hostID: studio.id, paneID: paneID)

        let id = UUID()
        _ = try request(.send(messageID: id, target, text: "rm -rf build"), to: bridge)
        #expect(
            await eventually {
                channel.events
                    == [.delivery(messageID: id, target, .notSent(reason: "This Agent is gone"))]
            })
        let latest = try request(.latest(target), to: bridge)
        #expect(await eventually { latest.values == [.failure("This Agent is gone")] })
        let prompt = try request(.blockedPrompt(target), to: bridge)
        #expect(await eventually { prompt.values == [.failure("This Agent is gone")] })
        let reply = await bridge.sendNotificationReply("rm -rf build", to: target.consoleID)
        #expect(reply == .notSent(reason: "This Agent is gone"))

        #expect(harness.sent.isEmpty)
        #expect(harness.holds == harness.releases)
    }

    // MARK: Notification replies

    @Test func aNotificationReplyIsSentToAListedAgent() async {
        let (bridge, _, harness) = make()
        let outcome = await bridge.sendNotificationReply("ship it", to: agentID.consoleID)
        #expect(outcome == .sent)
        #expect(harness.sent == ["ship it"])
        #expect(harness.holds == harness.releases)
    }

    @Test func aNotificationReplyFromALockedPhoneIsNotSent() async {
        let (bridge, _, harness) = make()
        harness.keychainReadable = false
        let outcome = await bridge.sendNotificationReply("ship it", to: agentID.consoleID)
        #expect(outcome == .notSent(reason: "Unlock your iPhone"))
        #expect(harness.sent.isEmpty)
    }

    @Test func aNotificationReplyThatOutrunsItsDeadlineIsUnknown() async {
        let (bridge, _, harness) = make(timing: Self.timing { $0.readDeadline = Self.short })
        harness.holdsSends = true
        let outcome = await bridge.sendNotificationReply("ship it", to: agentID.consoleID)
        #expect(outcome == .unknown)
        #expect(harness.sent == ["ship it"])
        #expect(harness.holds == harness.releases)
        harness.releaseSends()
    }

    // MARK: Latest

    @Test func latestIsTheSummaryWithoutATranscript() async throws {
        let (bridge, _, harness) = make(source: connectedSource(agents: [summarized()]))
        harness.lastReply = "Never read."
        let replies = try request(.latest(agentID), to: bridge)
        #expect(
            await eventually {
                replies.values
                    == [.latest(WatchLatest(source: .summary, text: "Shipped.", lastReply: nil, isStale: false))]
            })
        #expect(harness.replyReads == 0)
    }

    @Test func latestIsTheFullReplyWhenTheTranscriptReads() async throws {
        let reply = "Shipped the fix.\n\nAll 40 tests pass, and the docs are updated."
        let (bridge, _, harness) = make(source: connectedSource(agents: [summarized(session: "s-1")]))
        harness.lastReply = reply
        let replies = try request(.latest(agentID), to: bridge)
        #expect(
            await eventually {
                replies.values == [.latest(WatchLatest(source: .reply, text: reply, lastReply: nil, isStale: false))]
            })
    }

    /// A transcript read past the deadline falls back to the summary
    /// already on the phone, never to an unreachable error.
    @Test func aSlowTranscriptReadFallsBackToTheSummary() async throws {
        let (bridge, _, harness) = make(
            source: connectedSource(agents: [summarized(session: "s-1")]),
            timing: Self.timing { $0.readDeadline = Self.short })
        harness.lastReply = "Too late."
        harness.replyStalls = true
        let replies = try request(.latest(agentID), to: bridge)
        #expect(
            await eventually {
                replies.values
                    == [.latest(WatchLatest(source: .summary, text: "Shipped.", lastReply: nil, isStale: false))]
            })
        #expect(harness.replyReads == 1)
    }

    /// The deadline holds even for a read that ignores cancellation: the
    /// timer answers by itself, and the read's late result is dropped.
    @Test func aTranscriptReadThatIgnoresCancellationStillFallsBack() async throws {
        let (bridge, _, harness) = make(
            source: connectedSource(agents: [summarized(session: "s-1")]),
            timing: Self.timing { $0.readDeadline = Self.short })
        harness.lastReply = "Too late."
        harness.replyParks = true
        let replies = try request(.latest(agentID), to: bridge)
        let summary = WatchReply.latest(
            WatchLatest(source: .summary, text: "Shipped.", lastReply: nil, isStale: false))
        #expect(await eventually { replies.values == [summary] })

        harness.releaseReads()
        #expect(await eventually { harness.readsReturned == 1 })
        await settle()
        #expect(replies.values == [summary], "one reply only")
    }

    @Test func aChatModeAgentWithoutASessionStillReadsItsTranscript() async throws {
        var source = connectedSource(agents: [summarized()])
        source.chatModeAgents = [agentID.consoleID]
        let (bridge, _, harness) = make(source: source)
        harness.lastReply = "From the transcript."
        let replies = try request(.latest(agentID), to: bridge)
        #expect(
            await eventually {
                replies.values
                    == [.latest(WatchLatest(source: .reply, text: "From the transcript.", lastReply: nil, isStale: false))]
            })
    }

    @Test func aWorkingAgentShowsItsSummaryOverTheLastReply() async throws {
        let agent = summarized(.working, summary: "Running the tests.", session: "s-1")
        let (bridge, _, harness) = make(source: connectedSource(agents: [agent]))
        harness.lastReply = "Earlier reply."
        let replies = try request(.latest(agentID), to: bridge)
        #expect(
            await eventually {
                replies.values
                    == [
                        .latest(
                            WatchLatest(
                                source: .summary, text: "Running the tests.", lastReply: "Earlier reply.",
                                isStale: false))
                    ]
            })
    }

    @Test func anOverBudgetReplyKeepsItsEndWithTheNotice() async throws {
        let reply = String(repeating: "Lorem ipsum dolor. ", count: 4_000) + "Final line."
        let (bridge, _, harness) = make(source: connectedSource(agents: [summarized(session: "s-1")]))
        harness.lastReply = reply
        let replies = try request(.latest(agentID), to: bridge)
        #expect(await eventually { !replies.values.isEmpty })
        guard case .latest(let latest?) = replies.values.first else {
            Issue.record("expected a Latest, got \(replies.values)")
            return
        }
        #expect(latest.text.hasPrefix(WatchStateBuilder.earlierTextNotice + "\n\n"))
        #expect(latest.text.hasSuffix("Final line."))
        #expect(try WatchWireCodec.encode(WatchReply.latest(latest)).count <= WatchStateBuilder.latestByteBudget + 1024)
    }

    @Test func latestForAnUnreachableHostSaysSo() async throws {
        let (bridge, _, _) = make(
            source: connectedSource(.ended), timing: Self.timing { $0.hostDeadline = Self.short })
        let replies = try request(.latest(agentID), to: bridge)
        #expect(await eventually { replies.values == [.failure("Can't reach studio")] })
    }

    /// A Host whose events session the background suspended resumes on its
    /// own, so it reads as connecting, not unreachable.
    @Test func latestForASuspendedHostSaysItIsStillConnecting() async throws {
        let (bridge, _, _) = make(
            source: connectedSource(.suspended), timing: Self.timing { $0.hostDeadline = Self.short })
        let replies = try request(.latest(agentID), to: bridge)
        #expect(await eventually { replies.values == [.failure("studio is still connecting")] })
    }

    // MARK: Blocked prompts

    @Test func aPromptIsAnsweredUnderTheIDItWasShownWith() async throws {
        let (bridge, _, harness) = make()
        harness.snapshot = try permission()
        let read = try request(.blockedPrompt(agentID), to: bridge)
        #expect(await eventually { !read.values.isEmpty })
        guard case .blockedPrompt(let prompt?) = read.values.first else {
            Issue.record("expected a prompt, got \(read.values)")
            return
        }
        #expect(prompt.approval == .allow)
        #expect(prompt.command == "touch x.txt")

        let answer = try request(.answer(agentID, promptID: prompt.promptID, .allow), to: bridge)
        #expect(await eventually { answer.values == [.answerResult(.sent)] })
        let again = try request(.answer(agentID, promptID: prompt.promptID, .allow), to: bridge)
        #expect(await eventually { again.values == [.answerResult(.sent)] })
        #expect(harness.answers == [true])
    }

    @Test func anAnswerToAPromptThePhoneDoesNotKeepIsPromptChanged() throws {
        let (bridge, _, harness) = make()
        let replies = try request(.answer(agentID, promptID: UUID(), .deny), to: bridge)
        #expect(replies.values == [.answerResult(.promptChanged)])
        #expect(harness.answers.isEmpty)
    }

    /// A prompt id shown for one Agent never answers another's prompt.
    @Test func anAnswerNamingAnotherAgentIsPromptChanged() async throws {
        let (bridge, _, harness) = make(source: connectedSource(agents: [agent(), agent("other")]))
        harness.snapshot = try permission()
        let promptID = try await shownPromptID(bridge)
        let other = WatchAgentID(hostID: studio.id, paneID: "other")
        let replies = try request(.answer(other, promptID: promptID, .allow), to: bridge)
        #expect(replies.values == [.answerResult(.promptChanged)])
        #expect(harness.answers.isEmpty)
    }

    @Test func aNewerReadRetiresTheEarlierPromptID() async throws {
        let (bridge, _, harness) = make()
        harness.snapshot = try permission()
        let earlier = try await shownPromptID(bridge)
        _ = try await shownPromptID(bridge)
        let replies = try request(.answer(agentID, promptID: earlier, .deny), to: bridge)
        #expect(replies.values == [.answerResult(.promptChanged)])
    }

    @Test func blockedReadFailuresReadAsCopy() async throws {
        let (bridge, _, harness) = make()
        harness.blockedError = AgentActionService.BlockedPromptError.notListed
        let gone = try request(.blockedPrompt(agentID), to: bridge)
        #expect(await eventually { gone.values == [.failure("This Agent is gone")] })
        harness.blockedError = AgentActionService.BlockedPromptError.unreadable
        let blank = try request(.blockedPrompt(agentID), to: bridge)
        #expect(await eventually { blank.values == [.failure("Couldn't read the prompt")] })
    }

    /// Allow while the Host reconnects: nothing goes out, and the same
    /// prompt can be answered once the Host is back.
    @Test func anAnswerTheHostNeverTookCanBeRetriedUnderTheSameID() async throws {
        let (bridge, _, harness) = make(timing: Self.timing { $0.hostDeadline = Self.short })
        harness.snapshot = try permission()
        let promptID = try await shownPromptID(bridge)
        harness.source = connectedSource(.connecting)
        let failed = try request(.answer(agentID, promptID: promptID, .allow), to: bridge)
        #expect(await eventually { failed.values == [.failure("studio is still connecting")] })
        #expect(harness.answers.isEmpty)

        harness.source = connectedSource()
        let retried = try request(.answer(agentID, promptID: promptID, .allow), to: bridge)
        #expect(await eventually { retried.values == [.answerResult(.sent)] })
        #expect(harness.answers == [true])
        #expect(harness.holds == harness.releases)
    }

    /// A failed answer (CarPlay mid-answer, or the keys never confirmed) is
    /// not replayed to a retry: the prompt is spent, so the watch reads it anew.
    @Test func aFailedAnswerIsNotKeptForARetry() async throws {
        let (bridge, _, harness) = make()
        harness.snapshot = try permission()
        harness.answerOutcome = .failed
        let promptID = try await shownPromptID(bridge)
        let failed = try request(.answer(agentID, promptID: promptID, .allow), to: bridge)
        #expect(await eventually { failed.values == [.answerResult(.failed)] })

        harness.answerOutcome = .sent
        let retried = try request(.answer(agentID, promptID: promptID, .allow), to: bridge)
        #expect(retried.values == [.answerResult(.promptChanged)])
        #expect(harness.answers == [true])
    }

    /// Deny under a prompt id whose Allow is still running never reports
    /// Allow's outcome as its own: it waits for Allow, then reads as changed.
    @Test func aDifferentAnswerUnderTheSameIDIsPromptChanged() async throws {
        let (bridge, _, harness) = make()
        harness.snapshot = try permission()
        harness.answerParks = true
        let promptID = try await shownPromptID(bridge)
        let allow = try request(.answer(agentID, promptID: promptID, .allow), to: bridge)
        #expect(await eventually { harness.answers == [true] })
        let deny = try request(.answer(agentID, promptID: promptID, .deny), to: bridge)
        await settle()
        #expect(deny.values.isEmpty, "waits for the first answer")

        harness.releaseAnswers()
        #expect(await eventually { allow.values == [.answerResult(.sent)] })
        #expect(await eventually { deny.values == [.answerResult(.promptChanged)] })
        #expect(harness.answers == [true])
    }

    /// An answer's reply, first or repeated, goes out while the app is still
    /// held awake; the hold ends only after it.
    @Test func answerRepliesLeaveBeforeTheHoldEnds() async throws {
        let (bridge, _, harness) = make()
        harness.snapshot = try permission()
        let promptID = try await shownPromptID(bridge)
        #expect(await eventually { harness.holds == harness.releases })
        let base = harness.releases
        let data = try WatchWireCodec.encode(WatchRequest.answer(agentID, promptID: promptID, .allow))
        var releasesAtReply: [Int] = []
        bridge.receive(messageData: data) { _ in releasesAtReply.append(harness.releases - base) }
        #expect(await eventually { harness.releases == base + 1 })
        bridge.receive(messageData: data) { _ in releasesAtReply.append(harness.releases - base) }
        #expect(await eventually { harness.releases == base + 2 })
        #expect(harness.holds == base + 2)
        #expect(releasesAtReply == [0, 1])
    }

    @Test func anAnswerThatOutrunsItsDeadlineFails() async throws {
        let (bridge, _, harness) = make(timing: Self.timing { $0.answerDeadline = Self.short })
        harness.snapshot = try permission()
        harness.answerStalls = true
        let promptID = try await shownPromptID(bridge)
        let replies = try request(.answer(agentID, promptID: promptID, .allow), to: bridge)
        #expect(await eventually { replies.values == [.answerResult(.failed)] })
        #expect(harness.holds == harness.releases)
    }

    // MARK: Voice

    @Test func voiceMessageThenRecordingIsTranscribedAndSent() async throws {
        let (bridge, channel, harness) = make()
        let id = UUID()
        let replies = try request(.voice(messageID: id, agentID), to: bridge)
        #expect(replies.values == [.received])
        let url = try recording()
        defer { removeRecordings(at: url) }
        bridge.receive(recordingAt: url, metadata: try metadata(id))
        let sent = WatchEvent.delivery(messageID: id, agentID, .sent(text: Self.transcript))
        #expect(await eventually { channel.events == [sent] })
        #expect(harness.sent == [Self.transcript])
        #expect(!exists(url))
        #expect(harness.holds == harness.releases)
    }

    @Test func recordingThenVoiceMessageIsTranscribedAndSent() async throws {
        let (bridge, channel, harness) = make()
        let id = UUID()
        let url = try recording()
        defer { removeRecordings(at: url) }
        bridge.receive(recordingAt: url, metadata: try metadata(id))
        #expect(harness.sent.isEmpty)
        let replies = try request(.voice(messageID: id, agentID), to: bridge)
        #expect(replies.values == [.received])
        let sent = WatchEvent.delivery(messageID: id, agentID, .sent(text: Self.transcript))
        #expect(await eventually { channel.events == [sent] })
        #expect(!exists(url))
    }

    @Test func anEmptyTranscriptSendsNothing() async throws {
        let (bridge, channel, harness) = make(transcriber: .words("  "))
        let id = UUID()
        _ = try request(.voice(messageID: id, agentID), to: bridge)
        let url = try recording()
        defer { removeRecordings(at: url) }
        bridge.receive(recordingAt: url, metadata: try metadata(id))
        #expect(await eventually { channel.events == [.delivery(messageID: id, agentID, .noWords)] })
        #expect(harness.sent.isEmpty)
        #expect(!exists(url))
    }

    /// No transcriber (below iOS 26), one that throws, and one that outruns
    /// its deadline: each a definite not-sent, the recording deleted.
    @Test(arguments: [
        (nil, "This iPhone can't transcribe voice"),
        (.fails, "Couldn't transcribe the recording"),
        (.stalls, "Couldn't transcribe the recording"),
    ] as [(ScriptedTranscriber.Behavior?, String)])
    func aRecordingThatIsNotTranscribedIsNotSent(
        transcriber: ScriptedTranscriber.Behavior?, reason: String
    ) async throws {
        let (bridge, channel, harness) = make(
            transcriber: transcriber, timing: Self.timing { $0.transcriptionDeadline = Self.short })
        let id = UUID()
        _ = try request(.voice(messageID: id, agentID), to: bridge)
        let url = try recording()
        defer { removeRecordings(at: url) }
        bridge.receive(recordingAt: url, metadata: try metadata(id))
        #expect(
            await eventually {
                channel.events == [.delivery(messageID: id, agentID, .notSent(reason: reason))]
            })
        #expect(harness.sent.isEmpty)
        #expect(!exists(url))
        #expect(harness.holds == harness.releases)
    }

    @Test func aRecordingThatNeverArrivesIsNotSent() async throws {
        let (bridge, channel, harness) = make(timing: Self.timing { $0.recordingWait = Self.short })
        let id = UUID()
        _ = try request(.voice(messageID: id, agentID), to: bridge)
        #expect(
            await eventually {
                channel.events
                    == [.delivery(messageID: id, agentID, .notSent(reason: "Recording didn't reach iPhone"))]
            })
        #expect(harness.sent.isEmpty)
        #expect(harness.holds == harness.releases)
    }

    /// The recording lands after the phone gave up on it: the watch's Try
    /// again finds it and sends.
    @Test func aRecordingThatArrivesLateIsSentOnRetry() async throws {
        let (bridge, channel, harness) = make(timing: Self.timing { $0.recordingWait = Self.short })
        let id = UUID()
        _ = try request(.voice(messageID: id, agentID), to: bridge)
        #expect(await eventually { channel.events.count == 1 })
        let url = try recording()
        defer { removeRecordings(at: url) }
        bridge.receive(recordingAt: url, metadata: try metadata(id))
        #expect(exists(url))

        _ = try request(.voice(messageID: id, agentID), to: bridge)
        let sent = WatchEvent.delivery(messageID: id, agentID, .sent(text: Self.transcript))
        #expect(await eventually { channel.events.last == sent })
        #expect(harness.sent == [Self.transcript])
        #expect(!exists(url))
        #expect(harness.holds == harness.releases)
    }

    @Test func aSecondCopyOfARecordingIsDeleted() async throws {
        let (bridge, channel, harness) = make()
        harness.holdsSends = true
        let id = UUID()
        _ = try request(.voice(messageID: id, agentID), to: bridge)
        let first = try recording()
        let whileInFlight = try recording()
        let afterwards = try recording()
        defer { removeRecordings(at: first, whileInFlight, afterwards) }
        bridge.receive(recordingAt: first, metadata: try metadata(id))
        #expect(await eventually { harness.sent.count == 1 })
        bridge.receive(recordingAt: whileInFlight, metadata: try metadata(id))
        #expect(!exists(whileInFlight))

        harness.releaseSends()
        #expect(await eventually { channel.events.count == 1 })
        bridge.receive(recordingAt: afterwards, metadata: try metadata(id))
        #expect(!exists(afterwards))
        #expect(harness.sent == [Self.transcript])
    }

    @Test func anUnclaimedRecordingExpires() async throws {
        let (bridge, _, _) = make(timing: Self.timing { $0.unclaimedRecordingLifetime = Self.short })
        let url = try recording()
        defer { removeRecordings(at: url) }
        bridge.receive(recordingAt: url, metadata: try metadata(UUID()))
        #expect(exists(url))
        #expect(await eventually { !exists(url) })
    }

    /// The expiry timer doesn't run while the app is suspended, so the next
    /// request sweeps whatever outlived it.
    @Test func eachRequestSweepsRecordingsPastTheirLifetime() throws {
        let (bridge, _, harness) = make()
        let stale = try recording()
        let fresh = try recording()
        defer { removeRecordings(at: stale, fresh) }
        bridge.receive(recordingAt: stale, metadata: try metadata(UUID()))
        harness.now = now.addingTimeInterval(299)
        bridge.receive(recordingAt: fresh, metadata: try metadata(UUID()))
        #expect(exists(stale))

        harness.now = now.addingTimeInterval(301)
        _ = try request(.refresh, to: bridge)
        #expect(!exists(stale))
        #expect(exists(fresh))
    }

    /// A voice message whose recording already expired is not sent at once,
    /// without waiting for a file that is gone; the watch's Try again
    /// transfers the recording again, and that one is sent.
    @Test func aVoiceMessageAfterItsRecordingExpiredIsNotSentAtOnce() async throws {
        let (bridge, channel, harness) = make()
        let id = UUID()
        let stale = try recording()
        let again = try recording()
        defer { removeRecordings(at: stale, again) }
        bridge.receive(recordingAt: stale, metadata: try metadata(id))
        harness.now = now.addingTimeInterval(301)

        _ = try request(.voice(messageID: id, agentID), to: bridge)

        #expect(!exists(stale))
        #expect(
            channel.events
                == [.delivery(messageID: id, agentID, .notSent(reason: "Recording didn't reach iPhone"))])
        #expect(harness.holds == harness.releases)

        bridge.receive(recordingAt: again, metadata: try metadata(id))
        _ = try request(.voice(messageID: id, agentID), to: bridge)
        let sent = WatchEvent.delivery(messageID: id, agentID, .sent(text: Self.transcript))
        #expect(await eventually { channel.events.last == sent })
        #expect(harness.sent == [Self.transcript])
    }

    @Test func aRetriedVoiceMessageResendsItsTranscript() async throws {
        let (bridge, channel, harness) = make()
        harness.sendOutcome = .notSent(reason: "Host isn't connected")
        let id = UUID()
        _ = try request(.voice(messageID: id, agentID), to: bridge)
        let url = try recording()
        defer { removeRecordings(at: url) }
        bridge.receive(recordingAt: url, metadata: try metadata(id))
        #expect(await eventually { channel.events.count == 1 })
        harness.sendOutcome = .sent
        _ = try request(.voice(messageID: id, agentID), to: bridge)
        #expect(await eventually { channel.events.count == 2 })
        #expect(harness.sent == [Self.transcript, Self.transcript])
        #expect(channel.events.last == .delivery(messageID: id, agentID, .sent(text: Self.transcript)))
    }

    // MARK: Holding the app awake

    @Test func reachabilityHoldsTheAppUntilTheWatchLeaves() {
        let (bridge, _, harness) = make()
        bridge.reachabilityDidChange(true)
        bridge.reachabilityDidChange(true)
        #expect(harness.holds == 1)
        #expect(harness.releases == 0)
        bridge.reachabilityDidChange(false)
        #expect(harness.releases == 1)
    }

    @Test func theWatchLeavingMidSendKeepsTheAppUntilTheSendEnds() async throws {
        let (bridge, channel, harness) = make()
        bridge.reachabilityDidChange(true)
        harness.holdsSends = true
        _ = try request(.send(messageID: UUID(), agentID, text: "next"), to: bridge)
        #expect(await eventually { harness.sent.count == 1 })
        bridge.reachabilityDidChange(false)
        #expect(harness.releases == 0)

        harness.releaseSends()
        #expect(await eventually { channel.events.count == 1 })
        #expect(harness.holds == 1)
        #expect(harness.releases == 1)
    }

    /// Background time running out lets go once; the requests still running
    /// release nothing more when they end, and one already answered is not
    /// answered again.
    @Test func backgroundTimeRunningOutReleasesOnce() async throws {
        let (bridge, channel, harness) = make()
        harness.holdsSends = true
        let replies = try request(.send(messageID: UUID(), agentID, text: "next"), to: bridge)
        #expect(harness.holds == 1)
        let expire = try #require(harness.expirations.first)
        expire()
        #expect(harness.releases == 1)
        expire()
        #expect(harness.releases == 1)
        #expect(replies.values == [.received])

        harness.releaseSends()
        #expect(await eventually { channel.events.count == 1 })
        #expect(harness.releases == 1)
    }

    /// Background time running out answers every request still waiting, at
    /// once, while the app still runs: a reply after it freezes never
    /// arrives. The read finishing later replies nothing more.
    @Test func backgroundTimeRunningOutAnswersEveryOpenRequest() async throws {
        let (bridge, _, harness) = make(source: connectedSource(agents: [summarized(session: "s-1")]))
        harness.lastReply = "Shipped the fix."
        harness.replyParks = true
        let latest = try request(.latest(agentID), to: bridge)
        #expect(await eventually { harness.replyReads == 1 })
        #expect(latest.values.isEmpty)

        let expire = try #require(harness.expirations.first)
        expire()
        #expect(latest.values == [.failure("Waycar on iPhone ran out of time — open it")])
        #expect(harness.releases == 1)

        harness.releaseReads()
        #expect(await eventually { harness.readsReturned == 1 })
        await settle()
        #expect(latest.values.count == 1, "never answered twice")
    }

    @Test func expirationRepliesBeforeReleaseAndOldWorkCannotReleaseANewLease() async throws {
        let (bridge, _, harness) = make(source: connectedSource(agents: [summarized(session: "s-1")]))
        harness.replyParks = true
        let latest = try request(.latest(agentID), to: bridge)
        try await waitUntil { harness.replyReads == 1 }
        harness.onRelease = { #expect(latest.values == [.failure(WatchBridge.Copy.ranOutOfTime)]) }
        let expire = try #require(harness.expirations.first)
        expire()
        harness.onRelease = nil
        bridge.reachabilityDidChange(true)
        harness.releaseReads()
        try await waitUntil { harness.readsReturned == 1 }
        #expect(harness.releases == 1)
        bridge.reachabilityDidChange(false)
        #expect(harness.releases == 2)
    }

    /// An expiration from an earlier hold never ends a later one.
    @Test func anEarlierHoldsExpirationIsIgnored() throws {
        let (bridge, _, harness) = make()
        bridge.reachabilityDidChange(true)
        bridge.reachabilityDidChange(false)
        bridge.reachabilityDidChange(true)
        #expect(harness.holds == 2)
        #expect(harness.releases == 1)

        try #require(harness.expirations.count == 2)
        harness.expirations[0]()
        #expect(harness.releases == 1)
        harness.expirations[1]()
        #expect(harness.releases == 2)
        // The reachability hold went with it: leaving releases nothing more.
        bridge.reachabilityDidChange(false)
        #expect(harness.releases == 2)
    }
}
