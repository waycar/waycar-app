import Foundation

/// The Sample Host's Transport (WAY-285): answers from `SampleFixture` and
/// opens no socket, so it works in airplane mode on a first launch. It is the
/// production counterpart of the screenshot fixture's DEBUG-only transport,
/// and unlike it reads no demo-mode flag.
///
/// It implements only what the Console needs to show the sample and let a
/// person look around. Everything that would write to a Host (notification
/// registration, Chat Mode markers, files, worktrees, status hooks) keeps
/// the protocol's refusing default, so a sample that somehow reached one
/// would fail rather than pretend. Keys sent to an Agent and prompts go
/// nowhere: the sample has no Agent to receive them.
actor SampleTransport: Transport {
    private var isClosed = false
    private var eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
    /// One live channel per Attach target, as the real transport keeps; a
    /// second target opens beside it and only a duplicate is refused.
    private var terminals:
        [TerminalAttachTarget: (
            output: AsyncThrowingStream<Data, any Error>.Continuation,
            input: TerminalAttachInputQueue
        )] = [:]

    init() {}

    func ping() async throws -> ServerInfo {
        ServerInfo(version: SampleFixture.snapshot.version, protocolVersion: 17)
    }

    func listAgents() async throws -> [Agent] {
        SampleFixture.snapshot.agents.map(Agent.init)
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        [.claude, .codex, .gemini, .opencode]
    }

    func readAgentSummaries() async throws -> [String: AgentSummary] {
        SampleFixture.summaries(now: Date())
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        SampleFixture.snapshot
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        let agent = SampleFixture.snapshot.agents.first(where: { $0.paneID == params.paneID })
        return PaneReadResult(
            format: .text,
            paneID: params.paneID,
            revision: 1,
            source: params.source,
            tabID: agent?.tabID ?? "sample:t1",
            text: params.paneID == SampleFixture.blockedPaneID
                ? SampleFixture.blockedPrompt : "Ready.",
            truncated: false,
            workspaceID: agent?.workspaceID ?? "sample")
    }

    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
        let agent = SampleFixture.snapshot.agents.first(where: { $0.paneID == params.target })
        return PaneReadResult(
            format: params.format ?? .text,
            paneID: params.target,
            revision: 1,
            source: params.source,
            tabID: agent?.tabID ?? "sample:t1",
            text: SampleFixture.terminalFrame(cols: 40, agent: agent),
            truncated: false,
            workspaceID: agent?.workspaceID ?? "sample")
    }

    private var readOnly: TransportError {
        .channelFailed(detail: "This is a read-only sample. Connect your machine to use your own agents.")
    }

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        throw readOnly
    }

    func checkAgentInputScreen(target: String) async throws { throw readOnly }

    func sendAgentKeys(_ params: AgentSendKeysParams) async throws { throw readOnly }

    func sendPaneInput(_ params: PaneSendInputParams) async throws { throw readOnly }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent { throw readOnly }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec,
        attempt: WorktreeLaunchAttempt
    ) async throws -> Agent { throw readOnly }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent { throw readOnly }

    func closePane(_ params: PaneTarget, closesWorktreeGroup: Bool) async throws { throw readOnly }

    func closeTab(_ params: TabTarget) async throws { throw readOnly }

    // There is no Host to probe or bootstrap, so mosh reports unavailable and
    // every attach rides the SSH-shaped `attachTerminal` below.
    func probeMoshServer() async throws -> Bool { false }

    func runMoshBootstrap(_ request: TerminalAttachRequest) async throws -> MoshBootstrap {
        throw TransportError.channelFailed(detail: "mosh is not available in the sample")
    }

    func hostResourceUsage() async throws -> HostResourceUsage {
        throw HostResourceUsage.Unsupported()
    }

    func movePane(_ params: PaneMoveParams) async throws -> PaneMoveResponse {
        throw TransportError.channelFailed(detail: "moves are not available in the sample")
    }

    func focusAgent(_ target: AgentTarget) async throws { throw readOnly }

    func renameAgent(_ params: AgentRenameParams) async throws { throw readOnly }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws { throw readOnly }

    func subscribeToEvents(
        _ subscriptions: [EventSubscription]
    ) async throws -> HerdrEventStream {
        guard eventContinuation == nil else {
            throw TransportError.eventsChannelAlreadyOpen
        }
        let (events, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
        eventContinuation = continuation
        return HerdrEventStream(events: events) { await self.endEvents() }
    }

    func attachTerminal(
        _ request: TerminalAttachRequest
    ) async throws -> TerminalAttachSession {
        let target = request.target
        guard terminals[target] == nil else {
            throw TransportError.terminalChannelAlreadyOpen
        }
        let (output, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let input = TerminalAttachInputQueue()
        terminals[target] = (continuation, input)
        let agent = SampleFixture.snapshot.agents.first(where: {
            $0.paneID == target.identifier || $0.terminalID == target.identifier
        })
        continuation.yield(
            Data(SampleFixture.terminalFrame(cols: request.cols, agent: agent).utf8))
        Task {
            // Repaint on every window change, as a TUI behind a real PTY does;
            // keystrokes and scrolling have nothing to drive.
            while let item = await input.next() {
                if case .resize(let cols, _) = item {
                    continuation.yield(
                        Data(SampleFixture.terminalFrame(cols: cols, agent: agent).utf8))
                }
            }
        }
        return TerminalAttachSession(output: { output }, input: input) {
            await self.endTerminal(target)
        }
    }

    var isConnected: Bool { !isClosed }

    func close() async throws {
        isClosed = true
        endEvents()
        for target in Array(terminals.keys) { endTerminal(target) }
    }

    private func endEvents() {
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func endTerminal(_ target: TerminalAttachTarget) {
        guard let channel = terminals.removeValue(forKey: target) else { return }
        channel.input.finish()
        channel.output.finish()
    }
}
