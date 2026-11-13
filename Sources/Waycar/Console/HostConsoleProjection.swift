import Foundation
import Synchronization

/// One Host's Console projection. It owns snapshot-then-delta convergence,
/// subscription changes, retry, Agent Summary fetches, Host RPC follow-ups
/// and the EventsSession that supplies them. ConsoleStore only aggregates the
/// resulting rows and observable Host state.
@MainActor
final class HostConsoleProjection {
    let host: Host
    /// The backend this projection serves (ADR 0026); stamped on every row
    /// and workspace it lists. A Host running herdr and tmux has one
    /// projection for each.
    let backend: HostBackend
    let session: EventsSession

    private(set) var agentsByPane: [String: ConsoleAgent] = [:]
    private var serverLinkFacts = ServerSessionLinkFacts()
    /// What the server keeps archived, as of the last snapshot: Closed
    /// Sessions for an archiving server chat runtime (OpenCode).
    private(set) var archivedSessions: [ArchivedServerSession] = []
    private(set) var closedZellijSessions: [ZellijClosedSession] = []
    private var ultimateChildren: [String: [UltimateChildInfo]] = [:]
    private var ultimateQuestions: [String: Int] = [:]

    func addressableAgent(_ paneID: String) -> ConsoleAgent? {
        agentsByPane[paneID] ?? agentsByPane.values.lazy.compactMap { $0.ultimateChild(paneID) }.first
    }
    private(set) var workspaces: [ConsoleWorkspace] = []
    private(set) var status: EventsSessionStatus?
    /// The failure that last stopped automatic recovery, retained after the
    /// next activation begins and discarded when that activation resolves.
    /// See Standing Failure in `CONTEXT.md`.
    private(set) var standingFailure: TransportError?
    /// The last herdr `ping` round trip measured on the Host's *current*
    /// connection, mirrored from `EventsSession.currentLatency` so a
    /// measurement never outlives the connection that proved it.
    private(set) var latency: Duration?
    private(set) var syncError: String?
    /// The error behind `syncError`, for work that must fail with it rather
    /// than wait on a snapshot this connection cannot take.
    private(set) var syncFailure: (any Error)?
    private(set) var transportGeneration: UInt64 = 0
    private(set) var sidebarRevision: UInt64 = 0
    /// Whether the rows still await verification by a snapshot taken on the
    /// Host's *current* connection. Until then they are the last-known Agent
    /// Inventory — kept through a reconnect, or seeded from the on-device
    /// cache — and Agent-scoped RPCs wait for the live snapshot.
    /// `.connected` arrives before that request completes, so it alone
    /// never verifies anything.
    var isAwaitingSnapshot: Bool { snapshots.isAwaitingSnapshot }
    /// Whether any snapshot, cached or live, has populated the rows. Without
    /// one an empty projection means "unknown", not "no Agents".
    private(set) var hasInventory = false
    /// The snapshot behind the current rows: the seeded one until the first
    /// live snapshot lands, then the latest live one.
    private(set) var inventorySnapshot: SessionSnapshot?
    /// Bumped by every applied *live* snapshot, never by a seed.
    private(set) var liveSnapshotRevision: UInt64 = 0
    /// When a live snapshot last showed the rows: the latest one this
    /// projection applied, or for seeded rows the time their own live
    /// snapshot was taken (nil when unknown). A Closed Session capture
    /// carries it as the last time its Agent was seen running.
    private(set) var inventoryVerifiedAt: Date?
    /// Stable success surfaces keyed by every Agent that belonged to the
    /// exact validated worktree at dispatch.
    var removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] {
        worktreeRemovalReceiptsByAgent.mapValues(\.receipt)
    }

    /// Installed by ConsoleStore once per projection: whether the Host's
    /// mosh is the choice right now, its standbys, and what a mosh session
    /// proves (#105). Late-bound so the projection never reaches into the
    /// store; nil keeps every terminal on SSH.
    var moshAttach: MoshAttachCoordinator?

    /// Installed by ConsoleStore once per projection: receives the Agents a
    /// live snapshot no longer runs (CONTEXT.md **Closed Session**). Called
    /// only from `apply`: a disconnect keeps the last-known rows and a
    /// removed Host's projection just ends, and neither is an Agent closing.
    var onAgentsClosed: @MainActor ([ClosedAgentCapture]) -> Void = { _ in }

    private struct WorktreeRemovalReceiptRecord {
        let receipt: WorktreeRemovalReceipt
        let snapshotRequestGeneration: UInt64
    }

    private let snapshotRetryDelay: Duration
    /// When this Host refreshes its Agent Summaries.
    private let summaryRefreshTiming: AgentSummaryRefreshTiming
    /// How often this Host's Shell Activity is swept while on screen.
    private let shellActivityTiming: ShellActivityTiming
    private let onChange: @MainActor @Sendable () -> Void
    /// Stamps `inventoryVerifiedAt`.
    private let now: @MainActor () -> Date
    private var consumeTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var terminalTransportTask: Task<Void, Never>?
    /// The activation `start(isActive: true)` hands to the session.
    private var startTask: Task<Void, Never>?
    /// The rows' authority and the snapshot work behind it: one resync at a
    /// time with one follow-up, the retry, and the epoch.
    private var snapshots = SnapshotAuthorityMachine()
    /// The resync in flight, which `refreshSidebarMetadata` joins.
    private var resyncTask: Task<Void, Never>?
    private var resyncRetryTask: Task<Void, Never>?
    /// Invalidates snapshot work that crossed a disconnected state. A request
    /// already in flight may still return after its Host drops, but its rows
    /// must never replace the last-known ones or pass as verification.
    private var snapshotEpoch: UInt64 { snapshots.epoch }
    /// Request-start order, used only after a complete remove request line was
    /// written. A snapshot already in flight cannot resolve its outcome.
    private var snapshotRequestGeneration: UInt64 = 0
    private var workspacesByID: [String: WorkspaceInfo] = [:]
    private var worktreeRemovalOperations: [UUID: WorktreeRemovalMachine] = [:]
    private var worktreeRemovalReceiptsByAgent: [ConsoleAgent.ID: WorktreeRemovalReceiptRecord] =
        [:]
    private var paneChangeRevision: UInt64 = 0
    private var latestPaneChanges: [String: (revision: UInt64, pane: PaneInfo)] = [:]
    private var statusChangeRevision: UInt64 = 0
    private var latestStatusChanges: [
        String: (revision: UInt64, status: AgentStatus)
    ] = [:]
    /// The Host's latest Agent Summaries by pane, as last read.
    private var summariesByPane: [String: AgentSummary] = [:]
    private var summaryReads = AgentSummaryReadMachine()
    private var summaryReadTasks: [UInt64: Task<Void, Never>] = [:]
    /// The cadence joins the read currently owned by the machine.
    private var summaryReadTask: Task<Void, Never>? {
        summaryReads.readToken.flatMap { summaryReadTasks[$0] }
    }
    private var summariesUnavailable: Bool { summaryReads.isUnavailable }
    /// Whether the app is on screen and AI summaries are on (ConsoleStore).
    private var summaryRefreshGate = AgentSummaryRefreshGate()
    /// The refresh cadence: the wait, the one refresh in flight (trigger,
    /// settle, re-read), its follow-up, failures and a missing action.
    private var summaryRefresh = AgentSummaryRefreshMachine()
    /// The Agent Summary refresh in flight, by the machine's token.
    private var summaryRefreshTasks: [UInt64: Task<Void, Never>] = [:]
    /// The wait before the next refresh: the periodic interval (backed off
    /// after failures), or the debounce after a status change.
    private var summaryRefreshTimer: Task<Void, Never>?
    /// When the periodic clock last restarted: every finished refresh but a
    /// status-triggered one that ran before the periodic one was due.
    private var summaryRefreshFinishedAt: Date?
    /// Set when this connection's plugin (or herdr) has no refresh action:
    /// periodic refreshes stop until the next connection, and a status
    /// change only re-reads what the store already has.
    private var summaryRefreshUnsupported: Bool { summaryRefresh.isUnsupported }
    /// Panes a finished refresh covered, kept across reconnects: an Agent
    /// the plugin never summarizes (no model on the Host) must not wait for
    /// its first summary again after every reconnect. Any other Agent
    /// without a summary is still waiting for its first one.
    private var summaryRefreshedPanes: Set<String> = []
    /// Whether a store read on this connection found the plugin. Until one
    /// has, no row waits for a summary the Host may have no way to write.
    private var summaryStoreFound = false
    /// Whether a store record read on this connection declared `progress`
    /// (`AgentSummary.declaresProgress`): the plugin reports Agent Progress,
    /// so a Working row without an estimate waits for one. Sticky until the
    /// connection drops or AI summaries are turned off.
    private var summaryProgressReported = false
    /// Per terminal, the last `agent_session` herdr reported for the Agent
    /// running there, with that Agent's kind. herdr clears the session as
    /// the Agent leaves its Pane — sometimes a snapshot before the row goes
    /// — so a closed Agent's session comes from here.
    private var lastAgentSessions: [String: (kind: String, session: AgentSessionInfo)] = [:]
    private var hasEnded = false
    /// Mutations herdr confirmed, each with the snapshot request generation
    /// current when it was: laid over snapshots that may predate it until a
    /// later-requested one shows it (`ConsoleLocalEdit`).
    private var localEdits: [(edit: ConsoleLocalEdit, snapshotRequestGeneration: UInt64)] = []
    /// Each Shell pane's last-read Shell Activity, with the terminal it was
    /// read for: a pane id reused by another terminal never inherits it.
    /// Holds command lines, which may hold secrets: never logged.
    private var shellActivityByPane: [String: (terminalID: String, activity: ShellActivity)] = [:]
    /// The Shell Activity read in flight, and (herdr only) the wait before
    /// the next one.
    private var shellActivitySweepTask: Task<Void, Never>?
    private var shellActivityTimer: Task<Void, Never>?
    /// A live snapshot landed while a sweep was in flight: that sweep's
    /// answer may miss a Shell the snapshot listed.
    private var shellActivitySweepPending = false
    /// Whether a phone or iPad window is on screen (ConsoleStore). Shell
    /// Activity is swept only then, so it starts off: a CarPlay-only launch
    /// never sweeps.
    private var isForeground = false

    init(
        host: Host,
        session: EventsSession,
        backend: HostBackend = .herdr,
        snapshotRetryDelay: Duration,
        summaryRefreshTiming: AgentSummaryRefreshTiming = AgentSummaryRefreshTiming(),
        shellActivityTiming: ShellActivityTiming = ShellActivityTiming(),
        now: @escaping @MainActor () -> Date = Date.init,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.backend = backend
        self.session = session
        self.snapshotRetryDelay = snapshotRetryDelay
        self.summaryRefreshTiming = summaryRefreshTiming
        self.shellActivityTiming = shellActivityTiming
        self.now = now
        self.onChange = onChange
    }

    func start(isActive: Bool) {
        consumeTask = Task { [weak self] in
            guard let self else { return }
            for await update in session.updates {
                guard !Task.isCancelled else { return }
                self.handle(update)
            }
        }
        // The stream is only the wake-up: `latencyUpdates` and `updates` are
        // consumed by two tasks whose order against each other is undefined,
        // so the sample it carries could be one this Host's connection no
        // longer stands behind. `session.currentLatency` is the value ordered
        // against the status updates the other task folds.
        latencyTask = Task { [weak self] in
            guard let self else { return }
            for await _ in session.latencyUpdates {
                guard !Task.isCancelled else { return }
                self.latency = session.currentLatency
                self.publish()
            }
        }
        terminalTransportTask = Task { [weak self] in
            guard let self else { return }
            for await generation in session.terminalTransportGenerations {
                guard !Task.isCancelled else { return }
                // Transport installation is the terminal readiness edge. It
                // intentionally precedes events subscription and snapshot work.
                transportGeneration = max(transportGeneration, generation)
                publish()
            }
        }
        if isActive {
            startTask = Task { await resume() }
        }
    }

    /// Returns once the activation `start` began has reached the session.
    /// Until then `session.withTransport` still sees a suspended session
    /// and fails at once instead of waiting for the connection.
    func started() async {
        await startTask?.value
    }

    /// Activates the session, subscribing first with the Agent pane set of
    /// the rows on screen (#105): the last-known ones, cached or kept from
    /// the previous connection. When the Host still runs those panes, the
    /// resync after `.connected` finds that set in force and skips a second
    /// subscribe and snapshot; a pane that exited meanwhile only costs the
    /// session's `pane_not_found` fallback to the global set.
    ///
    /// `resume`, `revalidate` and `retry` do nothing once `end()` has run.
    /// `ConsoleStore` walks a captured array of projections across awaits,
    /// so one can end mid-walk (its Host disabled or removed); dialing it
    /// then would contact a Host the user just turned off.
    func resume() async {
        guard !hasEnded else { return }
        await session.resume(seeding: seedSubscriptions)
    }

    /// The subscription set the last-known rows ask for, the way `runResync`
    /// derives it from a live snapshot; nil without rows to derive it from.
    private var seedSubscriptions: [EventSubscription]? {
        guard let snapshot = inventorySnapshot else { return nil }
        return Self.subscriptions(
            paneIDs: agentPaneIDs, protocolVersion: snapshot.protocolVersion)
    }

    /// Only Agents report Agent Status; a shell becoming an Agent arrives
    /// through the global `pane.agent_detected` resync.
    private var agentPaneIDs: [String] {
        agentsByPane.values.lazy.filter { !$0.isShell }.map(\.agent.paneID)
    }

    /// Re-proves this Host on a foreground return, by whatever means its
    /// current state calls for.
    ///
    /// A session that was never told to suspend — the app froze before its
    /// teardown ran, or the trip out was short enough that the grace period
    /// absorbed it — comes back believing it is still connected. `resume()`
    /// is a no-op on such a session, so without this nothing asks it until
    /// the keepalive's next turn (#142). That case is a ping.
    ///
    /// A session already stopped on a non-retryable failure is restarted
    /// instead (#147). Its reconnect loop returned while the phase stayed
    /// `.active`, so `resume()` no-ops and no live channel remains to ping.
    /// The gap that leaves is the same one #142 covers for connected Hosts,
    /// and it is exactly that narrow: an absence longer than
    /// `AppActivityCoordinator.defaultGracePeriod` does run `suspend()` — the
    /// phase is still `.active`, so `deactivate()` proceeds — and the return's
    /// `resume()` then restarts the run loop on its own. What was left
    /// stranded is a return *inside* the grace period, or one where the
    /// process froze before its teardown could run. Inside that window a user
    /// who went and restarted herdr came back to the same failure until they
    /// found the Retry button.
    ///
    /// This is deliberately not a retry cadence. The classification that
    /// stopped the loop stands — retrying a stopped herdr on reconnect timing
    /// would be a hot loop against a server that is not there, and would bury
    /// the guidance the user needs. It is one attempt on an explicit user
    /// action, and coming back to the app is one. A Host that is still broken
    /// reports `.connecting` while that attempt runs, and the Standing
    /// Failure keeps every status-derived surface presenting the same
    /// guidance until the activation answers.
    func revalidate() async {
        guard !hasEnded else { return }
        if case .failed = status {
            beginNewActivation()
            await session.retry()
        } else {
            await session.revalidate()
        }
    }

    /// Quiesces the session; `locally` waits on nothing the network decides
    /// (`EventsSession.suspend(locally:)`).
    func suspend(locally: Bool = false) async {
        await session.suspend(locally: locally)
    }

    func retry() async {
        guard !hasEnded else { return }
        beginNewActivation()
        await session.retry()
    }

    /// Makes the new activation visible on this projection before the
    /// session hops into teardown, so an in-flight resync cannot observe
    /// `.connected` after `currentTransport` is already gone.
    ///
    /// The latency is dropped outright rather than re-read from the session:
    /// this decision is what ends the old connection, and the session has not
    /// yet been asked to publish the status that clears its own copy.
    private func beginNewActivation() {
        status = .connecting
        latency = nil
        invalidateSnapshot()
        publish()
    }

    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        sendSummaryRead(.end)
        sendSnapshot(.end)
        consumeTask?.cancel()
        latencyTask?.cancel()
        terminalTransportTask?.cancel()
        sendSummaryRefresh(.end)
        stopShellActivitySweeps()
        _ = clearShellActivities()
        consumeTask = nil
        latencyTask = nil
        terminalTransportTask = nil
        Task { await session.end() }
    }

    func terminalRunner() -> TerminalSessionRunner {
        let session = session
        let mosh = moshAttach
        let currentGeneration: @MainActor @Sendable () -> UInt64 = { [weak self] in
            self?.transportGeneration ?? 0
        }
        return { request, handler in
            // A standby started for this Agent ahead of time (#105) takes
            // the client straight to its server: no SSH dial, bootstrap or
            // verification first. One whose server does not answer in time
            // leaves the attach to the ordinary path.
            if let mosh, await Self.choosesMosh(request, mosh),
                let standby = await mosh.takeStandby(request.target)
            {
                let ran = try await Self.runMoshSession(
                    at: standby.bootstrap, isStandby: true, route: TerminalAttachRoute(standby.origin),
                    request: request, handler: handler,
                    generation: await currentGeneration(), mosh: mosh,
                    prepare: { terminal in
                        try await session.withTransport { try await $0.prepareMoshTerminal(terminal, request: request) }
                    })
                if ran { return }
            }
            try await session.withTerminalTransport(target: request.target) {
                transport, generation in
                // The run rides this connection from here on (#105): said
                // now, since a mosh bootstrap can outlast the connection's
                // own proving, and a run still bootstrapping on the
                // connection just published must not be replaced as stale.
                await handler.transportDidBecomeAcquired(generation)
                // mosh carries the Agent terminal over UDP when the Host's
                // mosh is known to work here; any bootstrap failure — absent
                // binary, unparseable banner — falls back below to the SSH
                // attach on the same acquired transport. Ordinary shell
                // terminals stay on SSH outright.
                if let mosh, await Self.choosesMosh(request, mosh) {
                    // A standby prepared meanwhile serves instead of a second
                    // server; one that does not answer gets a fresh bootstrap.
                    while true {
                        let bootstrap: MoshBootstrap
                        let isStandby: Bool
                        let route: TerminalAttachRoute
                        if let standby = await mosh.claimBootstrap(request.target) {
                            (bootstrap, isStandby) = (standby.bootstrap, true)
                            route = TerminalAttachRoute(standby.origin)
                        } else {
                            do {
                                bootstrap = try await transport.runMoshBootstrap(request)
                                await mosh.finishBootstrap(request.target)
                            } catch {
                                await mosh.finishBootstrap(request.target)
                                // The mosh session never came up, so the SSH
                                // path has not run yet on this connection:
                                // ride it.
                                await handler.attachRouteDidResolve(
                                    await Self.sshRoute(on: session, generation: generation))
                                await handler.transportDidBecomeReady(generation, flavor: .ssh)
                                let fallback = try await transport.attachTerminal(request)
                                #if DEBUG
                                await handler.attachChannelDidOpen()
                                #endif
                                try await handler.runEndingSession(fallback)
                                return
                            }
                            isStandby = false
                            route = .bootstrap
                        }
                        if try await Self.runMoshSession(
                            at: bootstrap, isStandby: isStandby, route: route, request: request,
                            handler: handler, generation: generation, mosh: mosh,
                            prepare: { try await transport.prepareMoshTerminal($0, request: request) })
                        {
                            return
                        }
                    }
                }
                await handler.attachRouteDidResolve(
                    await Self.sshRoute(on: session, generation: generation))
                await handler.transportDidBecomeReady(generation, flavor: .ssh)
                #if DEBUG
                await handler.attachRequestDidStart()
                #endif
                let terminal = try await transport.attachTerminal(request)
                #if DEBUG
                await handler.attachChannelDidOpen()
                #endif
                try await handler.runEndingSession(terminal)
            }
        }
    }

    private nonisolated static func choosesMosh(
        _ request: TerminalAttachRequest, _ mosh: MoshAttachCoordinator
    ) async -> Bool {
        MoshTransportChoice.select(
            availability: await mosh.isAvailable(), target: request.target) == .mosh
    }

    /// An SSH attach's route: the connection kept across the last
    /// suspension, or the Host's live one.
    private nonisolated static func sshRoute(
        on session: EventsSession, generation: UInt64
    ) async -> TerminalAttachRoute {
        await session.ridesKeptConnection(generation: generation) ? .kept : .live
    }

    /// Runs one mosh session at `bootstrap` through `handler`: true once it
    /// ran, false for a standby whose server never answered — the caller
    /// goes on another way. The session's first contact settles what mosh
    /// is known to do on the network it started on (#105): an answer proves
    /// it, and a freshly bootstrapped server's silence means UDP does not
    /// get through (a standby's may only have expired).
    private nonisolated static func runMoshSession(
        at bootstrap: MoshBootstrap, isStandby: Bool, route: TerminalAttachRoute,
        request: TerminalAttachRequest, handler: TerminalSessionHandler, generation: UInt64,
        mosh: MoshAttachCoordinator,
        prepare: @escaping @Sendable (TerminalAttachSession) async throws -> TerminalAttachSession
    ) async throws -> Bool {
        #if DEBUG
        await handler.attachRequestDidStart()
        #endif
        await handler.attachRouteDidResolve(route)
        await handler.transportDidBecomeReady(generation, flavor: .mosh)
        let network = await mosh.currentNetwork()
        // The client's first datagram releases the server's attach, which
        // takes the pane over: an attach left meanwhile (taking a standby
        // can wait on its preparation) must never send it.
        try Task.checkCancellation()
        let terminal = mosh.makeSession(
            // SwiftMosh's screen model supports at most 512 columns; keep the first
            // Zellij view oversized without truncating its withheld frames.
            bootstrap, mosh.backend == .zellij ? 512 : request.cols,
            mosh.backend == .zellij ? 200 : request.rows,
            isStandby
                ? MoshAttachCoordinator.standbyFirstContactTimeout
                : MoshAttachCoordinator.firstContactTimeout)
        if let link = terminal.link {
            Task {
                switch await link.firstContact() {
                case .answered: await mosh.record(.available, on: network)
                case .timedOut where !isStandby: await mosh.record(.unavailable, on: network)
                case .timedOut, .ended: break
                }
            }
            // A server heard again after a stall proves the link is back,
            // often well before the SSH side notices (#105): its Host
            // redials at once instead of waiting out a backoff. The wait
            // for first contact is no stall.
            Task {
                var heard = false
                var stalled = false
                for await connectivity in link.connectivity() {
                    switch connectivity {
                    case .stalled: stalled = heard
                    case .connected:
                        if stalled { await mosh.serverDidAnswerAfterStall() }
                        heard = true
                        stalled = false
                    }
                }
            }
        }
        do {
            let prepared: TerminalAttachSession
            do { prepared = mosh.backend == .zellij ? try await prepare(terminal) : terminal }
            catch { await terminal.end(); throw error }
            try await handler.runEndingSession(prepared)
            return true
        } catch {
            guard isStandby, await terminal.link?.firstContact() == .timedOut else { throw error }
            return false
        }
    }

    func refreshClosedZellijSessions() async throws {
        closedZellijSessions = try await session.withTransport {
            try await $0.closedZellijSessions(refreshAge: true)
        }
    }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        let identity = try await session.withTransport { transport in
            try await transport.createShellTerminal(request)
        }
        await refreshTerminalInventory()
        return identity
    }

    /// A successful create must stay successful even if discovery needs retry.
    func refreshTerminalInventory() async {
        await refreshSidebarMetadata()
    }

    func imageStager() -> ImageStager {
        let session = session
        return { image, reporter in
            try await session.withTransport { transport in
                try await transport.stageImage(image) { progress in
                    await reporter.report(progress)
                }
            }
        }
    }

    /// Ranged Host-file reads for the terminal usage strip (#325). Resolved
    /// through the live connection on every call, so a reconnect cannot leave
    /// the strip reading through a transport that is already gone.
    func sessionFileReader() -> SessionFileReader {
        let session = session
        return { range in
            try await session.withTransport { transport in
                try await transport.readFileSlice(range)
            }
        }
    }

    /// Whole-file reads for previewing a path tapped in the terminal,
    /// late-bound like `sessionFileReader()`.
    func previewFileReader() -> PreviewFileReader {
        let session = session
        return { path, maxBytes in
            try await session.withTransport { transport in
                try await transport.readPreviewFile(atPath: path, maxBytes: maxBytes)
            }
        }
    }

    /// Model window lookups for the terminal usage strip (#325), late-bound
    /// like `sessionFileReader()`.
    func modelContextWindowResolver() -> ModelContextWindowResolver {
        let session = session
        return { selector in
            try await session.withTransport { transport in
                try await transport.modelContextWindow(selector: selector)
            }
        }
    }

    /// Branch reads for the Agent Footer (#169), late-bound like
    /// `sessionFileReader()`.
    func gitBranchReader() -> GitBranchReader {
        let session = session
        return { cwd in
            try await session.withTransport { transport in
                try await transport.gitBranch(atPath: cwd)
            }
        }
    }

    func fileStager() -> FileStager {
        let session = session
        return { file, reporter in
            try await session.withTransport { transport in
                try await transport.stageFile(file) { progress in
                    await reporter.report(progress)
                }
            }
        }
    }

    /// Launch Prompt File services, resolved through the live connection on
    /// every call like `fileStager()`. A capability probe that cannot reach
    /// a transport reads as no file routes.
    func launchPromptHost() -> LaunchPromptHost {
        let session = session
        return LaunchPromptHost(
            capabilities: {
                let capabilities = try? await session.withTransport { transport in
                    await transport.launchPromptCapabilities()
                }
                return capabilities ?? .none
            },
            stage: { files in
                try await session.withTransport { transport in
                    try await transport.stageLaunchPromptFiles(files)
                }
            },
            homeDirectory: {
                try await session.withTransport { transport in
                    try await transport.remoteHomeDirectory()
                }
            })
    }

    /// `retriesLinkFailure` is `withTransport`'s `retryOnLinkFailure`, for
    /// this and every launch below: a Queued Launch's replay turns it off,
    /// since a start whose answer was lost may have launched. Live retries
    /// keep their identity and reconcile: each call after the first sends
    /// mayHaveStarted, even if the first answer never came back.
    @discardableResult
    func startAgent(
        _ request: AgentLaunchRequest, retriesLinkFailure: Bool = true
    ) async throws -> Agent {
        let mayHaveStarted = Mutex(request.mayHaveStarted)
        let agent = try await session.withTransport(retryOnLinkFailure: retriesLinkFailure) {
            transport in
            let request = request.with(mayHaveStarted: mayHaveStarted.withLock { value in
                defer { value = true }
                return value
            })
            return try await transport.startAgent(request)
        }
        scheduleResync()
        return agent
    }

    /// One `WorktreeLaunchAttempt` spans every try of this launch: it is made
    /// outside `withTransport`, so a link-failure replay continues in the
    /// worktree (or Agent) a lost try already made instead of making another.
    @discardableResult
    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec, retriesLinkFailure: Bool = true
    ) async throws -> Agent {
        let attempt = WorktreeLaunchAttempt()
        let mayHaveStarted = Mutex(request.mayHaveStarted)
        let agent = try await session.withTransport(retryOnLinkFailure: retriesLinkFailure) {
            transport in
            let request = request.with(mayHaveStarted: mayHaveStarted.withLock { value in
                defer { value = true }
                return value
            })
            return try await transport.startAgentInNewWorktree(
                request, worktree: worktree, attempt: attempt)
        }
        scheduleResync()
        return agent
    }

    @discardableResult
    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec,
        retriesLinkFailure: Bool = true
    ) async throws -> Agent {
        let mayHaveStarted = Mutex(request.mayHaveStarted)
        let agent = try await session.withTransport(retryOnLinkFailure: retriesLinkFailure) {
            transport in
            let request = request.with(mayHaveStarted: mayHaveStarted.withLock { value in
                defer { value = true }
                return value
            })
            return try await transport.startAgentInNewWorkspace(request, workspace: workspace)
        }
        scheduleResync()
        return agent
    }

    /// Starts tmux's `main` session on a Host that runs none, then refreshes
    /// so its shell row appears.
    func startMainSession() async throws {
        try await session.withTransport { transport in
            try await transport.startMainSession()
        }
        scheduleResync()
    }

    /// Plain-shell launches refresh the whole projection: no agent exists,
    /// so the new pane reaches the Console as a shell row projected from the
    /// snapshot's panes.
    @discardableResult
    func startShellTerminal(
        _ request: ShellLaunchRequest, retriesLinkFailure: Bool = true
    ) async throws -> ShellLaunchResult {
        let mayHaveStarted = Mutex(request.mayHaveStarted)
        let result = try await session.withTransport(retryOnLinkFailure: retriesLinkFailure) {
            transport in
            let request = request.with(mayHaveStarted: mayHaveStarted.withLock { value in
                defer { value = true }
                return value
            })
            return try await transport.startShellTerminal(request)
        }
        await refreshTerminalInventory()
        return result
    }

    /// One `WorktreeLaunchAttempt` spans every try, as in
    /// `startAgentInNewWorktree`.
    @discardableResult
    func startShellTerminalInNewWorktree(
        _ request: ShellLaunchRequest, worktree: WorktreeSpec, retriesLinkFailure: Bool = true
    ) async throws -> ShellLaunchResult {
        let attempt = WorktreeLaunchAttempt()
        let mayHaveStarted = Mutex(request.mayHaveStarted)
        let result = try await session.withTransport(retryOnLinkFailure: retriesLinkFailure) {
            transport in
            let request = request.with(mayHaveStarted: mayHaveStarted.withLock { value in
                defer { value = true }
                return value
            })
            return try await transport.startShellTerminalInNewWorktree(
                request, worktree: worktree, attempt: attempt)
        }
        await refreshTerminalInventory()
        return result
    }

    @discardableResult
    func startShellTerminalInNewWorkspace(
        _ request: ShellLaunchRequest, workspace: NewWorkspaceSpec,
        retriesLinkFailure: Bool = true
    ) async throws -> ShellLaunchResult {
        let mayHaveStarted = Mutex(request.mayHaveStarted)
        let result = try await session.withTransport(retryOnLinkFailure: retriesLinkFailure) {
            transport in
            let request = request.with(mayHaveStarted: mayHaveStarted.withLock { value in
                defer { value = true }
                return value
            })
            return try await transport.startShellTerminalInNewWorkspace(request, workspace: workspace)
        }
        await refreshTerminalInventory()
        return result
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        try await session.withTransport { transport in
            try await transport.availableAgentKinds()
        }
    }

    /// Closes a pane. Its row leaves as soon as herdr confirms (#105); the
    /// resync that follows settles everything the close changed. With
    /// `removesRowAtOnce` false the row waits for that resync instead: the
    /// caller's own close bookkeeping owns how it leaves.
    /// `closesWorktreeGroup` is `Transport.closePane`'s: true only for a
    /// Close the user asked for.
    func closePane(
        _ paneID: String, closesWorktreeGroup: Bool, removesRowAtOnce: Bool = true
    ) async throws {
        try await session.withTransport { transport in
            try await transport.closePane(
                PaneTarget(paneID: paneID), closesWorktreeGroup: closesWorktreeGroup)
        }
        if removesRowAtOnce { applyConfirmedEdit(.closePane(paneID: paneID)) }
        scheduleResync()
    }

    /// Closes a tab: its rows, and its workspace when it was the last tab,
    /// leave as soon as herdr confirms (#105), unless `removesRowsAtOnce` is
    /// false and they wait for the resync, as in `closePane`. One the Host
    /// no longer has counts as closed: a `tab.close` whose answer a dropped
    /// connection lost is asked again on the redialed connection and finds
    /// its own work done (`tab_not_found`, herdr's code and tmux's for a
    /// missing window).
    func closeTab(_ tabID: String, removesRowsAtOnce: Bool = true) async throws {
        do {
            try await session.withTransport { transport in
                try await transport.closeTab(TabTarget(tabID: tabID))
            }
        } catch let error as HerdrAPIError where error.code == "tab_not_found" {}
        if removesRowsAtOnce { applyConfirmedEdit(.closeTab(tabID: tabID)) }
        scheduleResync()
    }

    /// Moves a Pane into another Workspace (`pane.move`). The reply carries
    /// the moved Pane's new id (herdr re-keys it); confirmation events also
    /// trigger a resync, the post-RPC call just makes the move land without
    /// waiting on the event round trip.
    @discardableResult
    func movePane(_ paneID: String, toWorkspaceID: String) async throws -> PaneMoveResponse {
        let response = try await session.withTransport { transport in
            try await transport.movePane(
                PaneMoveParams(
                    destination: .newTab(
                        PaneMoveDestinationNewTab(workspaceID: toWorkspaceID)),
                    paneID: paneID))
        }
        scheduleResync()
        return response
    }

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        try await session.withTransport { transport in
            try await transport.listWorktrees(forWorkspaceID: workspaceID)
        }
    }

    /// One operation record per immutable request prevents repeated taps and
    /// concurrent removals from replacing one another. Exact identity is
    /// checked again inside the Transport's write boundary, after channel
    /// admission and immediately before the first request byte.
    func removeWorktree(
        _ request: WorktreeRemovalRequest
    ) async throws -> WorktreeRemovalReceipt {
        guard request.identity.hostID == host.id else {
            throw WorktreeRemovalError.staleIdentity
        }
        guard worktreeRemovalOperations[request.id] == nil else {
            throw WorktreeRemovalError.alreadyInProgress
        }
        guard !worktreeRemovalOperations.values.contains(where: {
            $0.request.identity == request.identity
        }) else {
            throw WorktreeRemovalError.alreadyInProgress
        }
        worktreeRemovalOperations[request.id] = WorktreeRemovalMachine(request: request)

        do {
            let response = try await session.withTransport { transport in
                try await transport.removeWorktree(
                    request,
                    authorize: { request in
                        try await self.authorizeWorktreeRemoval(request)
                    },
                    onDispatched: { request in
                        await self.worktreeRemovalWasDispatched(request)
                    })
            }
            guard response.workspaceID == request.identity.workspaceID else {
                try markWorktreeRemovalUnconfirmed(request)
                scheduleResync()
                throw WorktreeRemovalError.outcomeUnconfirmed
            }
            let receipt = try finishSuccessfulWorktreeRemoval(request)
            scheduleResync()
            publish()
            return receipt
        } catch let error as WorktreeRemovalError {
            if error != .outcomeUnconfirmed {
                try? sendWorktreeRemoval(request.id, .refused)
            }
            publish()
            throw error
        } catch {
            if Self.isDefiniteWorktreeRejection(error) {
                try? sendWorktreeRemoval(request.id, .refused)
                publish()
                throw error
            }
            guard worktreeRemovalOperations[request.id]?.isDispatched == true else {
                try? sendWorktreeRemoval(request.id, .refused)
                publish()
                throw error
            }
            try markWorktreeRemovalUnconfirmed(request)
            scheduleResync()
            publish()
            throw WorktreeRemovalError.outcomeUnconfirmed
        }
    }

    private func authorizeWorktreeRemoval(_ request: WorktreeRemovalRequest) throws {
        var affected: Set<ConsoleAgent.ID>?
        if worktreeRemovalOperations[request.id]?.requiresIdentityProof == true,
            !isAwaitingSnapshot,
            let workspace = workspacesByID[request.identity.workspaceID],
            let checkout = workspace.worktree.map(RepositoryCheckout.init),
            request.identity.matches(checkout)
        {
            // Only this connection's snapshot proves an exact linked
            // checkout. A transport retry after dispatch keeps its old proof.
            affected = Set(
                agentsByPane.values.lazy
                    .filter {
                        $0.agent.workspaceID == request.identity.workspaceID
                            && $0.repositoryCheckout.map(request.identity.matches) == true
                    }
                    .map(\.id))
        }
        try sendWorktreeRemoval(request.id, .authorize(request, affected: affected))
    }

    private func worktreeRemovalWasDispatched(_ request: WorktreeRemovalRequest) {
        try? sendWorktreeRemoval(
            request.id, .dispatched(request, snapshotGeneration: snapshotRequestGeneration))
    }

    private func markWorktreeRemovalUnconfirmed(
        _ request: WorktreeRemovalRequest
    ) throws {
        try sendWorktreeRemoval(request.id, .unconfirmed(request))
    }

    private func finishSuccessfulWorktreeRemoval(
        _ request: WorktreeRemovalRequest
    ) throws -> WorktreeRemovalReceipt {
        guard let receipt = try sendWorktreeRemoval(
            request.id, .succeeded(request, snapshotGeneration: snapshotRequestGeneration))
        else { throw WorktreeRemovalError.staleIdentity }
        return receipt
    }

    @discardableResult
    private func sendWorktreeRemoval(
        _ id: UUID, _ event: WorktreeRemovalMachine.Event
    ) throws -> WorktreeRemovalReceipt? {
        guard var operation = worktreeRemovalOperations[id] else {
            throw WorktreeRemovalError.staleIdentity
        }
        let effects = operation.handle(event)
        worktreeRemovalOperations[id] = operation
        var receipt: WorktreeRemovalReceipt?
        for effect in effects {
            switch effect {
            case .record(let removed, let generation):
                record(removed, atSnapshotRequestGeneration: generation)
                receipt = removed
            case .finish:
                worktreeRemovalOperations[id] = nil
            case .reject(let error):
                throw error
            }
        }
        return receipt
    }

    private func record(
        _ receipt: WorktreeRemovalReceipt,
        atSnapshotRequestGeneration generation: UInt64
    ) {
        let record = WorktreeRemovalReceiptRecord(
            receipt: receipt,
            snapshotRequestGeneration: generation)
        for agentID in receipt.affectedAgentIDs {
            worktreeRemovalReceiptsByAgent[agentID] = record
        }
    }

    private static func isDefiniteWorktreeRejection(_ error: any Error) -> Bool {
        switch error {
        case is HerdrAPIError:
            true
        case TransportError.apiRejected(_, _):
            true
        default:
            false
        }
    }

    /// Focus can mark sibling Panes seen too; only a full Host snapshot can
    /// supply the resulting authoritative statuses, including Live Activity.
    func focusAgent(_ paneID: String) async throws {
        try Task.checkCancellation()
        guard !hasEnded, status == .connected, !isAwaitingSnapshot else {
            throw TransportError.sshUnreachable(detail: "The Host is not ready.")
        }
        guard let agent = agentsByPane[paneID] else {
            throw TransportError.apiRejected(
                code: "agent_not_found", message: "The Agent is no longer listed.")
        }
        guard agent.agent.status == .done else { throw CancellationError() }
        let epoch = snapshotEpoch
        try await session.withTransport { transport in
            try Task.checkCancellation()
            try await transport.focusAgent(AgentTarget(target: paneID))
        }
        // Cancellation cannot undo a delivered focus. A successful reply still
        // refreshes this connection, even if its detail has since left.
        guard !hasEnded, snapshotEpoch == epoch else { return }
        scheduleResync()
    }

    /// Renames an Agent (#98); a nil name clears back to the detected kind.
    /// The new name shows as soon as herdr confirms (#105); the post-RPC
    /// resync then confirms it, not an event delta: `pane.updated` does not
    /// carry the agent name and fires on every terminal-title change
    /// (measured live: 34 events in 6s on a working host), so subscribing to
    /// it as a resync trigger would re-snapshot continuously. Renames made
    /// by other clients therefore surface only on the next resync.
    func renameAgent(_ paneID: String, name: String?) async throws {
        try await session.withTransport { transport in
            try await transport.renameAgent(AgentRenameParams(target: paneID, name: name))
        }
        applyConfirmedEdit(.renameAgent(paneID: paneID, name: name))
        scheduleResync()
    }

    /// Renames a workspace (#98), shown as soon as herdr confirms (#105).
    /// `workspace.renamed` is already a membership event, so renames from
    /// other clients converge too.
    func renameWorkspace(_ workspaceID: String, label: String) async throws {
        try await session.withTransport { transport in
            try await transport.renameWorkspace(
                WorkspaceRenameParams(label: label, workspaceID: workspaceID))
        }
        applyConfirmedEdit(.renameWorkspace(workspaceID: workspaceID, label: label))
        scheduleResync()
    }

    /// Renames a Shell's tab: its name is its tab label, and `agent.rename`
    /// refuses a pane with no Agent. Shown as soon as herdr confirms (#105);
    /// `tab.renamed` is a membership event already.
    func renameTab(_ tabID: String, label: String) async throws {
        try await session.withTransport { transport in
            try await transport.renameShellTab(tabID: tabID, label: label)
        }
        applyConfirmedEdit(.renameTab(tabID: tabID, label: label))
        scheduleResync()
    }

    private func handle(_ update: EventsSessionUpdate) {
        guard !hasEnded else { return }
        switch update {
        case .status(let status):
            self.status = status
            // A latency belongs to the connection that measured it, and the
            // session clears this before publishing any status that ends one.
            // Reading it here rather than tracking the latency stream's
            // payload is what makes the pairing exact: a status that ends a
            // connection can only ever be folded against nil, and the sample
            // a new connection proved before announcing itself is already
            // here when its `.connected` lands.
            latency = session.currentLatency
            switch status {
            case .failed(let failure):
                standingFailure = failure
            case .connected, .reconnecting:
                standingFailure = nil
            case .connecting, .suspended, .ended:
                break
            }
            if status == .connected {
                // Subscription acknowledgement precedes this signal, including
                // replacement subscriptions. Keep consuming events while the
                // snapshot runs: lifecycle signals request a follow-up, and
                // status revisions survive an older snapshot response.
                _ = updateSummaryRows()
                publish()
                scheduleResync()
            } else {
                invalidateSnapshot()
                _ = updateSummaryRows()
                publish()
            }
        case .event(let event):
            if event.kind == PaneEventKind.agentStatusChanged.kind {
                if applyStatusChange(event.data) != nil {
                    // Status deltas keep badges responsive; the authoritative
                    // snapshot also supplies recency, titles and plugin values.
                    // Unknown can additionally mean the Agent left its Pane.
                    scheduleResync()
                }
            } else if event.kind == GlobalEventKind.paneUpdated.kind {
                applyPaneChange(event.data)
            } else if Self.resyncEventKinds.contains(event.kind) {
                scheduleResync()
            }
        }
    }

    /// An explicit fields refresh converges Agent values as well as the
    /// separate sidebar file. It shares the event-driven coalescing owner.
    func refreshSidebarMetadata() async {
        scheduleResync()
        while let task = resyncTask {
            await task.value
        }
    }

    /// Runs one re-snapshot at a time; signals arriving mid-run coalesce into
    /// one follow-up run.
    private func scheduleResync() {
        sendSnapshot(.requested(connected: status == .connected))
    }

    /// Feeds the snapshot authority and performs its effects; `apply` and
    /// `reportFailure` are the resync's own to carry out, so they are
    /// returned.
    @discardableResult
    private func sendSnapshot(_ event: SnapshotAuthorityMachine.Event) -> [SnapshotAuthorityMachine.Effect] {
        let effects = snapshots.handle(event)
        for effect in effects {
            switch effect {
            case .run(let token):
                resyncTask = Task { [weak self] in
                    guard let self else { return }
                    await runResync()
                    sendSnapshot(.resyncEnded(token: token, connected: status == .connected))
                }
            case .release:
                resyncTask = nil
            case .cancelRun:
                resyncTask?.cancel()
                resyncTask = nil
            case .armRetry:
                resyncRetryTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(for: snapshotRetryDelay)
                    } catch {
                        return
                    }
                    sendSnapshot(.retryElapsed(connected: status == .connected))
                }
            case .cancelRetry:
                resyncRetryTask?.cancel()
                resyncRetryTask = nil
            case .releaseRetry:
                resyncRetryTask = nil
            case .apply, .reportFailure:
                break
            }
        }
        return effects
    }

    private func runResync() async {
        snapshotRequestGeneration &+= 1
        let requestGeneration = snapshotRequestGeneration
        let epochBeforeSnapshot = snapshotEpoch
        let statusRevisionBeforeSnapshot = statusChangeRevision
        let paneRevisionBeforeSnapshot = paneChangeRevision
        let request = NetworkInterval("snapshot")
        do {
            let (snapshot, children, questions, linkFacts, archived, zellijClosed) = try await session.withTransport { transport in
                let snapshot = try await transport.sessionSnapshot()
                let children = await transport.ultimateConversationChildren()
                let questions = await transport.ultimateOpenQuestions()
                let linkFacts = await transport.serverSessionLinkFacts()
                let archived = await transport.archivedServerSessions()
                let zellijClosed = try await transport.closedZellijSessions(refreshAge: false)
                return (snapshot, children, questions, linkFacts, archived, zellijClosed)
            }
            request.end("received")
            guard
                sendSnapshot(.landed(epoch: epochBeforeSnapshot, connected: status == .connected))
                    .contains(.apply)
            else { return }
            syncError = nil
            syncFailure = nil
            serverLinkFacts = linkFacts
            archivedSessions = archived
            closedZellijSessions = zellijClosed
            ultimateChildren = children
            ultimateQuestions = questions
            apply(
                snapshot,
                preservingStatusChangesAfter: statusRevisionBeforeSnapshot,
                preservingPaneChangesAfter: paneRevisionBeforeSnapshot,
                requestGeneration: requestGeneration)
            await session.updateSubscriptions(
                Self.subscriptions(
                    paneIDs: agentPaneIDs, protocolVersion: snapshot.protocolVersion))
            // One exec for every pane's summary, riding each live snapshot:
            // it picks up summaries written while this device looked away.
            refreshSummaries()
            sendSummaryRefresh(.schedule(canRefresh: canRefreshSummaries))
            // herdr polls on its own interval, so a resync (every Agent
            // Status change brings one) sweeps only when no sweep or wait is
            // under way. tmux answers from the cache this snapshot just
            // filled, so it sweeps once after each.
            requestShellActivitySweep()
        } catch {
            request.end(NetworkAnalytics.Failure(error).rawValue)
            guard
                sendSnapshot(.refused(epoch: epochBeforeSnapshot, connected: status == .connected))
                    .contains(.reportFailure)
            else { return }
            syncError = Self.snapshotErrorMessage(error)
            syncFailure = error
            publish()
            sendSnapshot(.retryRequested(connected: status == .connected))
        }
    }

    /// Ends the current snapshot's authority without discarding its rows:
    /// they stay on screen as the last-known inventory, and the next live
    /// snapshot replaces them wholesale. In-flight snapshot work is fenced
    /// off by the epoch, so a response from the dropped connection can never
    /// masquerade as verification.
    private func invalidateSnapshot() {
        sendSnapshot(.connectionChanged)
        syncError = nil
        syncFailure = nil
        latestStatusChanges.removeAll(keepingCapacity: true)
        latestPaneChanges.removeAll(keepingCapacity: true)
        // Any snapshot on the next connection is requested after them.
        localEdits.removeAll()
        // The next connection asks for the plugin and its refresh action
        // again: either may have been installed meanwhile.
        sendSummaryRead(.connectionChanged)
        summaryStoreFound = false
        summaryProgressReported = false
        sendSummaryRefresh(.connectionChanged)
        // Shell Activity is the current connection's alone: the rows read
        // as unknown until a sweep on the next one answers.
        stopShellActivitySweeps()
        _ = clearShellActivities()
    }

    /// Populates a projection that has never seen a snapshot with the Host's
    /// last-known one (the on-device cache, or the projection this one
    /// replaces), taken live at `verifiedAt` (nil when unknown). The rows
    /// stay unverified until a live snapshot lands.
    func seed(_ snapshot: SessionSnapshot, verifiedAt: Date?) {
        guard !hasInventory, !hasEnded else { return }
        replaceInventory(
            with: snapshot,
            preservingStatusChangesAfter: .max,
            preservingPaneChangesAfter: .max,
            carryingSessionsForward: false)
        inventoryVerifiedAt = verifiedAt
        publish()
    }

    private func apply(
        _ liveSnapshot: SessionSnapshot,
        preservingStatusChangesAfter snapshotStartRevision: UInt64,
        preservingPaneChangesAfter paneStartRevision: UInt64,
        requestGeneration: UInt64
    ) {
        let snapshot = layingLocalEdits(over: liveSnapshot, requestGeneration: requestGeneration)
        // The rows this snapshot replaces, even the last-known ones kept
        // through a reconnect: an Agent gone once the Host answers again
        // really did leave while the app was away. They were last seen
        // running when their own live snapshot was taken.
        let previousRows = agentsByPane
        let previousSessions = lastAgentSessions
        let previousVerifiedAt = inventoryVerifiedAt
        // Across a reconnect anything may have run on a terminal meanwhile.
        let followsGap = isAwaitingSnapshot
        replaceInventory(
            with: snapshot,
            preservingStatusChangesAfter: snapshotStartRevision,
            preservingPaneChangesAfter: paneStartRevision,
            carryingSessionsForward: !followsGap)
        sendSnapshot(.verified)
        inventoryVerifiedAt = now()
        liveSnapshotRevision &+= 1
        pruneReceiptsReintroducedByCurrentSnapshot(
            requestGeneration: requestGeneration)
        reconcileUnconfirmedWorktreeRemovals(requestGeneration: requestGeneration)
        let closed = closedAgents(
            since: previousRows, sessions: previousSessions,
            lastSeenRunningAt: previousVerifiedAt, followsGap: followsGap)
        if !closed.isEmpty { onAgentsClosed(closed) }
        publish()
    }

    /// The Agents among `previous` this inventory no longer runs. One closed
    /// when no Agent of its kind is left on the terminal it ran in — it
    /// exited back to its shell, its Pane or Tab closed, or another kind took
    /// the terminal over — or, in the first snapshot after a gap, when the
    /// Agent of its kind there now reports a session other than the one it
    /// had: it exited and the same kind started again in the Pane while the
    /// app was away. A `pane.move` (same terminal, new pane id) is no
    /// closure, nor is an Agent whose session is live again elsewhere on the
    /// Host (herdr's restore), nor herdr naming an Agent it listed before it
    /// knew which one it was (`Agent.unidentifiedKind`, a launch still
    /// pending): whatever Agent that terminal now runs is the launch itself.
    ///
    /// On a live connection a different session is no closure: herdr lets a
    /// running Agent switch sessions in place (claude's `/clear` and
    /// `/resume`, and the like), and a real exit shows first as the Agent
    /// leaving its terminal. Across a gap the two look alike, so a switch
    /// made while the app was away is recorded as a closure.
    ///
    /// herdr exposes no process identity, so a relaunch that has not
    /// reported a session yet — or whose kind never reports one — cannot be
    /// told from the Agent it replaced: it counts as that Agent until it
    /// leaves, or reports a different session in the snapshot after a gap.
    private func closedAgents(
        since previous: [String: ConsoleAgent],
        sessions: [String: (kind: String, session: AgentSessionInfo)],
        lastSeenRunningAt: Date?,
        followsGap: Bool
    ) -> [ClosedAgentCapture] {
        // Per terminal and kind, the sessions its Agents report; "" is none.
        var running: [String: Set<String>] = [:]
        var agentTerminals: Set<String> = []
        var liveSessions: Set<String> = []
        for row in agentsByPane.values where !row.isShell {
            agentTerminals.insert(row.agent.terminalID)
            running["\(row.agent.terminalID)\u{1F}\(row.agent.kind)", default: []]
                .insert(row.agent.agentSession?.value ?? "")
            if let session = lastAgentSessions[row.agent.terminalID]?.session {
                liveSessions.insert("\(row.agent.kind)\u{1F}\(session.value)")
            }
        }
        return previous.values.compactMap { row in
            guard !row.isShell else { return nil }
            if backend == .zellij, let pane = ZellijPaneID(row.agent.paneID),
                closedZellijSessions.contains(where: { $0.name == pane.session }) { return nil }
            if row.agent.kind == Agent.unidentifiedKind,
                agentTerminals.contains(row.agent.terminalID)
            {
                return nil
            }
            let remembered = sessions[row.agent.terminalID].flatMap {
                $0.kind == row.agent.kind ? $0.session : nil
            }
            let session = row.agent.agentSession.flatMap { $0.value.isEmpty ? nil : $0 }
                ?? remembered
            if let reported = running["\(row.agent.terminalID)\u{1F}\(row.agent.kind)"] {
                guard followsGap, let session,
                    !reported.contains(where: { $0.isEmpty || $0 == session.value })
                else { return nil }
            }
            if let session, liveSessions.contains("\(row.agent.kind)\u{1F}\(session.value)") {
                return nil
            }
            return ClosedAgentCapture(
                row: row, session: session, lastSeenRunningAt: lastSeenRunningAt)
        }
    }

    /// Remembers each running Agent's session: the one its row reports, else
    /// — with `carryingForward`, while the same kind still runs on the
    /// terminal — the one remembered for it. Nothing is carried across a
    /// reconnect: what runs on the terminal now may be a relaunch, and a
    /// record of it would resume the conversation it replaced.
    private func rememberAgentSessions(carryingForward: Bool) {
        var remembered: [String: (kind: String, session: AgentSessionInfo)] = [:]
        for row in agentsByPane.values where !row.isShell {
            let terminalID = row.agent.terminalID
            if let session = row.agent.agentSession, !session.value.isEmpty {
                remembered[terminalID] = (row.agent.kind, session)
            } else if carryingForward, let last = lastAgentSessions[terminalID],
                last.kind == row.agent.kind
            {
                remembered[terminalID] = last
            }
        }
        lastAgentSessions = remembered
    }

    private func replaceInventory(
        with snapshot: SessionSnapshot,
        preservingStatusChangesAfter snapshotStartRevision: UInt64,
        preservingPaneChangesAfter paneStartRevision: UInt64,
        carryingSessionsForward: Bool
    ) {
        sidebarRevision &+= 1
        hasInventory = true
        inventorySnapshot = snapshot
        let paneByID = Dictionary(snapshot.panes.map { ($0.paneID, $0) }) { first, _ in first }
        let workspaceByID = Dictionary(
            snapshot.workspaces.map { ($0.workspaceID, $0) }) { first, _ in first }
        let tabByID = Dictionary(
            snapshot.tabs.map { ($0.tabID, $0) }) { first, _ in first }
        var tabCounts: [String: Int] = [:]
        var tabPositions: [String: Int] = [:]
        for tab in snapshot.tabs where tabPositions[tab.tabID] == nil {
            tabCounts[tab.workspaceID, default: 0] += 1
            tabPositions[tab.tabID] = tabCounts[tab.workspaceID]
        }
        var nextAgents: [String: ConsoleAgent] = [:]
        for (snapshotOrder, info) in snapshot.agents.enumerated() {
            let agent = Agent(info)
            let workspace = workspaceByID[agent.workspaceID]
            let tab = tabByID[agent.tabID].flatMap {
                $0.workspaceID == agent.workspaceID ? $0 : nil
            }
            let summaries = summaryState(forPane: agent.paneID, isShell: agent.isShell)
            nextAgents[agent.paneID] = ConsoleAgent(
                hostID: host.id,
                hostName: host.displayName,
                agent: agent,
                workspaceLabel: workspace?.label,
                repositoryCheckout: workspace?.worktree.map(RepositoryCheckout.init),
                summary: summaries.summary,
                isSummaryPending: summaries.isPending,
                hostReportsProgress: summaries.reportsProgress,
                hostUsername: host.username,
                tabLabel: tab?.label,
                tabPosition: tab.flatMap { tabPositions[$0.tabID] },
                workspaceTabCount: max(workspace?.tabCount ?? 0, tabCounts[agent.workspaceID] ?? 0),
                snapshotOrder: snapshotOrder,
                paneLabel: paneByID[agent.paneID].flatMap {
                    $0.tabID == agent.tabID && $0.workspaceID == agent.workspaceID ? $0.label : nil
                },
                backend: backend)
            nextAgents[agent.paneID]?.paneCommandLine = serverLinkFacts.commandLines[agent.paneID]
            if let server = backend.serverChat {
                let sessionID = server.sessionID(paneID: agent.paneID)
                nextAgents[agent.paneID]?.serverSessionOrigin = serverLinkFacts.sessionOrigins[sessionID]
            }
            if backend == .ultimate {
                nextAgents[agent.paneID]?.isUltimateLeader = ultimateChildren[agent.paneID] != nil
                nextAgents[agent.paneID]?.ultimateChildren = ultimateChildren[agent.paneID] ?? []
                nextAgents[agent.paneID]?.ultimateOpenQuestions = ultimateQuestions[agent.paneID] ?? 0
            }
        }
        for (paneID, change) in latestStatusChanges
        where change.revision > snapshotStartRevision {
            guard var row = nextAgents[paneID] else { continue }
            row.agent.replaceStatus(change.status)
            nextAgents[paneID] = row
        }
        latestStatusChanges.removeAll(keepingCapacity: true)
        for (order, snapshotPane) in snapshot.panes.enumerated() {
            let pane: PaneInfo
            if let change = latestPaneChanges[snapshotPane.paneID],
                change.revision > paneStartRevision,
                change.pane.terminalID == snapshotPane.terminalID,
                change.pane.workspaceID == snapshotPane.workspaceID,
                change.pane.tabID == snapshotPane.tabID
            {
                pane = change.pane
            } else {
                pane = snapshotPane
            }
            let tab = tabByID[pane.tabID].flatMap {
                $0.workspaceID == pane.workspaceID ? $0 : nil
            }
            let workspace = workspaceByID[pane.workspaceID]
            let tabPosition = tab.flatMap { tabPositions[$0.tabID] }
            // A pane with no Agent is a plain shell tab: to herdr just another
            // tab, so it is just another row. An Agent appearing on it later
            // replaces this row under the same ID, and an Agent exiting back
            // to its shell becomes this row again.
            guard nextAgents[pane.paneID] == nil else { continue }
            nextAgents[pane.paneID] = ConsoleAgent(
                hostID: host.id,
                hostName: host.displayName,
                agent: Agent(
                    shellPane: pane,
                    name: Self.shellName(tabLabel: tab?.label, tabPosition: tabPosition)),
                workspaceLabel: workspace?.label,
                repositoryCheckout: workspace?.worktree.map(RepositoryCheckout.init),
                hostUsername: host.username,
                tabLabel: tab?.label,
                tabPosition: tabPosition,
                workspaceTabCount: max(workspace?.tabCount ?? 0, tabCounts[pane.workspaceID] ?? 0),
                snapshotOrder: snapshot.agents.count + order,
                paneLabel: pane.label,
                backend: backend,
                shellActivity: shellActivity(forPane: pane.paneID, terminalID: pane.terminalID))
        }
        agentsByPane = nextAgents
        // A pane that is no longer a Shell on the terminal its activity was
        // read for drops it.
        shellActivityByPane = shellActivityByPane.filter { paneID, entry in
            guard let row = agentsByPane[paneID] else { return false }
            return row.isShell && row.agent.terminalID == entry.terminalID
        }
        rememberAgentSessions(carryingForward: carryingSessionsForward)
        latestPaneChanges.removeAll(keepingCapacity: true)
        setWorkspaces(from: snapshot, byID: workspaceByID)
    }

    private func setWorkspaces(
        from snapshot: SessionSnapshot, byID: [String: WorkspaceInfo]? = nil
    ) {
        workspacesByID = byID ?? Dictionary(
            snapshot.workspaces.map { ($0.workspaceID, $0) }) { first, _ in first }
        workspaces = snapshot.workspaces
            .map {
                ConsoleWorkspace(
                    id: $0.workspaceID, label: $0.label,
                    checkout: $0.worktree.map(RepositoryCheckout.init),
                    backend: backend)
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    // MARK: Local edits (#105)

    /// Shows a mutation herdr just confirmed (`ConsoleLocalEdit`) instead of
    /// waiting for the resync that follows it. An Agent a close takes off
    /// the rows is captured as closed now, as that resync would have.
    private func applyConfirmedEdit(_ edit: ConsoleLocalEdit) {
        guard !hasEnded, let snapshot = inventorySnapshot else { return }
        localEdits.append((edit, snapshotRequestGeneration))
        let previousRows = agentsByPane
        let previousSessions = lastAgentSessions
        let patched = edit.applied(to: snapshot)
        inventorySnapshot = patched
        sidebarRevision &+= 1
        agentsByPane = edit.applied(to: agentsByPane)
        rememberAgentSessions(carryingForward: true)
        setWorkspaces(from: patched)
        let closed = closedAgents(
            since: previousRows, sessions: previousSessions,
            lastSeenRunningAt: inventoryVerifiedAt, followsGap: false)
        if !closed.isEmpty { onAgentsClosed(closed) }
        publish()
    }

    /// `snapshot` with every confirmed edit it may predate laid over it. A
    /// snapshot requested after an edit was confirmed is authoritative for
    /// it, and the edit is retired.
    private func layingLocalEdits(
        over snapshot: SessionSnapshot, requestGeneration: UInt64
    ) -> SessionSnapshot {
        localEdits.removeAll { $0.snapshotRequestGeneration < requestGeneration }
        return localEdits.reduce(snapshot) { $1.edit.applied(to: $0) }
    }

    /// A later snapshot is the source of truth for existence. If the exact
    /// removed identity appears again, it is a recreated/live worktree and
    /// must not inherit an older success surface.
    private func pruneReceiptsReintroducedByCurrentSnapshot(
        requestGeneration: UInt64
    ) {
        worktreeRemovalReceiptsByAgent = worktreeRemovalReceiptsByAgent.filter {
            agentID, record in
            guard requestGeneration > record.snapshotRequestGeneration else {
                return true
            }
            guard let agent = agentsByPane[agentID.paneID], agent.id == agentID else {
                return true
            }
            let identity = record.receipt.request.identity
            return agent.agent.workspaceID != identity.workspaceID
                || agent.repositoryCheckout.map(identity.matches) != true
        }
    }

    private func reconcileUnconfirmedWorktreeRemovals(requestGeneration: UInt64) {
        for (id, operation) in worktreeRemovalOperations {
            guard operation.canReconcileSnapshot(generation: requestGeneration) else { continue }
            let stillPresent = workspacesByID[operation.request.identity.workspaceID]
                .flatMap(\.worktree)
                .map(RepositoryCheckout.init)
                .map(operation.request.identity.matches) == true
            try? sendWorktreeRemoval(
                id, .snapshot(generation: requestGeneration, stillPresent: stillPresent))
        }
    }

    /// Title/cwd updates are frequent. Fold their complete PaneInfo locally
    /// rather than turning terminal output into a stream of snapshot RPCs.
    private func applyPaneChange(_ data: JSONValue) {
        guard status == .connected,
            let value = data["pane"],
            let encoded = try? JSONEncoder().encode(value),
            let pane = try? JSONDecoder().decode(PaneInfo.self, from: encoded)
        else { return }
        paneChangeRevision &+= 1
        if resyncTask != nil {
            latestPaneChanges[pane.paneID] = (paneChangeRevision, pane)
        }
        // A shell row's title and cwd are its pane's, so they follow the same
        // delta. Agent rows keep theirs from the snapshot's agent entry.
        guard var row = agentsByPane[pane.paneID], row.isShell,
            row.agent.terminalID == pane.terminalID,
            row.agent.workspaceID == pane.workspaceID,
            row.agent.tabID == pane.tabID
        else { return }
        row.agent = Agent(shellPane: pane, name: row.agent.name)
        guard row != agentsByPane[pane.paneID] else { return }
        agentsByPane[pane.paneID] = row
        publish()
    }

    private func applyStatusChange(_ data: JSONValue) -> AgentStatus? {
        guard
            let paneID = data["pane_id"]?.stringValue,
            let rawStatus = data["agent_status"]?.stringValue
        else { return nil }
        let status = AgentStatus(rawValue: rawStatus)
        statusChangeRevision &+= 1
        latestStatusChanges[paneID] = (statusChangeRevision, status)
        if agentsByPane[paneID]?.agent.status != status {
            sendSummaryRefresh(.statusChanged(canRefresh: canRefreshSummaries))
        }
        // A shell row has no Agent Status to fold. A status event on its pane
        // means an Agent started there; the resync it triggers replaces the
        // shell row with the Agent's.
        guard var row = agentsByPane[paneID], !row.isShell else { return status }
        row.agent.replaceStatus(status)
        agentsByPane[paneID] = row
        publish()
        return status
    }

    // MARK: Agent Summaries

    /// ConsoleStore's word on refreshing: whether the app is on screen and
    /// AI summaries are on. Off hides every summary line at once and stops
    /// asking the Host; on reads the store again.
    func setSummaryRefreshGate(_ gate: AgentSummaryRefreshGate) {
        guard !hasEnded, gate != summaryRefreshGate else { return }
        let wasEnabled = summaryRefreshGate.isEnabled
        summaryRefreshGate = gate
        if !gate.isEnabled || !gate.isForeground { sendSummaryRefresh(.paused) }
        if !gate.isEnabled { summaryProgressReported = false }
        if gate.isEnabled, !wasEnabled, status == .connected, !isAwaitingSnapshot {
            refreshSummaries()
        }
        if updateSummaryRows() { publish() }
        sendSummaryRefresh(.schedule(canRefresh: canRefreshSummaries))
    }

    /// Whether this Host may ask its plugin for fresh summaries now.
    private var canRefreshSummaries: Bool {
        !hasEnded && summaryRefreshGate.isForeground && summaryRefreshGate.isEnabled
            && !summariesUnavailable && status == .connected && !isAwaitingSnapshot
    }

    /// How long until the periodic refresh is due: an interval after the
    /// periodic clock last restarted, backed off by consecutive failures,
    /// and at once when none has run.
    private var periodicSummaryRefreshDelay: Duration {
        AIUsagePollSchedule.delayUntilDue(
            lastFinishedAt: summaryRefreshFinishedAt,
            interval: summaryRefreshTiming.interval,
            consecutiveFailures: summaryRefresh.failures,
            now: Date())
    }

    /// Feeds the refresh cadence and performs what it asks for.
    private func sendSummaryRefresh(_ event: AgentSummaryRefreshMachine.Event) {
        for effect in summaryRefresh.handle(event) {
            switch effect {
            case .arm(let wait):
                // The periodic wait is due on its schedule; a status change
                // waits out the debounce, so a burst of changes asks once.
                let delay = wait == .periodic ? periodicSummaryRefreshDelay : summaryRefreshTiming.debounce
                summaryRefreshTimer?.cancel()
                summaryRefreshTimer = Task { [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    self?.summaryRefreshWaitEnded(wait)
                }
            case .cancelWait:
                summaryRefreshTimer?.cancel()
                summaryRefreshTimer = nil
            case .startRefresh(let token, let triggers):
                startSummaryRefresh(token: token, triggers: triggers)
            case .cancelRefresh(let token):
                summaryRefreshTasks[token]?.cancel()
            case .reportPluginMissing:
                sendSummaryRead(.pluginMissing)
            case .restartClock:
                summaryRefreshFinishedAt = Date()
            case .cover:
                summaryRefreshedPanes.formUnion(agentsByPane.keys)
            case .updateRows:
                if updateSummaryRows() { publish() }
            case .proceed(let readsStore):
                sendSummaryRefresh(.proceed(
                    readsStore: readsStore, canRefresh: canRefreshSummaries,
                    periodicDue: periodicSummaryRefreshDelay == .zero))
            }
        }
    }

    private func summaryRefreshWaitEnded(_ wait: AgentSummaryRefreshMachine.Wait) {
        sendSummaryRefresh(.waitEnded(
            wait, canRefresh: canRefreshSummaries,
            periodicDue: periodicSummaryRefreshDelay == .zero))
    }

    /// Triggers the plugin's refresh action, waits for it to write, and
    /// re-reads the store. A plugin without the action only gets the
    /// re-read, which still picks up what its Done/Blocked push wrote.
    private func startSummaryRefresh(token: UInt64, triggers: Bool) {
        let settle = summaryRefreshTiming.settle
        summaryRefreshTasks[token] = Task { [weak self] in
            guard let self else { return }
            var outcome = AgentSummaryRefreshMachine.Outcome.refreshed
            if triggers {
                do {
                    try await session.withTransport { try await $0.refreshAgentSummaries() }
                } catch {
                    outcome = AgentSummaryRefreshMachine.Outcome(error)
                }
            }
            if outcome == .refreshed {
                try? await Task.sleep(for: settle)
            }
            if outcome.readsStore, !Task.isCancelled {
                refreshSummaries()
                while let read = summaryReadTask { await read.value }
            }
            summaryRefreshTasks[token] = nil
            sendSummaryRefresh(.finished(token: token, Task.isCancelled ? .cancelled : outcome))
        }
    }

    /// Reads every pane's summary in one Host exec. One read at a time;
    /// requests arriving meanwhile coalesce into one follow-up. Failures keep
    /// the summaries already shown — they are a nicety, never a sync error.
    private func refreshSummaries() {
        guard !hasEnded else { return }
        sendSummaryRead(.request(epoch: snapshotEpoch, enabled: summaryRefreshGate.isEnabled))
    }

    private func sendSummaryRead(_ event: AgentSummaryReadMachine.Event) {
        for effect in summaryReads.handle(event) {
            switch effect {
            case .read(let token):
                summaryReadTasks[token] = Task { [weak self] in
                    guard let self else { return }
                    let outcome: AgentSummaryReadMachine.Outcome
                    do {
                        outcome = .summaries(
                            try await session.withTransport { try await $0.readAgentSummaries() })
                    } catch NotificationRegistrationError.pluginNotInstalled {
                        outcome = .pluginMissing
                    } catch {
                        outcome = .failed
                    }
                    summaryReadTasks[token] = nil
                    sendSummaryRead(.finished(
                        token: token, currentEpoch: snapshotEpoch, outcome: outcome))
                }
            case .apply(let summaries):
                summariesByPane = summaries
                summaryStoreFound = true
                if summaries.values.contains(where: \.declaresProgress) { summaryProgressReported = true }
                if updateSummaryRows() { publish() }
            case .requestFollowUp:
                refreshSummaries()
            case .pluginMissing:
                sendSummaryRefresh(.pluginMissing)
                if updateSummaryRows() { publish() }
            case .cancel(let token):
                summaryReadTasks.removeValue(forKey: token)?.cancel()
            }
        }
    }

    /// Folds the summaries and the first-load state into the rows; true
    /// when any row changed.
    private func updateSummaryRows() -> Bool {
        var changed = false
        for (paneID, row) in agentsByPane {
            let state = summaryState(forPane: paneID, isShell: row.isShell)
            guard
                row.summary != state.summary || row.isSummaryPending != state.isPending
                    || row.hostReportsProgress != state.reportsProgress
            else { continue }
            var updated = row
            updated.summary = state.summary
            updated.isSummaryPending = state.isPending
            updated.hostReportsProgress = state.reportsProgress
            agentsByPane[paneID] = updated
            changed = true
        }
        return changed
    }

    /// A row's summary, whether it still waits for its first, and whether
    /// its Host reports Agent Progress: nothing for a shell or with AI
    /// summaries off; pending while the plugin has been found on this
    /// connection, a refresh can run, and none has covered the pane yet;
    /// reporting once a store record on this connection declared progress.
    private func summaryState(
        forPane paneID: String, isShell: Bool
    ) -> (summary: AgentSummary?, isPending: Bool, reportsProgress: Bool) {
        guard !isShell, summaryRefreshGate.isEnabled else { return (nil, false, false) }
        let reportsProgress = summaryProgressReported && !summariesUnavailable
        if let summary = summariesByPane[paneID] { return (summary, false, reportsProgress) }
        let awaitsRefresh =
            summaryStoreFound && canRefreshSummaries && !summaryRefreshUnsupported
            && !summaryRefreshedPanes.contains(paneID)
        return (nil, awaitsRefresh, reportsProgress)
    }

    // MARK: Shell Activity

    /// ConsoleStore's word on whether the app is on screen. Shell Activity
    /// is swept only then; leaving clears it, since nothing reads it until
    /// the next sweep on return.
    func setForeground(_ isForeground: Bool) {
        guard !hasEnded, isForeground != self.isForeground else { return }
        self.isForeground = isForeground
        if isForeground {
            requestShellActivitySweep()
        } else {
            stopShellActivitySweeps()
            if clearShellActivities() { publish() }
        }
    }

    /// Whether this Host may sweep its Shell Activity now.
    private var canSweepShellActivities: Bool {
        !hasEnded && isForeground && status == .connected && !isAwaitingSnapshot
    }

    /// Sweeps now unless one is under way. One in flight takes the request
    /// as its follow-up, and herdr's armed wait already covers it, so
    /// resyncs never sweep a herdr Host faster than its interval.
    private func requestShellActivitySweep() {
        guard canSweepShellActivities else { return }
        guard shellActivitySweepTask == nil else {
            shellActivitySweepPending = true
            return
        }
        guard shellActivityTimer == nil else { return }
        startShellActivitySweep()
    }

    /// Arms the next herdr sweep one interval after the last one ended.
    /// tmux never polls: its sweeps answer from the snapshot cache, and a
    /// call through the session counts as link activity, which would hold
    /// off the keepalive that finds a half-open link.
    private func scheduleShellActivitySweep() {
        guard backend == .herdr, shellActivityTimer == nil, shellActivitySweepTask == nil,
            canSweepShellActivities
        else { return }
        let interval = shellActivityTiming.interval
        shellActivityTimer = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard !Task.isCancelled, let self else { return }
            shellActivityTimer = nil
            startShellActivitySweep()
        }
    }

    /// Reads the Shell Activity of every Shell row, each with the terminal
    /// it shows at request time. A Host listing no Shell asks nothing; the
    /// next live snapshot asks again.
    private func startShellActivitySweep() {
        guard shellActivitySweepTask == nil, canSweepShellActivities else { return }
        let requested = agentsByPane.compactMapValues { $0.isShell ? $0.agent.terminalID : nil }
        guard !requested.isEmpty else { return }
        let paneIDs = requested.keys.sorted()
        let epoch = snapshotEpoch
        shellActivitySweepTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<[String: ShellActivity], any Error>
            do {
                // Never replayed: after a link failure the next sweep waits
                // for the recovered connection's snapshot.
                result = .success(
                    try await session.withTransport(retryOnLinkFailure: false) {
                        try await $0.shellActivities(paneIDs: paneIDs)
                    })
            } catch {
                result = .failure(error)
            }
            // Whoever cancelled it has already let go of it.
            guard !Task.isCancelled else { return }
            finishShellActivitySweep(result, requested: requested, epoch: epoch)
        }
    }

    private func finishShellActivitySweep(
        _ result: Result<[String: ShellActivity], any Error>,
        requested: [String: String], epoch: UInt64
    ) {
        shellActivitySweepTask = nil
        guard !hasEnded, status == .connected, snapshotEpoch == epoch else { return }
        switch result {
        case .success(let activities):
            for (paneID, terminalID) in requested {
                // A pane that left, became an Agent or now shows another
                // terminal is not the one this answer describes.
                guard let row = agentsByPane[paneID], row.isShell,
                    row.agent.terminalID == terminalID
                else { continue }
                shellActivityByPane[paneID] = activities[paneID].map {
                    (terminalID: terminalID, activity: $0)
                }
            }
            if updateShellActivityRows() { publish() }
        case .failure(let error):
            switch error {
            case is CancellationError, TransportError.cancelled:
                shellActivitySweepPending = false
                return
            case _ where EventsSession.isTransportLinkFailure(error):
                // The connection's recovery sweeps once its snapshot lands,
                // unless that snapshot landed meanwhile: a silent redial
                // keeps the epoch and status, so its request stands.
                guard shellActivitySweepPending else { return }
            default:
                // Anything else keeps what the rows show until the next
                // sweep answers.
                break
            }
        }
        let followsSnapshot = shellActivitySweepPending
        shellActivitySweepPending = false
        switch backend {
        case .herdr:
            // Polled on the interval: a Shell a snapshot listed meanwhile is
            // read by the next sweep, never by one back to back.
            scheduleShellActivitySweep()
        case .core, .ultimate, .codex, .opencode:
            // herdr-core reports no Shell Activity yet (design §7): its
            // transport's default answers none, so nothing to sweep.
            break
        case .tmux, .zellij:
            // Answered from the snapshot cache: only a snapshot that landed
            // meanwhile has anything new.
            if followsSnapshot { startShellActivitySweep() }
        }
    }

    private func stopShellActivitySweeps() {
        shellActivityTimer?.cancel()
        shellActivityTimer = nil
        shellActivitySweepTask?.cancel()
        shellActivitySweepTask = nil
        shellActivitySweepPending = false
    }

    /// Forgets every Shell Activity: the rows read as unknown. True when any
    /// row changed.
    private func clearShellActivities() -> Bool {
        shellActivityByPane.removeAll()
        return updateShellActivityRows()
    }

    /// Folds the read Shell Activity into the rows; true when any row
    /// changed. An Agent row never carries one.
    private func updateShellActivityRows() -> Bool {
        var changed = false
        for (paneID, row) in agentsByPane {
            let activity =
                row.isShell ? shellActivity(forPane: paneID, terminalID: row.agent.terminalID) : nil
            guard row.shellActivity != activity else { continue }
            var updated = row
            updated.shellActivity = activity
            agentsByPane[paneID] = updated
            changed = true
        }
        return changed
    }

    /// The Shell Activity last read for `paneID` while it showed
    /// `terminalID`; nil when unknown.
    private func shellActivity(forPane paneID: String, terminalID: String) -> ShellActivity? {
        guard let entry = shellActivityByPane[paneID], entry.terminalID == terminalID
        else { return nil }
        return entry.activity
    }

    private func publish() {
        guard !hasEnded else { return }
        onChange()
    }

    /// A shell row's name is its tab's label when the user (or a Default
    /// Shell launch) set one. herdr's automatic label is the tab's position,
    /// which names nothing, so that falls back to the `shell` kind.
    nonisolated static func shellName(tabLabel: String?, tabPosition: Int?) -> String? {
        guard
            let label = tabLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !label.isEmpty,
            label != tabPosition.map(String.init)
        else { return nil }
        return label
    }

    private static func snapshotErrorMessage(_ error: any Error) -> String {
        switch error {
        case TransportError.timedOut:
            "The Host did not answer while syncing Agents. Retrying…"
        case let apiError as HerdrAPIError:
            "herdr rejected the Console sync: \(apiError.message). Retrying…"
        default:
            "Could not sync this Host's Agents. Retrying…"
        }
    }

    private static let snapshotChangeKinds: [GlobalEventKind] = [
        .paneAgentDetected, .paneCreated, .paneClosed, .paneExited,
        .workspaceCreated, .workspaceRenamed, .workspaceMetadataUpdated, .workspaceClosed,
        .workspaceMoved, .workspaceReordered,
        .tabCreated, .tabClosed, .tabRenamed, .tabMoved, .paneMoved,
    ]

    private static let resyncEventKinds =
        Set(snapshotChangeKinds.map(\.kind)).union([HerdrEventKind.eventsDropped])

    static func subscriptions(
        paneIDs: some Sequence<String>, protocolVersion: Int? = nil
    ) -> [EventSubscription] {
        // The first subscription precedes session.snapshot. Only opt into
        // protocol-19 events after this connection reports support.
        snapshotChangeKinds.filter {
            $0 != .workspaceReordered || (protocolVersion ?? 0) >= 19
        }.map(EventSubscription.global)
            + [.global(.paneUpdated)]
            + paneIDs.sorted().map { EventSubscription.pane(.agentStatusChanged, paneID: $0) }
    }
}

