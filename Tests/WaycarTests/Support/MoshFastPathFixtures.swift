import Foundation
import Synchronization
import Testing

@testable import Waycar

/// Network path readings a test hands a `NetworkPathMonitor` (#105).
final class ScriptedNetworkPathSource: NetworkPathSource {
    private let handler = Mutex<(@Sendable (NetworkPathSnapshot) -> Void)?>(nil)

    func start(_ handler: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        self.handler.withLock { $0 = handler }
    }

    func cancel() {}

    func read(_ snapshot: NetworkPathSnapshot) {
        handler.withLock { $0 }?(snapshot)
    }

    static let home = NetworkPathSnapshot(
        isSatisfied: true, interface: .wifi, interfaceName: "en0", localAddress: "192.168.1.20")
    static let cafe = NetworkPathSnapshot(
        isSatisfied: true, interface: .wifi, interfaceName: "en0", localAddress: "10.0.7.33")

    /// A monitor over this source that settles every change at once.
    func monitor() -> NetworkPathMonitor {
        NetworkPathMonitor(source: self, debounce: .zero, sleep: { _ in })
    }

    /// A monitor whose readings never settle within a test: `currentKey`
    /// follows each one, but `changes()` reports nothing, as with a blip
    /// shorter than the debounce.
    func unsettledMonitor() -> NetworkPathMonitor {
        NetworkPathMonitor(
            source: self, debounce: .milliseconds(300),
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
    }
}

/// Background time the test grants, reclaims and reports (#105).
@MainActor
final class ScriptedBackgroundGranter: BackgroundExecutionGranting {
    var timeRemaining: Duration = .seconds(10)
    private var live: [BackgroundExecutionToken: @MainActor @Sendable () -> Void] = [:]
    private var nextRawValue = 1

    var backgroundTimeRemaining: Duration { timeRemaining }

