import Foundation

/// One watch exec on the Host's shared SSH connection; ordinary execs carry every action.
/// A failed feed ends this transport, so EventsSession replaces the entire inventory on reconnect.
actor ZellijTransport: HostToolsTransport {
    struct Configuration: Sendable {
        var requestTimeout: Duration
        var silenceTimeout: Duration = .seconds(10)
        var resyncDebounce: Duration = .milliseconds(250)
        var screenInterval: Duration = .seconds(3)
        var wakesInLoginSession = false
        var launchConfirmationTimeout: Duration = .seconds(5)
    }

    let session: any HostSSHServices
    let hostTools: HostToolsService
    let commands: ZellijCommand
    let version: String
    let configuration: Configuration
    private var feed = ZellijFeedMachine()
    private var channel: (any HostControlChannel)?
    private var pump: Task<Void, Never>?
    private var screenPoll: Task<Void, Never>?
    private var resync: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
    private var streamID: UInt64 = 0
    private var released = false
    private(set) var stateDirectory = ""
    var frame = ZellijFrame()
    var firstSeenMs: [String: Int64] = [:]
    var generations: [String: UInt64] = [:]
    var screenVerdicts: [String: AgentStatus] = [:]
    /// Least-recently-read scheduling keeps a busy Host's ninth pane from starving.
    private var screenReadTimes: [String: ContinuousClock.Instant] = [:]
    var detectedAt: [String: ContinuousClock.Instant] = [:]
    var overlay = ZellijDoneOverlay()
    /// Who holds each pane's prompt turn and who waits for it, shared with
    /// tmux's prompt delivery.
    var promptTurns = TmuxPromptTurnMachine()
    /// The prompts waiting for their pane's turn, by the id they asked with.
    var promptTurnWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var closedSessionAges: [String: String] = [:]

    private init(
        session: any HostSSHServices, presence: ZellijPresence, configuration: Configuration
    ) throws {
        self.session = session
        hostTools = HostToolsService(session: session)
        commands = try ZellijCommand(zellij: presence.path)
        version = presence.version
        self.configuration = configuration
    }

    deinit {
        pump?.cancel()
        screenPoll?.cancel()
        resync?.cancel()
        let channel = channel
        let session = session
        let release = !released
        Task {
            await channel?.close()
            if release { await session.release() }
        }
    }

    /// Takes the caller's session hold only on success, like CoreTransport.open.
    static func open(
        session: any HostSSHServices, settings: SSHTransportSettings, presence: HostBackendPresence
    ) async throws -> ZellijTransport {
        guard let zellij = presence.zellij else { throw TransportError.zellijNotInstalled }
        return try await open(
            session: session, presence: zellij,
            configuration: Configuration(
                requestTimeout: settings.requestTimeout, wakesInLoginSession: settings.wakesInLoginSession))
    }

    static func open(
        session: any HostSSHServices, presence: ZellijPresence, configuration: Configuration
    ) async throws -> ZellijTransport {
        guard presence.meetsFloor else { throw TransportError.zellijTooOld(found: presence.version) }
        let transport = try ZellijTransport(
            session: session, presence: presence, configuration: configuration)
        do {
            try await transport.start()
            return transport
        } catch {
            // Failed open leaves the connection hold with the caller.
            await transport.abandon()
            throw error
        }
    }

    private func start() async throws {
        let home = try await session.remoteHomeDirectory()
        stateDirectory = home + "/.local/state/waycar/zellij"
        let configuration = configuration
        let channel = try await session.openZellijChannel(
            command: ZellijWatchCommand.script(zellij: commands.zellij, stateDirectory: stateDirectory))
        self.channel = channel
        var parser = ZellijFrameParser()
        // Bound first-frame admission even if a broken watcher sends heartbeats forever.
        let initialParser = parser
        let (first, nextParser) = try await AsyncDeadline.run(for: configuration.requestTimeout) {
            var parser = initialParser
            while let bytes = try await channel.read(
                maximumBytes: 64 * 1024, timeout: configuration.silenceTimeout)
            {
                let batch = parser.feed(bytes)
                if let frame = batch.frames.last { return (frame, parser) }
            }
            throw TransportError.channelFailed(detail: "Zellij watch ended before its first frame")
        }
        parser = nextParser
        accept(first, initial: true)
        pump = Task { [weak self, parser] in
            var parser = parser
            do {
                while !Task.isCancelled {
                    guard
                        let bytes = try await channel.read(
                            maximumBytes: 64 * 1024, timeout: configuration.silenceTimeout)
                    else { throw TransportError.channelFailed(detail: "Zellij watch ended") }
                    for frame in parser.feed(bytes).frames { await self?.accept(frame) }
                }
            } catch {
                await self?.lost(error)
            }
        }
    }

    func ensureOpen() throws {
        switch feed.state {
        case .starting, .live: return
        case .lost(let error): throw error
        case .closed: throw TransportError.cancelled
        }
    }

    var isConnected: Bool {
        get async {
            guard case .live = feed.state else { return false }
            return await session.isConnected
        }
    }

    private func abandon() async {
        released = true
        await endFeed(.close)
    }

    func close() async throws {
        await endFeed(.close)
        guard !released else { return }
        released = true
        await session.release()
    }

    func transportDistrusted() async {
        await endFeed(.failed(.channelFailed(detail: "Zellij transport was replaced")))
    }

    private func lost(_ error: any Error) async {
        await endFeed(
            .failed(
                (error as? TransportError) ?? .channelFailed(detail: error.localizedDescription)))
    }

    private func endFeed(_ event: ZellijFeedMachine.Event) async {
        let effects = feed.handle(event)
        guard !effects.isEmpty else { return }
        pump?.cancel()
        pump = nil
        screenPoll?.cancel()
        screenPoll = nil
        resync?.cancel()
        resync = nil
        for effect in effects {
            if case .finish(let error) = effect { continuation?.finish(throwing: error) }
        }
        continuation = nil
        let previous = channel
        channel = nil
        await previous?.close()
    }

    private func accept(_ next: ZellijFrame, initial: Bool = false) {
        switch feed.state {
        case .closed, .lost: return
        case .starting, .live:
            let before = frame
            let oldLive = Set(before.sessions.filter { !$0.closed }.map(\.name))
            let newLive = Set(next.sessions.filter { !$0.closed }.map(\.name))
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            for name in newLive.subtracting(oldLive) {
                // Existing hook documents are valid on the first connection frame. A reappearance
                // in this connection is a restart and must not inherit the old pane's documents.
                if !initial {
                    firstSeenMs[name] = now
                    generations[name, default: 0] &+= 1
                }
            }
            frame = next
            _ = feed.handle(.frame)
            let snapshot = currentSnapshot()
            let ids = Set(snapshot.agents.map(\.paneID))
            screenVerdicts = screenVerdicts.filter { ids.contains($0.key) }
            detectedAt = detectedAt.filter { ids.contains($0.key) }
            for id in ids where detectedAt[id] == nil { detectedAt[id] = .now }
            var statuses: [String: ZellijResolvedStatus] = [:]
            for pane in snapshot.panes {
                if let id = ZellijPaneID(pane.paneID), let row = record(id) {
                    statuses[pane.terminalID] = resolved(row, id: id)
                }
            }
            overlay.prune(keeping: statuses)
            for event in ZellijEvents.events(
                previous: initial ? nil : before, frame: next, firstSeenMs: firstSeenMs)
            {
                deliver(event)
            }
        }
    }

    func currentSnapshot() -> SessionSnapshot {
        ZellijSnapshotBuilder.snapshot(
            frame: frame, generations: generations, overlays: overlay, screenVerdicts: screenVerdicts,
            firstSeenMs: firstSeenMs, version: version)
    }

    func record(_ id: ZellijPaneID) -> ZellijPaneRecord? {
        ZellijSnapshotBuilder.visiblePanes(frame, session: id.session).first { $0.id == id.pane }
    }

    func resolved(_ row: ZellijPaneRecord, id: ZellijPaneID) -> ZellijResolvedStatus {
        ZellijSnapshotBuilder.status(
            row, document: ZellijSnapshotBuilder.document(for: id, frame: frame, firstSeenMs: firstSeenMs),
            screen: screenVerdicts[id.description])
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        try ensureOpen()
        return currentSnapshot()
    }
    func listAgents() async throws -> [Agent] { try await sessionSnapshot().agents.map(Agent.init) }
    func shellActivities(paneIDs: [String]) async throws -> [String: ShellActivity] {
        try ensureOpen()
        let wanted = Set(paneIDs)
        return ZellijSnapshotBuilder.shellActivities(frame: frame, firstSeenMs: firstSeenMs)
            .filter { wanted.contains($0.key) }
    }

    func ping() async throws -> ServerInfo {
        _ = try await exec(commands.listSessions(), allowsNoSessions: true)
        return ServerInfo(version: version, protocolVersion: 0, backend: .zellij)
    }

    /// The only one-shot command path, under ordinarySession admission. Never retries input.
    @discardableResult
    func exec(
        _ command: String, input: Data = Data(), allowsNoSessions: Bool = false
    ) async throws -> String {
        try ensureOpen()
        let answer = try await session.runExec(command, input: input, timeout: configuration.requestTimeout)
        let output = String(decoding: answer.stdout, as: UTF8.self)
        let error = String(decoding: answer.stderr, as: UTF8.self)
        guard
            answer.exitStatus == 0
                || (allowsNoSessions && answer.exitStatus == 1
                    && (output + error).contains("No active zellij sessions found."))
        else {
            throw HerdrAPIError(code: "zellij_command_failed", message: error.isEmpty ? output : error)
        }
        return output
    }

    @discardableResult
    func exec(_ input: ZellijCommand.InputExec) async throws -> String {
        try await exec(input.command, input: input.input)
    }

    // MARK: Events

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        try ensureOpen()
        guard continuation == nil else { throw TransportError.eventsChannelAlreadyOpen }
        let (events, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(HerdrEventStream.bufferLimit))
        streamID &+= 1
        let id = streamID
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.endEvents(id) } }
        screenPoll = Task { [weak self, interval = configuration.screenInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.pollScreens(stream: id)
            }
        }
        return HerdrEventStream(events: events) { [weak self] in await self?.endEvents(id) }
    }

    private func endEvents(_ id: UInt64) {
        guard streamID == id else { return }
        let previous = continuation
        continuation = nil
        screenPoll?.cancel()
        screenPoll = nil
        resync?.cancel()
        resync = nil
        previous?.finish()
    }

    func deliver(_ event: HerdrEvent) {
        guard continuation != nil else { return }
        if event.kind == ZellijEvents.resync.kind {
            guard resync == nil else { return }
            resync = Task { [weak self, delay = configuration.resyncDebounce, id = streamID] in
                do { try await Task.sleep(for: delay) } catch { return }
                await self?.flushResync(stream: id)
            }
        } else {
            continuation?.yield(event)
        }
    }

    private func flushResync(stream id: UInt64) {
        guard streamID == id else { return }
        resync = nil
        continuation?.yield(ZellijEvents.resync)
    }

    private func pollScreens(stream token: UInt64) async {
        guard streamID == token, continuation != nil else { return }
        let candidates = currentSnapshot().agents.filter { agent in
            guard let kind = agent.agent, TmuxScreenDetector.supports(kind: kind),
                let id = ZellijPaneID(agent.paneID), let row = record(id)
            else { return false }
            return row.rootStatus?.agentStatus == nil
                && ZellijSnapshotBuilder.document(for: id, frame: frame, firstSeenMs: firstSeenMs)?.status
                    == nil
        }
        let eligible = Set(candidates.map(\.paneID))
        screenReadTimes = screenReadTimes.filter { eligible.contains($0.key) }
        let selected = candidates.sorted { lhs, rhs in
            switch (screenReadTimes[lhs.paneID], screenReadTimes[rhs.paneID]) {
            case (nil, nil): return lhs.paneID < rhs.paneID
            case (nil, _): return true
            case (_, nil): return false
            case (let left?, let right?): return left == right ? lhs.paneID < rhs.paneID : left < right
            }
        }.prefix(8)
        let now = ContinuousClock.now
        for agent in selected { screenReadTimes[agent.paneID] = now }
        for agent in selected {
            guard !Task.isCancelled, streamID == token, continuation != nil,
                let id = ZellijPaneID(agent.paneID), let row = record(id),
                let screen = try? await exec(commands.dumpScreen(id))
            else { continue }
            // A hook/report or replacement arriving during dump-screen wins over its stale answer.
            guard !Task.isCancelled, streamID == token, record(id) == row else { continue }
            let status = TmuxScreenDetector.classify(
                kind: agent.agent ?? Agent.unidentifiedKind,
                screen: screen, title: row.title ?? "")
            if screenVerdicts[id.description] != status {
                screenVerdicts[id.description] = status
                deliver(ZellijEvents.resync)
            }
        }
    }
}