private extension AgentLaunchRequest {
    func with(mayHaveStarted: Bool) -> Self {
        Self(
            kind: kind, name: name, arguments: arguments, workspaceID: workspaceID,
            cwd: cwd, environment: environment, launchID: launchID, mayHaveStarted: mayHaveStarted,
            codex: codex, joinsCodexServer: joinsCodexServer, opencode: opencode)
    }
}

private extension ShellLaunchRequest {
    func with(mayHaveStarted: Bool) -> Self {
        Self(
            name: name, workspaceID: workspaceID, cwd: cwd,
            launchID: launchID, mayHaveStarted: mayHaveStarted)
    }
}

/// When a Host refreshes its Agent Summaries while the app is on screen.
struct AgentSummaryRefreshTiming: Sendable {
    /// Between refreshes.
    var interval: Duration = .seconds(60)
    /// From the trigger to the store re-read. herdr returns as soon as the
    /// action spawns; the plugin then asks a model for each changed screen,
    /// a few at a time.
    var settle: Duration = .seconds(15)
    /// A burst of status changes asks once.
    var debounce: Duration = .seconds(3)
}

/// When a Host sweeps its Shell Activity while the app is on screen.
struct ShellActivityTiming: Sendable {
    /// From the end of one sweep to the start of the next.
    var interval: Duration = .seconds(3)
}

/// What the whole app says about refreshing Agent Summaries: only while it
/// is in the foreground, and only with AI summaries on.
struct AgentSummaryRefreshGate: Equatable, Sendable {
    var isForeground = true
    var isEnabled = true
}
