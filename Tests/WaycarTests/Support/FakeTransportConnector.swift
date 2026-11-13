import Foundation

@testable import Waycar

/// Scripted `Transport` for store tests: protocol-level, no SSH.
final actor FakeTransport: Transport {
    private let pingResult: Result<ServerInfo, TransportError>
    private let sessions: [HerdrSession]
    /// The Host tools' `waycar hooks status`; nil means none installed.
    private var statusHooks: Result<StatusHooksReport, TransportError>?
    /// What `subscribeToEvents` answers; nil means this fake scripts no events.
    private let eventsAnswer: Result<Void, TransportError>?
    private(set) var isClosed = false
    private(set) var listSessionsCount = 0
    private(set) var installStatusHooksCount = 0

    init(
        pingResult: Result<ServerInfo, TransportError>, sessions: [HerdrSession] = [],
        statusHooks: Result<StatusHooksReport, TransportError>? = nil,
        eventsAnswer: Result<Void, TransportError>? = nil
    ) {
        self.pingResult = pingResult
        self.sessions = sessions
        self.statusHooks = statusHooks
        self.eventsAnswer = eventsAnswer
    }

    func ping() async throws -> ServerInfo {
        try pingResult.get()
    }

    func listSessions() async throws -> [HerdrSession] {
        listSessionsCount += 1
        return sessions
    }

    func statusHooksReport() async throws -> StatusHooksReport {
        guard let statusHooks else {
            throw TransportError.channelFailed(detail: "FakeTransport has no Host tools")
        }
        return try statusHooks.get()
    }

    /// Marks every agent's hooks installed, as `waycar hooks install` does.
    func installStatusHooks() async throws -> StatusHooksReport {
        installStatusHooksCount += 1
        let current = try await statusHooksReport()
        let installed = StatusHooksReport(
            version: current.version, hostTools: current.hostTools, backends: current.backends,
            configDir: current.configDir,
            agents: current.agents.map {
                StatusHooksReport.AgentHooks(
                    agent: $0.agent, installed: true, configPath: $0.configPath,
                    needsCodexReview: $0.needsCodexReview)
            })
        statusHooks = .success(installed)
        return installed
    }

    func listAgents() async throws -> [Agent] {
        []
    }

    /// Ranged Host-file reads (#325): scripted answers, in order.
    private var scriptedFileSlices: [RemoteFileSlice] = []
    private(set) var fileRanges: [RemoteFileRange] = []

    func setFileSlices(_ slices: [RemoteFileSlice]) {
        scriptedFileSlices = slices
    }

    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        fileRanges.append(range)
        guard !scriptedFileSlices.isEmpty else {
            throw TransportError.channelFailed(
                detail: "FakeTransport does not script file slices")
        }
        return scriptedFileSlices.removeFirst()
    }

    /// Model window lookups (#325): scripted per selector; unscripted ones
    /// are unknown, as with a model omp does not list.
    private var scriptedContextWindows: [String: Int] = [:]
    private(set) var contextWindowSelectors: [String] = []

    func setContextWindows(_ windows: [String: Int]) {
        scriptedContextWindows = windows
    }

    func modelContextWindow(selector: String) async throws -> Int? {
        contextWindowSelectors.append(selector)
        return scriptedContextWindows[selector]
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        SessionSnapshot(
            agents: [], layouts: [], panes: [], protocolVersion: 17, tabs: [],
            version: "0.7.5-fake", workspaces: [])
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        throw TransportError.channelFailed(detail: "FakeTransport does not script pane reads")
    }

    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
        throw TransportError.channelFailed(detail: "FakeTransport does not script Agent reads")
    }

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        throw TransportError.channelFailed(detail: "FakeTransport does not script Agent prompts")
    }

    func checkAgentInputScreen(target: String) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script Agent screens")
    }

    func sendAgentKeys(_ params: AgentSendKeysParams) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script Agent send-keys")
    }

    func sendPaneInput(_ params: PaneSendInputParams) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script pane input")
    }

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        guard let eventsAnswer else {
            throw TransportError.channelFailed(detail: "FakeTransport does not script events")
        }
        try eventsAnswer.get()
        let (stream, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
        return HerdrEventStream(events: stream) { continuation.finish() }
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        throw TransportError.channelFailed(detail: "FakeTransport does not script attach")
    }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        throw TransportError.channelFailed(detail: "FakeTransport does not script agent starts")
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec, attempt: WorktreeLaunchAttempt
    ) async throws -> Agent {
        throw TransportError.channelFailed(detail: "FakeTransport does not script agent starts")
    }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        throw TransportError.channelFailed(detail: "FakeTransport does not script agent starts")
    }

    func closePane(_ params: PaneTarget, closesWorktreeGroup: Bool) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script closes")
    }

    // mosh is not scripted in store tests; every attach stays SSH.
    func probeMoshServer() async throws -> Bool { false }
    func runMoshBootstrap(_ request: TerminalAttachRequest) async throws -> MoshBootstrap {
        throw TransportError.channelFailed(detail: "FakeTransport does not script mosh")
    }

    func closeTab(_ params: TabTarget) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script closes")
    }

    func movePane(_ params: PaneMoveParams) async throws -> PaneMoveResponse {
        throw TransportError.channelFailed(detail: "FakeTransport does not script moves")
    }

    func focusAgent(_ target: AgentTarget) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script focus")
    }

    func renameAgent(_ params: AgentRenameParams) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script renames")
    }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script renames")
    }

    var isConnected: Bool {
        !isClosed
    }

    func close() async throws {
        isClosed = true
    }
}

