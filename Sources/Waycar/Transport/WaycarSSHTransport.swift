import Foundation
import WaycarSSH

private struct WaycarSSHSessionListResponse: Decodable {
    let sessions: [HerdrSession]
}

/// herdr's Transport. Ordinary herdr RPCs use fresh direct-streamlocal
/// channels, Events owns one reserved forwarding channel, and Attach owns one
/// reserved PTY exec channel per target (ADR 0011), all on the Host's
/// `HostSSHSession`, which also serves every request that does not speak
/// herdr (ADR 0026, design §4.8).
actor WaycarSSHTransport: Transport {
    /// Lowest herdr protocol this build can drive. Below it, methods this app
    /// calls may genuinely be absent, so the Host is refused.
    static let minimumProtocolVersion = 17
    /// Highest protocol the committed schema snapshot
    /// (`scripts/herdr-schema.json`) was generated against. A Host above this
    /// is accepted and fully usable; it is merely newer than this build knows.
    ///
    /// The version check is a floor rather than an equality on purpose. herdr
    /// states no stability guarantee, and CLAUDE.md's contract is to parse
    /// leniently and *surface* mismatches — surfacing and refusing are not the
    /// same thing. Equality turned protocol 19, which is additively compatible
    /// with 17 in every one of its 164 shared definitions, into an unusable
    /// Host (#140); bumping the constant would have rebuilt the same outage at
    /// protocol 20.
    static let generatedProtocolVersion = 22
    static let maximumResponseBytes = 1_048_576
    static let maxConcurrentForwardingChannels =
        SSHChannelAdmission.Limits.production.ordinaryForwarding
    static let maxConcurrentExecChannels =
        SSHChannelAdmission.Limits.production.ordinarySession
    static let maxConnectionChannels = SSHChannelAdmission.Limits.production.connection

    private let session: HostSSHSession
    private let socketLocation: HerdrSocketLocation
    private let requestTimeout: Duration
    private let shellReadinessBudget: Duration
    private let shellReadinessRetryDelay: Duration
    private let launchSettleDelay: Duration
    private let launchSettleInterval: Duration
    private let launchSettleWindow: Duration
    private let inputReadyTimeout: Duration
    private let worktreeCreateTimeout: Duration
    private let worktreeReconcileBudget: Duration
    private let worktreeReconcileInterval: Duration
    private let sessionListCommand: String
    private let attachCommand: String
    private let terminalAttachCommand: String
    private let pluginListCommand: String
    private let notificationConfigDirCommand: String
    private let codexHelpCommand: String
    private let notificationPlugin = SharedAsyncOperation<NotificationPlugin>(cachesSuccess: true)
    private let codexNoDaemon = SharedAsyncOperation<Bool>(cachesSuccess: true)
    /// True once `close()` has released this Transport's hold on the session.
    private var closed = false

    private enum EventsChannelState: Equatable {
        case idle
        case opening
        case streaming(readerID: UInt64)
    }

    private var eventsChannelState: EventsChannelState = .idle
    private var nextEventsReaderID: UInt64 = 0
    private var endedEventsReaders: Set<UInt64> = []
    /// Live events readers, so `close()` can end them when the session
    /// outlives this Transport.
    private var eventsReaders: [UInt64: Task<Void, Never>] = [:]

    private enum TerminalChannelState: Equatable {
        case opening
        case streaming(readerID: UInt64)
    }

    private var terminalChannelStates: [TerminalAttachTarget: TerminalChannelState] = [:]
    private var nextTerminalReaderID: UInt64 = 0
    /// Attach channels that ended before `attachTerminal` recorded them.
    private var endedTerminalReaders: Set<UInt64> = []
    /// Live Attaches, so `close()` can end them when the session outlives
    /// this Transport.
    private var liveAttaches: [UInt64: TerminalAttachSession] = [:]
    /// The post-start settle per launched pane (`scheduleLaunchSettle`).
    private var launchSettles: [String: Task<Void, Never>] = [:]

    /// A launch this Transport started whose prompts wait until the Agent
    /// takes input (`awaitAgentInput`), per its kind's
    /// `AgentScreen.InputReadiness`.
    private struct InputGate: Equatable {
        let kind: String
        let readiness: AgentScreen.InputReadiness
        /// Until then nothing goes out (`InputReadiness.minimumDelay`).
        let readyAt: ContinuousClock.Instant
        /// The input hold ends here: with a marker, `inputReadyTimeout`
        /// after the launch; without, at ``readyAt``.
        let opensAt: ContinuousClock.Instant
    }

    /// Open input gates by pane id (`gateAgentInput`).
    private var inputGates: [String: InputGate] = [:]

    /// Agent kinds by prompt target (pane id, or the name an `agent.get`
    /// was asked for), as launched here or as herdr last listed them
    /// (``agentKind(of:)``).
    private var agentKinds: [String: String] = [:]

    /// Dials a private session for `settings`: a connection this Transport
    /// alone holds and closes, as every Transport had before connections
    /// were shared. `HostSSHSession.dial(settings:)` describes the dial.
    static func connect(settings: SSHTransportSettings) async throws -> WaycarSSHTransport {
        let session = try await HostSSHSession.dial(settings: settings)
        return WaycarSSHTransport(session: session, settings: settings)
    }

    /// Test and fixture entry that already holds an authenticated connection.
    /// Command defaults come from `SSHTransportSettings` statics so they cannot
    /// drift from the production `init(session:settings:)` path (#133).
    init(
        connection: SSHConnection,
        socketPath: String,
        host: String = "127.0.0.1",
        requestTimeout: Duration = SSHTransportSettings.defaultRequestTimeout
    ) {
        session = HostSSHSession(
            connection: connection,
            host: host,
            socketLocation: .absolutePath(socketPath),
            requestTimeout: requestTimeout)
        socketLocation = .absolutePath(socketPath)
        self.requestTimeout = requestTimeout
        shellReadinessBudget = SSHTransportSettings.defaultShellReadinessBudget
        shellReadinessRetryDelay = SSHTransportSettings.defaultShellReadinessRetryDelay
        launchSettleDelay = SSHTransportSettings.defaultLaunchSettleDelay
        launchSettleInterval = SSHTransportSettings.defaultLaunchSettleInterval
        launchSettleWindow = SSHTransportSettings.defaultLaunchSettleWindow
        inputReadyTimeout = SSHTransportSettings.defaultInputReadyTimeout
        worktreeCreateTimeout = SSHTransportSettings.defaultWorktreeCreateTimeout
        worktreeReconcileBudget = SSHTransportSettings.defaultWorktreeReconcileBudget
        worktreeReconcileInterval = SSHTransportSettings.defaultWorktreeReconcileInterval
        sessionListCommand = SSHTransportSettings.defaultSessionListCommand
        attachCommand = SSHTransportSettings.defaultAttachCommand
        terminalAttachCommand = SSHTransportSettings.defaultTerminalAttachCommand
        pluginListCommand = SSHTransportSettings.defaultPluginListCommand
        notificationConfigDirCommand =
            SSHTransportSettings.defaultNotificationConfigDirCommand
        codexHelpCommand = SSHTransportSettings.defaultCodexHelpCommand
    }

    /// herdr's Transport on `session`, taking over one hold the caller
    /// already has on it; `close()` releases that hold.
    init(session: HostSSHSession, settings: SSHTransportSettings) {
        self.session = session
        socketLocation = settings.socket
        requestTimeout = settings.requestTimeout
        shellReadinessBudget = settings.shellReadinessBudget
        shellReadinessRetryDelay = settings.shellReadinessRetryDelay
        launchSettleDelay = settings.launchSettleDelay
        launchSettleInterval = settings.launchSettleInterval
        launchSettleWindow = settings.launchSettleWindow
        inputReadyTimeout = settings.inputReadyTimeout
        worktreeCreateTimeout = settings.worktreeCreateTimeout
        worktreeReconcileBudget = settings.worktreeReconcileBudget
        worktreeReconcileInterval = settings.worktreeReconcileInterval
        sessionListCommand = settings.sessionListCommand
        attachCommand = settings.attachCommand
        terminalAttachCommand = settings.terminalAttachCommand
        pluginListCommand = settings.pluginListCommand
        notificationConfigDirCommand = settings.notificationConfigDirCommand
        codexHelpCommand = settings.codexHelpCommand
    }

    deinit {
        // A Transport dropped without `close()` still returns its hold, so a
        // shared connection is not kept open for it.
        guard !closed else { return }
        let session = session
        Task { await session.release() }
    }

    func ping() async throws -> ServerInfo {
        let pong = try await request(method: "ping", decoding: PongResponse.self)
        return try Self.serverInfo(from: pong)
    }

    static func serverInfo(from pong: PongResponse) throws -> ServerInfo {
        guard pong.protocolVersion >= Self.minimumProtocolVersion else {
            throw TransportError.protocolVersionMismatch(
                server: pong.protocolVersion,
                supported: Self.minimumProtocolVersion)
        }
        return ServerInfo(
            version: pong.version,
            protocolVersion: pong.protocolVersion,
            exceedsGeneratedProtocol: pong.protocolVersion > Self.generatedProtocolVersion)
    }

    func listSessions() async throws -> [HerdrSession] {
        let output = try await runHostCommand(sessionListCommand)
        let sessions: [HerdrSession]
        do {
            sessions = try JSONDecoder().decode(
                WaycarSSHSessionListResponse.self,
                from: output).sessions
        } catch {
            throw TransportError.malformedResponse(
                "herdr session list returned invalid JSON: \(Self.preview(output))")
        }
        guard sessions.allSatisfy({ HerdrSessionName.isValid($0.name) }) else {
            throw TransportError.malformedResponse(
                "herdr session list returned an invalid session name")
        }
        return sessions
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        try await session.availableAgentKinds()
    }

    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill] {
        try await session.listSkills(query)
    }

    func readSkillFile(atPath path: String) async throws -> String {
        try await session.readSkillFile(atPath: path)
    }

    func listAgents() async throws -> [Agent] {
        let agents = try await request(method: "agent.list", decoding: AgentListResponse.self)
            .agents
        noteAgentKinds(agents)
        return agents.map(Agent.init)
    }

    func modelContextWindow(selector: String) async throws -> Int? {
        try await session.modelContextWindow(selector: selector)
    }

    func gitBranch(atPath path: String) async throws -> String? {
        try await session.gitBranch(atPath: path)
    }

    func locateCodexBar(customPath: String?) async throws -> String? {
        try await session.locateCodexBar(customPath: customPath)
    }

    func codexBarUsage(executablePath: String) async throws -> AIUsageReport {
        try await session.codexBarUsage(executablePath: executablePath)
    }

    func hostResourceUsage() async throws -> HostResourceUsage {
        try await session.hostResourceUsage()
    }

    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        try await session.readFileSlice(range)
    }

    func readPreviewFile(atPath path: String, maxBytes: Int) async throws -> Data {
        try await session.readPreviewFile(atPath: path, maxBytes: maxBytes)
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        let snapshot = try await request(
            method: "session.snapshot", decoding: SessionSnapshotResponse.self
        ).snapshot
        noteAgentKinds(snapshot.agents)
        return snapshot
    }

    /// Remembers each listed Agent's kind for ``agentKind(of:)``.
    private func noteAgentKinds(_ agents: [AgentInfo]) {
        for info in agents {
            if let kind = info.agent { agentKinds[info.paneID] = kind }
        }
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        try await request(method: "pane.read", params: params, decoding: PaneReadResponse.self)
            .read
    }

    /// Default request timeout on purpose: a short override's `.timedOut`
    /// would make EventsSession distrust and redial the link.
    func paneProcessInfo(paneID: String) async throws -> PaneProcessInfo {
        try await request(
            method: "pane.process_info", params: PaneProcessInfoParams(paneID: paneID),
            decoding: PaneProcessInfoResponse.self
        ).processInfo
    }

    /// One `pane.process_info` per pane, in order. A per-pane API error
    /// (`pane_not_found`, …) or bad response leaves that pane unknown;
    /// cancellation and link failures are rethrown. The command line
    /// may hold secrets: it is never logged here.
    func shellActivities(paneIDs: [String]) async throws -> [String: ShellActivity] {
        var result: [String: ShellActivity] = [:]
        for paneID in paneIDs {
            try Task.checkCancellation()
            do {
                let info = try await paneProcessInfo(paneID: paneID)
                if let activity = ShellForeground.activity(info) {
                    result[paneID] = activity
                }
            } catch is HerdrAPIError {
                continue
            } catch {
                if error is CancellationError || EventsSession.isTransportLinkFailure(error) {
                    throw error
                }
                if case .cancelled? = RequestNotSentError.unwrapped(error) as? TransportError {
                    throw error
                }
            }
        }
        return result
    }

    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
        try await request(method: "agent.read", params: params, decoding: PaneReadResponse.self)
            .read
    }

    /// A failure before the request's first byte — the input gate's screen
    /// read, the channel open, the request queue's deadline — fails
    /// `RequestNotSentError`. Once the channel is open and the write starts,
    /// a failure may come after herdr took the prompt, so it stays as is.
    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        let writing = RequestWriteMark()
        do {
            try await awaitAgentInput(target: params.target)
            let response = try await request(
                method: "agent.prompt", params: params, decoding: AgentPromptedResponse.self,
                beforeDispatch: { writing.mark() })
            return Agent(response.agent)
        } catch {
            guard !writing.isMarked else { throw error }
            throw RequestNotSentError.wrapping(error)
        }
    }

    /// Holds a prompt to an Agent this Transport launched until the kind's
    /// TUI takes input (`AgentScreen.readiness(kind:)`), and refuses one
    /// to a sign-in screen. herdr promotes a launch about 3.6 s after
    /// `agent.start` and `agent.prompt` then answers `agent_prompted`, but
    /// opencode and kilo drop typed input until their `┃` box draws (11–42 s
    /// for opencode on a 2-vCPU Host) and cline until its `❯` row does: the
    /// prompt was acked and lost. Each such prompt reads the visible screen
    /// once (`pane.read`); the marker ends the gate for good, and without it
    /// nothing is sent and the prompt fails `AgentInputNotReadyError`, which
    /// the Composer retries until its `opensAt`. A gate past
    /// `inputReadyTimeout` opens unread, as tmux's does
    /// (`TmuxTransport.checkLaunchReadiness`); every check drops such gates
    /// first. herdr reports a sign-in screen idle and ready (herdr 0.9.3),
    /// so every prompt to an Agent of a kind with one (cursor, devin, kiro,
    /// agy, muse) reads the screen and fails `AgentSignInRequiredError`
    /// while it shows, whoever launched the Agent and whichever Transport
    /// (reconnects build a new one): the kind is the target's
    /// (``agentKind(of:)``), not a launch's. The same holds for a
    /// folder-trust dialog herdr reads as idle (grok, gemini) or may (qwen,
    /// muse: herdr reads both as blocked, muse only by its remote
    /// `muse.toml`, but each kind shares one rule for both backends): it
    /// fails `AgentFolderTrustRequiredError`, since the prompt's text or
    /// Enter would answer it.
    private func awaitAgentInput(target: String) async throws {
        let now = ContinuousClock.now
        inputGates = inputGates.filter { now < $0.value.opensAt }
        let gate = inputGates[target]
        if let gate, now < gate.readyAt {
            throw AgentInputNotReadyError(kind: gate.kind, target: target, opensAt: gate.readyAt)
        }
        // A gate past its `readyAt` that is still open waits for a marker.
        let marker = gate?.readiness.marker
        let kind = try await agentKind(of: target)
        let readiness = kind.map(AgentScreen.readiness(kind:))
        let readsScreen = readiness.map { $0.hasSignInScreen || $0.hasTrustDialog } ?? false
        guard marker != nil || readsScreen else { return }
        let screen: PaneReadResult
        do {
            screen = try await readPane(PaneReadParams(paneID: target, source: .visible))
        } catch let error as HerdrAPIError where error.code == "pane_not_found" {
            // The pane closed: nothing will take input there any more.
            if let gate { forgetInputGate(gate, paneID: target) }
            agentKinds[target] = nil
            throw error
        }
        if let kind { try Self.refuseInputScreen(kind: kind, target: target, screen: screen.text) }
        if let gate, let marker {
            guard AgentScreen.inputIsOnScreen(marker, screen: screen.text) else {
                throw AgentInputNotReadyError(
                    kind: gate.kind, target: target, opensAt: gate.opensAt)
            }
            forgetInputGate(gate, paneID: target)
        }
    }

    /// The screen check ``awaitAgentInput(target:)`` runs, for the kind of
    /// the Agent `target` names; one `pane.read` for a kind with a sign-in
    /// screen or folder-trust dialog, none otherwise.
    func checkAgentInputScreen(target: String) async throws {
        guard let kind = try await agentKind(of: target) else { return }
        let readiness = AgentScreen.readiness(kind: kind)
        guard readiness.hasSignInScreen || readiness.hasTrustDialog else { return }
        let screen = try await readPane(PaneReadParams(paneID: target, source: .visible))
        try Self.refuseInputScreen(kind: kind, target: target, screen: screen.text)
    }

    /// Fails `AgentSignInRequiredError` while `screen` is `kind`'s sign-in
    /// screen, `AgentFolderTrustRequiredError` while it shows its
    /// folder-trust dialog.
    private static func refuseInputScreen(kind: String, target: String, screen: String) throws {
        let readiness = AgentScreen.readiness(kind: kind)
        if readiness.hasSignInScreen, AgentScreen.signInRequired(kind: kind, screen: screen) {
            throw AgentSignInRequiredError(kind: kind, target: target)
        }
        if readiness.hasTrustDialog, AgentScreen.trustDialogShown(kind: kind, screen: screen) {
            throw AgentFolderTrustRequiredError(kind: kind, target: target)
        }
    }

    /// The kind of the Agent `target` names: as launched here or as herdr
    /// last listed it (`session.snapshot`, `agent.list`), else as one
    /// `agent.get` now reports it, remembered. Nil when herdr names no
    /// kind or refuses the `agent.get`: the prompt then fails on its own.
    private func agentKind(of target: String) async throws -> String? {
        if let kind = agentKinds[target] { return kind }
        let info: AgentInfo
        do {
            info = try await request(
                method: "agent.get", params: AgentTarget(target: target),
                decoding: AgentInfoResponse.self
            ).agent
        } catch is HerdrAPIError {
            return nil
        }
        guard let kind = info.agent else { return nil }
        agentKinds[target] = kind
        return kind
    }

    /// Remembers the kind of a launch in `paneID` that started at
    /// `launchedAt`, and opens an input gate for it when its readiness
    /// needs one. Any other kind's launch replaces a gate the pane still
    /// had.
    private func gateAgentInput(
        kind: String, paneID: String, launchedAt: ContinuousClock.Instant
    ) {
        agentKinds[paneID] = kind
        let readiness = AgentScreen.readiness(kind: kind)
        guard readiness.gatesLaunch else {
            inputGates[paneID] = nil
            return
        }
        let readyAt = launchedAt + readiness.minimumDelay
        inputGates[paneID] = InputGate(
            kind: kind, readiness: readiness, readyAt: readyAt,
            opensAt: readiness.marker == nil ? readyAt : launchedAt + inputReadyTimeout)
    }

    /// Drops `gate`, unless a later launch in `paneID` replaced it while
    /// its screen was being read.
    private func forgetInputGate(_ gate: InputGate, paneID: String) {
        if inputGates[paneID] == gate { inputGates[paneID] = nil }
    }

    func sendAgentKeys(_ params: AgentSendKeysParams) async throws {
        _ = try await request(
            method: "agent.send_keys",
            params: params,
            decoding: OkResponse.self)
    }

    func sendPaneInput(_ params: PaneSendInputParams) async throws {
        _ = try await request(
            method: "pane.send_input",
            params: params,
            decoding: OkResponse.self)
    }

    /// Renames a tab. Best-effort at launch sites: the reply is `tab_info`
    /// (probed live against herdr 0.9), so a cosmetic rename must never fail
    /// a start that already succeeded.
    func renameTab(_ params: TabRenameParams) async throws -> TabInfoResponse {
        try await request(
            method: "tab.rename",
            params: params,
            decoding: TabInfoResponse.self)
    }

    func renameShellTab(tabID: String, label: String) async throws {
        _ = try await renameTab(TabRenameParams(label: label, tabID: tabID))
    }

    func createShellTerminal(
        _ creation: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        let created = try await request(
            method: "tab.create",
            params: TabCreateParams(
                cwd: creation.cwd,
                env: Self.shellLaunchEnvironment,
                focus: false,
                workspaceID: creation.workspaceID),
            decoding: TabCreatedResponse.self)
        return ShellTerminalIdentity(
            paneID: created.rootPane.paneID,
            tabID: created.rootPane.tabID,
            terminalID: created.rootPane.terminalID)
    }

    func startAgent(_ launch: AgentLaunchRequest) async throws -> Agent {
        if let earlier = try await earlierAgentLaunch(launch, workspaceID: launch.workspaceID) {
            return earlier
        }
        LaunchProgress.report(.creatingTab)
        let created = try await request(
            method: "tab.create",
            params: TabCreateParams(
                cwd: launch.cwd,
                env: launch.environment.isEmpty ? nil : launch.environment,
                focus: false,
                label: launch.name,
                workspaceID: launch.workspaceID),
            decoding: TabCreatedResponse.self)
        LaunchProgress.report(.startingAgent)
        do {
            let response = try await startAgentAwaitingShell(
                launch,
                paneID: created.rootPane.paneID)
            return Agent(response.agent)
        } catch let error as HerdrAPIError {
            try? await closePane(
                PaneTarget(paneID: created.rootPane.paneID), closesWorktreeGroup: false)
            throw error
        }
    }

    func startAgentInNewWorktree(
        _ launch: AgentLaunchRequest,
        worktree: WorktreeSpec,
        attempt: WorktreeLaunchAttempt
    ) async throws -> Agent {
        guard let sourceWorkspaceID = launch.workspaceID else {
            throw TransportError.channelFailed(
                detail: "a worktree launch needs a workspace")
        }
        switch try await worktreeLaunchTarget(
            worktree, sourceWorkspaceID: sourceWorkspaceID, attempt: attempt)
        {
        case .adopted(let adopted):
            if let earlier = try await earlierAgentLaunch(
                launch, workspaceID: adopted.workspaceID) { return earlier }
            if let running = try await runningAgent(
                inWorkspace: adopted.workspaceID, preferringKind: launch.kind,
                excludingTabLabel: launch.mayHaveStarted && launch.launchID != nil ? launch.name : nil)
            {
                LaunchProgress.report(.joiningRunningAgent)
                return running
            }
            return try await startAgent(
                AgentLaunchRequest(
                    kind: launch.kind,
                    name: launch.name,
                    arguments: launch.arguments,
                    workspaceID: adopted.workspaceID,
                    cwd: adopted.path,
                    environment: launch.environment,
                    launchID: launch.launchID, mayHaveStarted: launch.mayHaveStarted,
                    joinsCodexServer: launch.joinsCodexServer))
        case .own(let own, let continuing):
            if let earlier = try await earlierAgentLaunch(
                launch, workspaceID: own.workspaceID) { return earlier }
            // The worktree's new Workspace is branch-named, so give the Tab
            // the agent's name. Best-effort: a cosmetic rename must never
            // fail a start that already succeeded.
            if launch.launchID == nil || launch.environment.isEmpty {
                try? await renameTab(
                    TabRenameParams(label: launch.name, tabID: own.tabID))
            }
            if !launch.environment.isEmpty {
                return try await startAgentInOwnTab(
                    launch, own: own, continuing: continuing, attempt: attempt)
            }
            if continuing,
                let started = try await agentStartedEarlier(
                    where: { $0.paneID == own.rootPaneID }, kind: launch.kind, attempt: attempt)
            {
                return started
            }
            let mayRemove = attempt.current.mayRemoveWorktreeOnFailure
            LaunchProgress.report(.startingAgent)
            do {
                let response = try await startAgentAwaitingShell(
                    launch,
                    paneID: own.rootPaneID,
                    onDispatched: { attempt.recordAgentStartDispatched(at: .now) })
                return Agent(response.agent)
            } catch let error as HerdrAPIError {
                if mayRemove {
                    try? await removeCreatedWorktree(workspaceID: own.workspaceID)
                }
                throw error
            }
        }
    }

    /// An env-carrying launch in its own worktree. `worktree.create` takes
    /// no env (herdr 0.9.3 schema), so the root pane cannot carry it: the
    /// Agent gets a tab of its own, which can, and the bare root shell goes.
    /// A continuing try first waits for the Agent an earlier try started in
    /// such a tab, then starts in the tab an earlier try opened, if any,
    /// rather than opening another.
    private func startAgentInOwnTab(
        _ launch: AgentLaunchRequest, own: WorktreeLaunchAttempt.Worktree, continuing: Bool,
        attempt: WorktreeLaunchAttempt
    ) async throws -> Agent {
        if continuing,
            let running = try await agentStartedEarlier(
                where: { $0.workspaceID == own.workspaceID }, kind: launch.kind, attempt: attempt)
        {
            // Best-effort: an earlier try may have closed it.
            try? await closePane(PaneTarget(paneID: own.rootPaneID), closesWorktreeGroup: false)
            return running
        }
        // An earlier try records the dispatch before its `tab.create`.
        var orphan: ShellLaunchResult?
        if continuing, attempt.current.agentStartDispatchedAt != nil {
            orphan = try await earlierTab(openedIn: own)
        }
        let mayRemove = attempt.current.mayRemoveWorktreeOnFailure
        attempt.recordAgentStartDispatched(at: .now)
        do {
            let agent: Agent
            if let orphan {
                LaunchProgress.report(.startingAgent)
                do {
                    agent = Agent(try await startAgentAwaitingShell(launch, paneID: orphan.paneID).agent)
                } catch let error as HerdrAPIError {
                    try? await closePane(
                        PaneTarget(paneID: orphan.paneID), closesWorktreeGroup: false)
                    throw error
                }
            } else {
                agent = try await startAgent(
                    AgentLaunchRequest(
                        kind: launch.kind, name: launch.name, arguments: launch.arguments,
                        workspaceID: own.workspaceID, cwd: own.path,
                        environment: launch.environment,
                        launchID: launch.launchID, mayHaveStarted: launch.mayHaveStarted,
                        joinsCodexServer: launch.joinsCodexServer))
            }
            try? await closePane(PaneTarget(paneID: own.rootPaneID), closesWorktreeGroup: false)
            return agent
        } catch let error as HerdrAPIError {
            if mayRemove {
                try? await removeCreatedWorktree(workspaceID: own.workspaceID)
            }
            throw error
        }
    }

    func startAgentInNewWorkspace(
        _ launch: AgentLaunchRequest,
        workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        if let earlier = try await earlierAgentLaunch(launch, workspaceID: nil) { return earlier }
        LaunchProgress.report(.creatingWorkspace)
        let created = try await request(
            method: "workspace.create",
            params: WorkspaceCreateParams(
                cwd: workspace.directory,
                env: launch.environment.isEmpty ? nil : launch.environment,
                focus: false,
                label: workspace.label),
            decoding: WorkspaceCreatedResponse.self)
        // workspace.create labels the Workspace, not its first tab; give the
        // fresh tab the agent's name so the tab bar reads right. Best-effort:
        // a rename failure must not abort a launch that already succeeded.
        try? await renameTab(
            TabRenameParams(label: launch.name, tabID: created.tab.tabID))
        LaunchProgress.report(.startingAgent)
        do {
            let response = try await startAgentAwaitingShell(
                launch,
                paneID: created.rootPane.paneID)
            return Agent(response.agent)
        } catch let error as HerdrAPIError {
            try? await closeCreatedWorkspace(workspaceID: created.workspace.workspaceID)
            throw error
        }
    }

    // Plain-shell launches from the new-agent flow: the same
    // tab.create / worktree.create / workspace.create choreography as the
    // agent variants, minus `agent.start`. herdr's root panes already run
    // the Host's default shell, so the created pane is the shell an SSH
    // login would land in; the Console lists it as a shell row.
    //
    // Every shell pane is created with `shellLaunchEnvironment`, so a Host's
    // rc can tell a requested plain shell from an ordinary fresh pane and
    // skip agent auto-launch hooks there.

    /// Environment marking a pane Waycar created as a plain shell.
    static let shellLaunchEnvironment = ["WAYCAR_SHELL": "1"]

    func startShellTerminal(
        _ launch: ShellLaunchRequest
    ) async throws -> ShellLaunchResult {
        guard let workspaceID = launch.workspaceID else {
            throw TransportError.channelFailed(
                detail: "a shell launch needs a workspace")
        }
        if launch.mayHaveStarted, launch.launchID != nil,
            let earlier = try await taggedLaunchTab(name: launch.name, workspaceID: workspaceID)
        {
            return earlier
        }
        // The marked tab is the shell itself: one `tab.create`, one step.
        LaunchProgress.report(.openingShell)
        // Like `startAgent`, an absent cwd is left to herdr: with a
        // workspace id, `tab.create` resolves it to that Workspace's
        // focused pane cwd, never another Workspace's.
        let created = try await request(
            method: "tab.create",
            params: TabCreateParams(
                cwd: launch.cwd,
                env: Self.shellLaunchEnvironment,
                focus: false,
                label: launch.name,
                workspaceID: workspaceID),
            decoding: TabCreatedResponse.self)
        return ShellLaunchResult(
            paneID: created.rootPane.paneID,
            tabID: created.rootPane.tabID,
            terminalID: created.rootPane.terminalID,
            workspaceID: workspaceID)
    }

    func startShellTerminalInNewWorktree(
        _ launch: ShellLaunchRequest,
        worktree: WorktreeSpec,
        attempt: WorktreeLaunchAttempt
    ) async throws -> ShellLaunchResult {
        guard let sourceWorkspaceID = launch.workspaceID else {
            throw TransportError.channelFailed(
                detail: "a shell launch needs a workspace")
        }
        switch try await worktreeLaunchTarget(
            worktree, sourceWorkspaceID: sourceWorkspaceID, attempt: attempt)
        {
        case .adopted(let adopted):
            return try await startShellTerminal(
                ShellLaunchRequest(
                    name: launch.name, workspaceID: adopted.workspaceID, cwd: adopted.path,
                    launchID: launch.launchID, mayHaveStarted: launch.mayHaveStarted))
        case .own(let own, _):
            if launch.mayHaveStarted, launch.launchID != nil,
                let earlier = try await taggedLaunchTab(name: launch.name, workspaceID: own.workspaceID)
            {
                return earlier
            }
            // worktree.create takes no env, and its root pane's shell has
            // already started unmarked. Open the marked shell as a second tab
            // at the checkout, then close the unmarked root tab.
            LaunchProgress.report(.openingShell)
            let shell: ShellLaunchResult
            if !launch.mayHaveStarted, attempt.current.shellTabDispatched,
                let opened = try await earlierTab(openedIn: own)
            {
                shell = opened
            } else {
                let mayRemove = attempt.current.mayRemoveWorktreeOnFailure
                let opened: TabCreatedResponse
                do {
                    opened = try await request(
                        method: "tab.create",
                        params: TabCreateParams(
                            cwd: own.path,
                            env: Self.shellLaunchEnvironment,
                            focus: false,
                            label: launch.name,
                            workspaceID: own.workspaceID),
                        decoding: TabCreatedResponse.self,
                        onDispatched: { attempt.recordShellTabDispatched() })
                } catch let error as HerdrAPIError {
                    if mayRemove {
                        try? await removeCreatedWorktree(workspaceID: own.workspaceID)
                    }
                    throw error
                }
                shell = ShellLaunchResult(
                    paneID: opened.rootPane.paneID,
                    tabID: opened.rootPane.tabID,
                    terminalID: opened.rootPane.terminalID,
                    workspaceID: own.workspaceID)
            }
            // Best-effort: a lingering root tab must not fail a launch whose
            // shell already exists. An earlier try may have closed it.
            try? await closeOwnTab(TabTarget(tabID: own.tabID))
            return shell
        }
    }

    func startShellTerminalInNewWorkspace(
        _ launch: ShellLaunchRequest,
        workspace: NewWorkspaceSpec
    ) async throws -> ShellLaunchResult {
        if launch.mayHaveStarted, launch.launchID != nil,
            let earlier = try await taggedLaunchTab(name: launch.name, workspaceID: nil)
        {
            return earlier
        }
        LaunchProgress.report(.creatingWorkspace)
        let created = try await request(
            method: "workspace.create",
            params: WorkspaceCreateParams(
                cwd: workspace.directory,
                env: Self.shellLaunchEnvironment,
                focus: false,
                label: workspace.label),
            decoding: WorkspaceCreatedResponse.self)
        // The Workspace's root pane is the marked shell; what remains is
        // naming its tab.
        LaunchProgress.report(.openingShell)
        // workspace.create labels the Workspace, not its first tab. Best-effort.
        if let label = launch.name {
            try? await renameTab(
                TabRenameParams(label: label, tabID: created.tab.tabID))
        }
        return ShellLaunchResult(
            paneID: created.rootPane.paneID,
            tabID: created.rootPane.tabID,
            terminalID: created.rootPane.terminalID,
            workspaceID: created.workspace.workspaceID)
    }

    /// Where a worktree launch continues once its worktree is settled.
    private enum WorktreeLaunchTarget: Sendable {
        /// This launch's own worktree (`WorktreeLaunchAttempt.State.worktree`):
        /// its root pane takes the Agent, or gives way to the marked shell
        /// tab. `continuing` is false only right after this try's own
        /// `worktree.create` answered; otherwise an earlier try, or an earlier
        /// launch on the same minted branch, may already have started there.
        case own(WorktreeLaunchAttempt.Worktree, continuing: Bool)
        /// An open linked worktree on the typed branch that this launch did
        /// not make, or cannot tell it made. The launch jumps into it with a
        /// new tab and never removes it.
        case adopted(WorktreeLaunchReconciliation.OpenWorktree)
    }

    /// How long a try that continues in its own worktree waits for
    /// `agent.list` to show the Agent an earlier try's unanswered
    /// `agent.start` began, before sending `agent.start` again: herdr starts
    /// Agents asynchronously.
    private static let earlierAgentStartWait: Duration = .seconds(10)

    /// Settles the worktree one try of a worktree launch continues in,
    /// sending `worktree.create` at most once per `attempt`. A worktree is
    /// only ever recognised by its exact branch: one on a branch this launch
    /// minted (`WorktreeSpec.branchIsGenerated`) is its own, one on a typed
    /// branch is adopted.
    ///
    /// 1. A worktree an earlier try settled as its own is reused as is.
    /// 2. After a `worktree.create` herdr may have acted on without an
    ///    answer, `worktree.list` is polled for its branch instead
    ///    (`reconcileCreatedWorktree`).
    /// 3. A branch already checked out in an open linked worktree is
    ///    jumped into.
    /// 4. Otherwise the base is resolved and `worktree.create` sent. herdr
    ///    refusing it while the branch shows up open is step 3. Its refusal
    ///    while another create at that path is still running
    ///    (`worktree_operation_in_progress`), and any failure that is not
    ///    herdr's answer once it was dispatched, are step 2.
    ///
    /// One `worktree.list` of the source Workspace per try feeds steps 2
    /// and 3 and the latest-main resolution.
    private func worktreeLaunchTarget(
        _ worktree: WorktreeSpec,
        sourceWorkspaceID: String,
        attempt: WorktreeLaunchAttempt
    ) async throws -> WorktreeLaunchTarget {
        if let known = attempt.current.worktree { return .own(known, continuing: true) }
        let listing = try await listWorktrees(forWorkspaceID: sourceWorkspaceID)
        if attempt.current.createDispatched {
            return try await reconcileCreatedWorktree(
                worktree, sourceWorkspaceID: sourceWorkspaceID, attempt: attempt,
                firstListing: listing)
        }
        if let branch = worktree.branch,
            let existing = WorktreeLaunchReconciliation.existingWorktree(
                in: listing.worktrees, branch: branch)
        {
            LaunchProgress.report(.usingExistingWorktree)
            return try await continueInExistingWorktree(
                existing, worktree, branch: branch, sourceWorkspaceID: sourceWorkspaceID,
                attempt: attempt, listing: listing)
        }
        let base = try await worktreeCreateBase(
            worktree, sourceWorkspaceID: sourceWorkspaceID, listing: listing)
        LaunchProgress.report(.creatingWorktree)
        let created: WorktreeCreatedResponse
        do {
            // No label: herdr names the new worktree Workspace after its
            // branch, which is the honest identity for a checkout. The
            // launch's name belongs on the Tab.
            created = try await request(
                method: "worktree.create",
                params: WorktreeCreateParams(
                    base: base,
                    branch: worktree.branch,
                    focus: false,
                    workspaceID: sourceWorkspaceID),
                decoding: WorktreeCreatedResponse.self,
                timeout: worktreeCreateTimeout,
                onDispatched: { attempt.recordCreateDispatched() })
        } catch let error as HerdrAPIError
            where error.code == "worktree_operation_in_progress" && worktree.branch != nil
        {
            // herdr is still making a worktree at this branch's path (an
            // earlier launch's create): wait for it like a lost create.
            return try await reconcileCreatedWorktree(
                worktree, sourceWorkspaceID: sourceWorkspaceID, attempt: attempt,
                firstListing: nil)
        } catch let error as HerdrAPIError {
            // The branch got checked out meanwhile (another launch, or an
            // earlier launch on the same minted branch still finishing):
            // jump into it instead of failing. A re-list that fails keeps
            // herdr's own answer.
            guard error.code == "worktree_create_failed",
                let branch = worktree.branch,
                let relisted = try? await listWorktrees(forWorkspaceID: sourceWorkspaceID),
                let existing = WorktreeLaunchReconciliation.existingWorktree(
                    in: relisted.worktrees, branch: branch)
            else { throw error }
            LaunchProgress.report(.usingExistingWorktree)
            return try await continueInExistingWorktree(
                existing, worktree, branch: branch, sourceWorkspaceID: sourceWorkspaceID,
                attempt: attempt, listing: relisted)
        } catch _ where attempt.current.createDispatched {
            // No answer, but herdr may still be running `git worktree add`,
            // or have finished it. Look for the result on this link; a link
            // failure while looking reaches `EventsSession`, whose replay
            // lands in step 2.
            return try await reconcileCreatedWorktree(
                worktree, sourceWorkspaceID: sourceWorkspaceID, attempt: attempt,
                firstListing: nil)
        }
        let known = WorktreeLaunchAttempt.Worktree(
            workspaceID: created.workspace.workspaceID,
            tabID: created.tab.tabID,
            rootPaneID: created.rootPane.paneID,
            path: created.worktree.path)
        attempt.recordWorktree(known)
        return .own(known, continuing: false)
    }

    /// Continues in `existing`, the open worktree already on the launch's
    /// `branch`: adopted when the branch is typed, this launch's own when it
    /// is minted, since no one else knows that name. `listing` found it and
    /// is the first poll for its root pane.
    private func continueInExistingWorktree(
        _ existing: WorktreeLaunchReconciliation.OpenWorktree,
        _ worktree: WorktreeSpec,
        branch: String,
        sourceWorkspaceID: String,
        attempt: WorktreeLaunchAttempt,
        listing: WorktreeListResponse
    ) async throws -> WorktreeLaunchTarget {
        guard worktree.branchIsGenerated else { return .adopted(existing) }
        return try await findWorktree(
            worktree, branch: branch, sourceWorkspaceID: sourceWorkspaceID,
            attempt: attempt, firstListing: listing)
    }

    /// Looks for the worktree an unanswered `worktree.create` of this launch
    /// may have made. A launch without a branch has nothing to recognise it
    /// by, so it stops at once. Never sends `worktree.create`.
    private func reconcileCreatedWorktree(
        _ worktree: WorktreeSpec,
        sourceWorkspaceID: String,
        attempt: WorktreeLaunchAttempt,
        firstListing: WorktreeListResponse?
    ) async throws -> WorktreeLaunchTarget {
        guard let branch = worktree.branch else { throw WorktreeLaunchError.createUnconfirmed }
        LaunchProgress.report(.checkingForCreatedWorktree)
        return try await findWorktree(
            worktree, branch: branch, sourceWorkspaceID: sourceWorkspaceID,
            attempt: attempt, firstListing: firstListing)
    }

    /// Polls `worktree.list` every `worktreeReconcileInterval` for the open
    /// linked worktree on exactly `branch`; `firstListing`, when given, is
    /// the first poll. On a typed branch it is adopted. On a minted branch it
    /// is this launch's own and recorded in `attempt`, once
    /// `session.snapshot` lists its root pane.
    ///
    /// Every poll is cut off at `worktreeReconcileBudget` from the start, and
    /// running out ends the launch with `WorktreeLaunchError.createUnconfirmed`.
    /// Link failures pass through for replay.
    private func findWorktree(
        _ worktree: WorktreeSpec,
        branch: String,
        sourceWorkspaceID: String,
        attempt: WorktreeLaunchAttempt,
        firstListing: WorktreeListResponse?
    ) async throws -> WorktreeLaunchTarget {
        let deadline = ContinuousClock.now + worktreeReconcileBudget
        var pending = firstListing
        while true {
            let listing: WorktreeListResponse
            if let first = pending {
                listing = first
                pending = nil
            } else {
                listing = try await beforeReconcileDeadline(deadline) {
                    try await self.listWorktrees(forWorkspaceID: sourceWorkspaceID)
                }
            }
            if let found = WorktreeLaunchReconciliation.existingWorktree(
                in: listing.worktrees, branch: branch)
            {
                guard worktree.branchIsGenerated else {
                    LaunchProgress.report(.usingExistingWorktree)
                    return .adopted(found)
                }
                if let own = try await beforeReconcileDeadline(deadline, {
                    try await self.ownWorktree(found)
                }) {
                    attempt.recordWorktree(own)
                    return .own(own, continuing: true)
                }
            }
            guard ContinuousClock.now + worktreeReconcileInterval < deadline else {
                throw WorktreeLaunchError.createUnconfirmed
            }
            try await Task.sleep(for: worktreeReconcileInterval)
        }
    }

    /// Runs one reconcile poll, cut off at `deadline`. Running out is
    /// `WorktreeLaunchError.createUnconfirmed`, never a link failure, so the
    /// Console does not replay the launch.
    private func beforeReconcileDeadline<T: Sendable>(
        _ deadline: ContinuousClock.Instant,
        _ poll: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw WorktreeLaunchError.createUnconfirmed }
        do {
            return try await AsyncDeadline.run(for: remaining, operation: poll)
        } catch AsyncDeadlineError.timedOut {
            throw WorktreeLaunchError.createUnconfirmed
        }
    }

    /// The first tab (lowest number) of `found`'s Workspace and that tab's
    /// first pane, from `session.snapshot`; nil while herdr lists neither.
    private func ownWorktree(
        _ found: WorktreeLaunchReconciliation.OpenWorktree
    ) async throws -> WorktreeLaunchAttempt.Worktree? {
        let snapshot = try await sessionSnapshot()
        guard
            let tab = snapshot.tabs
                .filter({ $0.workspaceID == found.workspaceID })
                .min(by: { $0.number < $1.number }),
            let pane = snapshot.panes.first(where: { $0.tabID == tab.tabID })
        else { return nil }
        return WorktreeLaunchAttempt.Worktree(
            workspaceID: found.workspaceID,
            tabID: tab.tabID,
            rootPaneID: pane.paneID,
            path: found.path)
    }

    /// The Agent `matches` picks (in the root pane, or anywhere in the
    /// Workspace) of a worktree this launch continues in, if one runs
    /// there. After an earlier try dispatched `agent.start`, `agent.list`
    /// is asked again until `earlierAgentStartWait` passes, since herdr may
    /// still be starting it.
    ///
    /// A found Agent gets the input gate of a fresh start, anchored at
    /// recovery. A pending launch also settles immediately; see
    /// `earlierAgentLaunch` for why no dispatch time is needed.
    private func agentStartedEarlier(
        where matches: (Agent) -> Bool, kind: String, attempt: WorktreeLaunchAttempt
    ) async throws -> Agent? {
        let dispatchedAt = attempt.current.agentStartDispatchedAt
        let deadline = ContinuousClock.now + Self.earlierAgentStartWait
        while true {
            let agents = try await request(method: "agent.list", decoding: AgentListResponse.self).agents
            noteAgentKinds(agents)
            if let info = agents.first(where: { matches(Agent($0)) }) {
                let recoveredAt = ContinuousClock.now
                gateAgentInput(kind: kind, paneID: info.paneID, launchedAt: recoveredAt)
                if info.launchPending == true {
                    scheduleLaunchSettle(paneID: info.paneID, dispatchedAt: recoveredAt, immediately: true)
                }
                return Agent(info)
            }
            guard dispatchedAt != nil,
                ContinuousClock.now + shellReadinessRetryDelay < deadline
            else { return nil }
            try await Task.sleep(for: shellReadinessRetryDelay)
        }
    }

    /// The tab an earlier try's unanswered `tab.create` opened in `own`'s
    /// Workspace (a marked shell, or an env-carrying launch's Agent tab):
    /// its newest tab other than the root tab, from `session.snapshot`. Nil
    /// when herdr lists none.
    private func earlierTab(
        openedIn own: WorktreeLaunchAttempt.Worktree
    ) async throws -> ShellLaunchResult? {
        let snapshot = try await sessionSnapshot()
        guard
            let tab = snapshot.tabs
                .filter({ $0.workspaceID == own.workspaceID && $0.tabID != own.tabID })
                .max(by: { $0.number < $1.number }),
            let pane = snapshot.panes.first(where: { $0.tabID == tab.tabID })
        else { return nil }
        return ShellLaunchResult(
            paneID: pane.paneID,
            tabID: tab.tabID,
            terminalID: pane.terminalID,
            workspaceID: own.workspaceID)
    }

    /// herdr does not retain a launch's environment across a server restart.
    /// The Console's Host-unique, stable name is therefore the Launch Tag.
    /// New-Workspace retries do not know their created Workspace id yet;
    /// existing-Workspace and worktree retries always constrain the lookup.
    private func taggedLaunchTab(
        name: String?, workspaceID: String?
    ) async throws -> ShellLaunchResult? {
        guard let name, !name.isEmpty else { return nil }
        let snapshot = try await sessionSnapshot()
        guard let tab = snapshot.tabs.first(where: {
            $0.label == name && (workspaceID == nil || $0.workspaceID == workspaceID)
        }), let pane = snapshot.panes.first(where: { $0.tabID == tab.tabID }) else { return nil }
        return ShellLaunchResult(
            paneID: pane.paneID, tabID: tab.tabID, terminalID: pane.terminalID,
            workspaceID: tab.workspaceID)
    }

    /// Return any Agent in our tagged tab, even before kind detection, or
    /// finish a start interrupted after tab creation. Recovery reopens the
    /// input gate and settles a pending launch immediately, anchored at now.
    /// Dispatch timing need not survive a reconnect: a late `agent.get` may
    /// clear herdr's expired gate and managed name rather than promote it,
    /// but either makes it promptable, and the tab label retains its name.
    private func earlierAgentLaunch(
        _ launch: AgentLaunchRequest, workspaceID: String?
    ) async throws -> Agent? {
        guard launch.mayHaveStarted, launch.launchID != nil else { return nil }
        let snapshot = try await sessionSnapshot()
        let tabs = snapshot.tabs.filter {
            $0.label == launch.name && (workspaceID == nil || $0.workspaceID == workspaceID)
        }
        guard !tabs.isEmpty else { return nil }
        let tabIDs = Set(tabs.map(\.tabID))
        let agents = try await request(method: "agent.list", decoding: AgentListResponse.self).agents
        noteAgentKinds(agents)
        if let info = agents.first(where: { tabIDs.contains($0.tabID) }) {
            let recoveredAt = ContinuousClock.now
            gateAgentInput(kind: launch.kind, paneID: info.paneID, launchedAt: recoveredAt)
            if info.launchPending == true {
                scheduleLaunchSettle(paneID: info.paneID, dispatchedAt: recoveredAt, immediately: true)
            }
            return Agent(info)
        }
        guard let pane = snapshot.panes.first(where: { tabIDs.contains($0.tabID) })
        else { return nil }
        LaunchProgress.report(.startingAgent)
        return Agent(try await startAgentAwaitingShell(launch, paneID: pane.paneID).agent)
    }

    /// An Agent already running in `workspaceID`: the first of `kind` in
    /// herdr's `agent.list` order, else the first of any kind.
    private func runningAgent(
        inWorkspace workspaceID: String, preferringKind kind: String, excludingTabLabel: String? = nil
    ) async throws -> Agent? {
        var excludedTabs: Set<String> = []
        if let excludingTabLabel {
            excludedTabs = Set(try await sessionSnapshot().tabs.filter {
                $0.workspaceID == workspaceID && $0.label == excludingTabLabel
            }.map(\.tabID))
        }
        let agents = try await listAgents().filter {
            $0.workspaceID == workspaceID && !excludedTabs.contains($0.tabID)
        }
        return agents.first(where: { $0.kind == kind }) ?? agents.first
    }

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        try await request(
            method: "worktree.list",
            params: WorktreeListParams(workspaceID: workspaceID),
            decoding: WorktreeListResponse.self)
    }

    /// The `base` both worktree launch variants hand `worktree.create`,
    /// resolved before anything is created. herdr passes it verbatim to
    /// `git -C <source checkout> worktree add -b <branch> <path> <base>` and
    /// defaults nil to that checkout's HEAD.
    ///
    /// `.latestDefaultBranch` resolves origin's default branch in exactly the
    /// checkout herdr branches from (`listing`'s `source_checkout_path`, the
    /// launch's own `worktree.list` of `sourceWorkspaceID`) and passes the
    /// commit SHA, not `origin/main`: git sets no upstream for a SHA start
    /// point, the same as herdr's default HEAD base. A requested branch that
    /// already exists gets no base, since herdr checks it out as-is.
    private func worktreeCreateBase(
        _ worktree: WorktreeSpec,
        sourceWorkspaceID: String,
        listing: WorktreeListResponse
    ) async throws -> String? {
        switch worktree.base {
        case .sourceHead:
            return nil
        case .ref(let ref):
            return ref
        case .latestDefaultBranch:
            // herdr refuses a linked worktree as the source
            // (`linked_worktree_source`); say so before any network work.
            if listing.worktrees.contains(where: {
                $0.openWorkspaceID == sourceWorkspaceID && $0.isLinkedWorktree
            }) {
                throw WorktreeBaseResolutionError.linkedWorktreeSource
            }
            LaunchProgress.report(.gettingLatestMain)
            switch try await resolveLatestDefaultBranch(
                sourceCheckoutPath: listing.source.sourceCheckoutPath,
                branch: worktree.branch)
            {
            case .commit(let commit): return commit
            case .existingBranch: return nil
            }
        }
    }

    /// One resolution run under its own network-sized budget, inputs on
    /// stdin. Running out of it is `WorktreeBaseResolutionError.timedOut`,
    /// never `TransportError.timedOut`: a slow remote is not a dead link,
    /// and the Console would otherwise redial and replay the launch.
    private func resolveLatestDefaultBranch(
        sourceCheckoutPath: String, branch: String?
    ) async throws -> WorktreeBaseResolution.Resolution {
        let input = try WorktreeBaseResolution.input(
            sourceCheckoutPath: sourceCheckoutPath, branch: branch)
        let command = Self.cLocaleCommand(WorktreeBaseResolution.command)
        let timeout = WorktreeBaseResolution.timeout
        let result: SSHExecResult
        do {
            result = try await AsyncDeadline.run(for: timeout) {
                try await self.runExec(command, input: input, timeout: timeout)
            }
        } catch {
            throw WorktreeBaseResolutionError.replacingTimeout(error)
        }
        guard result.reachedEOF else {
            throw TransportError.channelFailed(detail: "Host command closed before EOF")
        }
        return try WorktreeBaseResolution.resolution(
            exitStatus: result.exitStatus, stdout: result.stdout, stderr: result.stderr)
    }

    func removeWorktree(
        _ removal: WorktreeRemovalRequest,
        authorize: @escaping @Sendable (WorktreeRemovalRequest) async throws -> Void,
        onDispatched: @escaping @Sendable (WorktreeRemovalRequest) async -> Void
    ) async throws -> WorktreeRemovedResponse {
        try await request(
            method: "worktree.remove",
            params: WorktreeRemoveParams(
                workspaceID: removal.identity.workspaceID,
                force: false),
            decoding: WorktreeRemovedResponse.self,
            beforeDispatch: { try await authorize(removal) },
            onDispatched: { await onDispatched(removal) })
    }

    private func removeCreatedWorktree(workspaceID: String) async throws {
        _ = try await request(
            method: "worktree.remove",
            params: WorktreeRemoveParams(workspaceID: workspaceID),
            decoding: WorktreeRemovedResponse.self)
    }

    private func closeCreatedWorkspace(workspaceID: String) async throws {
        _ = try await request(
            method: "workspace.close",
            params: WorkspaceCloseParams(workspaceID: workspaceID),
            decoding: OkResponse.self)
    }

    /// Detection sees login PATH installations that bare SSH probes miss.
    /// Probe only without detection; a missing executable is never cached.
    /// A shared-server resume never asks for this capability.
    private func codexSupportsNoDaemon() async -> Bool {
        await AgentLaunchBuilder.codexSupportsNoDaemon(presence: await session.codexPresence) { [self] in
            try await codexNoDaemon.value { [self] in
                let result = try await runExec(Self.cLocaleCommand(codexHelpCommand))
                return try AgentLaunchBuilder.codexNoDaemonProbe(
                    stdout: String(decoding: result.stdout, as: UTF8.self),
                    stderr: String(decoding: result.stderr, as: UTF8.self), exitCode: Int(result.exitStatus))
            }
        }
    }

    nonisolated static func agentStartParams(
        _ launch: AgentLaunchRequest, paneID: String,
        codexSupportsNoDaemon: @Sendable () async -> Bool
    ) async throws -> AgentStartParams {
        let arguments = try await AgentLaunchBuilder.argv(
            for: launch, codexSupportsNoDaemon: codexSupportsNoDaemon).dropFirst()
        return AgentStartParams(
            kind: launch.kind, name: launch.name, paneID: paneID,
            args: arguments.isEmpty ? nil : Array(arguments))
    }

    /// Starts the agent, retrying while herdr refuses the fresh pane as not
    /// yet an available shell (`agent_pane_busy`, seen on 0.7.5 and again on
    /// 0.9.1 while the pane's shell rc is still running).
    ///
    /// Returns on herdr's ack, before the agent is promptable
    /// (`launch_pending: true`): the New Agent sheet awaits this call. The
    /// ack schedules `scheduleLaunchSettle`, never awaited, because herdr
    /// 0.9.1 promotes a pending launch only on a reconcile (`agent.get` or a
    /// status change) from 3 s after the start. On one Linux Host, omp with
    /// herdr's integration reported idle before then and never changed again,
    /// so without an `agent.get` 5 of 6 launches stayed `agent_not_ready`
    /// (#17). An earlier post-start `agent.list` poll never cleared that:
    /// `agent.list` does not reconcile, and it held the sheet open for its
    /// whole 10 s budget. The ack also opens the launch's input gate
    /// (`gateAgentInput`), since promotion does not mean the TUI takes input.
    ///
    /// Reports `.waitingForShell` once, on herdr's first `agent_pane_busy`.
    /// `onDispatched` runs each time an `agent.start` line is written.
    private func startAgentAwaitingShell(
        _ launch: AgentLaunchRequest,
        paneID: String,
        onDispatched: (@Sendable () async -> Void)? = nil
    ) async throws -> AgentStartedResponse {
        let params = try await Self.agentStartParams(
            launch, paneID: paneID, codexSupportsNoDaemon: { await self.codexSupportsNoDaemon() })
        let deadline = ContinuousClock.now + shellReadinessBudget
        var reportedWaiting = false
        while true {
            do {
                let started = try await request(
                    method: "agent.start",
                    params: params,
                    decoding: AgentStartedResponse.self,
                    onDispatched: onDispatched)
                scheduleLaunchSettle(paneID: paneID)
                gateAgentInput(kind: launch.kind, paneID: paneID, launchedAt: .now)
                return started
            } catch let error as HerdrAPIError where error.code == "agent_pane_busy" {
                guard ContinuousClock.now + shellReadinessRetryDelay < deadline else {
                    throw error
                }
                if !reportedWaiting {
                    reportedWaiting = true
                    LaunchProgress.report(.waitingForShell)
                }
                try await Task.sleep(for: shellReadinessRetryDelay)
            }
        }
    }

    /// Asks `agent.get` for `paneID` from `launchSettleDelay` after
    /// `startedAt`, every `launchSettleInterval` while the launch is still
    /// pending, which is what lets herdr 0.9.1 promote it (see
    /// `startAgentAwaitingShell`). `startedAt` is the ack, or the dispatch
    /// of an earlier try's `agent.start` whose Agent a replay found. With
    /// `immediately`, recovery supplies now and skips the initial delay.
    ///
    /// Nothing is dispatched past `launchSettleWindow` after `startedAt`,
    /// queue wait included: an `agent.get` after herdr's 30 s launch deadline
    /// clears the name (and gate) of an Agent still pending and not blocked,
    /// instead of promoting it.
    private func scheduleLaunchSettle(
        paneID: String, dispatchedAt startedAt: ContinuousClock.Instant = .now,
        immediately: Bool = false
    ) {
        launchSettles[paneID]?.cancel()
        let windowEnd = startedAt + launchSettleWindow
        let firstPause = immediately
            ? .zero : max(.zero, ContinuousClock.now.duration(to: startedAt + launchSettleDelay))
        let interval = launchSettleInterval
        launchSettles[paneID] = Task { [weak self] in
            var pause = firstPause
            while true {
                try? await Task.sleep(for: pause)
                guard !Task.isCancelled, ContinuousClock.now < windowEnd, let self,
                    await self.launchStillPending(paneID: paneID, windowEnd: windowEnd)
                else { break }
                pause = interval
            }
            await self?.endLaunchSettle(paneID: paneID)
        }
    }

    /// One settle `agent.get`. `agent_not_found` counts as pending, since
    /// registration can lag the ack; any other failure ends the settle.
    private func launchStillPending(
        paneID: String,
        windowEnd: ContinuousClock.Instant
    ) async -> Bool {
        do {
            let info = try await request(
                method: "agent.get",
                params: AgentTarget(target: paneID),
                decoding: AgentInfoResponse.self,
                beforeDispatch: {
                    guard ContinuousClock.now < windowEnd else { throw CancellationError() }
                })
            return info.agent.launchPending == true
        } catch let error as HerdrAPIError where error.code == "agent_not_found" {
            return true
        } catch {
            return false
        }
    }

    private func endLaunchSettle(paneID: String) {
        // A cancelled settle was replaced or closed; its slot is not its own.
        guard !Task.isCancelled else { return }
        launchSettles[paneID] = nil
    }

    /// Closes a Pane (`pane.close`). herdr 0.9.x refuses, with
    /// `confirmation_required`, a close that would empty a repo's
    /// main-checkout Workspace, since that takes every linked worktree
    /// Workspace with it. A Close the user asked for
    /// (`closesWorktreeGroup`) is that confirmation, as on herdr's desktop,
    /// so the group closes (`closeWorktreeGroup`); any other close keeps
    /// the refusal.
    func closePane(_ params: PaneTarget, closesWorktreeGroup: Bool) async throws {
        inputGates[params.paneID] = nil
        agentKinds[params.paneID] = nil
        do {
            _ = try await request(
                method: "pane.close",
                params: params,
                decoding: OkResponse.self)
        } catch let error as HerdrAPIError
            where closesWorktreeGroup && error.code == "confirmation_required"
        {
            let pane = try await request(
                method: "pane.get",
                params: params,
                decoding: PaneInfoResponse.self
            ).pane
            try await closeWorktreeGroup(ofLastTab: pane.tabID, requiringSinglePane: true)
        }
    }

    /// Closes a Tab the user closed (`tab.close`): the Console row's
    /// swipe-to-close action. herdr closes the workspace server-side when
    /// this was its last tab, and refuses a main checkout's last tab as
    /// `closePane` describes, which closes the worktree group here too.
    func closeTab(_ params: TabTarget) async throws {
        do {
            try await closeOwnTab(params)
        } catch let error as HerdrAPIError where error.code == "confirmation_required" {
            try await closeWorktreeGroup(ofLastTab: params.tabID, requiringSinglePane: false)
        }
    }

    /// `tab.close` alone, for tabs this transport opened itself.
    private func closeOwnTab(_ params: TabTarget) async throws {
        _ = try await request(
            method: "tab.close",
            params: params,
            decoding: OkResponse.self)
    }

    /// Closes the Workspace whose only tab is `tabID` with its worktree
    /// group (`workspace.close` with `close_group`, which counts no tabs).
    /// First re-checks, like herdr's confirm-close overlay
    /// (`accept_close_confirmation`), that `tabID` is still the Workspace's
    /// only tab and, with `requiringSinglePane`, holds one pane: a tab or
    /// pane opened since the refusal must not go with it.
    private func closeWorktreeGroup(ofLastTab tabID: String, requiringSinglePane: Bool)
        async throws
    {
        let workspaceID = try await request(
            method: "tab.get",
            params: TabTarget(tabID: tabID),
            decoding: TabInfoResponse.self
        ).tab.workspaceID
        let tabs = try await request(
            method: "tab.list",
            params: TabListParams(workspaceID: workspaceID),
            decoding: TabListResponse.self
        ).tabs
        guard tabs.map(\.tabID) == [tabID],
            !requiringSinglePane || tabs.first?.paneCount == 1
        else {
            throw HerdrAPIError(
                code: "close_target_changed",
                message: "the workspace changed while closing; try closing again")
        }
        _ = try await request(
            method: "workspace.close",
            params: WorkspaceCloseParams(workspaceID: workspaceID, closeGroup: true),
            decoding: OkResponse.self)
    }

    func movePane(_ params: PaneMoveParams) async throws -> PaneMoveResponse {
        try await request(
            method: "pane.move",
            params: params,
            decoding: PaneMoveResponse.self)
    }

    func focusAgent(_ target: AgentTarget) async throws {
        _ = try await request(
            method: "agent.focus",
            params: target,
            decoding: AgentInfoResponse.self)
    }

    func renameAgent(_ params: AgentRenameParams) async throws {
        _ = try await request(
            method: "agent.rename",
            params: params,
            decoding: AgentInfoResponse.self)
    }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        _ = try await request(
            method: "workspace.rename",
            params: params,
            decoding: WorkspaceInfoResponse.self)
    }

    // MARK: Notification plugin files

    static let notificationRegistrationFileName = "notifications.json"
    static let notificationConfigFileName = "notify.json"
    static let sidebarLayoutFileName = "sidebar.json"

    func readNotificationRegistration() async throws -> Data? {
        try await readPluginConfigFile(named: Self.notificationRegistrationFileName)
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        try await replacePluginConfigFile(
            named: Self.notificationRegistrationFileName,
            contents: contents)
    }

    func readNotificationConfig() async throws -> Data? {
        try await readPluginConfigFile(named: Self.notificationConfigFileName)
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        try await replacePluginConfigFile(
            named: Self.notificationConfigFileName,
            contents: contents)
    }

    func readSidebarLayout() async throws -> Data? {
        try await readPluginConfigFile(named: Self.sidebarLayoutFileName)
    }

    /// One exec over the plugin config dir the registration files resolve
    /// to; the dir itself is resolved once per connection and cached.
    func readAgentSummaries() async throws -> [String: AgentSummary] {
        guard await notificationConnectionIsAvailable() else {
            throw TransportError.channelFailed(detail: "the SSH connection is unavailable")
        }
        let directory = try await notificationPluginConfigDirectory()
        guard let quoted = RemoteShellPath.quotedAbsolute(directory) else {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The plugin config directory cannot be quoted safely.")
        }
        let command = AgentSummary.readCommand(quotedConfigDirectory: quoted)
        let result = try await withRequestDeadline {
            try await self.runExec(Self.cLocaleCommand(command))
        }
        guard result.exitStatus == 0, result.reachedEOF else {
            throw TransportError.channelFailed(detail: "the Agent Summary read failed")
        }
        return AgentSummary.latestByPane(fromNDJSON: result.stdout)
    }

    /// Fires the plugin's `refresh-summaries` action. herdr answers as soon
    /// as the action process spawns; the action's own outcome only shows in
    /// the store the next `readAgentSummaries` reads.
    func refreshAgentSummaries() async throws {
        guard await notificationConnectionIsAvailable() else {
            throw TransportError.channelFailed(detail: "the SSH connection is unavailable")
        }
        let plugin = try await resolvedNotificationPlugin()
        let command = AgentSummary.refreshCommand(pluginID: plugin.id)
        let result = try await withRequestDeadline {
            try await self.runExec(Self.cLocaleCommand(HerdrHostPath.wrappingBareHerdr(command)))
        }
        if let missing = HerdrHostPath.missingBinaryError(
            exitStatus: result.exitStatus, command: command)
        {
            throw missing
        }
        guard result.exitStatus == 0 else {
            throw AgentSummary.refreshFailure(exitStatus: result.exitStatus, stderr: result.stderr)
        }
    }

    // MARK: Chat Mode

    /// The Chat Markers' directory inside the plugin config dir.
    static let chatModeMarkerDirectoryName = "chat"
    /// How long the transcript reader may run on the Host: inside the
    /// ordinary request deadline, so the Host stops it before the app gives
    /// up on the channel (`HostWatchdog`).
    static let chatTranscriptHostLimitSeconds = 12
    /// The read's exit status when the plugin root or its
    /// reader is missing (neither `src/chat-read.js` nor an executable
    /// `bin/waycar`): a plugin that predates the reader.
    static let chatReaderMissingStatus: Int32 = 64
    /// How long the media reader may run on the Host. A 25 MiB image has to
    /// leave through the exec channel inside it, so it is sized for a slow
    /// link rather than a round trip; the app waits a little longer
    /// (`chatMediaRequestBudget`) so the Host stops it first.
    static let chatMediaHostLimitSeconds = 120
    static let chatMediaRequestBudget: Duration = .seconds(chatMediaHostLimitSeconds + 15)
    /// The media reader's exit status for a missing file, line, pointer or
    /// base64 string, and for a decoded size over `max_bytes`.
    static let chatMediaUnavailableStatus: Int32 = 65
    static let chatMediaTooLargeStatus: Int32 = 66

    /// One exec over the plugin config dir's `chat/`, like the Agent
    /// Summaries read; the dir itself is resolved once per connection.
    func readChatModeMarkers() async throws -> [ChatModeMarker] {
        guard await notificationConnectionIsAvailable() else {
            throw TransportError.channelFailed(detail: "the SSH connection is unavailable")
        }
        let directory = try await notificationPluginConfigDirectory()
        guard let quoted = RemoteShellPath.quotedAbsolute(directory) else {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The plugin config directory cannot be quoted safely.")
        }
        let command = Self.chatModeMarkerReadCommand(quotedConfigDirectory: quoted)
        let result = try await withRequestDeadline {
            try await self.runExec(Self.cLocaleCommand(command))
        }
        guard result.exitStatus == 0, result.reachedEOF else {
            throw TransportError.channelFailed(detail: "the Chat Marker read failed")
        }
        return Self.chatModeMarkers(fromNDJSON: result.stdout)
    }

    func writeChatModeMarker(_ marker: ChatModeMarker) async throws {
        let contents: Data
        do {
            contents = try JSONEncoder().encode(marker)
        } catch {
            throw NotificationRegistrationError.writeFailed(
                detail: "The Chat Marker could not be encoded.")
        }
        try await replacePluginConfigFile(
            named: ChatModeMarker.fileName(paneID: marker.paneID),
            inSubdirectory: Self.chatModeMarkerDirectoryName,
            contents: contents)
    }

    /// Runs the plugin's transcript reader from its own root in one exec,
    /// bounded on the Host by `waycar_watch`.
    func readChatTranscript(_ request: ChatTranscriptRequest) async throws -> ChatTranscriptSnapshot {
        guard await notificationConnectionIsAvailable() else {
            throw TransportError.channelFailed(detail: "the SSH connection is unavailable")
        }
        let plugin = try await resolvedNotificationPlugin()
        guard let root = plugin.root, let quotedRoot = RemoteShellPath.quotedAbsolute(root) else {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "herdr did not report a usable plugin root.")
        }
        let command = Self.chatTranscriptReadCommand(quotedPluginRoot: quotedRoot)
        let input = try Self.chatTranscriptRequestJSON(request)
        let result = try await withRequestDeadline {
            try await self.runExec(Self.cLocaleCommand(command), input: input)
        }
        switch result.exitStatus {
        case 0:
            break
        case Self.chatReaderMissingStatus:
            throw ChatTranscriptError.readerUnavailable
        case HostWatchdog.stoppedStatus:
            throw TransportError.channelFailed(detail: "the chat transcript read ran too long")
        default:
            throw TransportError.channelFailed(
                detail: "the chat transcript read failed: \(Self.preview(result.stderr))")
        }
        guard result.reachedEOF else {
            throw TransportError.channelFailed(detail: "the chat transcript read closed before EOF")
        }
        return try ChatTranscriptDecoding.decode(result.stdout)
    }

    /// Runs the plugin's media reader from its own root in one exec, bounded
    /// on the Host by `waycar_watch`; its stdout is the decoded bytes.
    func readChatMedia(_ request: ChatMediaRequest) async throws -> Data {
        guard await notificationConnectionIsAvailable() else {
            throw TransportError.channelFailed(detail: "the SSH connection is unavailable")
        }
        let plugin = try await resolvedNotificationPlugin()
        guard let root = plugin.root, let quotedRoot = RemoteShellPath.quotedAbsolute(root) else {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "herdr did not report a usable plugin root.")
        }
        let command = Self.chatMediaReadCommand(quotedPluginRoot: quotedRoot)
        let input = try Self.chatMediaRequestJSON(request)
        let budget = Self.chatMediaRequestBudget
        let result = try await withRequestDeadline(budget) {
            try await self.runExec(Self.cLocaleCommand(command), input: input, timeout: budget)
        }
        if let failure = Self.chatMediaFailure(exitStatus: result.exitStatus, stderr: result.stderr) {
            throw failure
        }
        guard result.reachedEOF else {
            throw TransportError.channelFailed(detail: "the chat media read closed before EOF")
        }
        guard result.stdout.count <= request.maxBytes else { throw ChatMediaError.tooLarge }
        return result.stdout
    }

    /// The error a media reader exit status stands for; nil for success.
    static func chatMediaFailure(exitStatus: Int32, stderr: Data) -> (any Error)? {
        switch exitStatus {
        case 0: nil
        case chatReaderMissingStatus: ChatMediaError.pluginOutdated
        case chatMediaUnavailableStatus: ChatMediaError.unavailable
        case chatMediaTooLargeStatus: ChatMediaError.tooLarge
        case HostWatchdog.stoppedStatus:
            TransportError.channelFailed(detail: "the chat media read ran too long")
        default:
            TransportError.channelFailed(detail: "the chat media read failed: \(preview(stderr))")
        }
    }

    /// Prints every marker file in `directory/chat` as NDJSON (one file per
    /// line); nothing when the directory is absent. The config dir travels
    /// as `$1`, already quoted, and each file is capped like a summary.
    static func chatModeMarkerReadCommand(quotedConfigDirectory: String) -> String {
        "/bin/sh -c 'd=\"$1/\(chatModeMarkerDirectoryName)\"; [ -d \"$d\" ] || exit 0; "
            + "for f in \"$d\"/*.json; do [ -f \"$f\" ] || continue; "
            + "head -c 4096 \"$f\"; echo; done' waycar \(quotedConfigDirectory)"
    }

    /// Decodes the read's lines leniently: blank, malformed and
    /// other-version markers are skipped.
    static func chatModeMarkers(fromNDJSON output: Data) -> [ChatModeMarker] {
        let decoder = JSONDecoder()
        return output.split(separator: 0x0A).compactMap { line in
            guard let marker = try? decoder.decode(ChatModeMarker.self, from: Data(line)),
                marker.v == 1
            else { return nil }
            return marker
        }
    }

    /// `cd <root> && sh bin/node.sh src/chat-read.js --request -` on a
    /// Node-era Host, `bin/waycar chat-read --request -` on a native one
    /// (``HostToolProbe``), under the Host PATH fix and `waycar_watch`; a
    /// missing root or reader exits `chatReaderMissingStatus`. Only the constant script and the quoted
    /// root are on the command line: the request travels as JSON on stdin
    /// (``chatTranscriptRequestJSON(_:)``), so no Host value is shell-quoted.
    ///
    /// `waycar_watch` runs the command as an asynchronous list, whose stdin
    /// `sh` replaces with `/dev/null` unless that command redirects it
    /// itself. The script therefore keeps the exec's stdin on fd 3 and the
    /// watched `sh -c` hands it back to the reader as fd 0. A redirect needs no temp file to create and clean up.
    static func chatTranscriptReadCommand(quotedPluginRoot: String) -> String {
        let script = "\(HerdrHostPath.pathExport); "
            + HostToolProbe.selection(
                script: "chat-read", subcommand: "chat-read", arguments: "--request -",
                missingStatus: chatReaderMissingStatus)
            + "exec 3<&0; \(HostWatchdog.definition); "
            + "waycar_watch \(chatTranscriptHostLimitSeconds) "
            + "sh -c \"exec $waycar_run <&3 3<&-\""
        return "/bin/sh -c '\(script)' waycar-chat \(quotedPluginRoot)"
    }

    /// `cd <root> && sh bin/node.sh src/chat-media.js --request -` (Node-era)
    /// or `bin/waycar chat-media --request -` (native), built like ``chatTranscriptReadCommand(quotedPluginRoot:)``: a missing root
    /// or reader exits `chatReaderMissingStatus`, and the request travels as
    /// JSON on stdin (``chatMediaRequestJSON(_:)``).
    static func chatMediaReadCommand(quotedPluginRoot: String) -> String {
        let script = "\(HerdrHostPath.pathExport); "
            + HostToolProbe.selection(
                script: "chat-media", subcommand: "chat-media", arguments: "--request -",
                missingStatus: chatReaderMissingStatus)
            + "exec 3<&0; \(HostWatchdog.definition); "
            + "waycar_watch \(chatMediaHostLimitSeconds) "
            + "sh -c \"exec $waycar_run <&3 3<&-\""
        return "/bin/sh -c '\(script)' waycar-chat-media \(quotedPluginRoot)"
    }

    /// The media reader's `--request -` object. The transcript form carries
    /// `transcript`, `offset` and `pointer`; the session form carries
    /// `session`, the media item's `id` and `pointer`, plus `kind` for a
    /// harness other than opencode whose export the reader re-runs
    /// (`kilo`) — exactly what `plugin/src/chat-media.js` type-checks for
    /// each form.
    static func chatMediaRequestJSON(_ request: ChatMediaRequest) throws -> Data {
        struct Body: Encodable {
            let transcript: String?
            let offset: Int?
            let session: String?
            let id: String?
            let pointer: String
            let maxBytes: Int
            let kind: String?

            enum CodingKeys: String, CodingKey {
                case transcript, offset, session, id, pointer, kind
                case maxBytes = "max_bytes"
            }
        }
        let body: Body = switch request {
        case .line(let transcript, let offset, let pointer, let maxBytes):
            Body(
                transcript: transcript, offset: offset, session: nil, id: nil, pointer: pointer,
                maxBytes: maxBytes, kind: nil)
        case .sessionInline(let session, let id, let pointer, let agentKind, let maxBytes):
            Body(
                transcript: nil, offset: nil, session: session, id: id, pointer: pointer,
                maxBytes: maxBytes, kind: agentKind)
        }
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw TransportError.channelFailed(detail: "the chat media request could not be encoded")
        }
    }

    /// The reader's `--request -` object: every key present, null when unset.
    static func chatTranscriptRequestJSON(_ request: ChatTranscriptRequest) throws -> Data {
        struct Body: Encodable {
            let kind: String
            let sessionKind: String?
            let sessionValue: String?
            let cwd: String?
            let launchedAt: String?
            let status: String?
            let after: String?

            enum CodingKeys: String, CodingKey {
                case kind, cwd, status, after
                case sessionKind = "session_kind"
                case sessionValue = "session_value"
                case launchedAt = "launched_at"
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(kind, forKey: .kind)
                try container.encode(sessionKind, forKey: .sessionKind)
                try container.encode(sessionValue, forKey: .sessionValue)
                try container.encode(cwd, forKey: .cwd)
                try container.encode(launchedAt, forKey: .launchedAt)
                try container.encode(status, forKey: .status)
                try container.encode(after, forKey: .after)
            }
        }
        let hasSession = request.sessionKind != nil && request.sessionValue != nil
        let body = Body(
            kind: request.kind,
            sessionKind: hasSession ? request.sessionKind : nil,
            sessionValue: hasSession ? request.sessionValue : nil,
            cwd: request.cwd,
            launchedAt: request.launchedAt.map { ChatModeTimestamp.string(from: $0) },
            status: request.status?.rawValue,
            after: request.after)
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw TransportError.channelFailed(detail: "the chat transcript request could not be encoded")
        }
    }

    /// Deletes `chat/<ChatModeMarker.fileName>` in the plugin config dir;
    /// an already-absent marker is fine.
    func deleteChatModeMarker(paneID: String) async throws {
        try await withNotificationFileRequestDeadline {
            guard await self.notificationConnectionIsAvailable() else {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The SSH connection is unavailable.")
            }
            let configDirectory = try await self.notificationPluginConfigDirectory()
            try await self.session.deleteConfigFileWithinDeadline(
                named: ChatModeMarker.fileName(paneID: paneID),
                inDirectory: configDirectory,
                subdirectory: Self.chatModeMarkerDirectoryName)
        }
    }

    private func readPluginConfigFile(named name: String) async throws -> Data? {
        try await withNotificationFileRequestDeadline {
            guard await self.notificationConnectionIsAvailable() else {
                throw NotificationRegistrationError.readFailed(
                    detail: "The SSH connection is unavailable.")
            }
            let directory = try await self.notificationPluginConfigDirectory()
            return try await self.session.readConfigFileWithinDeadline(
                named: name, inDirectory: directory)
        }
    }

    /// Atomically replaces `name` in the plugin config dir, or in
    /// `subdirectory` of it, which is created (0700) when missing.
    private func replacePluginConfigFile(
        named name: String, inSubdirectory subdirectory: String? = nil, contents: Data
    ) async throws {
        try await withNotificationFileRequestDeadline {
            guard await self.notificationConnectionIsAvailable() else {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The SSH connection is unavailable.")
            }
            let configDirectory = try await self.notificationPluginConfigDirectory()
            try await self.session.replaceConfigFileWithinDeadline(
                named: name, inDirectory: configDirectory, subdirectory: subdirectory,
                contents: contents)
        }
    }

    private func notificationConnectionIsAvailable() async -> Bool {
        guard !closed else { return false }
        return await session.isConnected
    }

    /// One deadline over the plugin config dir resolution and the file
    /// operation together.
    private func withNotificationFileRequestDeadline<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await HostSSHSession.withNotificationFileDeadline(requestTimeout, operation)
    }