    func begin(
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken? {
        let token = BackgroundExecutionToken(rawValue: nextRawValue)
        nextRawValue += 1
        live[token] = onExpiration
        return token
    }

    func end(_ token: BackgroundExecutionToken) {
        live[token] = nil
    }

    /// The system reclaiming its background time.
    func expireAll() {
        for handler in live.values { handler() }
    }
}

/// The connections a Host makes, in order (the last one serves every later
/// attempt); a gated attempt waits for its gate first.
actor ScriptedHostConnections {
    private var transports: [ScriptedTransport]
    private let gates: [Int: ScriptedTransportCallGate]
    private(set) var attempts = 0
    private var unreachable = false

    init(_ transports: [ScriptedTransport], gating gates: [Int: ScriptedTransportCallGate] = [:]) {
        self.transports = transports
        self.gates = gates
    }

    /// Whether every later attempt finds no route to the Host.
    func setUnreachable(_ unreachable: Bool) {
        self.unreachable = unreachable
    }

    func connect() async throws -> any Transport {
        attempts += 1
        if let gate = gates[attempts] { await gate.waitUntilOpen() }
        if unreachable { throw TransportError.sshUnreachable(detail: "no route to host") }
        guard let first = transports.first else {
            throw TransportError.sshUnreachable(detail: "no scripted connection")
        }
        if transports.count > 1 { transports.removeFirst() }
        return first
    }
}

/// A mutable clock for `StandbyMoshStore` ages.
@MainActor
final class StandbyClock {
    var now = ContinuousClock.now

    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
    }
}

/// One Host's Console wired to scripted connections and scripted mosh
/// sessions through a test `MoshFastPath` (#105): the attach path runs for
/// real down to `MoshSessionFactory`, with no UDP and no SSH.
@MainActor
final class MoshFlowFixture {
    nonisolated static let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))
    nonisolated static let attachBootstrap = MoshBootstrap(
        host: "203.0.113.7", udpPort: "60001", key: "MDEyMzQ1Njc4OWFiY2RlZg")
    nonisolated static let standbyBootstrap = MoshBootstrap(
        host: "203.0.113.7", udpPort: "60002", key: "QUJDREVGR0hJSktMTU5PUA")
    nonisolated static let laterBootstrap = MoshBootstrap(
        host: "203.0.113.7", udpPort: "60003", key: "cXJzdHV2d3h5ejAxMjM0NQ")

    let host: Host
    let connections: ScriptedHostConnections
    let mosh = ScriptedMoshSessions()
    let path = ScriptedNetworkPathSource()
    let fastPath: MoshFastPath
    let console: ConsoleStore

    init(
        host: Host = .fixture(),
        transports: [ScriptedTransport],
        gating gates: [Int: ScriptedTransportCallGate] = [:],
        availability: MoshAvailabilityStore = MoshAvailabilityStore(),
        standbys: StandbyMoshStore = StandbyMoshStore(),
        gridSizes: TerminalGridSizeMemory? = nil,
        speculativeStandbyRefresh: Duration = .seconds(40),
        presence: HostBackendPresence = .herdrOnly,
        pathSettles: Bool = true,
        reconnectPolicy: ReconnectPolicy = MoshFlowFixture.fastPolicy
    ) {
        self.host = host
        let connections = ScriptedHostConnections(transports, gating: gates)
        self.connections = connections
        fastPath = MoshFastPath(
            availability: availability, standbys: standbys,
            networkPath: pathSettles ? path.monitor() : path.unsettledMonitor(),
            speculativeStandbyRefresh: speculativeStandbyRefresh,
            makeSession: mosh.factory)
        let defaults = UserDefaults(suiteName: "mosh-flow-\(UUID().uuidString)") ?? .standard
        let makeSession: @Sendable (Host, HostBackend, [EventSubscription]) -> EventsSession = {
            _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { try await connections.connect() },
                reconnectPolicy: reconnectPolicy,
                keepalive: nil)
        }
        console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            chatMode: ChatModeStore(defaults: defaults),
            rowLayouts: AgentRowLayoutStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            makeSession: makeSession,
            detectBackends: { _ in presence })
        console.agentTerminals.gridSizes = gridSizes
        console.installMoshFastPath(fastPath)
    }

    /// Connects the Host and waits for its rows.
    func start(expectingAgents count: Int = 1) async throws {
        console.setHosts([host])
        await console.resume()
        try await pollUntil("the Host's Agents should arrive") { console.agents.count == count }
    }

    /// Connects the Host and waits for its connect-time probe to prove mosh.
    func startOnMosh(expectingAgents count: Int = 1) async throws {
        try await start(expectingAgents: count)
        try await pollUntil("the probe should prove mosh") {
            console.moshProbe(for: host.id)?.available == true
        }
    }

    func agent(_ paneID: String = "w1:p1") throws -> ConsoleAgent {
        try #require(console.agents.first { $0.agent.paneID == paneID })
    }

    func key(_ paneID: String = "w1:p1", backend: HostBackend = .herdr) -> StandbyMoshStore.Key {
        StandbyMoshStore.Key(hostID: host.id, backend: backend, target: .agentPane(paneID))
    }

    /// Opens the Agent's detail the way the Console does, in a window of
    /// `windowLayout`, with the view's first size report unless
    /// `reportingSize` is false.
    func open(
        _ agent: ConsoleAgent, reportingSize: Bool = true,
        windowLayout: TerminalGridSizeMemory.Layout? = nil
    ) -> AgentTerminalCache.Entry {
        let entry = console.agentTerminals.acquire(
            agent: agent, console: console, composer: console.composerStore(for: agent),
            ownerID: UUID(), windowLayout: { windowLayout })
        if reportingSize { entry.attach.viewDidResize(cols: 80, rows: 24) }
        return entry
    }

    /// Opens the Agent and paints its first mosh frame: a live mosh terminal.
    func openLiveMosh(_ paneID: String = "w1:p1") async throws -> AgentTerminalCache.Entry {
        let made = mosh.sessions.count
        let entry = open(try agent(paneID))
        try await pollUntil("the mosh session should start") { mosh.sessions.count == made + 1 }
        try #require(mosh.sessions.count > made)
        mosh.sessions[made].emit("\u{1B}[H$ ready")
        try await pollUntil("the mosh terminal should go live") {
            entry.attach.terminalStatus == .live && entry.attach.terminalRunsLiveMosh
        }
        return entry
    }

    func tearDown() async {
        console.setHosts([])
        await console.agentTerminals.suspend()
    }
}

/// Polls until `condition` holds, yielding so the stores' tasks progress.
@MainActor
func pollUntil(
    _ comment: Comment, timeout: Duration = .waitCeiling,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await condition(), comment, sourceLocation: sourceLocation)
}
