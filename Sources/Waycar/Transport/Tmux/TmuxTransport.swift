import Foundation
import WaycarSSH

/// tmux's Transport (ADR 0026, design §4.3): one `tmux -u -C attach` control
/// client on the Host's shared SSH connection, anchored on an existing
/// session, plus one-shot `tmux` execs while the server has no session to
/// anchor on ("idle"). Every id it hands out carries the `tmux:` prefix
/// (`TmuxID`); tmux commands take the raw id.
///
/// The control channel's events feed the one `HerdrEventStream`: format
/// subscriptions (`wc-topo`, `wc-status`) and topology notifications become
/// the herdr event kinds HostConsoleProjection already consumes. A channel
/// that exits while the server still lists sessions is replaced in place
/// (below tmux 3.6 the anchor's death detaches the client), and idempotent
/// lines it left unanswered go out again on the replacement
/// (``runLine(_:recheckIdle:)``); one that is lost ends the event stream so
/// EventsSession reconnects.
actor TmuxTransport: HostToolsTransport {
    /// Timing the transport runs on, and one tmux-behavior seam; tests
    /// change them.
    struct Configuration: Sendable {
        var requestTimeout: Duration
        /// How often an idle transport with an open event stream asks
        /// `tmux ls` whether sessions appeared; only on a tmux-only Host.
        var idlePollInterval: Duration = .seconds(15)
        /// The Host's backends. While idle, a tmux-only Host polls `tmux ls`
        /// and its keepalive pings re-check; a dual Host re-checks only on
        /// activation and foreground returns (`subscribeToEvents`,
        /// `revalidate()`), so herdr Hosts whose OS merely ships tmux pay
        /// nothing (design §4.3).
        var hostRole: HostRole = .tmuxOnly
        /// Identical resyncs inside this window go out once, at its end.
        var resyncDebounce: Duration = .milliseconds(250)
        /// A launched Agent without a gate of its own (claude's, or an input
        /// marker's) is promptable this long after its kind is first
        /// detected, and no sooner than its kind's
        /// `AgentScreen.InputReadiness.minimumDelay` after launch (design
        /// §4.3 Launch).
        var launchReadyDelay: Duration = .milliseconds(1500)
        /// A launched claude is promptable once its `SessionStart` hook set
        /// `@waycar_session`, or this long after launch on a Host without
        /// Status Hooks, whichever comes first.
        var claudeLaunchReadyTimeout: Duration = .seconds(8)
        /// A launched kind with an input marker (opencode, kilo, cline:
        /// `AgentScreen.InputMarker`) is promptable once the marker is on
        /// the screen or its pane has an `@waycar_status`, or this long after
        /// launch, whichever comes first. opencode took 6–24 s to take input
        /// on Linux test Hosts.
        var inputReadyTimeout: Duration = .seconds(30)
        /// Screen reads for Status Hooks' blind spots (design §4.6).
        var screenWatch = TmuxScreenVerdictMachine.Timing()
        /// Whether the control client asks for `no-detach-on-destroy`. Off
        /// only in tests, so tmux 3.6+ detaches the client with `%exit` when
        /// its anchor dies, as every tmux below 3.6 does.
        var requestsNoDetachOnDestroy = true

        init(requestTimeout: Duration) {
            self.requestTimeout = requestTimeout
        }
    }

    /// Whether a herdr runtime shares the Host (design §4.1): the TUI, or
    /// herdr-core while this build resolves Hosts to it. Either way tmux's
    /// empty session list is not the Host's whole story.
    enum HostRole: Sendable, Equatable {
        case tmuxOnly
        case dual

        init(_ presence: HostBackendPresence) {
            let slot = presence.herdrSlot
            self = slot == nil ? .tmuxOnly : .dual
        }
    }

    struct ListedSession: Sendable, Equatable {
        let id: String
        let destroyUnattached: Bool
        let name: String
    }

    /// The `tmux ls -F` format: free text (the name) last.
    static let sessionListFormat = "#{session_id} #{destroy-unattached} #{session_name}"

    let session: any HostSSHServices
    let configuration: Configuration
    /// `tmux -V`'s version, replaced by the server's own once control mode
    /// answers `#{version}`.
    var version: String
    /// The server's `#{start_time}.#{pid}`, read on the startup line of each
    /// control connection; part of every terminal id
    /// (``TmuxInventory/terminalID(pane:server:)``). Empty until a server
    /// answered it.
    var serverIdentity = ""
    /// Where commands go, the dial, and how the transport ends.
    var link = TmuxLinkMachine()
    /// The last client a dial kept, by its generation; the link while
    /// `link` names that generation (``controlChannel``).
    var keptClient: (generation: UInt64, channel: TmuxControlChannel)?
    /// The dial callers join while `link` dials.
    var connecting: Task<TmuxControlChannel?, any Error>?
    var pump: Task<Void, Never>?
    /// Whether the server applied `no-detach-on-destroy` (tmux 3.6+).
    var noDetachOnDestroy = false
    /// The last value per subscription name, the baseline for diffs.
    var subscriptionBaseline = TmuxSubscriptionBaselineMachine()
    var eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
    var eventStreamID: UInt64 = 0
    var subscribing = false
    var idlePoll: Task<Void, Never>?
    var pendingResyncs: [HerdrEventKind: Task<Void, Never>] = [:]
    /// Screen reads while the event stream is open, and their state.
    var screenPoll: Task<Void, Never>?
    var screenWatch = TmuxScreenVerdictMachine()
    /// The last inventory, for attach targets, Agent construction, session
    /// names and launch gates.
    var records = TmuxRecords()
    var lastSnapshot: SessionSnapshot?
    /// Which inventory refresh is in force (``sessionSnapshot()``): an older
    /// one never publishes over a newer.
    var inventoryPublication = TmuxInventoryPublicationMachine()
    /// Foreground kinds resolved over `ps`, per raw pane id.
    var foregroundCache: [String: TmuxForegroundKind] = [:]
    /// Shell Activity of the last snapshot's shown Shell panes, per app pane
    /// id. Holds command lines: never logged.
    var lastShellActivities: [String: ShellActivity] = [:]
    /// Agents this transport launched that may not take a prompt yet, per
    /// raw pane id.
    var launchGates = TmuxLaunchGateMachine()
    /// Who holds each pane's prompt turn and who waits for it, per raw pane
    /// id (``promptAgent(_:)``).
    var promptTurns = TmuxPromptTurnMachine()
    /// The prompts waiting for their pane's turn, by the id they asked with.
    var promptTurnWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    /// Whether this transport made attach sessions (`waycar-*`), so
    /// `close()` sweeps the orphaned ones.
    var madeAttachSessions = false
    let hostTools: HostToolsService
    let codexNoDaemon = SharedAsyncOperation<Bool>(cachesSuccess: true)

    /// Whether `close()` ran, or a failed `open` abandoned the transport.
    var closed: Bool { link.isClosed }

    /// The client that is the link; nil while idle or lost.
    var controlChannel: TmuxControlChannel? {
        guard let generation = link.controlGeneration, let kept = keptClient,
            kept.generation == generation
        else { return nil }
        return kept.channel
    }

    private init(session: any HostSSHServices, version: String, configuration: Configuration) {
        self.session = session
        hostTools = HostToolsService(session: session)
        self.version = version
        self.configuration = configuration
    }

    deinit {
        // A Transport dropped without `close()` still returns its hold on the
        // shared connection and its control channel.
        guard !link.isClosed else { return }
        let session = session
        if let generation = link.controlGeneration, let kept = keptClient,
            kept.generation == generation
        {
            let channel = kept.channel
            Task { await channel.close() }
        }
        Task { await session.release() }
    }

    // MARK: Opening

    /// tmux's Transport on `session`, taking over one hold the caller has on
    /// it: `close()` releases that hold. When this throws the hold stays the
    /// caller's. `presence` is the Host's backend detection, run on `session`
    /// just now: its `tmux -V` stands in for the version probe, and its herdr
    /// line decides the Host's role.
    static func open(
        session: any HostSSHServices, settings: SSHTransportSettings,
        presence: HostBackendPresence
    ) async throws -> TmuxTransport {
        guard let version = presence.tmuxVersion else { throw TransportError.tmuxNotInstalled }
        guard HostBackendPresence.meetsTmuxFloor(version) else {
            throw TransportError.tmuxTooOld(found: version)
        }
        var configuration = Configuration(requestTimeout: settings.requestTimeout)
        configuration.hostRole = HostRole(presence)
        return try await open(session: session, version: version, configuration: configuration)
    }

    /// ``open(session:settings:presence:)`` with its own `tmux -V` probe and
    /// the role `configuration` names.
    static func open(
        session: any HostSSHServices, configuration: Configuration
    ) async throws -> TmuxTransport {
        let version = try await probeVersion(session: session)
        return try await open(session: session, version: version, configuration: configuration)
    }

    private static func open(
        session: any HostSSHServices, version: String, configuration: Configuration
    ) async throws -> TmuxTransport {
        let transport = TmuxTransport(
            session: session, version: version, configuration: configuration)
        do {
            try await transport.connect()
        } catch {
            await transport.abandon()
            throw error
        }
        return transport
    }

    /// `tmux -V`, gated on the 3.2 floor.
    static func probeVersion(session: any HostSSHServices) async throws -> String {
        let result = try await session.runExec(
            shellCommand("exec tmux -V", cLocale: true), input: Data(), timeout: nil)
        let output = text(result.stdout)
        let failure = text(result.stderr) + "\n" + output
        if result.exitStatus == 127 { throw TransportError.tmuxNotInstalled }
        if TmuxErrors.transportError(failure) == .tmuxNotInstalled {
            throw TransportError.tmuxNotInstalled
        }
        guard result.exitStatus == 0, let version = parseVersion(output) else {
            throw TransportError.channelFailed(
                detail: "tmux -V printed: \(preview(failure))")
        }
        guard HostBackendPresence.meetsTmuxFloor(version) else {
            throw TransportError.tmuxTooOld(found: version)
        }
        return version
    }

    /// The version in `tmux 3.7c` (the last such line, after any login-shell
    /// chatter).
    static func parseVersion(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("tmux ") else { continue }
            let version = trimmed.dropFirst("tmux ".count)
                .trimmingCharacters(in: .whitespaces)
            if !version.isEmpty { return version }
        }
        return nil
    }

    /// An `open` that failed: the caller keeps its hold on the session.
    private func abandon() async {
        await performLink(link.handle(.close))
    }

    // MARK: Control channel

    /// The control client's exec: `-u` for UTF-8 whatever the exec's locale,
    /// `no-output` (no `%output` flood) and, unless a test turns it off,
    /// `no-detach-on-destroy` (3.6+), always with `-t`, since a bare attach
    /// picks the newest session.
    static func controlCommand(anchor: String, noDetachOnDestroy: Bool = true) throws -> String {
        let flags = noDetachOnDestroy ? "no-output,no-detach-on-destroy" : "no-output"
        return try shellCommand(
            "exec env -u TMUX tmux -u -C attach -f \(flags) -t \"$1\"",
            arguments: [anchor])
    }

    /// `#{version}␟#{client_flags}␟#{start_time}␟#{pid}`: the last two are
    /// the server's (``serverIdentity(startTime:pid:)``), answered alike by
    /// 3.2a through 3.7c.
    static var versionFlagsCommand: String {
        TmuxCommand.display(
            format: TmuxInventory.fields(["version", "client_flags", "start_time", "pid"]))
    }

    /// `<start_time>.<pid>`: a restarted server differs in both, so pane
    /// ids it hands out again get new terminal ids. Empty when either is
    /// missing or not a number.
    static func serverIdentity(startTime: String, pid: String) -> String {
        let parts = [startTime, pid].map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return "" }
        return parts.joined(separator: ".")
    }

    /// The anchor: the lowest-id session that is neither one of Waycar's
    /// attach sessions nor `destroy-unattached`, which the control client
    /// would keep alive.
    static func anchor(in sessions: [ListedSession]) -> ListedSession? {
        sessions
            .filter { !$0.name.hasPrefix(TmuxAttachCommand.attachSessionPrefix) && !$0.destroyUnattached }
            .min { (TmuxID.number($0.id) ?? .max) < (TmuxID.number($1.id) ?? .max) }
    }

    /// `tmux ls` over exec; empty when no server runs.
    func listServerSessions() async throws -> [ListedSession] {
        let result = try await session.runExec(
            Self.shellCommand(
                "exec env -u TMUX tmux ls -F \"$1\"", arguments: [Self.sessionListFormat],
                cLocale: true),
            input: Data(), timeout: nil)
        let output = Self.text(result.stdout)
        guard result.exitStatus == 0 else {
            let failure = Self.text(result.stderr) + "\n" + output
            if result.exitStatus == 127 { throw TransportError.tmuxNotInstalled }
            if failure.contains("no server running") || failure.contains("error connecting to") {
                return []
            }
            throw TmuxErrors.error(failure)
        }
        return Self.parseSessionList(output)
    }

    static func parseSessionList(_ output: String) -> [ListedSession] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == 3, fields[0].first == "$", TmuxID.number(fields[0]) != nil
            else { return nil }
            let option = fields[1]
            return ListedSession(
                id: fields[0],
                destroyUnattached: !(option.isEmpty || option == "off" || option == "0"),
                name: fields[2])
        }
    }

    /// Connects the control client when the server has a session to anchor
    /// on; nil (idle) otherwise. Single-flight.
    @discardableResult
    func connect() async throws -> TmuxControlChannel? {
        for effect in link.handle(.connect) {
            switch effect {
            case .join:
                if let connecting { return try await connecting.value }
            case .dial:
                let task = Task { try await self.establish() }
                connecting = task
                defer {
                    connecting = nil
                    _ = link.handle(.dialEnded)
                }
                return try await task.value
            case .refuse, .closeClient, .listSessions, .enterIdle, .openClient, .recordServer,
                .keep, .discard, .finishEvents, .reattach, .endControl:
                break
            }
        }
        return nil
    }

    /// One dial (``TmuxLinkMachine``): the server's sessions, then a client
    /// on the anchor, kept once its startup line is answered; nil when no
    /// session can anchor one.
    private func establish() async throws -> TmuxControlChannel? {
        var attempt: UInt64 = 0
        for effect in link.handle(.dialStarted) {
            switch effect {
            case .refuse(let error):
                throw error
            case .closeClient(let generation):
                await closeClient(generation)
            case .listSessions(let generation):
                attempt = generation
            case .dial, .join, .enterIdle, .openClient, .recordServer, .keep, .discard,
                .finishEvents, .reattach, .endControl:
                break
            }
        }
        let sessions = try await listServerSessions()
        let anchored = Self.anchor(in: sessions)
        for effect in link.handle(.sessionsListed(generation: attempt, anchored: anchored != nil)) {
            switch effect {
            case .refuse(let error):
                throw error
            case .enterIdle:
                enterIdle()
                return nil
            case .openClient:
                break
            case .dial, .join, .closeClient, .listSessions, .recordServer, .keep, .discard,
                .finishEvents, .reattach, .endControl:
                break
            }
        }
        guard let anchor = anchored else { return nil }
        let command = try Self.controlCommand(
            anchor: anchor.id, noDetachOnDestroy: configuration.requestsNoDetachOnDestroy)
        let session = self.session
        let channel = TmuxControlChannel(requestTimeout: configuration.requestTimeout) {
            try await session.openControlChannel(command: command)
        }
        let answer: StartupAnswer
        do {
            try await channel.start()
            let replies = try await channel.send([
                Self.versionFlagsCommand,
                TmuxEvents.topologySubscribeCommand,
                TmuxEvents.statusSubscribeCommand,
            ])
            answer = try Self.startupAnswer(replies)
            guard HostBackendPresence.meetsTmuxFloor(answer.version) else {
                throw TransportError.tmuxTooOld(found: answer.version)
            }
        } catch {
            await channel.close()
            throw error
        }
        for effect in link.handle(.startupAnswered(generation: attempt)) {
            switch effect {
            case .refuse(let error):
                await channel.close()
                throw error
            case .recordServer:
                version = answer.version
                serverIdentity = answer.serverIdentity
                noDetachOnDestroy = answer.flags.split(separator: ",")
                    .contains("no-detach-on-destroy")
            case .discard:
                await channel.close()
                throw TransportError.channelFailed(detail: "the tmux control channel was replaced")
            case .keep(let generation):
                keptClient = (generation: generation, channel: channel)
                _ = subscriptionBaseline.handle(.reset)
                stopIdlePoll()
                startPump(channel, generation: generation)
                // A new channel may have missed changes: the projection
                // re-snapshots.
                emitResync(TmuxEvents.resyncKind)
            case .dial, .join, .closeClient, .listSessions, .enterIdle, .openClient,
                .finishEvents, .reattach, .endControl:
                break
            }
        }
        return channel
    }

    /// Closes the client kept under `generation`, if it is the one kept.
    private func closeClient(_ generation: UInt64) async {
        guard let kept = keptClient, kept.generation == generation else { return }
        keptClient = nil
        await kept.channel.close()
    }

    struct StartupAnswer: Equatable {
        let version: String
        let flags: String
        /// ``serverIdentity(startTime:pid:)``; empty when not answered.
        let serverIdentity: String
    }

    /// The startup line's answer: ``versionFlagsCommand`` and two
    /// acknowledged subscriptions.
    static func startupAnswer(_ replies: [TmuxReply]) throws -> StartupAnswer {
        if let failed = replies.first(where: \.isError) { throw TmuxErrors.apiError(reply: failed) }
        guard replies.count == 3, let line = replies[0].lines.first(where: { !$0.isEmpty }) else {
            throw TransportError.malformedResponse("tmux startup answered \(replies.count) blocks")
        }
        let fields = TmuxInventory.split(line, at: TmuxInventory.fieldSeparator)
        let version = fields[0].trimmingCharacters(in: .whitespaces)
        guard !version.isEmpty else {
            throw TransportError.malformedResponse("tmux reported no version")
        }
        return StartupAnswer(
            version: version, flags: fields.count > 1 ? fields[1] : "",
            serverIdentity: fields.count > 3
                ? serverIdentity(startTime: fields[2], pid: fields[3]) : "")
    }

    /// The server has no session to anchor on: its panes (and their screen
    /// verdicts) are gone, and a tmux-only Host starts polling.
    private func enterIdle() {
        _ = subscriptionBaseline.handle(.reset)
        _ = screenWatch.handle(.forget)
        if eventContinuation != nil { startIdlePoll() }
    }

    private func startPump(_ channel: TmuxControlChannel, generation: UInt64) {
        pump = Task { [weak self] in
            for await event in channel.events {
                guard let self else { return }
                await self.handle(event, generation: generation)
            }
        }
    }

    private func handle(_ event: TmuxControlEvent, generation eventGeneration: UInt64) async {
        guard link.accepts(generation: eventGeneration) else { return }
        switch event {
        case .notification(let notification):
            handle(notification: notification)
        case .ended(let end):
            await controlEnded(end)
        }
    }

    private func controlEnded(_ end: TmuxControlEnd) async {
        await performLink(link.handle(.clientEnded(end)))
    }

    /// Performs the link machine's effects that end or replace the link:
    /// a client's end, distrust, close.
    private func performLink(_ effects: [TmuxLinkMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .finishEvents(let error):
                finishEvents(throwing: error)
            case .reattach:
                // Either way the projection re-snapshots.
                do {
                    if try await connect() == nil { emitResync(TmuxEvents.resyncKind) }
                } catch {
                    finishEvents(throwing: error)
                }
            case .endControl(let closing):
                await endControl(closing: closing)
            case .closeClient(let generation):
                await closeClient(generation)
            case .dial, .join, .refuse, .listSessions, .enterIdle, .openClient, .recordServer,
                .keep, .discard:
                break
            }
        }
    }

    private func handle(notification: TmuxNotification) {
        switch notification {
        case .subscriptionChanged(let change):
            // Subscription evaluation lags its acknowledgement: the first
            // status push may already differ from the snapshot we handed out.
            let effects = subscriptionBaseline.handle(.pushed(
                name: change.name, value: change.value,
                snapshotPanes: lastSnapshot != nil ? records.panes : nil))
            for effect in effects {
                switch effect {
                case .deliver(let event): deliver(event)
                case .resync(let kind): emitResync(kind)
                }
            }
        case .sessionsChanged:
            emitResync(GlobalEventKind.workspaceCreated.kind)
        case .sessionRenamed:
            emitResync(GlobalEventKind.workspaceRenamed.kind)
        case .windowAdd, .unlinkedWindowAdd:
            emitResync(GlobalEventKind.tabCreated.kind)
        case .windowClose, .unlinkedWindowClose:
            emitResync(GlobalEventKind.tabClosed.kind)
        case .windowRenamed, .unlinkedWindowRenamed:
            emitResync(GlobalEventKind.tabRenamed.kind)
        default:
            // Layout changes are covered by `wc-topo`; output, pauses, config
            // errors and focus moves need nothing. `%exit` arrives as the
            // channel's end.
            break
        }
    }

    /// The control channel when one is (or can be made) open; nil while
    /// idle. `recheckIdle` asks `tmux ls` again first. A channel found ended
    /// before its pump got to the end has the end handled here, once
    /// (``controlEnded(_:)``): the pump drops a replaced channel's events,
    /// so a reattach started here would otherwise lose that end's resync, or
    /// the event stream's failure.
    func activeControl(recheckIdle: Bool) async throws -> TmuxControlChannel? {
        try ensureOpen()
        if let channel = controlChannel, let end = await channel.end, controlChannel === channel {
            await controlEnded(end)
        }
        switch link.state.link {
        case .control:
            if let channel = controlChannel, await channel.isOpen { return channel }
            return try await connect()
        case .idle:
            return recheckIdle ? try await connect() : nil
        case .lost:
            return try await connect()
        }
    }

    /// The control channel, or `code` (herdr's not-found code for the
    /// target kind) when the server has no sessions.
    func requireControl(missing code: String) async throws -> TmuxControlChannel {
        guard let channel = try await activeControl(recheckIdle: true) else {
            throw HerdrAPIError(code: code, message: "tmux has no sessions")
        }
        return channel
    }

    /// One control line on `channel`. The first error reply throws; a line
    /// that ends early without one is malformed. It goes out once: whether
    /// it may go again is the caller's call (``runLine(_:recheckIdle:)``).
    func send(_ channel: TmuxControlChannel, _ commands: [String]) async throws -> [TmuxReply] {
        let replies = try await channel.send(commands)
        if let failed = replies.first(where: \.isError) { throw TmuxErrors.apiError(reply: failed) }
        guard replies.count == commands.count else {
            throw TransportError.malformedResponse(
                "tmux answered \(replies.count) of \(commands.count) commands")
        }
        return replies
    }

    /// `commands` as one control line, connecting when needed; nil while
    /// the server has no session to anchor on. A line tmux's `%exit` left
    /// unanswered (below 3.6 the control client's anchor session died, maybe
    /// of a line beside it; such a line never ran, T24) goes out again on
    /// the replacement client when every command in it is idempotent
    /// (``TmuxCommand/isIdempotent(_:)``) and the replacement reached the
    /// same server, whose objects the line's ids name; and again should that
    /// client's anchor die too, as when a bulk Close empties several
    /// sessions. Each pass takes another `%exit`, so this ends once the line
    /// is answered or no session is left. Anything else fails as it came,
    /// never re-sent (ADR 0018).
    func runLine(_ commands: [String], recheckIdle: Bool = true) async throws -> [TmuxReply]? {
        guard var channel = try await activeControl(recheckIdle: recheckIdle) else { return nil }
        let server = serverIdentity
        let replayable = commands.allSatisfy(TmuxCommand.isIdempotent)
        while true {
            do {
                return try await send(channel, commands)
            } catch {
                guard replayable, await Self.exitLeftUnanswered(error, on: channel) else {
                    throw error
                }
                guard let replacement = try await activeControl(recheckIdle: recheckIdle) else {
                    return nil
                }
                guard serverIdentity == server else { throw error }
                channel = replacement
            }
        }
    }

    /// Whether `error` is `channel` failing a line because tmux sent `%exit`
    /// before answering it (T24).
    static func exitLeftUnanswered(_ error: any Error, on channel: TmuxControlChannel) async -> Bool {
        guard case .channelFailed = error as? TransportError, case .exited = await channel.end
        else { return false }
        return true
    }

    /// ``runLine(_:recheckIdle:)``, or `code` (herdr's not-found code for
    /// the target kind) when the server has no sessions.
    @discardableResult
    func run(_ commands: [String], missing code: String = "pane_not_found") async throws
        -> [TmuxReply]
    {
        guard let replies = try await runLine(commands) else {
            throw HerdrAPIError(code: code, message: "tmux has no sessions")
        }
        return replies
    }

    func ensureOpen() throws {
        guard !closed else { throw TmuxLinkMachine.closedError }
    }

    // MARK: Events

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        // tmux pushes everything: the requested subscriptions are ignored.
        try ensureOpen()
        guard eventContinuation == nil, !subscribing else {
            throw TransportError.eventsChannelAlreadyOpen
        }
        subscribing = true
        defer { subscribing = false }
        _ = try await activeControl(recheckIdle: true)
        try ensureOpen()
        let (stream, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(HerdrEventStream.bufferLimit))
        eventStreamID &+= 1
        let id = eventStreamID
        eventContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.eventStreamTerminated(id: id) }
        }
        if link.state.link == .idle { startIdlePoll() }
        startScreenPoll()
        return HerdrEventStream(events: stream) { [weak self] in
            await self?.endEventStream(id: id)
        }
    }

    private func endEventStream(id: UInt64) {
        guard id == eventStreamID, let continuation = eventContinuation else { return }
        eventContinuation = nil
        stopEventWork()
        continuation.finish()
    }

    private func eventStreamTerminated(id: UInt64) {
        guard id == eventStreamID, eventContinuation != nil else { return }
        eventContinuation = nil
        stopEventWork()
    }

    /// The control link ended: the stream ends with it, and the screen
    /// verdicts go too (a deliberate resubscribe keeps them).
    private func finishEvents(throwing error: (any Error)?) {
        guard let continuation = eventContinuation else { return }
        eventContinuation = nil
        stopEventWork()
        _ = screenWatch.handle(.forget)
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func stopEventWork() {
        stopIdlePoll()
        stopScreenPoll()
        for task in pendingResyncs.values { task.cancel() }
        pendingResyncs.removeAll()
    }

    func deliver(_ event: HerdrEvent) {
        guard let continuation = eventContinuation else { return }
        if case .dropped = continuation.yield(event) {
            _ = continuation.yield(.eventsDropped)
        }
    }

    /// A resync of `kind`, at the end of the debounce window; identical ones
    /// inside the window join it.
    func emitResync(_ kind: HerdrEventKind) {
        guard eventContinuation != nil, pendingResyncs[kind] == nil else { return }
        let delay = configuration.resyncDebounce
        pendingResyncs[kind] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flushResync(kind)
        }
    }

    private func flushResync(_ kind: HerdrEventKind) {
        guard pendingResyncs.removeValue(forKey: kind) != nil else { return }
        deliver(HerdrEvent(kind: kind, data: .object([:])))
    }

    /// Polls `tmux ls` while idle, on a tmux-only Host only.
    private func startIdlePoll() {
        guard idlePoll == nil, configuration.hostRole == .tmuxOnly else { return }
        let interval = configuration.idlePollInterval
        idlePoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                guard await self.pollIdle() else { return }
            }
        }
    }

    /// One idle poll; false once polling should stop.
    private func pollIdle() async -> Bool {
        guard !closed, eventContinuation != nil, link.state.link == .idle else {
            idlePoll = nil
            return false
        }
        // A failed poll (a slow Host) just waits for the next one; the
        // keepalive ping reports a dead link.
        if (try? await connect()) != nil {
            idlePoll = nil
            return false
        }
        return true
    }

    private func stopIdlePoll() {
        idlePoll?.cancel()
        idlePoll = nil
    }

    // MARK: Server identity and lifetime

    /// The keepalive's ping: a `display` round trip on the control channel.
    /// While idle a tmux-only Host asks `tmux ls` again; a dual Host leaves
    /// that to `revalidate()` and only checks that its SSH connection is up.
    func ping() async throws -> ServerInfo {
        try await serverInfo(recheckIdle: configuration.hostRole == .tmuxOnly)
    }

    /// The foreground re-proof: a ping that asks `tmux ls` again while idle
    /// on either kind of Host.
    func revalidate() async throws -> ServerInfo {
        try await serverInfo(recheckIdle: true)
    }

    private func serverInfo(recheckIdle: Bool) async throws -> ServerInfo {
        if let replies = try await runLine(
            [TmuxCommand.display(format: "#{version}")], recheckIdle: recheckIdle)
        {
            if let reported = replies[0].lines.first?.trimmingCharacters(in: .whitespaces),
                !reported.isEmpty
            {
                version = reported
            }
        } else if !(await session.isConnected) {
            throw TransportError.sshUnreachable(detail: "the SSH connection to the Host closed")
        }
        return ServerInfo(version: version, protocolVersion: 0, backend: .tmux)
    }

    var isConnected: Bool {
        get async {
            guard !closed else { return false }
            switch link.state.link {
            case .control:
                if let channel = controlChannel, await channel.isOpen { return true }
                return link.state.dialing
            case .idle:
                return await session.isConnected
            case .lost:
                return link.state.dialing
            }
        }
    }

    /// Ends the event stream and the control client, then releases its hold
    /// on the shared connection. It never waits on the Host: when this
    /// transport made attach sessions, the sweep for orphaned ones runs
    /// detached under `attachSweepBudget` and returns the hold when done.
    func close() async throws {
        guard !closed else { return }
        await performLink(link.handle(.close))
        _ = launchGates.handle(.closed)
        guard madeAttachSessions else {
            await session.release()
            return
        }
        let session = session
        Task {
            await Self.sweepOrphanedAttachSessions(on: session)
            await session.release()
        }
    }

    /// EventsSession dropped this transport without closing it, since
    /// Terminals may still use it: its control slot goes back to the
    /// connection for the replacement, the event stream, idle poll and
    /// screen reads stop, and it never opens a control client again. Attach
    /// Terminals and exec work are untouched; `close()` or deinit still
    /// releases the connection hold.
    func transportDistrusted() async {
        // A dial in flight sees itself superseded and closes its channel.
        await performLink(link.handle(.distrust))
    }

    /// Ends the event stream and its polling, then the control client kept
    /// under `closing`.
    private func endControl(closing generation: UInt64?) async {
        let continuation = eventContinuation
        eventContinuation = nil
        stopEventWork()
        continuation?.finish()
        pump?.cancel()
        pump = nil
        if let generation { await closeClient(generation) }
    }

    /// How long `close()`'s detached attach-session sweep may take.
    static let attachSweepBudget: Duration = .seconds(2)

    /// `destroy-unattached` ends an attach session when its client leaves,
    /// and tmux 3.7c ends a clientless one as soon as the option is set. A
    /// chain that failed before its `set-option`, or a tmux that acts only
    /// on a detach, can still leave one that never had a client, keeping
    /// its group's windows alive while inventory hides it. This kills every
    /// unattached `waycar-<8 hex>` session: the attach chain makes and
    /// attaches its session in one tmux command, so none is mid-attach.
    static var attachSweepCommand: String {
        let attachName = TmuxAttachCommand.attachSessionPrefix
            + String(repeating: "[0-9a-f]", count: 8)
        return shellCommand(
            "env -u TMUX tmux ls -F \"#{session_attached} #{session_name}\" 2>/dev/null"
                + " | while read -r attached name; do case \"$attached:$name\" in 0:\(attachName))"
                + " env -u TMUX tmux kill-session -t \"=$name\" 2>/dev/null;; esac; done; exit 0",
            cLocale: true)
    }

    /// Best-effort and bounded: a half-dead link costs the budget, never more.
    private static func sweepOrphanedAttachSessions(on session: any HostSSHServices) async {
        guard await session.isConnected else { return }
        let command = attachSweepCommand
        let budget = attachSweepBudget
        _ = try? await AsyncDeadline.run(for: budget) {
            _ = try await session.runExec(command, input: Data(), timeout: budget)
        }
    }

    // MARK: Host services

    func probeMoshServer() async throws -> Bool { try await session.probeMoshServer() }
    func remoteHomeDirectory() async throws -> String { try await session.remoteHomeDirectory() }

    func listDirectories(at path: String) async throws -> RemoteDirectoryListing {
        try await session.listDirectories(at: path)
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

    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        try await session.readFileSlice(range)
    }

    func readPreviewFile(atPath path: String, maxBytes: Int) async throws -> Data {
        try await session.readPreviewFile(atPath: path, maxBytes: maxBytes)
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

    // MARK: Shell helpers

    /// `/bin/sh -c '<PATH fix-up>; <script>' sh`: POSIX sh whatever the
    /// account shell is, with `HerdrHostPath`'s prefixes. `cLocale` adds
    /// `LC_ALL=C` for commands whose output is parsed; never for one that
    /// may start the tmux server, whose panes would inherit it. `script` is
    /// Waycar's own code: it must hold no backslash before a quote and no
    /// `\\`, which fish reads differently inside single quotes.
    static func shellCommand(_ script: String, cLocale: Bool = false) -> String {
        let locale = cLocale ? "LC_ALL=C; export LC_ALL; " : ""
        let body = "\(locale)\(HerdrHostPath.pathExport); \(script)"
        return ["/bin/sh", "-c", shellQuoted(body), "sh"].joined(separator: " ")
    }

    /// One `$n` word of ``shellCommand(_:arguments:cLocale:)``. The exec
    /// runs through the account's login shell, which may be fish: inside
    /// single quotes fish reads `\'` and `\\` as escapes, and outside them
    /// `\'` is a literal quote, as in POSIX shells.
    enum ShellArgument: Sendable, Equatable {
        /// A path or any other word: `RemoteShellPath`'s rule (no quote,
        /// backslash, or control character), refused with
        /// `TransportError.invalidDirectoryPath`.
        case path(String)
        /// A git ref name, or a slug made from one: only backslash and
        /// control characters are refused (git forbids both in ref names),
        /// with `TransportError.channelFailed`. A quote is safe: written
        /// `'\''`, it closes the quotes, adds `\'` outside them, and reopens,
        /// which POSIX shells and fish read alike. Callers check refs first
        /// to give git's own refusal.
        case ref(String)
    }

    /// ``shellCommand(_:cLocale:)`` with `arguments` as `$1…`, each a
    /// single-quoted word held to `RemoteShellPath`'s rule
    /// (``ShellArgument/path(_:)``), refused before anything runs.
    static func shellCommand(
        _ script: String, arguments: [String], cLocale: Bool = false
    ) throws -> String {
        try shellCommand(script, arguments: arguments.map(ShellArgument.path), cLocale: cLocale)
    }

    /// ``shellCommand(_:cLocale:)`` with `arguments` as `$1…`, each a
    /// single-quoted word checked by its own rule before anything runs.
    static func shellCommand(
        _ script: String, arguments: [ShellArgument], cLocale: Bool = false
    ) throws -> String {
        let words = try arguments.map { argument throws -> String in
            switch argument {
            case .path(let text):
                guard isLoginShellSafe(text) else {
                    throw TransportError.invalidDirectoryPath(path: text)
                }
                return shellQuoted(text)
            case .ref(let text):
                guard isLoginShellSafeRef(text) else {
                    throw TransportError.channelFailed(
                        detail: "the ref name cannot be quoted safely: \(text)")
                }
                return shellQuoted(text)
            }
        }
        return ([shellCommand(script, cLocale: cLocale)] + words).joined(separator: " ")
    }

    /// `RemoteShellPath`'s rule for any word: no quote, backslash, or
    /// control character, so POSIX shells and fish read it alike.
    static func isLoginShellSafe(_ text: String) -> Bool {
        isLoginShellSafeRef(text) && !text.unicodeScalars.contains("'")
    }

    /// ``ShellArgument/ref(_:)``'s rule: no backslash or control character.
    static func isLoginShellSafeRef(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar.value != 0x5C
        }
    }

    /// POSIX single quotes, each `'` written `'\''`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    static func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
    }
}