#if DEBUG
    func delayNextNotificationSFTPWriteForTesting(_ delay: Duration) async {
        await session.delayNextNotificationSFTPWriteForTesting(delay)
    }

    func holdNextOutboundWriteParkForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) async {
        await session.holdNextOutboundWriteParkForTesting(hold)
    }

    func holdStagingPhaseForTesting(
        _ phase: AttachmentStagingPhaseForTesting,
        _ hold: @escaping @Sendable () async -> Void
    ) async {
        await session.holdStagingPhaseForTesting(phase, hold)
    }

    func notificationFileStateForTesting() async -> WaycarSSHNotificationFileStateForTesting {
        await session.notificationFileStateForTesting()
    }

    func readRemoteFileForTesting(at path: String) async throws -> Data? {
        try await session.readRemoteFileForTesting(at: path)
    }

    func replacePluginConfigFileForTesting(named name: String, contents: Data) async throws {
        try await replacePluginConfigFile(named: name, contents: contents)
    }
#endif

    func listDirectories(at path: String) async throws -> RemoteDirectoryListing {
        try await session.listDirectories(at: path)
    }

    /// The Host's `waycar` plugin as this connection resolved it: the id it
    /// is enabled under, its config dir, and its install root (`plugin_root`
    /// in `herdr plugin list --json`; nil when herdr does not report one).
    private struct NotificationPlugin: Sendable {
        let id: String
        let configDirectory: String
        let root: String?
    }

    private func notificationPluginConfigDirectory() async throws -> String {
        try await resolvedNotificationPlugin().configDirectory
    }

    private func resolvedNotificationPlugin() async throws -> NotificationPlugin {
        try await notificationPlugin.value {
            try await self.resolveNotificationPlugin()
        }
    }

    private func resolveNotificationPlugin() async throws -> NotificationPlugin {
        let listOutput = try await runNotificationPluginProbe(command: pluginListCommand)
        let installed = try installedNotificationPlugin(in: listOutput)
        let configDirCommand = notificationConfigDirCommand.replacingOccurrences(
            of: SSHTransportSettings.notificationPluginIDToken,
            with: installed.id)
        let output = try await runNotificationPluginProbe(command: configDirCommand)
        guard
            let directory = Self.markerValue(
                in: output,
                prefix: Self.pluginConfigDirOutputPrefix),
            RemoteShellPath.isQuotableAbsolute(directory)
        else {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The plugin config directory response was invalid.")
        }
        return NotificationPlugin(
            id: installed.id, configDirectory: directory, root: installed.root)
    }

    /// The id the Host's `waycar` herdr plugin is enabled under, with its
    /// reported root: the current id when present, else the newest legacy
    /// id. Registration targets that plugin's own config dir, so a Host
    /// still on an old plugin build keeps working.
    private func installedNotificationPlugin(
        in listOutput: Data
    ) throws -> (id: String, root: String?) {
        let list: NotificationPluginListEnvelope
        do {
            list = try JSONDecoder().decode(NotificationPluginListEnvelope.self, from: listOutput)
        } catch {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The plugin list response was invalid.")
        }
        let enabled = list.result.plugins.filter { $0.enabled != false }
        let knownIDs = [SSHTransportSettings.notificationPluginID]
            + SSHTransportSettings.legacyNotificationPluginIDs
        for id in knownIDs {
            if let plugin = enabled.first(where: { $0.pluginID == id }) {
                return (id, plugin.pluginRoot)
            }
        }
        throw NotificationRegistrationError.pluginNotInstalled
    }

    private func runNotificationPluginProbe(command: String) async throws -> Data {
        do {
            let result = try await runExec(
                Self.cLocaleCommand(HerdrHostPath.wrappingBareHerdr(command)))
            if let missing = HerdrHostPath.missingBinaryError(
                exitStatus: result.exitStatus, command: command)
            {
                throw missing
            }
            guard result.exitStatus == 0, result.reachedEOF else {
                throw NotificationRegistrationError.pluginProbeFailed(
                    detail: "The Host plugin probe failed.")
            }
            return result.stdout
        } catch TransportError.cancelled {
            throw TransportError.cancelled
        } catch TransportError.timedOut {
            throw TransportError.timedOut
        } catch TransportError.herdrBinaryNotFound {
            throw TransportError.herdrBinaryNotFound
        } catch let error as NotificationRegistrationError {
            throw error
        } catch {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The Host plugin probe failed.")
        }
    }

    private struct NotificationPluginListEnvelope: Decodable {
        struct ResultBody: Decodable {
            let plugins: [Entry]
        }

        struct Entry: Decodable {
            let pluginID: String?
            let enabled: Bool?
            let pluginRoot: String?

            private enum CodingKeys: String, CodingKey {
                case pluginID = "plugin_id"
                case enabled
                case pluginRoot = "plugin_root"
            }
        }

        let result: ResultBody
    }

    // MARK: Attachment staging

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        try await session.stageImage(image, progress: progress)
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        try await session.stageFile(file, progress: progress)
    }

    func stageLaunchPromptFiles(
        _ files: [LaunchPromptFile]
    ) async throws -> [StagedLaunchPromptFile] {
        try await session.stageLaunchPromptFiles(files)
    }

    func launchPromptCapabilities() async -> LaunchPromptCapabilities {
        await session.launchPromptCapabilities()
    }

    var isConnected: Bool {
        get async {
            guard !closed else { return false }
            return await session.isConnected
        }
    }

    /// Releases this Transport's hold on its session. A session nothing else
    /// holds closes with it, ending every channel as before. One that lives
    /// on for another backend keeps its connection, so this Transport ends
    /// its own events and Attach channels itself (design §4.1).
    func close() async throws {
        guard !closed else { return }
        closed = true
        for settle in launchSettles.values { settle.cancel() }
        launchSettles.removeAll()
        inputGates.removeAll()
        agentKinds.removeAll()
        let readers = Array(eventsReaders.values)
        eventsReaders.removeAll()
        let attaches = Array(liveAttaches.values)
        liveAttaches.removeAll()
        try await session.releaseReportingTeardown()
        guard await session.isOpen else { return }
        for reader in readers { reader.cancel() }
        for attach in attaches { await attach.end() }
    }

    /// Whether this Transport may start a channel: not closed, and its
    /// session neither closed nor found invalidated.
    private func linkIsOpen() async -> Bool {
        guard !closed else { return false }
        return await session.isOpen
    }

    private func request<R: Decodable & Sendable>(
        method: String,
        decoding type: R.Type
    ) async throws -> R {
        try await request(
            method: method,
            params: HerdrWire.EmptyParams(),
            decoding: type)
    }

    /// `timeout` replaces ``requestTimeout`` for this one request, queue
    /// wait and channel exchange alike; nil keeps the shared budget.
    private func request<P: Encodable & Sendable, R: Decodable & Sendable>(
        method: String,
        params: P,
        decoding type: R.Type,
        timeout: Duration? = nil,
        beforeDispatch: (@Sendable () async throws -> Void)? = nil,
        onDispatched: (@Sendable () async -> Void)? = nil
    ) async throws -> R {
        try await retryingAfterHomeRefresh {
            try await self.performRequest(
                method: method,
                params: params,
                decoding: type,
                timeout: timeout,
                beforeDispatch: beforeDispatch,
                onDispatched: onDispatched)
        }
    }

    private func performRequest<P: Encodable & Sendable, R: Decodable & Sendable>(
        method: String,
        params: P,
        decoding type: R.Type,
        timeout: Duration? = nil,
        beforeDispatch: (@Sendable () async throws -> Void)? = nil,
        onDispatched: (@Sendable () async -> Void)? = nil
    ) async throws -> R {
        guard await linkIsOpen() else {
            throw TransportError.sshUnreachable(
                detail: "the SSH connection is closed")
        }
        let budget = timeout ?? requestTimeout
        let requestID = UUID().uuidString
        let line = try HerdrWire.requestLine(
            id: requestID,
            method: method,
            params: params)
        let responseLine = try await withRequestDeadline(budget) {
            let socketPath = try await self.resolvedSocketPath()
            // The response returns before the channel closes; its admission
            // stays held until the close really finishes (C-CLOSE), so
            // pending closes still count against the forwarding budget.
            return try await self.session.withChannel(
                .ordinaryForwarding,
                releasedBy: { onChannelReleased in
                    do {
                        return try await self.session.exchangeStreamLocal(
                            socketPath: socketPath,
                            request: Data(line.utf8),
                            maximumResponseBytes: Self.maximumResponseBytes,
                            timeout: budget,
                            beforeRequestWrite: beforeDispatch,
                            onRequestWritten: onDispatched,
                            onChannelReleased: onChannelReleased)
                    } catch SSHError.streamLocalOpenFailed {
                        throw try await self.classifyStreamLocalOpenFailure(
                            socketPath: socketPath)
                    } catch let error as SSHError {
                        throw await self.mapOperationError(error)
                    } catch {
                        throw error
                    }
                })
        }
        return try HerdrWire.decodeResult(
            type,
            fromResponseLine: responseLine,
            requestID: requestID)
    }

    /// Runs `operation`, and once more when its socket was not found at a
    /// path a remembered `$HOME` produced and resolving `$HOME` again moved
    /// the path (#105, C-CACHE). A stopped herdr is never started here: it
    /// surfaces as `.herdrNotRunning` or `.streamLocalOpenFailed`, and only
    /// the user's Start Herdr TUI starts it (`HostSSHSession.wakeHerdrServer`).
    private func retryingAfterHomeRefresh<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as TransportError {
            guard let failedPath = Self.missingSocketPath(in: error),
                await session.refreshHomeDirectory(
                    afterFailureAt: failedPath, location: socketLocation)
            else { throw error }
            return try await operation()
        }
    }

    /// The socket path a request found no herdr socket at, if that is how it
    /// failed.
    static func missingSocketPath(in error: TransportError) -> String? {
        switch error {
        case .socketNotFound(let path), .streamLocalOpenFailed(let path),
            .herdrNotRunning(let path), .herdrSessionNotFound(let path):
            path
        default: nil
        }
    }

    /// Tells why a stream-local open failed, with one exec: a socket that
    /// exists is stale or refused by SSH policy (`.streamLocalOpenFailed`); a
    /// missing one with herdr on the wake's PATH, in a session that exists,
    /// is a stopped server (`.herdrNotRunning`); herdr on the PATH with the
    /// session's folder missing is `.herdrSessionNotFound`; no herdr is
    /// `.socketNotFound`. herdr counts a named session only once its folder
    /// exists, and a start would create it, so a session whose folder is
    /// missing is never offered a start; the default session always is.
    /// Nothing here starts herdr.
    private func classifyStreamLocalOpenFailure(
        socketPath: String
    ) async throws -> TransportError {
        guard
            let command = Self.classificationCommand(
                socketPath: socketPath, socketLocation: socketLocation)
        else {
            return .socketNotFound(path: socketPath)
        }
        do {
            let result = try await runExec(command)
            switch result.exitStatus {
            case 1: return .socketNotFound(path: socketPath)
            case Self.herdrNotRunningStatus: return .herdrNotRunning(path: socketPath)
            case Self.herdrSessionNotFoundStatus: return .herdrSessionNotFound(path: socketPath)
            default: return .streamLocalOpenFailed(path: socketPath)
            }
        } catch TransportError.cancelled {
            throw TransportError.cancelled
        } catch TransportError.timedOut {
            throw TransportError.timedOut
        } catch {
            return .streamLocalOpenFailed(path: socketPath)
        }
    }

    /// `classifyStreamLocalOpenFailure`'s probe; nil when the path cannot be
    /// quoted. The default session skips the folder test: it can be started
    /// even before herdr ever created `~/.config/herdr`.
    static func classificationCommand(
        socketPath: String, socketLocation: HerdrSocketLocation
    ) -> String? {
        guard let quotedPath = RemoteShellPath.quotedAbsolute(socketPath) else { return nil }
        let sessionExists = socketLocation == .defaultSession
            ? "" : "[ -d \"${1%/*}\" ] || exit \(herdrSessionNotFoundStatus); "
        return "/bin/sh -c '\(HerdrHostPath.pathExport); [ -S \"$1\" ] && exit 0; "
            + "command -v herdr >/dev/null 2>&1 || exit 1; "
            + "\(sessionExists)exit \(herdrNotRunningStatus)' waycar \(quotedPath)"
    }

    private func resolvedSocketPath() async throws -> String {
        if case .absolutePath(let path) = socketLocation { return path }
        return socketLocation.path(homeDirectory: try await remoteHomeDirectory())
    }

    /// Herdr resolves its socket path once per session; awaiting it here —
    /// joining the dial-time prewarm — keeps it out of `EventsSession`'s
    /// timed ping (#87, WS2). A resolution failure surfaces through the
    /// first request instead, which maps it like any other first-request
    /// failure.
    func awaitSocketPathReadiness() async {
        try? await resolvedSocketPath()
    }

    func remoteHomeDirectory() async throws -> String {
        try await session.remoteHomeDirectory()
    }

    private func runHostCommand(_ command: String) async throws -> Data {
        try await session.runHostCommand(command)
    }

    private func runExec(
        _ command: String, input: Data = Data(), timeout: Duration? = nil
    ) async throws -> SSHExecResult {
        try await session.runExec(command, input: input, timeout: timeout)
    }

    private func withRequestDeadline<T: Sendable>(
        _ budget: Duration? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await HostSSHSession.withDeadline(budget ?? requestTimeout, operation)
    }

    private func mapOperationError(_ error: any Error) async -> TransportError {
        await session.mapOperationError(error)
    }

    #if DEBUG
    /// Test surface for the real connect-time mapper; not a second taxonomy.
    static func mapConnectForTesting(_ error: any Error) -> TransportError {
        HostSSHSession.mapConnect(error)
    }

    /// Test surface for the real post-connect mapper; not a second taxonomy.
    static func mapOperationForTesting(_ error: any Error) -> TransportError {
        HostSSHSession.mapOperation(error)
    }
    #endif

    private static let pluginConfigDirOutputPrefix = "__WAYCAR_PLUGIN_CONFIG_DIR__="

    private static func markerValue(in output: Data, prefix: String) -> String? {
        HostSSHSession.markerValue(in: output, prefix: prefix)
    }

    private static func preview(_ data: Data) -> String {
        HostSSHSession.preview(data)
    }

    private static func cLocaleCommand(_ command: String) -> String {
        HostSSHSession.cLocaleCommand(command)
    }

    /// `classifyStreamLocalOpenFailure`'s exit status for a stopped herdr; its
    /// probe exits 0 for a socket that exists and 1 for a missing one with no
    /// herdr, and a shell that cannot run it exits 2.
    private static let herdrNotRunningStatus: Int32 = 3
    /// The probe's exit status for herdr on the PATH and the session's folder
    /// missing.
    private static let herdrSessionNotFoundStatus: Int32 = 4

    /// The exec that starts a stopped herdr server when the user asks (Start
    /// Herdr TUI, or right after Install herdr), and what it reads on stdin.
    typealias WakeExec = HostServerStartExec

    /// The exec that starts a stopped herdr server (#6, #389). Waycar runs it
    /// only when the user asks: no request, reconnect or attach starts herdr.
    /// A named session scopes the wake to its own state directory, so the spawned server serves the
    /// socket the request is actually waiting on. The exec sets no locale: the
    /// server and every pane it starts inherit the wake's environment.
    ///
    /// `inLoginSession` first tries a one-shot launchd job in the user's
    /// `gui/<uid>` session (macOS with a logged-in user only), so the server
    /// gets the login session's Keychain and SSH agent instead of the SSH
    /// login's. The exec writes the job's folder (`/tmp/dev.waycar.herdr-wake.*`,
    /// its name the job's label) with the job script from stdin, an `env`
    /// file of only `PATH`, `HOME` and herdr's variables, and the plist, which
    /// holds fixed text and that folder's path alone. The job runs the wake
    /// from `$HOME`, writes the wake's exit status, then removes its folder
    /// and boots itself out, so nothing stays behind when the exec is gone.
    /// The exec waits up to 12 s for the job to finish (its folder to go), not
    /// for the socket: a stale socket file is there before the wake starts.
    /// It succeeds only when the wake exited 0 and the socket is there, and
    /// prints the job's stderr otherwise (status and stderr are read through
    /// descriptors it opened before the job started). When launchd refuses the job, the
    /// plain wake runs instead. The script holds no single quote and no
    /// backslash, so any account shell passes it to `/bin/sh` intact.
    static func wakeExec(
        wakeCommand: String, socketPath: String, socketLocation: HerdrSocketLocation,
        inLoginSession: Bool
    ) throws -> WakeExec {
        guard let quotedSocketPath = RemoteShellPath.quotedAbsolute(socketPath) else {
            throw TransportError.channelFailed(
                detail: "the remote socket path cannot be quoted safely")
        }
        let herdrVariables: [String]
        let arguments: String
        switch socketLocation {
        case .namedSession(let sessionName):
            guard HerdrSessionName.isValid(sessionName) else {
                throw TransportError.channelFailed(
                    detail: "the herdr session name is not valid")
            }
            herdrVariables = ["HERDR_SOCKET_PATH=\"$1\"", "HERDR_SESSION=\"$2\""]
            arguments = "\(quotedSocketPath) \(sessionName)"
        case .defaultSession, .absolutePath:
            herdrVariables = ["HERDR_SOCKET_PATH=\"$1\""]
            arguments = quotedSocketPath
        }
        let plainWake = herdrVariables.map { "export \($0); " }.joined()
            + "\(wakeCommand) < /dev/null"
        guard inLoginSession else {
            return WakeExec(
                command: "/bin/sh -c '\(HerdrHostPath.pathExport); \(plainWake)' wake \(arguments)",
                input: Data())
        }
        let loginSessionWake = HostLoginSessionStart.script(
            variables: herdrVariables, ready: "[ -S \"$1\" ]")
        return WakeExec(
            command: "/bin/sh -c '\(HerdrHostPath.pathExport); \(loginSessionWake)\(plainWake)' "
                + "wake \(arguments)",
            input: Data(HostLoginSessionStart.job(command: wakeCommand).utf8))
    }

    func subscribeToEvents(
        _ subscriptions: [EventSubscription]
    ) async throws -> HerdrEventStream {
        guard eventsChannelState == .idle else {
            throw TransportError.eventsChannelAlreadyOpen
        }
        eventsChannelState = .opening
        var admissionLease: SSHChannelAdmissionLease?
        do {
            let lease = try await session.acquireChannel(.events)
            admissionLease = lease
            let (stream, readerID) = try await retryingAfterHomeRefresh {
                try await self.openEventsChannel(
                    subscriptions,
                    admissionLease: lease)
            }
            if endedEventsReaders.remove(readerID) != nil {
                eventsChannelState = .idle
            } else {
                eventsChannelState = .streaming(readerID: readerID)
            }
            return stream
        } catch {
            if let admissionLease { await admissionLease.release() }
            eventsChannelState = .idle
            throw error
        }
    }

    private func openEventsChannel(
        _ subscriptions: [EventSubscription],
        admissionLease: SSHChannelAdmissionLease
    ) async throws -> (HerdrEventStream, readerID: UInt64) {
        guard await linkIsOpen() else {
            throw TransportError.sshUnreachable(detail: "the SSH connection is closed")
        }
        let socketPath = try await resolvedSocketPath()
        let requestID = UUID().uuidString
        let requestLine = try HerdrWire.subscribeRequestLine(
            id: requestID,
            subscriptions: subscriptions)
        let channel: SSHStreamLocalChannel
        do {
            channel = try await session.openStreamLocal(socketPath: socketPath)
        } catch SSHError.streamLocalOpenFailed {
            throw try await classifyStreamLocalOpenFailure(socketPath: socketPath)
        } catch {
            throw await mapOperationError(error)
        }

        do {
            try await channel.write(Data(requestLine.utf8), timeout: requestTimeout)
        } catch {
            try? await channel.close(timeout: .seconds(2))
            throw await mapOperationError(error)
        }

        let (events, eventContinuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(HerdrEventStream.bufferLimit))
        let (ackLines, ackContinuation) = AsyncThrowingStream<Data, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        nextEventsReaderID &+= 1
        let readerID = nextEventsReaderID
        let readerTask = Task {
            await self.runEventsChannel(
                readerID: readerID,
                channel: channel,
                admissionLease: admissionLease,
                ack: ackContinuation,
                events: eventContinuation)
        }
        eventsReaders[readerID] = readerTask

        do {
            let ackLine = try await withRequestDeadline {
                var iterator = ackLines.makeAsyncIterator()
                guard let line = try await iterator.next() else {
                    throw TransportError.channelFailed(
                        detail: "events channel ended before ack")
                }
                return line
            }
            _ = try HerdrWire.decodeResult(
                SubscriptionStartedResponse.self,
                fromResponseLine: ackLine,
                requestID: requestID)
        } catch {
            readerTask.cancel()
            await readerTask.value
            endedEventsReaders.remove(readerID)
            throw error
        }

        return (
            HerdrEventStream(events: events) {
                readerTask.cancel()
                await readerTask.value
            },
            readerID)
    }

    private func runEventsChannel(
        readerID: UInt64,
        channel: SSHStreamLocalChannel,
        admissionLease: SSHChannelAdmissionLease,
        ack ackContinuation: AsyncThrowingStream<Data, any Error>.Continuation,
        events eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation
    ) async {
        var pending = Data()
        var sawAck = false
        var streamFailure: TransportError?
        var ackFailure = TransportError.cancelled

        do {
            while !Task.isCancelled {
                let chunk: Data?
                do {
                    chunk = try await channel.read(
                        maximumBytes: 16 * 1024,
                        timeout: .seconds(1))
                } catch SSHError.timedOut {
                    continue
                }
                guard let chunk else {
                    if sawAck {
                        streamFailure = .channelFailed(
                            detail: "events channel closed by remote")
                    } else {
                        ackFailure = .channelFailed(
                            detail: "events channel ended before ack")
                        streamFailure = ackFailure
                    }
                    break
                }
                pending.append(chunk)
                guard pending.count <= Self.maximumResponseBytes else {
                    throw TransportError.malformedResponse(
                        "events line exceeds \(Self.maximumResponseBytes) bytes")
                }
                while let line = Self.takeLine(from: &pending) {
                    if !sawAck {
                        sawAck = true
                        ackContinuation.yield(line)
                        ackContinuation.finish()
                    } else if let event = HerdrWire.decodeEvent(fromLine: line) {
                        if case .dropped = eventContinuation.yield(event) {
                            _ = eventContinuation.yield(.eventsDropped)
                        }
                    }
                }
            }
        } catch SSHError.cancelled {
            streamFailure = nil
        } catch is CancellationError {
            streamFailure = nil
        } catch {
            let failure = await mapOperationError(error)
            ackFailure = failure
            streamFailure = failure
        }

        do {
            try await channel.close(timeout: .seconds(2))
        } catch {
            let failure = await mapOperationError(error)
            if !Task.isCancelled {
                ackFailure = failure
                streamFailure = failure
            }
        }
        await admissionLease.release()

        eventsChannelReaderDidEnd(readerID)
        ackContinuation.finish(throwing: ackFailure)
        if let streamFailure {
            eventContinuation.finish(throwing: streamFailure)
        } else {
            eventContinuation.finish()
        }
    }

    private func eventsChannelReaderDidEnd(_ readerID: UInt64) {
        eventsReaders[readerID] = nil
        if eventsChannelState == .streaming(readerID: readerID) {
            eventsChannelState = .idle
        } else {
            endedEventsReaders.insert(readerID)
        }
    }

    private static func takeLine(from pending: inout Data) -> Data? {
        guard let newline = pending.firstIndex(of: 0x0A) else { return nil }
        let line = Data(pending[...newline])
        pending.removeSubrange(...newline)
        return line
    }

    /// Builds the probe's bootstrap: the same `mosh-server new` exec as the
    /// real attach, wrapping a keep-alive shell instead of a herdr attach so
    /// the probe never touches a live Agent pane. The keep-alive command
    /// deliberately contains no single quotes (it rides inside the
    /// bootstrap's outer `/bin/sh -c '…'` wrapper).
    static func moshProbeBootstrapCommand(socketPath: String, bindsToPeer: Bool) throws -> String {
        try moshBootstrapCommand(
            // `echo` as a bare command: mosh-server flattens inner quoting
            // when it joins its arguments through the login shell, so the
            // wrapped command must not need quotes. The marker rides the
            // mosh session's rendered output back to the device — a real
            // end-to-end proof, and it completes in well under a second.
            agentAttachCommand: "echo MOSH_HANDSHAKE_OK",
            terminalAttachCommand: "",
            request: TerminalAttachRequest(
                target: .agentPane("mosh-probe"), takeover: false, cols: 80, rows: 24),
            socketPath: socketPath,
            appendsTarget: false,
            bindsToPeer: bindsToPeer)
    }

    func probeMoshServer() async throws -> Bool {
        try await session.probeMoshServer()
    }

    func runMoshBootstrap(_ request: TerminalAttachRequest) async throws -> MoshBootstrap {
        let socketPath = try await resolvedSocketPath()
        let agentAttachCommand = attachCommand
        let terminalAttachCommand = self.terminalAttachCommand
        return try await session.runMoshBootstrap { bindsToPeer in
            try Self.moshBootstrapCommand(
                agentAttachCommand: agentAttachCommand,
                terminalAttachCommand: terminalAttachCommand,
                request: request,
                socketPath: socketPath,
                bindsToPeer: bindsToPeer)
        }
    }

    func attachTerminal(
        _ request: TerminalAttachRequest
    ) async throws -> TerminalAttachSession {
        guard terminalChannelStates[request.target] == nil else {
            throw TransportError.terminalChannelAlreadyOpen
        }
        let target = request.target
        terminalChannelStates[target] = .opening
        nextTerminalReaderID &+= 1
        let readerID = nextTerminalReaderID

        do {
            let socketPath = try await resolvedSocketPath()
            let selectedAttachCommand = Self.attachCommand(
                agentAttachCommand: attachCommand,
                terminalAttachCommand: terminalAttachCommand,
                target: target)
            let command = try Self.attachExecCommand(
                agentAttachCommand: attachCommand,
                terminalAttachCommand: terminalAttachCommand,
                request: request,
                socketPath: socketPath)
            let attach = try await session.attachTerminal(
                command: command,
                request: request,
                exitCommand: selectedAttachCommand,
                onChannelEnded: { [weak self] in
                    await self?.attachChannelDidEnd(target: target, readerID: readerID)
                })
            if endedTerminalReaders.remove(readerID) != nil {
                terminalChannelStates.removeValue(forKey: target)
            } else {
                terminalChannelStates[target] = .streaming(readerID: readerID)
                liveAttaches[readerID] = attach
            }
            return attach
        } catch {
            terminalChannelStates.removeValue(forKey: target)
            throw error
        }
    }

    /// Builds the PTY-less exec that bootstraps one mosh session. Mirrors
    /// `attachExecCommand` up to the PTY source: mosh-server provides the
    /// wrapped command's PTY itself, so the SSH exec is an ordinary
    /// request. mosh-server prints its `MOSH CONNECT` banner and detaches,
    /// which closes the channel and lets the caller parse the answer.
    static func moshBootstrapCommand(
        agentAttachCommand: String,
        terminalAttachCommand: String,
        request: TerminalAttachRequest,
        socketPath: String,
        appendsTarget: Bool = true,
        bindsToPeer: Bool
    ) throws -> String {
        let attachCommand = attachCommand(
            agentAttachCommand: agentAttachCommand,
            terminalAttachCommand: terminalAttachCommand,
            target: request.target)
        let target = request.target.identifier
        let unquotable: (Character) -> Bool = { character in
            character == "'" || character == "\\"
                || character.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }
        guard
            !attachCommand.isEmpty,
            !target.isEmpty,
            !target.contains(where: unquotable)
        else {
            throw TransportError.channelFailed(
                detail: "mosh bootstrap target cannot be quoted for the remote command")
        }
        guard let quotedSocketPath = RemoteShellPath.quotedAbsolute(socketPath) else {
            throw TransportError.channelFailed(
                detail: "the remote socket path cannot be quoted safely")
        }
        let takeover = request.takeover ? " --takeover" : ""
        // `$1` is the attach target (the pane id herdr attach consumes).
        // Probes pass `appendsTarget: false`: their keep-alive command must
        // not receive the pane id — `sleep 120 mosh-probe` would reject the
        // extra argument and exit, killing the proof session on connect.
        // `-l LANG=en_US.UTF-8` gives the server-side PTY the UTF-8 locale
        // the attach TUI needs; the exec itself stays LC_ALL=C-prefixed by
        // the Host-command wrapper, which only affects mosh-server's own
        // argument parsing.
        let targetArgument = appendsTarget ? " \"$1\"" : ""
        // TERM must ride the wrapper: the bootstrap exec runs without a
        // PTY, so nothing sets a terminal type for mosh-server's own PTY —
        // and the herdr attach TUI exits immediately without one. The SSH
        // attach path never hits this because libssh2 sets TERM on its PTY
        // request. `-c` is the client terminal's color count, not a column
        // count: mosh-server sets the command's TERM to `xterm-256color`
        // for `-c 256` and to plain `xterm` for anything else.
        //
        // Server lifetime (#19): an attach holds herdr's resize lock on the
        // pane for as long as it runs, so a mosh-server that outlives its
        // client pins the pane at this device's size. Waycar ends each
        // session with mosh's shutdown handshake (`MoshAttachSession.end()`);
        // `MOSH_SERVER_NETWORK_TMOUT=60` is the backstop for a client that
        // vanished without one (killed app, lost network): mosh-server exits
        // 60 s after the client's last new state, ending the attach. A
        // connected client sends one every few seconds even when idle (its
        // heartbeat, see `Packages/SwiftMosh/PROVENANCE.md`).
        //
        // mosh-server's UDP source (#122): unbound, a multi-homed Host
        // answers from its primary interface's address whatever address the
        // client sent to, and the client's connected UDP flow drops
        // datagrams from any source but the one it sent to. So when the dial
        // pinned `HostSSHSession.moshUDPHost`, mosh-server gets `-s`, which
        // binds the address the SSH connection arrived on at the Host (the
        // local half of `SSH_CONNECTION`). A loopback arrival means a TCP
        // proxy fronts sshd (sslh, HAProxy, stunnel), where `-s` would bind
        // loopback, so the guard leaves mosh-server unbound as before
        // (`HostSSHSession.moshServerInvocation(bindsToPeer:)`).
        return "/bin/sh -c '\(HerdrHostPath.pathExport); "
            + "export HERDR_SOCKET_PATH=\"$2\"; export TERM=xterm-256color; "
            + "export MOSH_SERVER_NETWORK_TMOUT=60; "
            + HostSSHSession.moshServerInvocation(bindsToPeer: bindsToPeer)
            + "-- \(attachCommand)\(targetArgument)\(takeover)' mosh "
            + "'\(target)' \(quotedSocketPath)"
    }

    /// Builds the remote exec request used after the PTY has been accepted.
    /// `HERDR_SOCKET_PATH` is set by the command itself, not an SSH environment
    /// request that the Host may reject. OpenSSH still runs the request through
    /// the account shell as `shell -c …`, so generic shell or SSH rc chatter
    /// can still reach the PTY; the handshake marker is printed immediately
    /// before `exec` of attach so the bootstrap gate can drop everything earlier.
    /// See `AttachBootstrapHandshake`.
    static func attachExecCommand(
        agentAttachCommand: String,
        terminalAttachCommand: String,
        request: TerminalAttachRequest,
        socketPath: String
    ) throws -> String {
        let attachCommand = attachCommand(
            agentAttachCommand: agentAttachCommand,
            terminalAttachCommand: terminalAttachCommand,
            target: request.target)
        let target = request.target.identifier
        let unquotable: (Character) -> Bool = { character in
            character == "'" || character == "\\"
                || character.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }
        guard
            !attachCommand.isEmpty,
            !target.isEmpty,
            !target.contains(where: unquotable)
        else {
            throw TransportError.channelFailed(
                detail: "attach target cannot be quoted for the remote command")
        }
        guard let quotedSocketPath = RemoteShellPath.quotedAbsolute(socketPath) else {
            throw TransportError.channelFailed(
                detail: "the remote socket path cannot be quoted safely")
        }
        let takeover = request.takeover ? " --takeover" : ""
        // The marker goes out last thing before the exec, so earlier startup
        // chatter can be dropped.
        return "/bin/sh -c '\(HerdrHostPath.pathExport); "
            + "export HERDR_SOCKET_PATH=\"$2\"; "
            + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
            + "exec \(attachCommand) \"$1\"\(takeover)' attach "
            + "'\(target)' \(quotedSocketPath)"
    }

    /// Compatibility seam for existing Agent Attach tests and fixtures.
    static func attachExecCommand(
        attachCommand: String,
        request: TerminalAttachRequest,
        socketPath: String
    ) throws -> String {
        try attachExecCommand(
            agentAttachCommand: attachCommand,
            terminalAttachCommand: attachCommand,
            request: request,
            socketPath: socketPath)
    }

    private static func attachCommand(
        agentAttachCommand: String,
        terminalAttachCommand: String,
        target: TerminalAttachTarget
    ) -> String {
        switch target {
        case .agentPane:
            agentAttachCommand
        case .terminal:
            terminalAttachCommand
        }
    }

    /// The session closed `readerID`'s channel, so its target may attach
    /// again. A channel that ends before `attachTerminal` has recorded it is
    /// remembered, so that call does not record a dead channel.
    private func attachChannelDidEnd(target: TerminalAttachTarget, readerID: UInt64) {
        liveAttaches[readerID] = nil
        if terminalChannelStates[target] == .streaming(readerID: readerID) {
            terminalChannelStates.removeValue(forKey: target)
        } else {
            endedTerminalReaders.insert(readerID)
        }
    }
}
