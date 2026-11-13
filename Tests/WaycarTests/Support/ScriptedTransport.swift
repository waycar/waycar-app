import Foundation
import WaycarSSH

@testable import Waycar

/// Scripted `Transport` for Console and EventsSession protocol-level tests:
/// the test scripts the snapshot and pane text, and drives the event stream
/// by hand. No SSH anywhere.
final actor ScriptedTransport: Transport {
    private(set) var isClosed = false
    /// Liveness is scripted separately from `close()`, so a test can model a
    /// degraded connection (dead link, live events reader) before the session
    /// decides to replace the transport.
    private var connectionAlive = true
    /// Every subscription set received, in order; the Console's
    /// resubscribe-on-membership-change behavior asserts on this.
    private(set) var capturedSubscriptions: [[EventSubscription]] = []
    private(set) var agentPromptParams: [AgentPromptParams] = []
    private(set) var abortedRuns: [String] = []
    private(set) var requestAnswers: [(target: String, id: String, answer: AgentRequestAnswer)] = []
    private var pendingRequests: [AgentPendingRequest] = []
    private var linkFacts = ServerSessionLinkFacts()

    func setServerSessionLinkFacts(_ facts: ServerSessionLinkFacts) { linkFacts = facts }
    func serverSessionLinkFacts() async -> ServerSessionLinkFacts { linkFacts }
    private var archived: [ArchivedServerSession] = []
    func setArchivedServerSessions(_ sessions: [ArchivedServerSession]) { archived = sessions }
    func archivedServerSessions() async -> [ArchivedServerSession] { archived }

    func setPendingRequests(_ requests: [AgentPendingRequest]) {
        pendingRequests = requests
    }

    func abortAgentRun(target: String) { abortedRuns.append(target) }

    func pendingAgentRequests(target: String) -> [AgentPendingRequest] { pendingRequests }

    func answerAgentRequest(target: String, requestID: String, answer: AgentRequestAnswer) {
        requestAnswers.append((target, requestID, answer))
        pendingRequests.removeAll { $0.id == requestID }
    }

    /// Every `pane.send_input` received, in order; the Shell Terminal
    /// Composer delivers through it.
    private(set) var paneInputParams: [PaneSendInputParams] = []
    private var paneInputFailures: [Int: TransportError] = [:]
    /// Every `agent.start` received, in order; the new-agent flow (#12)
    /// asserts on the params it forwarded.
    private(set) var agentStarts: [AgentLaunchRequest] = []
    /// Every worktree launch try received, in order, with the attempt it
    /// carried; the new-worktree flow (#97) asserts on the request/spec pairs
    /// it forwarded, and a replayed launch on whether its tries shared one
    /// attempt.
    private(set) var worktreeStarts:
        [(request: AgentLaunchRequest, worktree: WorktreeSpec, attempt: WorktreeLaunchAttempt)] = []
    /// The attempt each plain-shell worktree launch try carried, in order.
    private(set) var shellWorktreeAttempts: [WorktreeLaunchAttempt] = []
    /// How many worktree launch tries sent `worktree.create`. A try whose
    /// attempt already sent it continues in that worktree instead.
    private(set) var worktreeCreateDispatches = 0
    private var losesNextWorktreeCreate = false
    /// Every new-Workspace launch received, in order; the new-Workspace flow
    /// (#230) asserts on the request/spec pairs it forwarded.
    private(set) var workspaceStarts: [(request: AgentLaunchRequest, workspace: NewWorkspaceSpec)] =
        []
    private(set) var agentDiscoveryCount = 0
    private var availableKinds = SupportedAgentKind.allCases
    private var agentDiscoveryFailure: TransportError?
    /// Every `pane.close` received, in order; the close-pane flow (#13)
    /// asserts on the pane it targeted (and that the cancel path never
    /// appends here).
    private(set) var closedPanes: [PaneTarget] = []
    private(set) var closedTabs: [TabTarget] = []
    private var closeFailure: TransportError?
    private var nextTabCloseGate: ScriptedTransportCallGate?
    private var nextTabCloseLostAnswer: TransportError?
    /// Tabs a `closeTab` with a lost answer closed.
    private var silentlyClosedTabs: Set<String> = []
    /// Every `pane.move` received, in order; the drag-to-workspace flow
    /// asserts on the pane and destination it forwarded.
    private(set) var paneMoves: [PaneMoveParams] = []
    private var paneMoveResponse: PaneMoveResponse?
    private var moveFailure: (any Error)?
    private var nextPaneMoveGate: ScriptedTransportCallGate?
    private(set) var listedWorktreeWorkspaceIDs: [String] = []
    private(set) var removedWorktreeRequests: [WorktreeRemovalRequest] = []
    private var worktreeListResponse: WorktreeListResponse?
    private var worktreeListFailure: (any Error)?
    private var worktreeRemoveFailure: (any Error)?
    private var worktreeRemoveResponsePath: String?
    private var nextWorktreeAuthorizationGate: ScriptedTransportCallGate?
    private(set) var agentFocuses: [AgentTarget] = []
    private var focusFailure: TransportError?
    /// Every `agent.rename` / `workspace.rename` received, in order; the
    /// rename flows (#98) assert on the params they forwarded.
    private(set) var agentRenames: [AgentRenameParams] = []
    private(set) var workspaceRenames: [WorkspaceRenameParams] = []
    private var renameFailure: TransportError?
    private var startFailure: TransportError?
    private var nextAgentStartGate: ScriptedTransportCallGate?
    private var startedAgent: AgentInfo?
    private(set) var snapshotFetchCount = 0
    /// Records acknowledgement readiness at each snapshot's request boundary.
    private(set) var snapshotHadLiveSubscription: [Bool] = []
    /// Every attach request received, in order; the Attach store's
    /// open-once behavior asserts on this.
    private(set) var attachRequests: [TerminalAttachRequest] = []
    /// Everything sent down the live attach session, in order — keystrokes
    /// and resizes interleaved exactly as the store issued them.
    private(set) var attachInputs: [TerminalAttachInput] = []

    /// Every `ping` received, in order of arrival; the keepalive tests assert
    /// on how many the idle loop generated.
    private(set) var pingCount = 0
    /// How many `revalidate()` calls arrived; each also counts as a ping.
    private(set) var revalidateCount = 0
    private var pingFailures: [Int: TransportError] = [:]
    private var pingGate: ScriptedTransportCallGate?
    private var closeGate: ScriptedTransportCallGate?
    /// The scripted cost of the transport's first-request prerequisite
    /// (herdr's socket-path resolution, #87); nil scripts none.
    private var socketPathReadinessDelay: Duration?
    private var socketPathReady = false
    /// Every `awaitSocketPathReadiness()` call, in order; a latency test
    /// asserts the session awaited it exactly once per connect.
    private(set) var socketPathReadinessCalls = 0

    private var serverInfo: ServerInfo
    private var snapshot: SessionSnapshot
    private var snapshotFailure: TransportError?
    private var nextSnapshotGate: ScriptedTransportCallGate?
    private var agentPromptFailure: (any Error)?
    private var agentPromptFailures: [any Error] = []
    private var nextAgentPromptGate: ScriptedTransportCallGate?
    private var missingPaneIDs: Set<String> = []
    private var rejectedSubscription: (entry: EventSubscription, code: String)?
    private var nextStreamID: UInt64 = 0
    private var liveStreamID: UInt64?
    private var eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
    private var subscriptionObservers: [UUID: AsyncStream<[EventSubscription]>.Continuation] = [:]
    private var nextSubscriptionGate: ScriptedTransportCallGate?
    private var nextAttachID: UInt64 = 0
    private var liveAttachID: UInt64?
    private var nextAttachGate: ScriptedTransportCallGate?
    private var nextAttachSessionGate: ScriptedTransportCallGate?
    private var attachContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var attachInputTask: Task<Void, Never>?
    private var nextAttachEndGate: ScriptedTransportCallGate?
    private(set) var stageRequests: [PreparedImage] = []
    private var stageOutcomes: [Result<StagedImage, AttachmentStagingError>] = []
    private var stageGate: ScriptedTransportCallGate?
    private(set) var fileStageRequests: [PreparedFile] = []
    private var fileStageOutcomes: [Result<StagedFile, AttachmentStagingError>] = []
    private var fileStageGate: ScriptedTransportCallGate?
    /// Every `stageLaunchPromptFiles` batch, in order.
    private(set) var launchPromptStageRequests: [[LaunchPromptFile]] = []
    private var launchPromptStagingFailure: LaunchPromptStagingError?
    private var launchPromptCapabilityAnswer = LaunchPromptCapabilities(
        claudeAppendSystemPromptFile: true, codexProfileFile: true)
    /// The Host's current Notification Registration file bytes; nil scripts
    /// "no device registered yet".
    private(set) var notificationRegistration: Data?
    /// Every whole-file replace received, in order; the ceremony tests
    /// assert on what would have landed on the Host.
    private(set) var replacedNotificationRegistrations: [Data] = []
    private(set) var notificationRegistrationReads = 0
    private var notificationRegistrationReadFailure: NotificationRegistrationError?
    private var notificationRegistrationWriteFailure: NotificationRegistrationError?
    private var nextNotificationRegistrationReadGate: ScriptedTransportCallGate?
    private var nextNotificationRegistrationWriteGate: ScriptedTransportCallGate?
    private var notificationConfigWriteFailure: NotificationRegistrationError?
    /// The Host's current `notify.json` bytes; nil scripts "no config yet".
    /// The relay-URL write path (#76) asserts on what the ceremony merged in.
    private(set) var notificationConfig: Data?
    /// Every `notify.json` replace received, in order.
    private(set) var replacedNotificationConfigs: [Data] = []
    private(set) var notificationConfigReads = 0
    private var nextNotificationConfigReadGate: ScriptedTransportCallGate?
    /// The Host's current `sidebar.json` bytes; nil scripts "no snapshot yet"
    /// so layout precedence can fall through.
    private(set) var sidebarLayout: Data?
    private(set) var sidebarLayoutReads = 0
    private var nextSidebarLayoutGate: ScriptedTransportCallGate?
    private var sidebarLayoutReadFailure: (any Error)?
    /// The Agent Summaries the Host's plugin currently holds, keyed by pane.
    private(set) var agentSummaries: [String: AgentSummary] = [:]
    private(set) var agentSummaryReads = 0
    private var agentSummaryReadFailure: (any Error)?
    private var nextAgentSummaryReadGate: ScriptedTransportCallGate?
    /// Every `refresh-summaries` trigger received.
    private(set) var agentSummaryRefreshes = 0
    private var agentSummaryRefreshFailure: (any Error)?
    private var nextAgentSummaryRefreshGate: ScriptedTransportCallGate?
    /// The Shell Activity every subsequent sweep reports, keyed by pane; a
    /// pane not listed (or not asked about) is unknown.
    private var shellActivitiesByPane: [String: ShellActivity] = [:]
    private var shellActivityFailure: (any Error)?
    /// Every `shellActivities(paneIDs:)` call, and the pane ids each asked.
    private(set) var shellActivityReads = 0
    private(set) var shellActivityRequests: [[String]] = []
    /// The Chat Markers every subsequent read returns.
    private var chatModeMarkers: [ChatModeMarker] = []
    /// Every Chat Marker write received, in order, including failed ones.
    private(set) var chatModeMarkerWrites: [ChatModeMarker] = []
    /// Every Chat Marker delete received (pane ids), in order.
    private(set) var chatModeMarkerDeletes: [String] = []
    private(set) var chatModeMarkerReadCount = 0
    private var chatModeMarkerReadFailure: (any Error)?
    private var chatModeMarkerWriteFailure: (any Error)?
    private var nextChatModeMarkerWriteGate: ScriptedTransportCallGate?
    private var nextChatModeMarkerReadGate: ScriptedTransportCallGate?
    /// Every transcript read received, in order.
    private(set) var chatTranscriptRequests: [ChatTranscriptRequest] = []
    private var chatTranscriptResponder:
        @Sendable (ChatTranscriptRequest) throws -> ChatTranscriptSnapshot = { _ in
            throw ChatTranscriptError.readerUnavailable
        }
    private var chatTranscriptReadGate: ScriptedTransportCallGate?
    /// Every whole-file read received, in order.
    private(set) var previewFileReads: [(path: String, maxBytes: Int)] = []
    private var previewFileResponder: @Sendable (String, Int) throws -> Data = { _, _ in
        throw RemoteFilePreviewError.missing
    }
    /// Every inline chat media read received, in order.
    private(set) var chatMediaRequests: [ChatMediaRequest] = []
    private var chatMediaResponder: @Sendable (ChatMediaRequest) throws -> Data = { _ in
        throw ChatMediaError.pluginOutdated
    }
    /// Holds whole-file and chat media reads, after recording them, until opened.
    private var mediaReadGate: ScriptedTransportCallGate?
    /// Every `agent.send_keys` received, in order.
    private(set) var agentKeyParams: [AgentSendKeysParams] = []
    /// Every `pane.read` received, in order.
    private(set) var paneReadParams: [PaneReadParams] = []
    private var paneReadText = ""

    init(
        snapshot: SessionSnapshot = .fixture(),
        serverInfo: ServerInfo = ServerInfo(version: "0.7.5-fake", protocolVersion: 17)
    ) {
        self.snapshot = snapshot
        self.serverInfo = serverInfo
    }

    // MARK: Scripting

    /// Replaces the snapshot subsequent `sessionSnapshot()` calls return.
    func setSnapshot(_ snapshot: SessionSnapshot) {
        self.snapshot = snapshot
    }

    /// Makes every subsequent `sessionSnapshot` throw `failure`.
    func setSnapshotFailure(_ failure: TransportError?) {
        snapshotFailure = failure
    }

    /// Pauses the next snapshot after capturing its response, so tests can
    /// deterministically deliver events while that stale response is in flight.
    func gateNextSnapshot(using gate: ScriptedTransportCallGate) {
        nextSnapshotGate = gate
    }

    /// Makes every subsequent `promptAgent` throw `failure`.
    func setAgentPromptFailure(_ failure: (any Error)?) {
        agentPromptFailure = failure
    }

    /// Scripts one-shot `promptAgent` failures consumed in order, one per
    /// call, before any persistent failure applies: a call whose queue is
    /// non-empty throws the head and the rest stays queued. Lets a test
    /// model herdr refusing the first prompts of a booting agent and then
    /// accepting.
    func setAgentPromptFailures(_ failures: [any Error]) {
        agentPromptFailures = failures
    }

    /// Pauses the next Agent prompt after recording its params.
    func gateNextAgentPrompt(using gate: ScriptedTransportCallGate) {
        nextAgentPromptGate = gate
    }

    /// Scripts the `AgentInfo` `startAgent` returns; without it the fake
    /// synthesizes a Working agent from the start params.
    func setStartedAgent(_ agent: AgentInfo) {
        startedAgent = agent
    }

    /// Pauses the next start after recording its request and outcome, so a
    /// reconnect can verify while its old answer is still outstanding.
    func gateNextAgentStart(using gate: ScriptedTransportCallGate) {
        nextAgentStartGate = gate
    }

    /// Makes every subsequent `startAgent` throw `failure`.
    func setStartFailure(_ failure: TransportError?) {
        startFailure = failure
    }

    func setAvailableAgentKinds(
        _ kinds: [SupportedAgentKind],
        failure: TransportError? = nil
    ) {
        availableKinds = kinds
        agentDiscoveryFailure = failure
    }

    /// Makes every subsequent `closePane` throw `failure`.
    func setCloseFailure(_ failure: TransportError?) {
        closeFailure = failure
    }

    /// Pauses the next `closeTab` before it answers, so a test can act
    /// while that `tab.close` is in flight.
    func gateNextTabClose(using gate: ScriptedTransportCallGate) {
        nextTabCloseGate = gate
    }

    /// The next `closeTab` closes its tab and then fails with `failure`, as
    /// a `tab.close` whose answer a dropped connection lost does. herdr
    /// answers a later close of that tab `tab_not_found`.
    func loseNextTabCloseAnswer(with failure: TransportError) {
        nextTabCloseLostAnswer = failure
    }

    /// Scripts the `pane.move` reply; nil restores the synthesized default
    /// (the moved pane re-keyed under the destination workspace).
    func setPaneMoveResponse(_ response: PaneMoveResponse?) {
        paneMoveResponse = response
    }

    /// Makes every subsequent `movePane` throw `failure`.
    func setMoveFailure(_ failure: (any Error)?) {
        moveFailure = failure
    }

    /// Pauses the next `movePane` after recording its params, so tests can
    /// land a snapshot while the move's reply is still in flight.
    func gateNextPaneMove(using gate: ScriptedTransportCallGate) {
        nextPaneMoveGate = gate
    }

    func configureWorktreeList(
        _ response: WorktreeListResponse?, failure: (any Error)? = nil
    ) {
        worktreeListResponse = response
        worktreeListFailure = failure
    }

    func setWorktreeRemoveFailure(_ failure: (any Error)?) {
        worktreeRemoveFailure = failure
    }

    func setWorktreeRemoveResponsePath(_ path: String?) {
        worktreeRemoveResponsePath = path
    }

    func gateNextWorktreeAuthorization(using gate: ScriptedTransportCallGate) {
        nextWorktreeAuthorizationGate = gate
    }

    /// Makes every subsequent rename (agent or workspace) throw `failure`.
    func setFocusFailure(_ failure: TransportError?) {
        focusFailure = failure
    }

    func setRenameFailure(_ failure: TransportError?) {
        renameFailure = failure
    }

    func configureImageStaging(
        outcomes: [Result<StagedImage, AttachmentStagingError>],
        gate: ScriptedTransportCallGate? = nil
    ) {
        stageOutcomes = outcomes
        stageGate = gate
    }

    func configureFileStaging(
        outcomes: [Result<StagedFile, AttachmentStagingError>],
        gate: ScriptedTransportCallGate? = nil
    ) {
        fileStageOutcomes = outcomes
        fileStageGate = gate
    }

    /// What `launchPromptCapabilities()` answers; both routes by default.
    func setLaunchPromptCapabilities(_ capabilities: LaunchPromptCapabilities) {
        launchPromptCapabilityAnswer = capabilities
    }

    /// Fails every later `stageLaunchPromptFiles` (still recorded); nil
    /// restores success.
    func setLaunchPromptStagingFailure(_ failure: LaunchPromptStagingError?) {
        launchPromptStagingFailure = failure
    }

    /// Where a staged Launch Prompt File lands on the scripted Host.
    static func stagedLaunchPromptPath(for file: LaunchPromptFile) -> String {
        switch file.destination {
        case .stageDirectory: "/tmp/waycar.scripted/\(file.name)"
        case .codexProfile: "/home/me/.codex/\(file.name).config.toml"
        }
    }

    func gateNextAttachEnd(on gate: ScriptedTransportCallGate) {
        nextAttachEndGate = gate
    }

    /// Pauses the next events subscription after recording its requested set.
    func gateNextSubscription(using gate: ScriptedTransportCallGate) {
        nextSubscriptionGate = gate
    }

    /// Wait for actual stream installation, not merely a captured request.
    /// AsyncStream cancellation ends the wait if the test is canceled.
    func waitForLiveSubscription(containing expected: [EventSubscription]) async throws {
        if liveStreamID != nil, let current = capturedSubscriptions.last,
            expected.allSatisfy(current.contains)
        { return }
        let id = UUID()
        let updates = AsyncStream<[EventSubscription]>.makeStream()
        subscriptionObservers[id] = updates.continuation
        defer {
            subscriptionObservers[id] = nil
            updates.continuation.finish()
        }
        for await current in updates.stream {
            if expected.allSatisfy(current.contains) { return }
        }
        throw CancellationError()
    }

    /// Pushes one event onto the live stream; false if none is live.
    @discardableResult
    func emit(_ event: HerdrEvent) -> Bool {
        guard let eventContinuation else { return false }
        eventContinuation.yield(event)
        return true
    }

    /// Kills the live stream with `failure`, as a remotely dropped events
    /// channel would.
    func failEventStream(_ failure: TransportError) {
        eventContinuation?.finish(throwing: failure)
        eventContinuation = nil
        liveStreamID = nil
    }

    /// Pushes raw PTY bytes onto the live attach session; false if none is
    /// live.
    @discardableResult
    func emitAttachOutput(_ bytes: Data) -> Bool {
        guard let attachContinuation else { return false }
        attachContinuation.yield(bytes)
        return true
    }

    /// Ends the live attach session gracefully, as the remote attach exiting
    /// cleanly (the user detached inside the TUI) would.
    func endAttachFromRemote() {
        attachContinuation?.finish()
        attachContinuation = nil
        liveAttachID = nil
    }

    /// Kills the live attach session with `failure`, as a remotely dropped
    /// terminal channel would.
    func failAttachStream(_ failure: TransportError) {
        attachContinuation?.finish(throwing: failure)
        attachContinuation = nil
        liveAttachID = nil
    }

    /// Whether an attach session is currently live.
    var hasLiveAttachSession: Bool {
        attachContinuation != nil
    }

    /// Scripts the registration file the Host currently holds.
    func setNotificationRegistration(_ data: Data?) {
        notificationRegistration = data
    }

    /// Makes every subsequent registration read throw `failure`.
    func setNotificationRegistrationReadFailure(_ failure: NotificationRegistrationError?) {
        notificationRegistrationReadFailure = failure
    }

    /// Makes every subsequent registration replace throw `failure`.
    func setNotificationRegistrationWriteFailure(_ failure: NotificationRegistrationError?) {
        notificationRegistrationWriteFailure = failure
    }

    /// Scripts the `notify.json` config the Host currently holds.
    func setNotificationConfig(_ data: Data?) {
        notificationConfig = data
    }

    /// Scripts the `sidebar.json` snapshot the Host currently holds.
    func setSidebarLayout(_ data: Data?) {
        sidebarLayout = data
    }

    /// Makes every subsequent sidebar layout read throw `failure`.
    func setSidebarLayoutReadFailure(_ failure: (any Error)?) {
        sidebarLayoutReadFailure = failure
    }

    /// Scripts the Agent Summaries every subsequent read returns.
    func setAgentSummaries(_ summaries: [AgentSummary]) {
        agentSummaries = Dictionary(summaries.map { ($0.paneID, $0) }) { _, last in last }
    }

    /// Makes every subsequent Agent Summary read throw `failure`.
    func setAgentSummaryReadFailure(_ failure: (any Error)?) {
        agentSummaryReadFailure = failure
    }

    /// Pauses the next Agent Summary read after counting it.
    func gateNextAgentSummaryRead(using gate: ScriptedTransportCallGate) {
        nextAgentSummaryReadGate = gate
    }

    /// Makes every subsequent Agent Summary refresh trigger throw `failure`.
    func setAgentSummaryRefreshFailure(_ failure: (any Error)?) {
        agentSummaryRefreshFailure = failure
    }

    /// Pauses the next Agent Summary refresh trigger after counting it.
    func gateNextAgentSummaryRefresh(using gate: ScriptedTransportCallGate) {
        nextAgentSummaryRefreshGate = gate
    }

    /// Scripts the Chat Markers every subsequent read returns.
    func setChatModeMarkers(_ markers: [ChatModeMarker]) {
        chatModeMarkers = markers
    }

    /// Makes every subsequent Chat Marker read throw `error`.
    func setChatModeMarkerReadFailure(_ error: (any Error)?) {
        chatModeMarkerReadFailure = error
    }

    /// Makes every subsequent Chat Marker write throw `error` after
    /// recording it.
    func setChatModeMarkerWriteFailure(_ error: (any Error)?) {
        chatModeMarkerWriteFailure = error
    }

    /// Pauses the next Chat Marker write after recording it.
    func gateNextChatModeMarkerWrite(using gate: ScriptedTransportCallGate) {
        nextChatModeMarkerWriteGate = gate
    }

    /// Pauses the next Chat Marker read after counting it; it answers with
    /// the markers listed when it was asked.
    func gateNextChatModeMarkerRead(using gate: ScriptedTransportCallGate) {
        nextChatModeMarkerReadGate = gate
    }

    /// Answers every subsequent transcript read; the default throws
    /// `ChatTranscriptError.readerUnavailable`, an outdated plugin.
    func setChatTranscriptResponder(
        _ responder: @escaping @Sendable (ChatTranscriptRequest) throws -> ChatTranscriptSnapshot
    ) {
        chatTranscriptResponder = responder
    }

    /// Answers every subsequent whole-file read; the default finds no file.
    func setPreviewFileResponder(_ responder: @escaping @Sendable (String, Int) throws -> Data) {
        previewFileResponder = responder
    }

    /// Answers every subsequent inline chat media read; the default throws
    /// `ChatMediaError.pluginOutdated`.
    func setChatMediaResponder(_ responder: @escaping @Sendable (ChatMediaRequest) throws -> Data) {
        chatMediaResponder = responder
    }

    /// Holds whole-file and chat media reads at `gate` once recorded.
    func setMediaReadGate(_ gate: ScriptedTransportCallGate?) {
        mediaReadGate = gate
    }

    /// Holds transcript reads at `gate` once recorded.
    func setChatTranscriptReadGate(_ gate: ScriptedTransportCallGate?) {
        chatTranscriptReadGate = gate
    }

    /// Scripts the text every subsequent `pane.read` returns.
    func setPaneReadText(_ text: String) {
        paneReadText = text
    }

    /// Makes the `ordinal`-th `ping` on this transport throw `failure`. A real
    /// Transport turns a request the connection never answers into
    /// `.timedOut` at its deadline, so scripting that outcome exercises the
    /// same seam the session sees without putting a test on the clock.
    func failPing(atCall ordinal: Int, with failure: TransportError) {
        pingFailures[ordinal] = failure
    }

    /// Makes the `ordinal`-th `pane.send_input` on this transport throw
    /// `failure` after recording it — a request the link swallowed, so herdr
    /// may or may not have acted on it.
    func failPaneInput(atCall ordinal: Int, with failure: TransportError) {
        paneInputFailures[ordinal] = failure
    }

    /// Parks the next `ping` on `gate`, after counting it, so a test can hold
    /// one Host's liveness proof in flight while inspecting another's.
    func gateNextPing(using gate: ScriptedTransportCallGate) {
        pingGate = gate
    }

    /// Scripts the connection-scoped work the transport's first timed request
    /// would otherwise pay for — herdr's socket-path resolution — so latency
    /// tests can prove the measurement excludes it (#87, WS2). nil scripts no
    /// prerequisite; that is the default.
    func setSocketPathReadiness(delay: Duration?) {
        socketPathReadinessDelay = delay
    }

    /// Parks the next `close()` on `gate` — which records the entry before
    /// waiting — so a test can pin a session teardown mid-flight.
    func gateNextClose(using gate: ScriptedTransportCallGate) {
        closeGate = gate
    }

    /// Parks the next terminal open after recording its request. Tests use the
    /// gate's entry edge as a deterministic proof that Attach startup began.
    func gateNextAttach(using gate: ScriptedTransportCallGate) {
        nextAttachGate = gate
    }

    /// Parks the next terminal open after its session exists but before the
    /// caller receives it. This lets tests drive buffered output without
    /// polling for actor scheduling.
    func gateNextAttachSession(using gate: ScriptedTransportCallGate) {
        nextAttachSessionGate = gate
    }

    /// Scripts panes that no longer exist on the Host. herdr fails an entire
    /// `events.subscribe` when one pane-scoped entry names a pane that has
    /// exited (verified against a live 0.7.5 server), so the fake rejects the
    /// same way instead of quietly skipping the entry.
    func setMissingPanes(_ paneIDs: Set<String>) {
        missingPaneIDs = paneIDs
    }

    /// Scripts herdr refusing any `events.subscribe` that carries `entry`
    /// with `code` — what a server that does not speak an event kind a
    /// cached snapshot's protocol promised would answer (#105).
    func rejectSubscribes(containing entry: EventSubscription, code: String) {
        rejectedSubscription = (entry, code)
    }

    // MARK: Transport

    func revalidate() async throws -> ServerInfo {
        revalidateCount += 1
        return try await ping()
    }

    /// The real herdr transport resolves the socket path before its first
    /// request; `EventsSession` awaits that same work off its latency clock
    /// (#87, WS2). Here it is a scripted sleep, single-flight like the real
    /// resolution: the first settle pays the delay, later ones find it done.
    func awaitSocketPathReadiness() async {
        socketPathReadinessCalls += 1
        await settleSocketPathReadiness()
    }

    private func settleSocketPathReadiness() async {
        guard !socketPathReady else { return }
        socketPathReady = true
        if let delay = socketPathReadinessDelay {
            try? await Task.sleep(for: delay)
        }
    }

    func ping() async throws -> ServerInfo {
        // A real Transport's ping fails on a link its events reader has not
        // reported dead yet; the scripted one must too, or callers that race
        // a replacement see a phantom success from the transport that is
        // about to be replaced. A closed transport is NOT modelled here:
        // tests reuse one ScriptedTransport across a teardown redial, which
        // a real connection could not survive.
        guard connectionAlive else {
            throw TransportError.sshUnreachable(detail: "connection is dead")
        }
        // A real transport's first request pays the socket-path resolution;
        // an unresolved scripted readiness is paid here too, inside whatever
        // window the caller started.
        await settleSocketPathReadiness()
        pingCount += 1
        let failure = pingFailures[pingCount]
        let gate = pingGate
        pingGate = nil
        await gate?.waitUntilOpen()
        if let failure { throw failure }
        return serverInfo
    }

    func listAgents() async throws -> [Agent] {
        snapshot.agents.map(Agent.init)
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        agentDiscoveryCount += 1
        if let agentDiscoveryFailure { throw agentDiscoveryFailure }
        return availableKinds
    }

    /// Every Start Session (design §2 scenario 8) received. Like tmux, the
    /// next snapshot lists the new `main` session.
    private(set) var mainSessionStarts = 0

    func startMainSession() async throws {
        mainSessionStarts += 1
        snapshot = .fixture(
            agents: snapshot.agents,
            workspaces: snapshot.workspaces + [.fixture(workspaceID: "tmux:$9", label: "main")])
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        snapshotFetchCount += 1
        snapshotHadLiveSubscription.append(liveStreamID != nil)
        let response = snapshot
        let failure = snapshotFailure
        let gate = nextSnapshotGate
        nextSnapshotGate = nil
        await gate?.waitUntilOpen()
        if let failure { throw failure }
        return response
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        paneReadParams.append(params)
        return PaneReadResult(
            format: .text, paneID: params.paneID, revision: 0,
            source: params.source, tabID: "t", text: paneReadText,
            truncated: false, workspaceID: "w")
    }

    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
        return PaneReadResult(
            format: params.format ?? .text, paneID: params.target, revision: 0,
            source: params.source, tabID: "t", text: "",
            truncated: false, workspaceID: "w")
    }

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        agentPromptParams.append(params)
        let oneShotFailure = agentPromptFailures.isEmpty ? nil : agentPromptFailures.removeFirst()
        let failure = agentPromptFailure
        let gate = nextAgentPromptGate
        nextAgentPromptGate = nil
        await gate?.waitUntilOpen()
        if let oneShotFailure { throw oneShotFailure }
        if let failure { throw failure }
        return Agent(.fixture(paneID: params.target, status: .working))
    }

    func checkAgentInputScreen(target: String) async throws {}

    func sendAgentKeys(_ params: AgentSendKeysParams) async throws {
        agentKeyParams.append(params)
    }

    func sendPaneInput(_ params: PaneSendInputParams) async throws {
        paneInputParams.append(params)
        if let failure = paneInputFailures[paneInputParams.count] { throw failure }
    }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        agentStarts.append(request)
        let failure = startFailure
        let gate = nextAgentStartGate
        nextAgentStartGate = nil
        await gate?.waitUntilOpen()
        if let failure { throw failure }
        if let startedAgent { return Agent(startedAgent) }
        // Synthesize a freshly-Working agent so the caller and the follow-up
        // snapshot see the same pane the real server would report.
        return Agent(
            .fixture(
                paneID: "\(request.workspaceID ?? "w1"):pnew", status: .working,
                workspaceID: request.workspaceID ?? "w1", kind: request.kind,
                title: request.name))
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec, attempt: WorktreeLaunchAttempt
    ) async throws -> Agent {
        worktreeStarts.append((request, worktree, attempt))
        try createWorktree(for: attempt)
        if let startFailure { throw startFailure }
        if let startedAgent { return Agent(startedAgent) }
        // The real server answers with an agent in the *new* worktree
        // workspace, not the source one.
        return Agent(
            .fixture(
                paneID: "wt1:pnew", status: .working, workspaceID: "wt1",
                kind: request.kind, title: request.name))
    }

    /// Makes the next worktree launch try that sends `worktree.create` lose
    /// its answer: herdr got the request (the attempt records the dispatch)
    /// but the try throws `TransportError.timedOut`, as when
    /// `git worktree add` outlives the request budget.
    func loseNextWorktreeCreate() {
        losesNextWorktreeCreate = true
    }

    /// Stands in for the real Transport's worktree step, reporting the same
    /// `LaunchStep`s: a try whose attempt already sent `worktree.create`
    /// continues in that worktree (the real Transport finds it by
    /// reconciling `worktree.list`) instead of creating another.
    private func createWorktree(for attempt: WorktreeLaunchAttempt) throws {
        if attempt.current.createDispatched {
            LaunchProgress.report(.checkingForCreatedWorktree)
            return
        }
        LaunchProgress.report(.creatingWorktree)
        attempt.recordCreateDispatched()
        worktreeCreateDispatches += 1
        if losesNextWorktreeCreate {
            losesNextWorktreeCreate = false
            throw TransportError.timedOut
        }
    }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        workspaceStarts.append((request, workspace))
        if let startFailure { throw startFailure }
        if let startedAgent { return Agent(startedAgent) }
        return Agent(
            .fixture(
                paneID: "nw1:pnew", status: .working, workspaceID: "nw1",
                kind: request.kind, title: request.name))
    }

    // MARK: shell launches (#12)

    private(set) var shellStarts: [ShellLaunchRequest] = []
    private(set) var shellDestinations: [StartAgentStore.LaunchDestination] = []
    private var shellLaunchFailure: (any Error)?
    private var nextShellStartGate: ScriptedTransportCallGate?
    private var shellLaunchResult = ShellLaunchResult(
        paneID: "w1:p-shell", tabID: "w1:t-shell", terminalID: "term-shell",
        workspaceID: "w1")

    /// Scripts the `ShellLaunchResult` shell starts return; without it the
    /// fake synthesizes the default shell pane above.
    func setShellLaunchResult(_ result: ShellLaunchResult) {
        shellLaunchResult = result
    }

    /// Makes every subsequent shell launch throw `failure`.
    func setShellLaunchFailure(_ failure: (any Error)?) {
        shellLaunchFailure = failure
    }

    /// Pauses the next shell start in an existing Workspace after recording
    /// it.
    func gateNextShellStart(using gate: ScriptedTransportCallGate) {
        nextShellStartGate = gate
    }

    private func recordShellStart(
        _ request: ShellLaunchRequest, _ destination: StartAgentStore.LaunchDestination
    ) throws -> ShellLaunchResult {
        shellStarts.append(request)
        shellDestinations.append(destination)
        if let shellLaunchFailure { throw shellLaunchFailure }
        return shellLaunchResult
    }

    func startShellTerminal(_ request: ShellLaunchRequest) async throws -> ShellLaunchResult {
        let result = try recordShellStart(request, .existingWorkspace)
        let gate = nextShellStartGate
        nextShellStartGate = nil
        await gate?.waitUntilOpen()
        return result
    }

    func startShellTerminalInNewWorktree(
        _ request: ShellLaunchRequest, worktree: WorktreeSpec, attempt: WorktreeLaunchAttempt
    ) async throws -> ShellLaunchResult {
        shellWorktreeAttempts.append(attempt)
        try createWorktree(for: attempt)
        return try recordShellStart(request, .newWorktree(worktree))
    }

    func startShellTerminalInNewWorkspace(
        _ request: ShellLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> ShellLaunchResult {
        try recordShellStart(request, .newWorkspace(workspace))
    }

    func closePane(_ params: PaneTarget, closesWorktreeGroup: Bool) async throws {
        if let closeFailure { throw closeFailure }
        closedPanes.append(params)
    }

    // MARK: mosh scripting

    /// Scripts the mosh availability probe: `available` answers plainly,
    /// `failure` throws (cached as unavailable by the Console). Unset
    /// probes answer false, like a Host without mosh-server.
    private var moshProbeAvailable = false
    private var moshProbeFailure: (any Error)?
    private var nextMoshProbeGate: ScriptedTransportCallGate?
    private(set) var moshProbeCount = 0

    func setMoshProbeAvailable(_ available: Bool) {
        moshProbeAvailable = available
        moshProbeFailure = nil
    }

    func setMoshProbeFailure(_ failure: any Error) {
        moshProbeFailure = failure
    }

    /// Pauses the next mosh availability probe, so a test can observe the
    /// capsule's in-flight state before the outcome lands.
    func gateNextMoshProbe(on gate: ScriptedTransportCallGate) {
        nextMoshProbeGate = gate
    }

    func probeMoshServer() async throws -> Bool {
        moshProbeCount += 1
        let gate = nextMoshProbeGate
        nextMoshProbeGate = nil
        if let gate {
            await gate.waitUntilOpen()
        }
        if let moshProbeFailure { throw moshProbeFailure }
        return moshProbeAvailable
    }

    /// Scripts `runMoshBootstrap`: nil (the default) throws, like a Host
    /// whose bootstrap cannot run, so the attach falls back to SSH.
    private var moshBootstrapAnswer: MoshBootstrap?
    private var nextMoshBootstrapGate: ScriptedTransportCallGate?
    /// Every mosh bootstrap received, in order, with the SSH priority it
    /// ran at (#105).
    private(set) var moshBootstrapRequests: [TerminalAttachRequest] = []
    private(set) var moshBootstrapPriorities: [SSHOperationPriority] = []

    func setMoshBootstrap(_ bootstrap: MoshBootstrap?) {
        moshBootstrapAnswer = bootstrap
    }

    /// Pauses the next mosh bootstrap until the gate opens.
    func gateNextMoshBootstrap(on gate: ScriptedTransportCallGate) {
        nextMoshBootstrapGate = gate
    }

    func runMoshBootstrap(_ request: TerminalAttachRequest) async throws -> MoshBootstrap {
        moshBootstrapRequests.append(request)
        moshBootstrapPriorities.append(SSHOperationPriority.current)
        let gate = nextMoshBootstrapGate
        nextMoshBootstrapGate = nil
        await gate?.waitUntilOpen()
        guard let moshBootstrapAnswer else {
            throw TransportError.channelFailed(detail: "mosh bootstrap is not scripted")
        }
        return moshBootstrapAnswer
    }

    func closeTab(_ params: TabTarget) async throws {
        let gate = nextTabCloseGate
        nextTabCloseGate = nil
        await gate?.waitUntilOpen()
        if let closeFailure { throw closeFailure }
        guard !silentlyClosedTabs.contains(params.tabID) else {
            throw HerdrAPIError(code: "tab_not_found", message: "tab \(params.tabID) not found")
        }
        closedTabs.append(params)
        if let lostAnswer = nextTabCloseLostAnswer {
            nextTabCloseLostAnswer = nil
            silentlyClosedTabs.insert(params.tabID)
            throw lostAnswer
        }
    }

    func movePane(_ params: PaneMoveParams) async throws -> PaneMoveResponse {
        paneMoves.append(params)
        let gate = nextPaneMoveGate
        nextPaneMoveGate = nil
        await gate?.waitUntilOpen()
        if let moveFailure { throw moveFailure }
        if let paneMoveResponse { return paneMoveResponse }
        // Default: the moved pane re-keyed under the destination workspace,
        // the shape herdr reports for a cross-workspace `new_tab` move.
        let workspaceID: String
        if case .newTab(let destination) = params.destination,
            let destinationWorkspace = destination.workspaceID
        {
            workspaceID = destinationWorkspace
        } else {
            workspaceID = params.paneID.split(separator: ":").first.map(String.init) ?? "w1"
        }
        let newPaneID = "\(workspaceID):moved"
        let sourceWorkspace =
            params.paneID.split(separator: ":").first.map(String.init) ?? "w1"
        return PaneMoveResponse(
            moveResult: PaneMoveResult(
                changed: true,
                focusedPaneID: newPaneID,
                pane: PaneInfo(
                    agentStatus: .idle, focused: false, paneID: newPaneID, revision: 1,
                    tabID: "\(workspaceID):t1", terminalID: "term-\(newPaneID)",
                    workspaceID: workspaceID),
                previousPaneID: params.paneID,
                previousTabID: "\(sourceWorkspace):t1",
                previousWorkspaceID: sourceWorkspace,
                targetLayout: PaneLayoutSnapshot(
                    area: PaneLayoutRect(height: 24, width: 80, x: 0, y: 0),
                    focusedPaneID: newPaneID, panes: [], splits: [],
                    tabID: "\(workspaceID):t1", workspaceID: workspaceID, zoomed: false)))
    }

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        listedWorktreeWorkspaceIDs.append(workspaceID)
        if let worktreeListFailure { throw worktreeListFailure }
        guard let worktreeListResponse else {
            throw TransportError.channelFailed(detail: "no worktree list scripted")
        }
        return worktreeListResponse
    }

    func removeWorktree(
        _ request: WorktreeRemovalRequest,
        authorize: @escaping @Sendable (WorktreeRemovalRequest) async throws -> Void,
        onDispatched: @escaping @Sendable (WorktreeRemovalRequest) async -> Void
    ) async throws -> WorktreeRemovedResponse {
        let gate = nextWorktreeAuthorizationGate
        nextWorktreeAuthorizationGate = nil
        await gate?.waitUntilOpen()
        try await authorize(request)
        removedWorktreeRequests.append(request)
        await onDispatched(request)
        if let worktreeRemoveFailure { throw worktreeRemoveFailure }
        return WorktreeRemovedResponse(
            forced: false,
            path: worktreeRemoveResponsePath ?? request.identity.checkoutPath,
            workspaceID: request.identity.workspaceID)
    }

    func focusAgent(_ target: AgentTarget) async throws {
        agentFocuses.append(target)
        if let focusFailure { throw focusFailure }
    }

    func renameAgent(_ params: AgentRenameParams) async throws {
        if let renameFailure { throw renameFailure }
        agentRenames.append(params)
    }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        if let renameFailure { throw renameFailure }
        workspaceRenames.append(params)
    }

    /// Every shell-terminal creation received, in order.
    private(set) var shellTerminalCreations: [ShellTerminalCreationRequest] = []
    private var shellTerminalCreationFailure: (any Error)?
    private var shellTerminalSnapshot: SessionSnapshot?
    private var nextShellTerminalGate: ScriptedTransportCallGate?

    /// Scripts the next shell-terminal creations: they fail with `failure`,
    /// or succeed and replace the snapshot with `snapshotAfter` when given.
    func scriptShellTerminalCreation(
        failure: (any Error)? = nil, snapshotAfter: SessionSnapshot? = nil
    ) {
        shellTerminalCreationFailure = failure
        shellTerminalSnapshot = snapshotAfter
    }

    /// Pauses the next creation after recording its request.
    func gateNextShellTerminalCreation(using gate: ScriptedTransportCallGate) {
        nextShellTerminalGate = gate
    }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        shellTerminalCreations.append(request)
        let gate = nextShellTerminalGate
        nextShellTerminalGate = nil
        await gate?.waitUntilOpen()
        if let shellTerminalCreationFailure { throw shellTerminalCreationFailure }
        if let shellTerminalSnapshot { snapshot = shellTerminalSnapshot }
        return ShellTerminalIdentity(paneID: "w1:p-shell", tabID: "w1:t-shell", terminalID: "term-shell")
    }

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        guard liveStreamID == nil else {
            throw TransportError.eventsChannelAlreadyOpen
        }
        capturedSubscriptions.append(subscriptions)
        let gate = nextSubscriptionGate
        nextSubscriptionGate = nil
        await gate?.waitUntilOpen()
        if let missing = subscriptions.firstMissingPane(in: missingPaneIDs) {
            throw HerdrAPIError(code: "pane_not_found", message: "pane \(missing) not found")
        }
        if let rejected = rejectedSubscription, subscriptions.contains(rejected.entry) {
            throw HerdrAPIError(code: rejected.code, message: "unsupported subscription")
        }
        nextStreamID += 1
        let streamID = nextStreamID
        let (events, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
        liveStreamID = streamID
        eventContinuation = continuation
        for observer in subscriptionObservers.values { observer.yield(subscriptions) }
        return HerdrEventStream(events: events) {
            await self.endStream(id: streamID)
        }
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        guard liveAttachID == nil else {
            throw TransportError.terminalChannelAlreadyOpen
        }
        attachRequests.append(request)
        let gate = nextAttachGate
        nextAttachGate = nil
        await gate?.waitUntilOpen()
        nextAttachID += 1
        let attachID = nextAttachID
        let (output, outputContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let input = TerminalAttachInputQueue()
        let endGate = nextAttachEndGate
        nextAttachEndGate = nil
        let sessionGate = nextAttachSessionGate
        nextAttachSessionGate = nil
        liveAttachID = attachID
        attachContinuation = outputContinuation
        attachInputTask = Task {
            while let item = await input.next() {
                self.recordAttachInput(item)
            }
        }
        await sessionGate?.waitUntilOpen()
        return TerminalAttachSession(output: { output }, input: input) {
            await endGate?.waitUntilOpen()
            await self.endAttach(id: attachID)
        }
    }

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        stageRequests.append(image)
        await progress(
            AttachmentStageProgress(transferredBytes: 0, totalBytes: image.byteCount))
        let gate = stageGate
        stageGate = nil
        await gate?.waitUntilOpen()
        try Task.checkCancellation()
        await progress(
            AttachmentStageProgress(
                transferredBytes: image.byteCount,
                totalBytes: image.byteCount))
        guard !stageOutcomes.isEmpty else {
            throw AttachmentStagingError.transferFailed
        }
        return try stageOutcomes.removeFirst().get()
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        fileStageRequests.append(file)
        await progress(
            AttachmentStageProgress(transferredBytes: 0, totalBytes: file.byteCount))
        let gate = fileStageGate
        fileStageGate = nil
        await gate?.waitUntilOpen()
        try Task.checkCancellation()
        await progress(
            AttachmentStageProgress(
                transferredBytes: file.byteCount,
                totalBytes: file.byteCount))
        guard !fileStageOutcomes.isEmpty else {
            throw AttachmentStagingError.transferFailed
        }
        return try fileStageOutcomes.removeFirst().get()
    }

    func stageLaunchPromptFiles(
        _ files: [LaunchPromptFile]
    ) async throws -> [StagedLaunchPromptFile] {
        launchPromptStageRequests.append(files)
        if let launchPromptStagingFailure { throw launchPromptStagingFailure }
        return files.map {
            StagedLaunchPromptFile(file: $0, path: Self.stagedLaunchPromptPath(for: $0))
        }
    }

    func launchPromptCapabilities() async -> LaunchPromptCapabilities {
        launchPromptCapabilityAnswer
    }

    func gateNextNotificationRegistrationRead(_ gate: ScriptedTransportCallGate) {
        nextNotificationRegistrationReadGate = gate
    }

    func gateNextNotificationRegistrationWrite(_ gate: ScriptedTransportCallGate) {
        nextNotificationRegistrationWriteGate = gate
    }

    func setNotificationConfigWriteFailure(_ failure: NotificationRegistrationError?) {
        notificationConfigWriteFailure = failure
    }

    func readNotificationRegistration() async throws -> Data? {
        notificationRegistrationReads += 1
        let data = notificationRegistration
        let failure = notificationRegistrationReadFailure
        let gate = nextNotificationRegistrationReadGate
        nextNotificationRegistrationReadGate = nil
        if let gate { await gate.waitUntilOpen() }
        if let failure { throw failure }
        return data
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        let failure = notificationRegistrationWriteFailure
        let gate = nextNotificationRegistrationWriteGate
        nextNotificationRegistrationWriteGate = nil
        if let gate { await gate.waitUntilOpen() }
        if let failure { throw failure }
        notificationRegistration = contents
        replacedNotificationRegistrations.append(contents)
    }

    func gateNextNotificationConfigRead(_ gate: ScriptedTransportCallGate) {
        nextNotificationConfigReadGate = gate
    }

    func readNotificationConfig() async throws -> Data? {
        notificationConfigReads += 1
        if let failure = notificationRegistrationReadFailure { throw failure }
        let current = notificationConfig
        let gate = nextNotificationConfigReadGate
        nextNotificationConfigReadGate = nil
        await gate?.waitUntilOpen()
        return current
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        if let failure = notificationConfigWriteFailure ?? notificationRegistrationWriteFailure {
            throw failure
        }
        notificationConfig = contents
        replacedNotificationConfigs.append(contents)
    }

    func gateNextSidebarLayoutRead(_ gate: ScriptedTransportCallGate) {
        nextSidebarLayoutGate = gate
    }

    func readSidebarLayout() async throws -> Data? {
        sidebarLayoutReads += 1
        let data = sidebarLayout
        let failure = sidebarLayoutReadFailure
        let gate = nextSidebarLayoutGate
        nextSidebarLayoutGate = nil
        if let gate { await gate.waitUntilOpen() }
        if let failure { throw failure }
        return data
    }

    func readAgentSummaries() async throws -> [String: AgentSummary] {
        agentSummaryReads += 1
        let gate = nextAgentSummaryReadGate
        nextAgentSummaryReadGate = nil
        let failure = agentSummaryReadFailure
        let summaries = agentSummaries
        if let gate { await gate.waitUntilOpen() }
        if let failure { throw failure }
        return summaries
    }

    func refreshAgentSummaries() async throws {
        agentSummaryRefreshes += 1
        let gate = nextAgentSummaryRefreshGate
        nextAgentSummaryRefreshGate = nil
        let failure = agentSummaryRefreshFailure
        if let gate { await gate.waitUntilOpen() }
        if let failure { throw failure }
    }

    // MARK: Shell Activity

    func setShellActivities(_ activities: [String: ShellActivity]) {
        shellActivitiesByPane = activities
    }

    /// Makes every subsequent Shell Activity sweep throw `failure`.
    func setShellActivityFailure(_ failure: (any Error)?) {
        shellActivityFailure = failure
    }

    func shellActivities(paneIDs: [String]) async throws -> [String: ShellActivity] {
        shellActivityReads += 1
        shellActivityRequests.append(paneIDs)
        if let failure = shellActivityFailure { throw failure }
        let asked = Set(paneIDs)
        return shellActivitiesByPane.filter { asked.contains($0.key) }
    }

    // MARK: Chat Mode

    func readChatModeMarkers() async throws -> [ChatModeMarker] {
        chatModeMarkerReadCount += 1
        let gate = nextChatModeMarkerReadGate
        nextChatModeMarkerReadGate = nil
        let failure = chatModeMarkerReadFailure
        let markers = chatModeMarkers
        if let gate { await gate.waitUntilOpen() }
        if let failure { throw failure }
        return markers
    }

    func writeChatModeMarker(_ marker: ChatModeMarker) async throws {
        chatModeMarkerWrites.append(marker)
        let gate = nextChatModeMarkerWriteGate
        nextChatModeMarkerWriteGate = nil
        await gate?.waitUntilOpen()
        if let failure = chatModeMarkerWriteFailure { throw failure }
    }

    func deleteChatModeMarker(paneID: String) async throws {
        chatModeMarkerDeletes.append(paneID)
    }

    func readChatTranscript(_ request: ChatTranscriptRequest) async throws -> ChatTranscriptSnapshot {
        chatTranscriptRequests.append(request)
        await chatTranscriptReadGate?.waitUntilOpen()
        return try chatTranscriptResponder(request)
    }

    func readPreviewFile(atPath path: String, maxBytes: Int) async throws -> Data {
        previewFileReads.append((path, maxBytes))
        await mediaReadGate?.waitUntilOpen()
        return try previewFileResponder(path, maxBytes)
    }

    func readChatMedia(_ request: ChatMediaRequest) async throws -> Data {
        chatMediaRequests.append(request)
        await mediaReadGate?.waitUntilOpen()
        return try chatMediaResponder(request)
    }

    // MARK: CodexBar

    /// Answers to successive CodexBar probes; the last one repeats.
    private var codexBarLocations: [Result<String?, any Error>] = [.success(nil)]
    private(set) var codexBarLocateCount = 0
    /// Answers to successive `usage` runs; the last one repeats.
    private var codexBarUsageResults: [Result<AIUsageReport, any Error>] = [
        .failure(TransportError.channelFailed(detail: "No scripted CodexBar usage."))
    ]
    /// The path every `usage` run was handed, in order of arrival.
    private(set) var codexBarUsagePaths: [String] = []
    /// `usage` runs that got past their gate and answered.
    private(set) var codexBarUsageAnswerCount = 0
    private var nextCodexBarUsageGate: ScriptedTransportCallGate?

    func scriptCodexBarLocations(_ results: [Result<String?, any Error>]) {
        codexBarLocations = results
    }

    func scriptCodexBarUsage(_ results: [Result<AIUsageReport, any Error>]) {
        codexBarUsageResults = results
    }

    func gateNextCodexBarUsage(_ gate: ScriptedTransportCallGate) {
        nextCodexBarUsageGate = gate
    }

    func locateCodexBar(customPath: String?) async throws -> String? {
        let result = codexBarLocations[min(codexBarLocateCount, codexBarLocations.count - 1)]
        codexBarLocateCount += 1
        return try result.get()
    }

    func codexBarUsage(executablePath: String) async throws -> AIUsageReport {
        let result = codexBarUsageResults[
            min(codexBarUsagePaths.count, codexBarUsageResults.count - 1)]
        codexBarUsagePaths.append(executablePath)
        let gate = nextCodexBarUsageGate
        nextCodexBarUsageGate = nil
        if let gate { await gate.waitUntilOpen() }
        codexBarUsageAnswerCount += 1
        return try result.get()
    }

    /// Answers to successive `hostResourceUsage()` calls; the last repeats.
    private var hostResourceUsageResults: [Result<HostResourceUsage, any Error>] = [
        .failure(TransportError.channelFailed(detail: "No scripted Host resource usage."))
    ]
    private(set) var hostResourceUsageCount = 0

    func scriptHostResourceUsage(_ results: [Result<HostResourceUsage, any Error>]) {
        hostResourceUsageResults = results
    }

    func hostResourceUsage() async throws -> HostResourceUsage {
        let result = hostResourceUsageResults[
            min(hostResourceUsageCount, hostResourceUsageResults.count - 1)]
        hostResourceUsageCount += 1
        return try result.get()
    }

    private var connectionCheckGate: ScriptedTransportCallGate?

    func gateNextConnectionCheck(using gate: ScriptedTransportCallGate) {
        connectionCheckGate = gate
    }

    var isConnected: Bool {
        get async {
            let gate = connectionCheckGate
            connectionCheckGate = nil
            await gate?.waitUntilOpen()
            return connectionAlive && !isClosed
        }
    }

    /// Scripts the connection's liveness independently of the events stream,
    /// so a test can hold the session's silent transport-replacement path
    /// open (a degraded connection its events reader has not reported yet).
    func setConnectionAlive(_ alive: Bool) {
        connectionAlive = alive
    }

    /// How many times EventsSession distrusted this transport.
    private(set) var distrustCount = 0
    private var onDistrusted: (@Sendable () async -> Void)?

    /// Runs `action` from `transportDistrusted()`: what a real transport
    /// gives up for its replacement there (tmux's control slot).
    func setOnDistrusted(_ action: @escaping @Sendable () async -> Void) {
        onDistrusted = action
    }

    func transportDistrusted() async {
        distrustCount += 1
        await onDistrusted?()
    }

    private var onClose: (@Sendable () async -> Void)?

    /// Runs `action` from the first `close()`: what a real Transport gives
    /// back then, its hold on a pooled connection (#105).
    func setOnClose(_ action: @escaping @Sendable () async -> Void) {
        onClose = action
    }

    func close() async throws {
        let gate = closeGate
        closeGate = nil
        await gate?.waitUntilOpen()
        isClosed = true
        eventContinuation?.finish()
        eventContinuation = nil
        liveStreamID = nil
        attachContinuation?.finish()
        attachContinuation = nil
        liveAttachID = nil
        let closed = onClose
        onClose = nil
        await closed?()
    }

    /// Explicit `end()` on the stream: finishes it gracefully, exactly like
    /// the real channel closed by its consumer.
    private func endStream(id: UInt64) {
        guard liveStreamID == id else { return }
        eventContinuation?.finish()
        eventContinuation = nil
        liveStreamID = nil
    }

    private func recordAttachInput(_ input: TerminalAttachInput) {
        attachInputs.append(input)
    }

    /// Explicit `end()` on the session: finishes it gracefully, exactly like
    /// the real channel closed by its consumer. Drains the input recording
    /// first — `end()` finishes the input queue before calling this — so
    /// tests can assert on `attachInputs` without polling.
    private func endAttach(id: UInt64) async {
        await attachInputTask?.value
        attachInputTask = nil
        guard liveAttachID == id else { return }
        attachContinuation?.finish()
        attachContinuation = nil
        liveAttachID = nil
    }
}

