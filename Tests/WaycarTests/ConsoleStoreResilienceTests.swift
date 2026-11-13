import Foundation
import Synchronization
import Testing

@testable import Waycar

/// The Console's side of keeping Host connections alive (#105). The
/// production session factory keeps each Host's pooled connection across a
/// suspension. The app's network path monitor re-proves every connected
/// Host on a path change and cuts reconnects short when a path comes back.
@MainActor
@Suite("Console store resilience", .timeLimit(.minutes(1)))
struct ConsoleStoreResilienceTests {
    private nonisolated static let fastReconnect = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    /// Through the production factory and a real pool: the suspension
    /// closes the Host's Transport but not its connection, and the return
    /// rides that connection with no dial.
    @Test func suspensionKeepsTheHostsConnectionAndTheReturnRidesItWithoutADial() async throws {
        let host = Host.fixture()
        let knownHosts = InMemoryKnownHostsStore()
        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: Data("host-key".utf8)),
            host: host.address, port: host.port)
        let connector = PoolingTransportConnector()
        let trustHolds = HostKeyTrustHoldReporter()
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            makeSession: ConsoleStore.sshSessionFactory(
                connector: connector,
                knownHosts: knownHosts,
                credentials: HostCredentialsProvider(
                    deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                    rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                    secrets: InMemorySecretStore()),
                trustPollInterval: .milliseconds(10),
                trustHolds: trustHolds),
            trustHolds: trustHolds)
        defer { store.setHosts([]) }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(connector.dials == 1)
        let connection = try #require(connector.session(number: 1))

        await store.suspend()
        try await waitUntil("the Host should suspend") {
            store.hostStatuses[host.id] == .suspended
        }
        // Its Transport let go; the keep alone holds the connection open.
        #expect(await connection.holds == 1)
        #expect(await !connection.isClosed)

        await store.reactivate()
        try await waitUntil("the Host should come back") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(connector.dials == 1)
        // The returning Transport holds it now; the keep's hold went back.
        try await waitUntil("only the returning Transport should hold it") {
            await connection.holds == 1
        }
        #expect(await !connection.isClosed)
    }

    @Test func aNewNetworkPathReprovesEveryConnectedHost() async throws {
        let hosts = [Host.fixture(), Host.fixture()]
        let transports = Dictionary(
            uniqueKeysWithValues: hosts.map { ($0.id, ScriptedTransport(snapshot: .fixture())) })
        let store = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) {
            host, _, subscriptions in
            let transport = transports[host.id]!
            return EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: Self.fastReconnect,
                keepalive: nil)
        }
        defer { store.setHosts([]) }
        store.setHosts(hosts)
        await store.resume()
        try await waitUntil("both Hosts should connect") {
            hosts.allSatisfy { store.hostStatuses[$0.id] == .connected }
        }
        let (monitor, source) = Self.makeMonitor()
        store.followNetworkPath(monitor)
        source.read(Self.wifi)

        source.read(Self.cellular)
        for host in hosts {
            let transport = transports[host.id]!
            try await waitUntil("every connected Host should be re-proved") {
                await transport.revalidateCount == 1
            }
        }
        #expect(hosts.allSatisfy { store.hostStatuses[$0.id] == .connected })
    }

    @Test func aPathBackAfterNoneRedialsAHostWaitingOutItsBackoff() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let dials = FailingFirstDial(transport)
        let store = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { try await dials.dial() },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .seconds(60), multiplier: 2, maxDelay: .seconds(60)),
                keepalive: nil)
        }
        defer { store.setHosts([]) }
        let (monitor, source) = Self.makeMonitor()
        let observed = monitor.changes()
        store.followNetworkPath(monitor)
        source.read(Self.wifi)
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should be waiting out a long backoff") {
            if case .reconnecting = store.hostStatuses[host.id] { true } else { false }
        }

        source.read(Self.offline)
        var changes = observed.makeAsyncIterator()
        #expect(await changes.next() == .some(nil))
        source.read(Self.wifi)
        try await waitUntil("the path back should redial at once") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(await dials.count == 2)
    }

    /// A slow revalidate must not hold the path loop: the stream keeps only
    /// the newest unread change, so a none read late is replaced by the
    /// path's return and the redial it calls for is lost.
    @Test func aSlowRevalidateDoesNotSwallowAPathBackAfterNone() async throws {
        let connected = Host.fixture()
        let waiting = Host.fixture()
        let live = ScriptedTransport(snapshot: .fixture())
        let dials = FailingFirstDial(ScriptedTransport(snapshot: .fixture()))
        let store = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { host, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    if host.id == connected.id { return live }
                    return try await dials.dial()
                },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .seconds(60), multiplier: 2, maxDelay: .seconds(60)),
                keepalive: nil)
        }
        defer { store.setHosts([]) }
        let (monitor, source) = Self.makeMonitor()
        let observed = monitor.changes()
        var changes = observed.makeAsyncIterator()
        monitor.start()
        // The baseline: the store follows from a known path, so the first
        // change is no return after none.
        source.read(Self.wifi)
        store.followNetworkPath(monitor)
        store.setHosts([connected, waiting])
        await store.resume()
        try await waitUntil("one Host connected, the other in a long backoff") {
            guard store.hostStatuses[connected.id] == .connected else { return false }
            if case .reconnecting = store.hostStatuses[waiting.id] { return true }
            return false
        }
        // Let the connect's own follow-up work settle so the gate holds the
        // path change's revalidate and nothing else.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await dials.count == 1, "the second Host is still waiting out its backoff")
        let ping = ScriptedTransportCallGate()
        await live.gateNextPing(using: ping)

        source.read(Self.cellular)
        #expect(await changes.next() == .some(Self.cellular.key))
        await ping.waitForEntry()
        #expect(await live.revalidateCount == 1, "the gate holds the path change's revalidate")
        source.read(Self.offline)
        #expect(await changes.next() == .some(nil))
        try await Task.sleep(for: .milliseconds(100))
        source.read(Self.wifi)
        try await waitUntil("the path back should redial at once") {
            store.hostStatuses[waiting.id] == .connected
        }
        #expect(await dials.count == 2)
        await ping.open()
    }

    /// CONSOLE-01: the baseline reading seeds the offline flag but is no
    /// change: it re-proves nothing. The path's return is one, and it
    /// re-proves the connected Host.
    @Test func aBaselineWithNoPathIsOfflineAtOnceAndItsReturnReprovesTheHost() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions, connect: { transport },
                reconnectPolicy: Self.fastReconnect, keepalive: nil)
        }
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(store.hasNetwork)
        let (monitor, source) = Self.makeMonitor()
        store.followNetworkPath(monitor)
        source.read(Self.offline)
        try await waitUntil("the baseline should say offline") { !store.hasNetwork }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.revalidateCount == 0)

        source.read(Self.wifi)
        try await waitUntil("the path back should re-prove the Host") {
            let reproved = await transport.revalidateCount == 1
            return reproved && store.hasNetwork
        }
        #expect(store.hostStatuses[host.id] == .connected)
    }

    /// CONSOLE-01: a path change while the Console is suspended re-proves
    /// nothing; the return does that.
    @Test func aPathChangeWhileSuspendedReprovesNothing() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions, connect: { transport },
                reconnectPolicy: Self.fastReconnect, keepalive: nil)
        }
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }
        let (monitor, source) = Self.makeMonitor()
        store.followNetworkPath(monitor)
        source.read(Self.wifi)
        await store.suspend()
        #expect(!store.isActive)
        source.read(Self.cellular)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await transport.revalidateCount == 0)
        #expect(store.hasNetwork)
    }

    // MARK: Helpers

    private static let wifi = NetworkPathSnapshot(
        isSatisfied: true, interface: .wifi, interfaceName: "en0", localAddress: "192.168.1.20")
    private static let cellular = NetworkPathSnapshot(
        isSatisfied: true, interface: .cellular, interfaceName: "pdp_ip0",
        localAddress: "10.20.30.40")
    private static let offline = NetworkPathSnapshot(
        isSatisfied: false, interface: nil, interfaceName: nil, localAddress: nil)

    /// A monitor whose readings settle at once.
    private static func makeMonitor() -> (NetworkPathMonitor, ScriptedPathSource) {
        let source = ScriptedPathSource()
        return (NetworkPathMonitor(source: source, debounce: .zero, sleep: { _ in }), source)
    }
}

/// Readings the test hands the monitor.
private final class ScriptedPathSource: NetworkPathSource {
    private let handler = Mutex<(@Sendable (NetworkPathSnapshot) -> Void)?>(nil)

    func start(_ handler: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        self.handler.withLock { $0 = handler }
    }

    func cancel() {}

    func read(_ snapshot: NetworkPathSnapshot) {
        handler.withLock { $0 }?(snapshot)
    }
}

/// A Host with no route at first: the first dial fails, every later one
/// connects.
private actor FailingFirstDial {
    private let transport: ScriptedTransport
    private(set) var count = 0

    init(_ transport: ScriptedTransport) {
        self.transport = transport
    }

    func dial() throws -> any Transport {
        count += 1
        guard count > 1 else {
            throw TransportError.sshUnreachable(detail: "no route to host")
        }
        return transport
    }
}