/// Scripted `TransportConnector` that replays the TOFU dance the real
/// validator performs — evaluate the presented key against the known-hosts
/// store, prompt via `confirmFirstConnect` when unknown, persist on trust —
/// so onboarding tests exercise the fingerprint flow without sshd.
final actor FakeTransportConnector: TransportConnector {
    enum Outcome: Sendable {
        /// Thrown before any host key is presented, like a DNS or TCP
        /// failure: the Host never answered.
        case unreachable(TransportError)
        /// Thrown only after the presented keys passed.
        case connectFails(TransportError)
        case connects(pingResult: Result<ServerInfo, TransportError>)
    }

    /// One outcome per dial, in order; the last repeats (`script(_:)`).
    private var outcomes: [Outcome]
    /// Whether `detectBackends` dials like `connect` (keys, outcome, a
    /// captured settings entry) before answering `presence`. Detection and
    /// session dials then share one script, so with several outcomes which
    /// dial gets which depends on the order they dial in.
    private let detectionDials: Bool
    /// The host key the fake "server" presents; nil skips host key
    /// evaluation entirely.
    private let presentedKeyBlob: Data?
    /// The key the Jump Host presents when `settings.jump` is set; nil skips
    /// that hop. Its failures surface as `.jumpHostFailed`, like the real one.
    private let presentedJumpKeyBlob: Data?
    private let sessions: [HerdrSession]
    /// What `detectBackends` reports (ADR 0026).
    private let presence: HostBackendPresence
    /// Thrown by `detectBackends` instead of answering `presence`.
    private let detectionError: TransportError?
    /// What `updateWaycarPlugin` answers; nil means the Host cannot update.
    private let update: Result<WaycarPluginUpdateResult, WaycarPluginUpdate.Failure>?
    /// The installer lines `updateWaycarPlugin` reports before answering.
    private let updateProgress: [String]
    /// Per-backend ping answers; a backend without one uses `outcome`'s.
    private let backendPings: [HostBackend: Result<ServerInfo, TransportError>]
    /// What a herdr-core transport's `events.subscribe` answers.
    private let coreEvents: Result<Void, TransportError>
    /// What each transport's Host tools answer; nil means none installed.
    private let statusHooks: Result<StatusHooksReport, TransportError>?
    private(set) var capturedSettings: [SSHTransportSettings] = []
    private(set) var transports: [FakeTransport] = []
    /// The backend each `connect(settings:backend:)` asked for, in order.
    private(set) var connectedBackends: [HostBackend] = []
    private(set) var detectionCount = 0
    /// The request of each `updateWaycarPlugin` call, in order.
    private(set) var updateRequests: [WaycarPluginUpdateRequest] = []

    // MARK: Backend install (WAY-338)

    /// What `preflightInstall` answers; nil means the Host cannot preflight.
    private var preflight: Result<HostInstallPreflight, TransportError>?
    /// One answer per `runBackendInstall`, in order; the last repeats.
    private var installRuns: [Result<BackendInstallRun, TransportError>] = []
    /// The lines `runBackendInstall` reports before answering.
    private var installProgress: [String] = []
    /// What `detectBackends` answers once an install has run; nil keeps `presence`.
    private var presenceAfterInstall: HostBackendPresence?
    /// Thrown by `wakeHerdr`; nil lets it succeed.
    private var wakeError: TransportError?
    private var holdsInstalls = false
    private var heldInstalls: [CheckedContinuation<Void, Never>] = []
    private(set) var preflightCount = 0
    /// The plan of each `runBackendInstall` call, in order.
    private(set) var installPlans: [BackendInstallPlan] = []
    private(set) var wakeCount = 0
    /// `startCore` calls; it throws `wakeError` too.
    private(set) var coreStartCount = 0
    private(set) var codexStartCount = 0
    private(set) var openCodeStartCount = 0

    func scriptInstall(
        preflight: Result<HostInstallPreflight, TransportError>? = nil,
        runs: [Result<BackendInstallRun, TransportError>] = [],
        progress: [String] = [],
        presenceAfter: HostBackendPresence? = nil,
        wakeError: TransportError? = nil
    ) {
        self.preflight = preflight
        installRuns = runs
        installProgress = progress
        presenceAfterInstall = presenceAfter
        self.wakeError = wakeError
    }

    /// Install runs wait at a gate until `releaseInstalls()`.
    func holdInstalls() {
        holdsInstalls = true
    }

    /// The first `detectBackends` waits at a gate until `releaseDetection()`.
    private var heldDetection: CheckedContinuation<Void, Never>?
    private var holdsDetection = false
    private var detectionGate: ScriptedTransportCallGate?

    func gateDetection(_ gate: ScriptedTransportCallGate) {
        detectionGate = gate
    }

    func holdDetection() {
        holdsDetection = true
    }

    func releaseDetection() {
        holdsDetection = false
        heldDetection?.resume()
        heldDetection = nil
    }

    func releaseInstalls() {
        holdsInstalls = false
        let waiting = heldInstalls
        heldInstalls = []
        for continuation in waiting { continuation.resume() }
    }

    func preflightInstall(settings: SSHTransportSettings) async throws -> HostInstallPreflight {
        preflightCount += 1
        guard let preflight else {
            throw TransportError.channelFailed(detail: "This Host cannot install software.")
        }
        return try preflight.get()
    }

    func runBackendInstall(
        settings: SSHTransportSettings, plan: BackendInstallPlan,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> BackendInstallRun {
        installPlans.append(plan)
        for line in installProgress { progress(line) }
        if holdsInstalls {
            await withCheckedContinuation { heldInstalls.append($0) }
        }
        guard !installRuns.isEmpty else {
            throw TransportError.channelFailed(detail: "This Host cannot install software.")
        }
        return try (installRuns.count > 1 ? installRuns.removeFirst() : installRuns[0]).get()
    }

    func wakeHerdr(settings: SSHTransportSettings) async throws {
        wakeCount += 1
        if let wakeError { throw wakeError }
    }

    func startCore(settings: SSHTransportSettings) async throws {
        coreStartCount += 1
        if let wakeError { throw wakeError }
    }

    func startCodex(settings: SSHTransportSettings) async throws {
        codexStartCount += 1
        if let wakeError { throw wakeError }
    }

    func startOpenCode(settings: SSHTransportSettings) async throws {
        openCodeStartCount += 1
        if let wakeError { throw wakeError }
    }

    init(
        outcome: Outcome, presentedKeyBlob: Data? = nil, presentedJumpKeyBlob: Data? = nil,
        detectionDials: Bool = false,
        sessions: [HerdrSession] = [],
        presence: HostBackendPresence = .herdrOnly,
        detectionError: TransportError? = nil,
        update: Result<WaycarPluginUpdateResult, WaycarPluginUpdate.Failure>? = nil,
        updateProgress: [String] = [],
        backendPings: [HostBackend: Result<ServerInfo, TransportError>] = [:],
        coreEvents: Result<Void, TransportError> = .success(()),
        statusHooks: Result<StatusHooksReport, TransportError>? = nil
    ) {
        outcomes = [outcome]
        self.detectionDials = detectionDials
        self.presentedKeyBlob = presentedKeyBlob
        self.presentedJumpKeyBlob = presentedJumpKeyBlob
        self.sessions = sessions
        self.presence = presence
        self.detectionError = detectionError
        self.update = update
        self.updateProgress = updateProgress
        self.backendPings = backendPings
        self.coreEvents = coreEvents
        self.statusHooks = statusHooks
    }

    /// Replaces the outcomes of the dials from now on; the last repeats.
    func script(_ outcomes: [Outcome]) {
        precondition(!outcomes.isEmpty)
        self.outcomes = outcomes
    }

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        try await open(settings: settings, pingOverride: nil)
    }

    func connect(settings: SSHTransportSettings, backend: HostBackend) async throws -> any Transport {
        connectedBackends.append(backend)
        return try await open(
            settings: settings, pingOverride: backendPings[backend],
            eventsAnswer: backend == .core ? coreEvents : nil)
    }

    func detectBackends(settings: SSHTransportSettings) async throws -> HostBackendPresence {
        detectionCount += 1
        await detectionGate?.waitUntilOpen()
        if holdsDetection {
            await withCheckedContinuation { heldDetection = $0 }
        }
        if detectionDials { _ = try await dial(settings: settings) }
        if let detectionError { throw detectionError }
        if !installPlans.isEmpty, let presenceAfterInstall { return presenceAfterInstall }
        return presence
    }

    func updateWaycarPlugin(
        settings: SSHTransportSettings, request: WaycarPluginUpdateRequest,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> WaycarPluginUpdateResult {
        updateRequests.append(request)
        for line in updateProgress { progress(line) }
        guard let update else {
            throw TransportError.channelFailed(detail: "This Host cannot update Waycar.")
        }
        return try update.get()
    }

    private func open(
        settings: SSHTransportSettings,
        pingOverride: Result<ServerInfo, TransportError>?,
        eventsAnswer: Result<Void, TransportError>? = nil
    ) async throws -> any Transport {
        let pingResult = try await dial(settings: settings)
        let transport = FakeTransport(
            pingResult: pingOverride ?? pingResult, sessions: sessions,
            statusHooks: statusHooks, eventsAnswer: eventsAnswer)
        transports.append(transport)
        return transport
    }

    /// One scripted dial: the Jump Host's key, then the Host's, then the
    /// outcome. Returns the ping answer of a dial that connects.
    private func dial(settings: SSHTransportSettings) async throws -> Result<ServerInfo, TransportError> {
        capturedSettings.append(settings)
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        if case .unreachable(let error) = outcome { throw error }
        if let presentedJumpKeyBlob, let jump = settings.jump {
            do {
                try await evaluateHostKey(
                    HostKeyFingerprint(publicKeyBlob: presentedJumpKeyBlob),
                    host: jump.host, port: jump.port, policy: settings.hostKeyPolicy)
            } catch let error as TransportError {
                throw TransportError.jumpHostFailed(error)
            }
        }
        if let presentedKeyBlob {
            try await evaluateHostKey(
                HostKeyFingerprint(publicKeyBlob: presentedKeyBlob),
                host: settings.host, port: settings.port, policy: settings.hostKeyPolicy)
        }
        switch outcome {
        case .unreachable(let error), .connectFails(let error):
            throw error
        case .connects(let pingResult):
            return pingResult
        }
    }

    /// Mirrors `WaycarSSHHostKeyVerifier.verify` at the policy level.
    private func evaluateHostKey(
        _ fingerprint: HostKeyFingerprint, host: String, port: Int, policy: HostKeyPolicy
    ) async throws {
        if let known = await policy.knownHosts.fingerprint(host: host, port: port) {
            guard known == fingerprint else {
                throw TransportError.hostKeyMismatch(known: known, presented: fingerprint)
            }
            return
        }
        let candidate = HostKeyCandidate(host: host, port: port, fingerprint: fingerprint)
        guard await policy.confirmFirstConnect(candidate) else {
            throw TransportError.hostKeyRejected(presented: fingerprint)
        }
        await policy.knownHosts.setFingerprint(fingerprint, host: host, port: port)
    }
}
