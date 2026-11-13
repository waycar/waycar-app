import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Agent action service")
struct AgentActionServiceTests {
    /// The Console calls the service makes, recorded.
    @MainActor
    final class FakeConsole {
        var agents: [ConsoleAgent]
        /// Returned in order; the last repeats. Empty throws.
        var screens: [String] = []
        private(set) var screenReads = 0
        private(set) var keys: [[String]] = []
        private(set) var prompts: [AgentPromptParams] = []
        var promptError: (any Error)?
        /// Set: each prompt waits here until resumed.
        var holdsPrompts = false
        private var heldPrompts: [CheckedContinuation<Void, Never>] = []
        private(set) var drafts: [String] = []
        private(set) var valueEvents = 0
        private(set) var turnsDone: [ConsoleAgent.ID] = []
        /// One status stream per `statusUpdates` call, oldest first.
        private(set) var feeds: [StatusFeed] = []
        /// The turn watcher's timeout clock: held until a test expires it.
        let clock = WatchClock()

        /// Pushes one status change (nil: the Agent left the list) to the
        /// newest watcher's stream. The feed is unbounded: nothing is
        /// dropped, and nothing here waits for the watcher to read it.
        func push(_ status: AgentStatus?) {
            feeds.last?.push(status)
        }

        init(_ agents: [ConsoleAgent]) {
            self.agents = agents
        }

        /// Lets every held prompt finish.
        func releasePrompts() {
            let held = heldPrompts
            heldPrompts = []
            for continuation in held { continuation.resume() }
        }

        var dependencies: AgentActionService.Dependencies {
            let clock = self.clock
            return AgentActionService.Dependencies(
                agent: { id in self.agents.first { $0.id == id } },
                readScreen: { _ in
                    defer { self.screenReads += 1 }
                    guard !self.screens.isEmpty else { throw TransportError.cancelled }
                    return self.screens[min(self.screenReads, self.screens.count - 1)]
                },
                sendKeys: { keys, _ in self.keys.append(keys) },
                promptAgent: { params, _ in
                    self.prompts.append(params)
                    if self.holdsPrompts {
                        await withCheckedContinuation { self.heldPrompts.append($0) }
                    }
                    if let error = self.promptError { throw error }
                },
                insertDraft: { _, text in self.drafts.append(text) },
                recordValueEvent: { self.valueEvents += 1 },
                noteTurnCompleted: { self.turnsDone.append($0) },
                statusUpdates: { id in
                    let (stream, continuation) = AsyncStream.makeStream(
                        of: ConsoleStore.AgentStatusUpdate.self)
                    let feed = StatusFeed(continuation)
                    // Like the Console's fan-out: the current status first.
                    feed.push(self.agents.first { $0.id == id }?.agent.status)
                    self.feeds.append(feed)
                    return stream
                },
                sleep: { duration in try await clock.sleep(duration) })
        }
    }

    /// One status stream the service watched, fed by the test.
    @MainActor
    final class StatusFeed {
        private let continuation: AsyncStream<ConsoleStore.AgentStatusUpdate>.Continuation
        /// The watcher's task was cancelled while it followed the stream.
        private(set) var wasCancelled = false

        init(_ continuation: AsyncStream<ConsoleStore.AgentStatusUpdate>.Continuation) {
            self.continuation = continuation
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { @MainActor in self?.wasCancelled = true }
            }
        }

