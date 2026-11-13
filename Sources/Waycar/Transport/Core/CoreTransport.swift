import Foundation

/// herdr-core's Transport (ADR 0031, design §5-§8): one framed `herdr-core
/// connect` on one non-PTY exec channel (`.core` admission class) carries
/// every request and the event stream; Attach is a separate PTY exec of
/// `herdr-core attach`. Core has no topology of its own, so the inventory
/// is a flat terminal table (`CoreInventory`) that `CoreSnapshotBuilder`
/// presents as Workspaces, Tabs and Panes, and every id it hands out carries
/// the `hc:` prefix (`CoreID`).
///
/// The connection is the transport's whole link: EOF (a core restart or
/// update ends every connection with no CLOSE frame), an exit status or
/// silence ends it, the event stream ends with the failure, and
/// `EventsSession` dials a replacement transport, which says hello and
/// subscribes afresh and replaces all state with the new snapshot. Terminals
/// survive all of that, so Console rows do not close.
actor CoreTransport: HostToolsTransport {
    /// Timing the transport runs on; tests change it.
    struct Configuration: Sendable {
        var requestTimeout: Duration
        /// Identical resyncs inside this window go out once, at its end.
        var resyncDebounce: Duration = .milliseconds(250)
        /// How long the login PATH exec may take before the connect line
        /// falls back to the SSH PATH and the usual directories.
        var loginPathTimeout: Duration = .seconds(8)
        /// How long a launched agent that has not reported its status
        /// (OSC 7501) is left alone before its screen is read to see
        /// whether it takes input (design §9 step 4).
        var unreportedWait: Duration = .seconds(5)
        var rpc = CoreRPCClient.Configuration()

        init(requestTimeout: Duration) {
            self.requestTimeout = requestTimeout
        }
    }

    /// The methods the Console, Composer and Attach need; a core missing
    /// one is too old (`TransportError.coreNeedsUpdate`).
    static let requiredMethods = [
        "server.status", "events.subscribe", "terminal.list", "terminal.read", "terminal.send",
        "terminal.keys", "terminal.kill",
    ]

    let session: any HostSSHServices
    /// Waycar's Host Tools on this Host: registration, summaries, Chat Mode.
    let hostTools: HostToolsService
    let configuration: Configuration
    let memory: (any HostConnectionMemory)?
    /// The binary detection found, when it ran: its absolute path.
    let corePath: String?
    /// The connection's and the transport's lifetime (CORE-01).
    private var link = CoreLinkMachine()
    /// The dial in flight, under the link's token; joined by every caller.
    private var dial: (token: UInt64, task: Task<CoreRPCClient, any Error>)?
    /// The client of the open link.
    private var client: CoreRPCClient?
    var hello: CoreHello?
    /// The login PATH the connect line exports, once resolved or remembered.
    var loginPATH: String?
    var inventory: CoreInventory?
    var overlay = CoreDoneOverlayMachine()
    /// Launches Waycar made on this connection whose first prompt has not
    /// been let through yet, by terminal address.
    var launchGate = CoreLaunchGateMachine()
    /// The PATH sent as `env.PATH` on every launch, once computed from the
    /// login PATH (`CoreLaunchPath`).
    var launchPATH: String?
    /// Whether the Host's codex takes `--no-daemon`, asked once.
    let codexNoDaemon = SharedAsyncOperation<Bool>(cachesSuccess: true)
    var cachedSnapshot: SessionSnapshot?
    private var appLayout: CoreAppLayout?
    /// The remote subscription and the consumer's stream (CORE-02).
    private var events = CoreEventsMachine()
    /// The current consumer's stream, while `events` delivers to one.
    private var eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
    /// Applies the subscription's notifications to `inventory`.
    private var pump: Task<Void, Never>?
    var pendingResyncs: [HerdrEventKind: Task<Void, Never>] = [:]

    private init(
        session: any HostSSHServices, configuration: Configuration,
        memory: (any HostConnectionMemory)?, corePath: String?
    ) {
        self.session = session
        hostTools = HostToolsService(session: session)
        self.configuration = configuration
        self.memory = memory
        self.corePath = corePath
        loginPATH = memory?.loginPATH
    }

    deinit {
        // A Transport dropped without `close()` still returns its hold on
        // the shared connection and its channel.
        guard !link.isClosed else { return }
        let session = session
        if case .open = link.state, let client {
            Task { await client.close() }
        }
        Task { await session.release() }
    }

    // MARK: Opening

    /// herdr-core's Transport on `session`, taking over one hold the caller
    /// has on it: `close()` releases that hold. When this throws the hold
    /// stays the caller's. `presence` is the Host's backend detection, run
    /// on `session` just now: the core binary it found, and whether it is
    /// recent enough.
    static func open(
        session: any HostSSHServices, settings: SSHTransportSettings,
        presence: HostBackendPresence
    ) async throws -> CoreTransport {
        guard let core = presence.core else { throw TransportError.coreNotInstalled }
        guard core.meetsFloor else {
            throw TransportError.coreNeedsUpdate(
                detail: "herdr-core \(core.version) is older than "
                    + "\(CorePresence.minimumVersion).")
        }
        return try await open(
            session: session,
            configuration: Configuration(requestTimeout: settings.requestTimeout),
            memory: settings.connectionMemory, corePath: core.path)
    }

    /// ``open(session:settings:presence:)`` with its own configuration and no
    /// detection: the connect line finds the binary itself.
    static func open(
        session: any HostSSHServices, configuration: Configuration,
        memory: (any HostConnectionMemory)? = nil, corePath: String? = nil
    ) async throws -> CoreTransport {
        let transport = CoreTransport(
            session: session, configuration: configuration, memory: memory, corePath: corePath)
        do {
            _ = try await transport.connection()
        } catch {
            await transport.abandon()
            throw error
        }
        return transport
    }

    /// A failed open leaves the caller's hold on the session with the caller.
    private func abandon() async {
        await applyLink(link.handle(.close(releasesHold: false)))
    }

    /// Performs what the link machine asks for (CORE-01).
    private func applyLink(_ effects: [CoreLinkMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .dial(let token):
                dial = (token, Task { try await self.establish() })
            case .keep(let token):
                if let dial, dial.token == token { self.dial = nil }
            case .discard:
                break
            case .closeLink:
                await closeLink()
            case .release:
                await session.release()
            }
        }
    }

    // MARK: Connection

    /// The open connection: the link already up, the dial in flight (joined
    /// by every caller), or a new dial. A lost link stays lost: the events
    /// session replaces this transport.
    func connection() async throws -> CoreRPCClient {
        try ensureOpen()
        switch link.state {
        case .open:
            guard let client else { throw TransportError.cancelled }
            if await client.isOpen { return client }
            let failure = TransportError.channelFailed(detail: "the herdr-core connection ended")
            _ = link.handle(.clientEnded(failure))
            throw failure
        case .connecting:
            guard let dial else { throw TransportError.cancelled }
            return try await dial.task.value
        case .lost(let failure):
            throw failure
        case .distrusted, .closed:
            // `ensureOpen` refused already.
            throw TransportError.cancelled
        case .idle:
            await applyLink(link.handle(.connect))
            guard let dial else { throw TransportError.cancelled }
            do {
                let dialed = try await dial.task.value
                let effects = link.handle(.dialed(token: dial.token))
                guard effects == [.keep(token: dial.token)] else {
                    await dialed.close()
                    throw TransportError.cancelled
                }
                client = dialed
                await applyLink(effects)
                return dialed
            } catch {
                _ = link.handle(.dialFailed(token: dial.token, Self.transportError(error)))
                throw error
            }
        }
    }

    /// One dial: the login PATH, the connect line, the marker, `hello`, and
    /// the floor and method checks.
    private func establish() async throws -> CoreRPCClient {
        let path = await resolveLoginPATH()
        let command = CoreConnectCommand.connect(path: corePath, loginPATH: path)
        let channel = try await session.openCoreChannel(command: command)
        let client = CoreRPCClient(channel: channel, configuration: configuration.rpc)
        do {
            let answer = try await client.open(marker: CoreConnectCommand.connectMarker)
            try Self.validate(answer)
            hello = answer
        } catch {
            await client.close()
            throw Self.transportError(error)
        }
        return client
    }

    /// The Host's login PATH, remembered per Host; nil when it cannot be
    /// resolved, which the connect line covers with the SSH PATH and the
    /// usual directories rather than failing. `refresh` asks the Host again
    /// whatever is remembered (a launch that found its program missing:
    /// the PATH may have been resolved before `~/.local/bin` existed, C22).
    func resolveLoginPATH(refresh: Bool = false) async -> String? {
        if !refresh, let loginPATH { return loginPATH }
        guard let path = await CoreLoginPath.resolve(
            on: session, timeout: configuration.loginPathTimeout)
        else { return refresh ? loginPATH : nil }
        loginPATH = path
        memory?.rememberLoginPATH(path)
        return path
    }

    /// The floor and the methods Waycar needs.
    static func validate(_ hello: CoreHello) throws {
        guard CorePresence.meetsFloor(hello.version) else {
            throw TransportError.coreNeedsUpdate(
                detail: "herdr-core \(hello.version) is older than "
                    + "\(CorePresence.minimumVersion).")
        }
        let missing = requiredMethods.filter { !hello.methods.contains($0) }
        guard missing.isEmpty else {
            throw TransportError.coreNeedsUpdate(
                detail: "herdr-core \(hello.version) does not offer "
                    + missing.joined(separator: ", ") + ".")
        }
    }

    func ensureOpen() throws {
        if let refusal = link.refusal { throw refusal }
    }

    // MARK: Calls

    /// One RPC on the open connection, failures mapped for the caller:
    /// core's error kinds to `HerdrAPIError` (`CoreErrors`), link failures
    /// as `TransportError`.
    func call<Result: Decodable & Sendable>(
        _ method: String, _ params: some Encodable & Sendable, as type: Result.Type,
        subject: CoreErrors.Subject = .agent, timeout: Duration? = nil
    ) async throws -> Result {
        let client = try await connection()
        do {
            return try await client.call(method, params: params, as: type, timeout: timeout)
        } catch {
            throw CoreErrors.map(error, subject: subject)
        }
    }

    /// `call(_:_:as:)` for a method whose result is not read.
    func perform(
        _ method: String, _ params: some Encodable & Sendable,
        subject: CoreErrors.Subject = .agent
    ) async throws {
        let client = try await connection()
        do {
            _ = try await client.call(method, params: params, timeout: nil)
        } catch {
            throw CoreErrors.map(error, subject: subject)
        }
    }

    /// A failure as `TransportError`: core's own error replies (which a
    /// handshake or liveness call never expects) are rejections.
    static func transportError(_ error: any Error) -> TransportError {
        if let transport = error as? TransportError { return transport }
        if let core = error as? CoreRPCError {
            return .apiRejected(code: core.kind, message: core.message)
        }
        if error is CancellationError { return .cancelled }
        return .channelFailed(detail: "\(error)")
    }

    // MARK: Identity and lifetime

    /// `hello`'s identity, and a `server.status` round trip as the liveness
    /// proof the keepalive wants.
    func ping() async throws -> ServerInfo {
        let client = try await connection()
        do {
            _ = try await client.call("server.status", params: CoreParams.Empty(), timeout: nil)
        } catch {
            throw Self.transportError(error)
        }
        guard let hello else { throw TransportError.channelFailed(detail: "no hello") }
        return ServerInfo(version: hello.version, protocolVersion: hello.generation, backend: .core)
    }

    func revalidate() async throws -> ServerInfo {
        try await ping()
    }

    var isConnected: Bool {
        get async {
            switch link.state {
            case .open:
                return await client?.isOpen ?? false
            case .connecting:
                return true
            case .idle:
                return await session.isConnected
            case .lost, .distrusted, .closed:
                return false
            }
        }
    }

    /// Ends the event stream and the connection, then releases its hold on
    /// the shared connection. It never waits on the Host.
    func close() async throws {
        await applyLink(link.handle(.close(releasesHold: true)))
    }

    /// `EventsSession` dropped this transport without closing it, since
    /// Terminals may still use it: its `.core` slot goes back to the
    /// connection for the replacement, and the event stream stops. Attach
    /// Terminals and exec work are untouched; `close()` or deinit still
    /// releases the connection hold.
    func transportDistrusted() async {
        await applyLink(link.handle(.distrust))
    }

    /// The link machine's `closeLink`: the events end, then the client
    /// closes or the dial is cancelled (and its client closed if it lands).
    private func closeLink() async {
        applyEvents(events.handle(.linkClosed))
        let open = client
        let dialing = dial
        client = nil
        dial = nil
        if let open {
            await open.close()
        } else if let dialing {
            dialing.task.cancel()
            if let dialed = try? await dialing.task.value { await dialed.close() }
        }
    }

    // MARK: Events

    /// The Host's events. core pushes every terminal's events, so the
    /// requested subscriptions are ignored, and one `events.subscribe` per
    /// connection feeds the inventory for the connection's whole life. A
    /// stream the consumer ends (`EventsSession` resubscribes whenever its
    /// pane set changes) does not touch the connection: the next call hands
    /// out a new stream over the same inventory, with no round trip.
    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        try ensureOpen()
        for case .refuse(let error) in events.handle(.subscribeRequested) { throw error }
        defer { applyEvents(events.handle(.openingEnded)) }
        let client = try await connection()
        for case .subscribe(let token) in events.handle(.connected) {
            do {
                try await subscribe(over: client, token: token)
            } catch {
                applyEvents(events.handle(.subscribeFailed(token: token)))
                throw error
            }
        }
        var handedOut: HerdrEventStream?
        for case .deliver(let id) in events.handle(.attach) {
            handedOut = deliverStream(id: id)
        }
        guard let handedOut else { throw TransportError.eventsChannelAlreadyOpen }
        return handedOut
    }

    /// The connection's one `events.subscribe` under `token`: the inventory
    /// it answers and the pump that keeps it current.
    private func subscribe(over client: CoreRPCClient, token: UInt64) async throws {
        let subscription: (snapshot: CoreSubscription, notifications: AsyncThrowingStream<CoreNotification, any Error>)
        do {
            subscription = try await client.subscribe()
        } catch {
            throw Self.transportError(error)
        }
        try ensureOpen()
        // Best-effort: synthesized names serve until the document reads.
        try? await refreshAppLayout()
        try ensureOpen()
        for case .startPump(let pumpToken) in events.handle(.subscribed(token: token)) {
            inventory = CoreInventory(subscription.snapshot)
            _ = overlay.handle(.inventoryChanged(inventory?.terminals ?? []))
            cachedSnapshot = nil
            pump = Task { [weak self] in
                await self?.runPump(subscription.notifications, pump: pumpToken)
            }
        }
    }

    /// A new consumer's stream under `id`.
    private func deliverStream(id: UInt64) -> HerdrEventStream {
        let (stream, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(HerdrEventStream.bufferLimit))
        eventContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.eventStreamTerminated(id: id) }
        }
        return HerdrEventStream(events: stream) { [weak self] in
            await self?.endEventStream(id: id)
        }
    }

    /// Performs what the events machine asks for (CORE-02). `refuse`,
    /// `subscribe`, `startPump` and `deliver` are performed where they are
    /// asked for, inline in `subscribeToEvents`.
    private func applyEvents(_ effects: [CoreEventsMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .finishStream(let failure):
                let continuation = eventContinuation
                eventContinuation = nil
                if let failure {
                    continuation?.finish(throwing: failure)
                } else {
                    continuation?.finish()
                }
            case .forgetStream:
                eventContinuation = nil
            case .cancelResyncs:
                cancelResyncs()
            case .cancelPump:
                pump?.cancel()
                pump = nil
            case .refuse, .subscribe, .startPump, .deliver:
                break
            }
        }
    }

    /// Applies the connection's notifications until it ends.
    private func runPump(
        _ notifications: AsyncThrowingStream<CoreNotification, any Error>, pump token: UInt64
    ) async {
        do {
            for try await notification in notifications {
                switch notification {
                // A failed name refresh never ends an otherwise healthy
                // connection: a dead one fails this loop's stream itself.
                case .event(let event)
                    where event.type == "doc" && event.data["name"]?.stringValue == "herdr-app":
                    if (try? await refreshAppLayout()) != nil {
                        emitResync(GlobalEventKind.workspaceMetadataUpdated.kind)
                    }
                case .missed:
                    try? await refreshAppLayout()
                default:
                    break
                }
                handle(notification)
            }
            connectionEnded(
                failure: .channelFailed(detail: "herdr-core ended the connection"), pump: token)
        } catch {
            connectionEnded(failure: Self.transportError(error), pump: token)
        }
    }

    /// The connection is gone: the link is lost and the current stream, if
    /// any, ends with the reason.
    private func connectionEnded(failure: TransportError, pump token: UInt64) {
        _ = link.handle(.connectionEnded(failure))
        applyEvents(events.handle(.connectionEnded(pump: token, failure)))
    }

    private func endEventStream(id: UInt64) async {
        applyEvents(events.handle(.consumerEnded(stream: id)))
    }

    private func eventStreamTerminated(id: UInt64) {
        applyEvents(events.handle(.consumerTerminated(stream: id)))
    }

    private func cancelResyncs() {
        for task in pendingResyncs.values { task.cancel() }
        pendingResyncs.removeAll()
    }

    /// One notification: the inventory applies it and the effects it names
    /// become the herdr events the projection already reads.
    private func handle(_ notification: CoreNotification) {
        guard var current = inventory else { return }
        var effects = current.apply(notification)
        inventory = current
        // A seen Done that finished another turn with the same word is Done
        // again, though no status the inventory tracks changed (B-23).
        if effects.isEmpty, case .event(let event) = notification, let address = event.terminal,
            let terminal = current.terminal(address: address)
        {
            for effect in overlay.handle(.recordMoved(terminal)) {
                switch effect {
                case .presentDone(let address): effects.append(.status(address: address))
                }
            }
        }
        guard !effects.isEmpty else { return }
        cachedSnapshot = nil
        // A Done terminal seen and then moved on must show Done again when
        // it next finishes a turn: drop the entries whose status changed.
        _ = overlay.handle(.inventoryChanged(current.terminals))
        for effect in effects {
            switch effect {
            case .status(let address):
                guard let terminal = current.terminal(address: address) else { continue }
                let status = CoreSnapshotBuilder.agentStatus(of: terminal, overlay: overlay)
                deliver(
                    HerdrEvent(
                        kind: PaneEventKind.agentStatusChanged.kind,
                        data: .object([
                            "pane_id": .string(CoreID.pane(address)),
                            "agent_status": .string(status.rawValue),
                        ])))
            case .paneUpdated(let address):
                guard let terminal = current.terminal(address: address),
                    let pane = CoreSnapshotBuilder.paneInfo(
                        for: terminal, in: currentSnapshot(), overlay: overlay),
                    let value = Self.jsonValue(pane)
                else { continue }
                deliver(
                    HerdrEvent(
                        kind: GlobalEventKind.paneUpdated.kind,
                        data: .object(["pane": value])))
            case .resync:
                emitResync(GlobalEventKind.workspaceMetadataUpdated.kind)
            }
        }
    }

    private static func jsonValue(_ pane: PaneInfo) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(pane) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func deliver(_ event: HerdrEvent) {
        guard let continuation = eventContinuation else { return }
        if case .dropped = continuation.yield(event) {
            _ = continuation.yield(.eventsDropped)
        }
    }

    /// A resync of `kind`, at the end of the debounce window; identical ones
    /// inside the window join it.
    private func emitResync(_ kind: HerdrEventKind) {
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

    // MARK: Inventory

    /// Reads names only; never writes the desktop app's document.
    private func refreshAppLayout() async throws {
        let result = try await call(
            "doc.get", CoreAppLayout.Request(), as: CoreAppLayout.Result.self)
        appLayout = result.value
        cachedSnapshot = nil
    }

    /// The Console's snapshot, from live inventory; before subscribing,
    /// reads the terminal list and the desktop app's names.
    func sessionSnapshot() async throws -> SessionSnapshot {
        if inventory == nil {
            // Best-effort: synthesized names serve when the document read fails.
            try? await refreshAppLayout()
            let listed = try await call(
                "terminal.list", CoreParams.List(all: true), as: CoreParams.Listed.self)
            return CoreSnapshotBuilder.snapshot(
                terminals: listed.terminals, core: hello, overlay: overlay, appLayout: appLayout)
        }
        return currentSnapshot()
    }

    func currentSnapshot() -> SessionSnapshot {
        if let cachedSnapshot { return cachedSnapshot }
        let snapshot = CoreSnapshotBuilder.snapshot(
            terminals: inventory?.terminals ?? [], core: hello, overlay: overlay, appLayout: appLayout)
        cachedSnapshot = snapshot
        return snapshot
    }

    func listAgents() async throws -> [Agent] {
        try await sessionSnapshot().agents.map(Agent.init)
    }

    func serverSessionLinkFacts() async -> ServerSessionLinkFacts {
        var lines: [String: String] = [:]
        for terminal in inventory?.terminals ?? [] {
            let argv = terminal.foreground?.argv ?? terminal.argv
            if !argv.isEmpty { lines[CoreID.pane(terminal.address)] = argv.joined(separator: " ") }
        }
        return ServerSessionLinkFacts(commandLines: lines)
    }

    /// The Shell Activities the live inventory derives; no traffic.
    func shellActivities(paneIDs: [String]) async throws -> [String: ShellActivity] {
        let all = CoreSnapshotBuilder.shellActivities(terminals: inventory?.terminals ?? [])
        return all.filter { paneIDs.contains($0.key) }
    }
}