private extension Sequence<EventSubscription> {
    /// The first pane-scoped entry naming a pane in `missing`, if any.
    func firstMissingPane(in missing: Set<String>) -> String? {
        for subscription in self {
            guard case .pane(_, let paneID) = subscription, missing.contains(paneID) else {
                continue
            }
            return paneID
        }
        return nil
    }
}

/// Hands scripted transports to an `EventsSession`'s `connect` closure in
/// order, one per dial, and counts the dials. The last entry repeats if the
/// session reconnects more often than the test scripted.
actor SequencedTransportConnector {
    private let transports: [ScriptedTransport]
    private(set) var connectCount = 0

    init(_ transports: [ScriptedTransport]) {
        precondition(!transports.isEmpty)
        self.transports = transports
    }

    func connect() async throws -> any Transport {
        let transport = transports[min(connectCount, transports.count - 1)]
        connectCount += 1
        return transport
    }
}

/// A one-shot test gate that exposes when a scripted transport call has
/// captured its response, then holds that response until the test releases it.
actor ScriptedTransportCallGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private(set) var entryCount = 0

    func waitUntilOpen() async {
        entryCount += 1
        let reached = entryWaiters.filter { entryCount >= $0.count }
        entryWaiters.removeAll { entryCount >= $0.count }
        for waiter in reached {
            waiter.continuation.resume()
        }
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForEntry(count: Int = 1) async {
        guard entryCount < count else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append((count, continuation))
        }
    }

    func open() {
        isOpen = true
        let resuming = waiters
        waiters.removeAll()
        for waiter in resuming { waiter.resume() }
    }
}