        func push(_ status: AgentStatus?) {
            continuation.yield(.init(status: status, liveUpdatesAvailable: status != nil))
        }
    }

    /// The turn watcher's clock, held still: a `sleep` returns only when
    /// `expire()` is called, and throws when its task is cancelled.
    @MainActor
    final class WatchClock {
        private(set) var requested: [Duration] = []
        private var expiries: [AsyncStream<Void>.Continuation] = []

        func sleep(_ duration: Duration) async throws {
            requested.append(duration)
            let (ticks, expiry) = AsyncStream.makeStream(of: Void.self)
            expiries.append(expiry)
            for await _ in ticks { return }
            // The stream ends only when this sleep's task is cancelled.
            try Task.checkCancellation()
        }

        /// The time is up for every sleeper.
        func expire() {
            for expiry in expiries { expiry.yield(()) }
            expiries = []
        }
    }

    struct LinkDown: Error {}

    private let host = Host.fixture(name: "studio")

    private func agent(_ status: AgentStatus, kind: String = "claude") -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(.fixture(paneID: "w1:p1", status: status, kind: kind)),
            workspaceLabel: "iOS App", repositoryCheckout: nil, summary: nil, backend: .herdr)
    }

    static let permission = TmuxScreenDetectorTests.claudePermission
    static let risky = permission.replacingOccurrences(
        of: " touch x.txt", with: " git push --force origin main")

    // MARK: Sending

    @Test func aSentMessageIsOneSafeLine() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        let outcome = await actions.send("fix it\u{1B}[31m\nplease", to: row.id, suffix: nil)
        #expect(outcome == .sent)
        #expect(console.prompts == [AgentPromptParams(target: "w1:p1", text: "fix it[31m please")])
    }

    @Test func aSuffixIsAppendedOnlyWhenGiven() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        _ = await actions.send("status?", to: row.id, suffix: nil)
        _ = await actions.send(
            "status?", to: row.id, suffix: CarVoiceScript.spokenReplyInstruction)
        #expect(
            console.prompts.map(\.text) == [
                "status?", CarVoiceScript.outgoingPrompt(transcript: "status?"),
            ])
    }

    @Test func aFailureBeforeHandOverIsNotSent() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        console.promptError = RequestNotSentError(cause: TransportError.timedOut)
        let actions = AgentActionService(dependencies: console.dependencies)
        let outcome = await actions.send("status?", to: row.id, suffix: nil)
        #expect(outcome == .notSent(reason: "Host didn't answer"))
        #expect(console.prompts.count == 1)
        #expect(console.drafts.isEmpty)
    }

    @Test func aFailureAfterHandOverIsUnknownAndNeverResent() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        console.promptError = LinkDown()
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("status?", to: row.id, suffix: nil) == .unknown)
        #expect(console.prompts.count == 1)
        #expect(console.drafts.isEmpty)
    }

    @Test func aBlockedAgentKeepsTheMessageAsDraft() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("use pnpm", to: row.id, suffix: nil) == .keptAsDraft(.blocked))
        #expect(console.prompts.isEmpty)
        #expect(console.drafts == ["use pnpm"])
    }

    @Test func anAgentNoLongerListedIsNotSent() async {
        let console = FakeConsole([])
        let actions = AgentActionService(dependencies: console.dependencies)
        let outcome = await actions.send("status?", to: agent(.idle).id, suffix: nil)
        #expect(outcome == .notSent(reason: AgentActionService.notListedReason))
        #expect(console.prompts.isEmpty)
        #expect(console.drafts.isEmpty)
    }

    @Test func aPromptRefusedAsBlockedKeepsTheMessageAsDraft() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        console.promptError = TransportError.apiRejected(code: "agent_blocked", message: "blocked")
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("use pnpm", to: row.id, suffix: nil) == .keptAsDraft(.blocked))
        #expect(console.drafts == ["use pnpm"])
    }

    /// A sign-in screen or folder-trust dialog refuses the prompt before
    /// anything is typed: kept as the draft, with the reason.
    @Test(arguments: [true, false])
    func aPromptRefusedUnsentKeepsTheMessageAsDraft(signIn: Bool) async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        console.promptError =
            signIn
            ? AgentSignInRequiredError(kind: "cursor", target: row.agent.paneID)
            : AgentFolderTrustRequiredError(kind: "grok", target: row.agent.paneID)
        let actions = AgentActionService(dependencies: console.dependencies)
        let outcome = await actions.send("use pnpm", to: row.id, suffix: nil)
        #expect(outcome == .keptAsDraft(signIn ? .signInRequired : .folderTrustRequired))
        #expect(console.drafts == ["use pnpm"])
    }

    @Test func oneMessageIsInFlightPerAgent() async throws {
        let row = agent(.idle)
        let console = FakeConsole([row])
        console.holdsPrompts = true
        let actions = AgentActionService(dependencies: console.dependencies)
        let first = Task { await actions.send("first", to: row.id, suffix: nil) }
        try await waitUntil("the first message should reach the Host") {
            !console.prompts.isEmpty
        }
        #expect(actions.isSending(to: row.id))
        let second = await actions.send("second", to: row.id, suffix: nil)
        #expect(second == .notSent(reason: AgentActionService.busyReason))
        console.releasePrompts()
        #expect(await first.value == .sent)
        #expect(console.prompts.map(\.text) == ["first"])
        #expect(!actions.isSending(to: row.id))
    }

    // MARK: Review Prompt

    @Test func aDeliveredMessageCountsOneValueEvent() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("status?", to: row.id, suffix: nil) == .sent)
        #expect(console.valueEvents == 1)
    }

    @Test func aDeliveredMessageRecordsInTheReviewPromptStore() async throws {
        let suite = "ReviewPromptActionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReviewPromptStore(defaults: defaults)
        let row = agent(.idle)
        let console = FakeConsole([row])
        var dependencies = console.dependencies
        dependencies.recordValueEvent = { store.recordValueEvent() }
        dependencies.noteTurnCompleted = { store.noteTurnCompleted(agent: $0) }
        let actions = AgentActionService(dependencies: dependencies)
        #expect(await actions.send("status?", to: row.id, suffix: nil) == .sent)
        #expect(store.state.valueEventCount == 1)
        console.push(.working)
        console.push(.done)
        try await waitUntil("the finished turn should reach the store") {
            store.completedTurn?.agent == row.id
        }
    }

    @Test func aMessageThatDidNotGoOutCountsNothing() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        console.promptError = RequestNotSentError(cause: TransportError.timedOut)
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("a", to: row.id, suffix: nil) == .notSent(reason: "Host didn't answer"))
        console.promptError = LinkDown()
        #expect(await actions.send("b", to: row.id, suffix: nil) == .unknown)
        console.promptError = AgentSignInRequiredError(kind: "claude", target: row.agent.paneID)
        #expect(await actions.send("c", to: row.id, suffix: nil) == .keptAsDraft(.signInRequired))
        #expect(console.valueEvents == 0)
        #expect(console.feeds.isEmpty)
    }

    @Test func aMessageKeptAsDraftForABlockedAgentCountsNothing() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("use pnpm", to: row.id, suffix: nil) == .keptAsDraft(.blocked))
        #expect(console.valueEvents == 0)
    }

    @Test func aShellCountsNothing() async {
        let row = agent(.idle, kind: Agent.shellKind)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("ls", to: row.id, suffix: nil) == .sent)
        #expect(console.valueEvents == 0)
        #expect(console.feeds.isEmpty)
    }

    @Test func withoutAReviewPromptStoreASendIsUnchanged() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        var dependencies = console.dependencies
        dependencies.recordValueEvent = nil
        dependencies.noteTurnCompleted = nil
        dependencies.statusUpdates = nil
        let actions = AgentActionService(dependencies: dependencies)
        #expect(await actions.send("status?", to: row.id, suffix: nil) == .sent)
        #expect(console.valueEvents == 0)
        #expect(console.feeds.isEmpty)
        #expect(!actions.isWatchingTurn(of: row.id))
    }

    /// Waits until the Agent's turn watch is over.
    private func waitForWatchEnd(
        _ actions: AgentActionService, _ agentID: ConsoleAgent.ID
    ) async throws {
        try await waitUntil("the turn watch should end") { !actions.isWatchingTurn(of: agentID) }
    }

    @Test func theTurnIsNotedOnceWhenTheAgentFinishesIt() async throws {
        let row = agent(.idle)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("status?", to: row.id, suffix: nil) == .sent)
        console.push(.working)
        console.push(.done)
        // Later changes are never read: the watch ended with the turn.
        console.push(.working)
        console.push(.done)
        try await waitForWatchEnd(actions, row.id)
        #expect(console.turnsDone == [row.id])
    }

    @Test func aTurnFinishedWhileTheAgentWasAlreadyWorkingNeedsFreshWork() async throws {
        let row = agent(.working)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("also this", to: row.id, suffix: nil) == .sent)
        console.push(.done)
        console.push(.working)
        console.push(.done)
        try await waitUntil("the next finished turn should be noted") {
            console.turnsDone == [row.id]
        }
    }

    /// The Done of the turn the Agent was already on is not the message's.
    @Test func theDoneOfAnEarlierTurnIsNotNoted() async throws {
        let row = agent(.working)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("also this", to: row.id, suffix: nil) == .sent)
        console.push(.done)
        console.push(nil)
        try await waitForWatchEnd(actions, row.id)
        #expect(console.turnsDone.isEmpty)
    }

    /// The prompt itself starts the turn: the status after it is already
    /// working. The watcher seeds from the status before the prompt (the
    /// Composer's rule), so the replayed working and the Done are the
    /// message's own turn.
    @Test func theWatcherSeedsFromTheStatusBeforeThePromptWasSent() async throws {
        let row = agent(.idle)
        let console = FakeConsole([row])
        console.holdsPrompts = true
        let actions = AgentActionService(dependencies: console.dependencies)
        let send = Task { await actions.send("go on", to: row.id, suffix: nil) }
        try await waitUntil("the message should reach the Host") { !console.prompts.isEmpty }
        console.agents = [agent(.working)]
        console.releasePrompts()
        #expect(await send.value == .sent)
        // The Console replays the current (working) status, then Done.
        console.push(.working)
        console.push(.done)
        try await waitForWatchEnd(actions, row.id)
        #expect(console.turnsDone == [row.id])
    }

    /// An Agent already working at the send still needs fresh work before
    /// its Done counts, even though the prompt returns while it works.
    @Test func anAgentWorkingAtTheSendStillNeedsFreshWorkAfterThePrompt() async throws {
        let row = agent(.working)
        let console = FakeConsole([row])
        console.holdsPrompts = true
        let actions = AgentActionService(dependencies: console.dependencies)
        let send = Task { await actions.send("go on", to: row.id, suffix: nil) }
        try await waitUntil("the message should reach the Host") { !console.prompts.isEmpty }
        console.releasePrompts()
        #expect(await send.value == .sent)
        console.push(.working)
        console.push(.done)
        console.push(nil)
        try await waitForWatchEnd(actions, row.id)
        #expect(console.turnsDone.isEmpty)
    }

    @Test func theWatchEndsWhenTheAgentLeavesTheList() async throws {
        let row = agent(.idle)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("status?", to: row.id, suffix: nil) == .sent)
        #expect(actions.isWatchingTurn(of: row.id))
        console.push(.working)
        console.push(nil)
        try await waitForWatchEnd(actions, row.id)
        #expect(console.turnsDone.isEmpty)
    }

    @Test func aTurnThatNeverFinishesIsGivenUpOnAfterTheReviewWindow() async throws {
        let row = agent(.idle)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("status?", to: row.id, suffix: nil) == .sent)
        try await waitUntil("the watcher should start its clock") {
            console.clock.requested.count == 1
        }
        #expect(console.clock.requested == [.seconds(4 * 60 * 60)])
        #expect(actions.isWatchingTurn(of: row.id))
        console.clock.expire()
        try await waitForWatchEnd(actions, row.id)
        #expect(console.turnsDone.isEmpty)
        try await waitUntil("the abandoned status stream should be released") {
            console.feeds[0].wasCancelled
        }
    }

    @Test func aSecondMessageReplacesTheFirstWatcher() async throws {
        let row = agent(.idle)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("one", to: row.id, suffix: nil) == .sent)
        #expect(await actions.send("two", to: row.id, suffix: nil) == .sent)
        #expect(console.feeds.count == 2)
        try await waitUntil("the first watcher should be cancelled") {
            console.feeds[0].wasCancelled
        }
        console.push(.working)
        console.push(.done)
        try await waitForWatchEnd(actions, row.id)
        #expect(console.turnsDone == [row.id])
        #expect(console.valueEvents == 2)
    }

    @Test func aFailedSendLeavesTheEarlierWatcherAndCountAlone() async throws {
        let row = agent(.idle)
        let console = FakeConsole([row])
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(await actions.send("one", to: row.id, suffix: nil) == .sent)
        let failures: [any Error] = [
            RequestNotSentError(cause: TransportError.timedOut),
            LinkDown(),
            AgentSignInRequiredError(kind: "claude", target: row.agent.paneID),
        ]
        for failure in failures {
            console.promptError = failure
            let outcome = await actions.send("again", to: row.id, suffix: nil)
            #expect(outcome != .sent)
            #expect(console.feeds.count == 1)
            #expect(console.valueEvents == 1)
            #expect(actions.isWatchingTurn(of: row.id))
        }
        // The first message's watcher is still the one following the Agent.
        console.push(.working)
        console.push(.done)
        try await waitUntil("the first message's turn should still be noted") {
            console.turnsDone == [row.id]
        }
    }

    /// The hooks read the Console's Review Prompt store when called: the app
    /// makes the service before it installs the store.
    @Test func aLiveConsoleDeliveryCountsInAStoreInstalledAfterTheService() async throws {
        let suite = "ReviewPromptLiveActionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults)
        ) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
                keepalive: nil)
        }
        defer { console.setHosts([]) }
        console.setHosts([host])
        await console.resume()
        try await waitUntil("the Agent should arrive") { console.agents.count == 1 }
        let row = try #require(console.agents.first)

        let actions = AgentActionService(console: console)
        let store = ReviewPromptStore(defaults: defaults)
        console.installReviewPrompt(store)

        #expect(await actions.send("status?", to: row.id, suffix: nil) == .sent)
        #expect(store.state.valueEventCount == 1)
        #expect(await transport.agentPromptParams.map(\.text) == ["status?"])
        #expect(actions.isWatchingTurn(of: row.id))
    }

    // MARK: Blocked

    @Test func aBlockedPromptIsReadAndClassified() async throws {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        let actions = AgentActionService(dependencies: console.dependencies)
        let snapshot = try await actions.blockedPrompt(for: row.id)
        #expect(snapshot?.approval == .allow)
        #expect(snapshot?.prompt == .permission(command: "touch x.txt", isLossless: true))
    }

    @Test func anAgentThatIsNotBlockedHasNoPrompt() async throws {
        let row = agent(.working)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        let actions = AgentActionService(dependencies: console.dependencies)
        #expect(try await actions.blockedPrompt(for: row.id) == nil)
        #expect(console.screenReads == 0)
    }

    @Test func allowSendsEnterAndDenySendsEsc() async throws {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        let actions = AgentActionService(dependencies: console.dependencies)
        let shown = try #require(try await actions.blockedPrompt(for: row.id))
        #expect(await actions.answer(allow: true, agentID: row.id, shown: shown) == .sent)
        #expect(await actions.answer(allow: false, agentID: row.id, shown: shown) == .sent)
        #expect(console.keys == [["enter"], ["esc"]])
    }

    @Test func allowIsRefusedUnlessTheApprovalIsAllow() async throws {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.risky]
        let actions = AgentActionService(dependencies: console.dependencies)
        let held = try #require(try await actions.blockedPrompt(for: row.id))
        #expect(held.approval != .allow)
        #expect(await actions.answer(allow: true, agentID: row.id, shown: held) == .refused)
        #expect(console.keys.isEmpty)
        // A held prompt still gets Deny.
        #expect(await actions.answer(allow: false, agentID: row.id, shown: held) == .sent)
        #expect(console.keys == [["esc"]])
    }

    @Test func denyIsRefusedForAReadOnlyPrompt() async throws {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [TmuxScreenDetectorTests.claudeTrust]
        let actions = AgentActionService(dependencies: console.dependencies)
        let readOnly = try #require(try await actions.blockedPrompt(for: row.id))
        #expect(readOnly.approval == .readOnly)
        #expect(await actions.answer(allow: false, agentID: row.id, shown: readOnly) == .refused)
        #expect(await actions.answer(allow: true, agentID: row.id, shown: readOnly) == .refused)
        #expect(console.keys.isEmpty)
    }

    @Test func aPromptThatChangedSinceItWasShownIsNotAnswered() async throws {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission, Self.risky]
        let actions = AgentActionService(dependencies: console.dependencies)
        let shown = try #require(try await actions.blockedPrompt(for: row.id))
        #expect(await actions.answer(allow: true, agentID: row.id, shown: shown) == .promptChanged)
        #expect(await actions.answer(allow: false, agentID: row.id, shown: shown) == .promptChanged)
        #expect(console.keys.isEmpty)
    }

    @Test func anAnswerForAnAgentNoLongerListedFails() async throws {
        let console = FakeConsole([])
        console.screens = [Self.permission]
        let actions = AgentActionService(dependencies: console.dependencies)
        let shown = try #require(BlockedPromptSnapshot(kind: "claude", fullScreen: Self.permission))
        let gone = agent(.blocked).id
        #expect(await actions.answer(allow: true, agentID: gone, shown: shown) == .failed)
        #expect(await actions.answer(allow: false, agentID: gone, shown: shown) == .failed)
        #expect(console.screenReads == 0)
        #expect(console.keys.isEmpty)
    }

    /// A re-read that fails confirms nothing: not a changed prompt.
    @Test func anAnswerWhoseScreenReReadFailsFails() async throws {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        let actions = AgentActionService(dependencies: console.dependencies)
        let shown = try #require(try await actions.blockedPrompt(for: row.id))
        console.screens = []
        #expect(await actions.answer(allow: true, agentID: row.id, shown: shown) == .failed)
        #expect(await actions.answer(allow: false, agentID: row.id, shown: shown) == .failed)
        #expect(console.keys.isEmpty)
    }

    /// The screen may still show the prompt while the Agent has moved on.
    @Test func anAnswerAfterTheAgentLeftBlockedIsNotSent() async throws {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        let actions = AgentActionService(dependencies: console.dependencies)
        let shown = try #require(try await actions.blockedPrompt(for: row.id))
        console.agents = [agent(.working)]
        #expect(await actions.answer(allow: true, agentID: row.id, shown: shown) == .promptChanged)
        #expect(await actions.answer(allow: false, agentID: row.id, shown: shown) == .promptChanged)
        #expect(console.keys.isEmpty)
    }
}