/// The request and result shapes of the RPC methods Waycar calls.
enum CoreParams {
    struct Empty: Encodable, Sendable {}

    struct List: Encodable, Sendable {
        let all: Bool
    }

    struct Listed: Decodable, Sendable {
        let terminals: [CoreTerminal]
    }

    struct Terminal: Encodable, Sendable {
        let terminal: String
    }

    struct Read: Encodable, Sendable {
        let terminal: String
        let lines: Int
    }

    struct ReadResult: Decodable, Sendable {
        let text: String
        let complete: Bool?
    }

    struct Send: Encodable, Sendable {
        let terminal: String
        let text: String
    }

    struct Keys: Encodable, Sendable {
        let terminal: String
        let keys: [String]
    }

    /// `terminal.run`: a program exec'd directly (no shell), with the
    /// Waycar labels and the PATH to look it up on. No template, no name,
    /// no `wait` (design §9 step 3).
    struct Run: Encodable, Sendable {
        let argv: [String]
        let cwd: String
        let env: [String: String]
        let labels: [String: String]
    }

    /// `machine.exec` of a program (no shell); `timeout` is seconds.
    struct Exec: Encodable, Sendable {
        let argv: [String]
        let env: [String: String]?
        let timeout: Int?

        init(argv: [String], env: [String: String]? = nil, timeout: Int? = nil) {
            self.argv = argv
            self.env = env
            self.timeout = timeout
        }
    }

    /// How a `machine.exec` ended: `code` is nil when a signal or the
    /// timeout ended it. `stdout` and `stderr` are core's base64, decoded.
    struct ExecResult: Decodable, Sendable {
        let code: Int?
        let timedOut: Bool
        let stdout: String
        let stderr: String

        private enum CodingKeys: String, CodingKey {
            case code, stdout, stderr
            case timedOut = "timed_out"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decodeIfPresent(Int.self, forKey: .code)
            timedOut = (try? container.decodeIfPresent(Bool.self, forKey: .timedOut)) ?? false
            func text(_ key: CodingKeys) -> String {
                guard let encoded = try? container.decodeIfPresent(String.self, forKey: key),
                    let data = Data(base64Encoded: encoded)
                else { return "" }
                return String(decoding: data, as: UTF8.self)
            }
            stdout = text(.stdout)
            stderr = text(.stderr)
        }
    }
}
