import Foundation
import Synchronization

@testable import Waycar

/// A `TransportConnector` whose Transports share connections through a real
/// `SSHSessionPool`, the way `SSHTransportConnector` shares
/// `HostSSHSession`s (#105). Each Transport is a `ScriptedTransport` holding
/// one hold on its session until it closes. Every dial is counted, so a test
/// can tell a connection the pool handed back from a new one.
final class PoolingTransportConnector: TransportConnector {
    let pool = SSHSessionPool<CountedPooledSession>()
    private let dialed = Mutex<[CountedPooledSession]>([])

    var dials: Int { dialed.withLock { $0.count } }

    func session(number: Int) -> CountedPooledSession? {
        dialed.withLock { $0.indices.contains(number - 1) ? $0[number - 1] : nil }
    }

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        try await connect(settings: settings, backend: .herdr, replacing: nil).transport
    }

    func connect(
        settings: SSHTransportSettings, backend: HostBackend, replacing: PooledConnectionID?
    ) async throws -> SharedTransport {
        let acquired = try await pool.acquire(key: settings.poolKey, replacing: replacing) {
            let session = CountedPooledSession()
            self.dialed.withLock { $0.append(session) }
            return session
        }
        let transport = ScriptedTransport(snapshot: .fixture())
        let session = acquired.session
        await transport.setOnClose { await session.release() }
        return SharedTransport(transport: transport, connection: acquired.id)
    }

    func keepConnection(_ connection: PooledConnectionID) async -> Bool {
        await pool.keep(connection)
    }

    func releaseKeptConnection(_ connection: PooledConnectionID) async {
        await pool.releaseKept(connection)
    }

    func retireConnection(_ connection: PooledConnectionID) async {
        await pool.retire(connection)
    }

    func abandonDial(poolKey: String) async {
        await pool.abandonDial(key: poolKey)
    }
}

/// A pooled connection that counts holds and closes with its last release.
actor CountedPooledSession: SSHPooledSession {
    private(set) var holds = 1
    private(set) var isClosed = false

    var isConnected: Bool { !isClosed }

    func retain() -> Bool {
        guard !isClosed else { return false }
        holds += 1
        return true
    }

    func release() {
        guard holds > 0 else { return }
        holds -= 1
        if holds == 0 { isClosed = true }
    }
}