// MARK: Fixtures

extension SessionSnapshot {
    static func fixture(
        agents: [AgentInfo] = [], workspaces: [WorkspaceInfo] = [], protocolVersion: Int = 17,
        tabs: [TabInfo] = []
    ) -> SessionSnapshot {
        SessionSnapshot(
            agents: agents, layouts: [], panes: [], protocolVersion: protocolVersion, tabs: tabs,
            version: "0.7.5-fake", workspaces: workspaces)
    }
}

extension AgentInfo {
    static func fixture(
        paneID: String,
        status: AgentStatus = .idle,
        workspaceID: String = "w1",
        kind: String = "claude",
        title: String = "Task",
        revision: Int = 1,
        name: String? = nil,
        stateChangeSeq: Int? = nil
    ) -> AgentInfo {
        AgentInfo(
            agentStatus: status, focused: false, paneID: paneID, revision: revision,
            tabID: "\(workspaceID):t1", terminalID: "term_\(paneID)",
            workspaceID: workspaceID, agent: kind, cwd: "/work/\(workspaceID)",
            name: name, stateChangeSeq: stateChangeSeq, terminalTitleStripped: title)
    }
}

extension WorkspaceInfo {
    static func fixture(
        workspaceID: String,
        label: String,
        repoName: String? = nil,
        checkoutPath: String? = nil,
        isLinkedWorktree: Bool = false
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            activeTabID: "\(workspaceID):t1", agentStatus: .unknown, focused: false,
            label: label, number: 1, paneCount: 1, tabCount: 1, workspaceID: workspaceID,
            worktree: repoName.map { name in
                WorkspaceWorktreeInfo(
                    checkoutPath: checkoutPath ?? "/work/\(name)",
                    isLinkedWorktree: isLinkedWorktree,
                    repoKey: "/work/\(name)/.git", repoName: name, repoRoot: "/work/\(name)")
            })
    }
}

extension HerdrEvent {
    /// A `pane.agent_status_changed` event line as the live wire delivers it.
    static func agentStatusChanged(paneID: String, status: AgentStatus) -> HerdrEvent {
        HerdrEvent(
            kind: PaneEventKind.agentStatusChanged.kind,
            data: .object([
                "pane_id": .string(paneID),
                "agent_status": .string(status.rawValue),
                "state_labels": .object([:]),
            ]))
    }
}
