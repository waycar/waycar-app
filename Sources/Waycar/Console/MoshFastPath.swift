import Foundation

/// Everything the Console keeps to get an Agent onto mosh fast (#105): what
/// each Host's mosh is known to do on each network, the standbys started
/// ahead of attaches, and the running sessions a network change rebinds.
/// The network path it follows is the app's (`WaycarAppModel` owns it).
///
/// The defaults keep everything in memory and read no network path — what
/// tests and previews want; `live(networkPath:)` is the app's.
@MainActor
final class MoshFastPath {
    let availability: MoshAvailabilityStore
    let standbys: StandbyMoshStore
    /// The app's path monitor, injected. Every consumer subscribes to it
    /// with its own `changes()` stream.
    let networkPath: NetworkPathMonitor
    let sessions: MoshSessionRegistry
    let makeSession: MoshSessionFactory
    /// How often a speculative standby is renewed: well inside both its
    /// usable age (`StandbyMoshStore.maxAge`) and mosh-server's 60 s wait
    /// for a client.
    let speculativeStandbyRefresh: Duration
    /// Told of each settled path change, after mosh sessions were asked to
    /// rebind.
    var networkDidChange: @MainActor (NetworkPathKey?) -> Void = { _ in }
    private var pathChanges: Task<Void, Never>?

    init(
        availability: MoshAvailabilityStore = MoshAvailabilityStore(),
        standbys: StandbyMoshStore = StandbyMoshStore(),
        networkPath: NetworkPathMonitor = NetworkPathMonitor(source: QuietNetworkPathSource()),
        sessions: MoshSessionRegistry = MoshSessionRegistry(),
        speculativeStandbyRefresh: Duration = .seconds(40),
        makeSession: MoshSessionFactory? = nil
    ) {
        self.availability = availability
        self.standbys = standbys
        self.networkPath = networkPath
        self.sessions = sessions
        self.speculativeStandbyRefresh = speculativeStandbyRefresh
        self.makeSession =
            makeSession ?? { bootstrap, cols, rows, firstContactTimeout in
                MoshAttachSession.make(
                    bootstrap: bootstrap, cols: cols, rows: rows,
                    firstContactTimeout: firstContactTimeout, registry: sessions)
            }
    }

    /// The app's: outcomes kept in the backup-excluded Application Support
    /// directory, on the app's network path.
    static func live(networkPath: NetworkPathMonitor) -> MoshFastPath {
        MoshFastPath(
            availability: MoshAvailabilityStore(
                fileURL: MoshAvailabilityStore.applicationSupportFile()),
            networkPath: networkPath)
    }

    /// Starts reading the network path; on every settled change, running
    /// mosh sessions get a fresh UDP flow at once (#105). Idempotent.
    func start() {
        guard pathChanges == nil else { return }
        let changes = networkPath.changes()
        networkPath.start()
        pathChanges = Task { [weak self] in
            for await key in changes {
                guard let self else { return }
                if key != nil {
                    sessions.rebindAll()
                }
                networkDidChange(key)
            }
        }
    }

    /// What the network the device is on now is called, for keying what is
    /// learned there.
    var currentNetwork: NetworkPathKey? {
        networkPath.currentKey
    }

    /// One standby's bootstrap over `session`'s live connection at
    /// `priority` (#105, C-PRIORITY): `.interactive` for a standby an
    /// imminent return waits on, `.normal` for a speculative one. It needs
    /// no terminal lease: nothing attaches until a client uses it.
    nonisolated static func standbyBootstrap(
        over session: EventsSession, priority: TransportPriority,
        _ request: TerminalAttachRequest
    ) -> @Sendable () async throws -> MoshBootstrap {
        {
            try await session.withTransport(priority: priority) { transport in
                try await transport.runMoshBootstrap(request)
            }
        }
    }
}

/// A path source that never reports: the default outside the app, where no
/// network identity is known and nothing is keyed by one.
final class QuietNetworkPathSource: NetworkPathSource {
    func start(_ handler: @escaping @Sendable (NetworkPathSnapshot) -> Void) {}
    func cancel() {}
}

/// One Host backend's view of the fast path, for its terminal runner
/// (`HostConsoleProjection.terminalRunner`). Main-actor state behind async
/// calls, so the runner can ask from anywhere.
@MainActor
final class MoshAttachCoordinator {
    /// How long a standby's server gets to answer its client before the
    /// attach goes the ordinary way.
    nonisolated static let standbyFirstContactTimeout: Duration = .seconds(3)
    /// How long a freshly bootstrapped server gets.
    nonisolated static let firstContactTimeout: Duration = .seconds(6)

    nonisolated let hostID: Host.ID
    nonisolated let backend: HostBackend
    nonisolated let makeSession: MoshSessionFactory
    private let standbys: StandbyMoshStore
    private let available: @MainActor () -> Bool
    private let network: @MainActor () -> NetworkPathKey?
    private let recordOutcome: @MainActor (MoshAvailabilityStore.Outcome, NetworkPathKey?) -> Void
    private let serverHeardAgain: @MainActor () -> Void

    init(
        hostID: Host.ID, backend: HostBackend, fastPath: MoshFastPath,
        available: @escaping @MainActor () -> Bool,
        currentNetwork: @escaping @MainActor () -> NetworkPathKey?,
        recordOutcome: @escaping @MainActor (MoshAvailabilityStore.Outcome, NetworkPathKey?) -> Void,
        serverHeardAgain: @escaping @MainActor () -> Void = {}
    ) {
        self.hostID = hostID
        self.backend = backend
        makeSession = fastPath.makeSession
        standbys = fastPath.standbys
        self.available = available
        network = currentNetwork
        self.recordOutcome = recordOutcome
        self.serverHeardAgain = serverHeardAgain
    }

    /// Whether the Host's mosh is the choice right now.
    func isAvailable() -> Bool {
        available()
    }

    /// A standby for `target` to start the client at, before any SSH.
    func takeStandby(_ target: TerminalAttachTarget) async -> StandbyMosh? {
        await standbys.take(key(target))
    }

    /// A standby if one is there by now; else nil, and the caller's own
    /// bootstrap is registered until `finishBootstrap(_:)`.
    func claimBootstrap(_ target: TerminalAttachTarget) async -> StandbyMosh? {
        await standbys.claimAttachBootstrap(key(target))
    }

    func finishBootstrap(_ target: TerminalAttachTarget) {
        standbys.finishAttachBootstrap(key(target))
    }

    /// The network the device is on now: what a session starting now
    /// measures (#105).
    func currentNetwork() -> NetworkPathKey? {
        network()
    }

    /// What a session's first contact proved about mosh on `network`, the
    /// one it started on.
    func record(_ outcome: MoshAvailabilityStore.Outcome, on network: NetworkPathKey?) {
        recordOutcome(outcome, network)
    }

    /// A running session's server answered again after a stall (#105): the
    /// network is back, so the Host's SSH need not wait out its backoff.
    func serverDidAnswerAfterStall() {
        serverHeardAgain()
    }

    private func key(_ target: TerminalAttachTarget) -> StandbyMoshStore.Key {
        StandbyMoshStore.Key(hostID: hostID, backend: backend, target: target)
    }
}
