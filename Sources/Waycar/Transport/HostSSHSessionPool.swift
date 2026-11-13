import Foundation

/// A shareable SSH session as `SSHSessionPool` sees it: held once by whoever
/// dialed it, closed with its last `release()`.
protocol SSHPooledSession: AnyObject, Sendable {
    var isConnected: Bool { get async }
    /// One more hold; false once the session has closed.
    func retain() async -> Bool
    func release() async
}

extension HostSSHSession: SSHPooledSession {}

/// One pooled connection: its pool key and the serial the pool gave it when
/// it was dialed. A later call names exactly that connection, never a
/// successor dialed under the same key.
struct PooledConnectionID: Hashable, Sendable {
    let key: String
    let serial: UInt64
}

/// The app's one place Host connections are shared (ADR 0026, design §4.1):
/// herdr's and tmux's Transports for one Host acquire the same
/// `HostSSHSession`, so the Host is dialed once and its channels share one
/// admission budget.
final class HostSSHSessionPool: Sendable {
    static let shared = HostSSHSessionPool(dialer: { settings in
        try await HostSSHSession.dial(settings: settings)
    })

    private let sessions: SSHSessionPool<HostSSHSession>
    private let dialer: @Sendable (SSHTransportSettings) async throws -> HostSSHSession

    init(dialer: @escaping @Sendable (SSHTransportSettings) async throws -> HostSSHSession) {
        sessions = SSHSessionPool()
        self.dialer = dialer
    }

    /// The live session for `settings.poolKey`, held once for the caller,
    /// who releases it with `HostSSHSession.release()`. A nil key always
    /// dials a private session.
    func acquire(settings: SSHTransportSettings) async throws -> HostSSHSession {
        try await acquire(settings: settings, replacing: nil).session
    }

    /// `acquire(settings:)`, naming the pooled connection it hands out. See
    /// `SSHSessionPool.acquire(key:replacing:dial:)` for `replacing`.
    func acquire(
        settings: SSHTransportSettings, replacing: PooledConnectionID?
    ) async throws -> SSHSessionPool<HostSSHSession>.Acquired {
        let dialer = dialer
        return try await sessions.acquire(key: settings.poolKey, replacing: replacing) {
            try await dialer(settings)
        }
    }

    func keep(_ connection: PooledConnectionID) async -> Bool {
        await sessions.keep(connection)
    }

    func releaseKept(_ connection: PooledConnectionID) async {
        await sessions.releaseKept(connection)
    }

    func retire(_ connection: PooledConnectionID) async {
        await sessions.retire(connection)
    }

    func abandonDial(key: String) async {
        await sessions.abandonDial(key: key)
    }
}

/// Single-flight sharing of sessions by key. Every `acquire` is one hold on
/// the session it returns. Concurrent acquirers of a key share one dial; a
/// session that is no longer connected is replaced on the next acquire,
/// while its remaining holders keep it until they release.
///
/// A dial nobody waits for any more is cancelled, and a session it still
/// produces is released at once.
///
/// Across an app suspension (#105) a connection can be kept open with no
/// Transport on it (`keep`), so the return probes it instead of dialing. A
/// connection that does not answer is replaced by a hedged dial
/// (`acquire(key:replacing:dial:)`) and stops being shared once its user
/// gives up on it (`retire`).
///
/// Which connection is live, kept or a hedge, and the dials and their
/// waiters, are `SessionPoolMachine`'s; the pool performs the probes,
/// retains, releases and dials, and keeps the waiters' continuations and the
/// dial Tasks by id.
actor SSHSessionPool<Session: SSHPooledSession> {
    typealias Dial = @Sendable () async throws -> Session
    private typealias Machine = SessionPoolMachine<Session>

    /// A session handed out, held once for the caller, with the pooled
    /// connection it is; nil for a private (nil-key) dial.
    struct Acquired: Sendable {
        let session: Session
        let id: PooledConnectionID?
    }

    private var machine = Machine()
    private var waiters: [UInt64: CheckedContinuation<Acquired, any Error>] = [:]
    private var dialTasks: [UInt64: Task<Void, Never>] = [:]

    init() {}

    func acquire(key: String?, dial: @escaping Dial) async throws -> Session {
        try await acquire(key: key, replacing: nil, dial: dial).session
    }

    /// The live session for `key`, held once for the caller. `replacing`
    /// names a connection its caller found unanswered: that one is never
    /// handed out again here. The caller gets the replacement someone
    /// already made, or else a new dial. That dial is shared only once the
    /// replaced connection is retired, because the probe of the replaced
    /// connection may still answer.
    func acquire(
        key: String?, replacing stale: PooledConnectionID?, dial: @escaping Dial
    ) async throws -> Acquired {
        guard let key else { return Acquired(session: try await dial(), id: nil) }
        let staleSerial = stale?.key == key ? stale?.serial : nil
        var step = machine.handle(.lookUp(key: key, stale: staleSerial))
        while let effect = step.first {
            switch effect {
            case .probeLive(let entry):
                let retained = await Self.probe(entry.session)
                step = machine.handle(
                    .liveProbed(key: key, entry, retained: retained, stale: staleSerial))
            case .probeReplacement(let entry):
                let retained = await Self.probe(entry.session)
                step = machine.handle(
                    .replacementProbed(key: key, entry, retained: retained, stale: staleSerial))
            case .handOut(let entry):
                return Acquired(session: entry.session, id: id(key, entry))
            case .wait(let waiterID):
                return try await wait(
                    key: key, waiterID: waiterID, stale: staleSerial, dial: dial)
            default:
                step.removeFirst()
            }
        }
        throw TransportError.cancelled
    }

    /// Connected, and one more hold taken.
    private static func probe(_ session: Session) async -> Bool {
        guard await session.isConnected else { return false }
        return await session.retain()
    }

    private func wait(
        key: String, waiterID: UInt64, stale: UInt64?, dial: @escaping Dial
    ) async throws -> Acquired {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: TransportError.cancelled)
                    return
                }
                waiters[waiterID] = continuation
                for effect in machine.handle(.join(key: key, waiter: waiterID, stale: stale)) {
                    if case .startDial(let dialID) = effect {
                        startDial(key: key, dialID: dialID, dial: dial)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, waiterID: waiterID) }
        }
    }

    /// Holds `connection` open while no Transport rides it, so closing every
    /// Transport for a suspension leaves it up. False when it is no longer
    /// the key's live connection or has closed. Idempotent; a key keeps at
    /// most one connection.
    func keep(_ connection: PooledConnectionID) async -> Bool {
        let key = connection.key
        var step = machine.handle(.keep(key: key, serial: connection.serial))
        while let effect = step.first {
            step.removeFirst()
            switch effect {
            case .retainForKeep(let entry):
                let retained = await entry.session.retain()
                step = machine.handle(.keepRetained(key: key, entry, retained: retained))
            case .release(let entry):
                await entry.session.release()
            case .releaseLater(let entry):
                Task { await entry.session.release() }
            case .keepAnswered(let kept):
                return kept
            default:
                continue
            }
        }
        return false
    }

    /// `keep`'s hold goes back: the kept connection answered, and the
    /// Transport that proved it holds it now. A replacement dialed for it
    /// meanwhile is never shared.
    func releaseKept(_ connection: PooledConnectionID) {
        for case .releaseLater(let entry) in machine.handle(
            .releaseKept(key: connection.key, serial: connection.serial))
        {
            Task { await entry.session.release() }
        }
    }

    /// Stops sharing `connection`: its user found it dead. A replacement
    /// already dialed for it becomes the key's live connection; otherwise
    /// the next acquire dials. Holders keep the retired session until they
    /// release it, and `keep`'s hold on it goes back. Nothing here waits for
    /// a close.
    func retire(_ connection: PooledConnectionID) async {
        let key = connection.key
        for effect in machine.handle(.retire(key: key, serial: connection.serial)) {
            switch effect {
            case .releaseLater(let entry):
                Task { await entry.session.release() }
            case .checkReplacement(let replacement):
                let connected = await replacement.session.isConnected
                _ = machine.handle(
                    .replacementChecked(key: key, replacement, connected: connected))
            default:
                continue
            }
        }
    }

    /// New acquirers of `key` no longer join the dial in flight: the network
    /// path it started on went away, and it may sit retrying a SYN there.
    /// It goes on for the waiters it has, and is cancelled once they leave.
    func abandonDial(key: String) {
        _ = machine.handle(.abandonDial(key: key))
    }

    private func id(_ key: String, _ entry: Machine.Entry) -> PooledConnectionID {
        PooledConnectionID(key: key, serial: entry.serial)
    }

    private func startDial(key: String, dialID: UInt64, dial: @escaping Dial) {
        dialTasks[dialID] = Task {
            let result: Result<Session, any Error>
            do {
                result = .success(try await dial())
            } catch {
                result = .failure(error)
            }
            await self.dialFinished(key: key, dialID: dialID, result: result)
        }
    }

    private func dialFinished(
        key: String, dialID: UInt64, result: Result<Session, any Error>
    ) async {
        dialTasks[dialID] = nil
        let session = try? result.get()
        var step = machine.handle(.dialEnded(key: key, dial: dialID, session: session))
        while let effect = step.first {
            step.removeFirst()
            switch effect {
            case .failWaiters(let ids):
                guard case .failure(let error) = result else { continue }
                for id in ids { waiters.removeValue(forKey: id)?.resume(throwing: error) }
            case .releaseUnclaimed:
                // Every waiter gave up; nobody takes the dial's hold.
                await session?.release()
            case .checkCurrent(let current, let entry, let ids):
                let connected = await current.session.isConnected
                step = machine.handle(
                    .currentChecked(key: key, placing: entry, waiters: ids, connected: connected))
            case .distribute(let entry, let ids):
                await distribute(entry, key: key, to: ids)
            default:
                continue
            }
        }
    }

    /// The dial's own hold goes to the first waiter; one more each.
    private func distribute(_ entry: Machine.Entry, key: String, to ids: [UInt64]) async {
        let waiting = ids.compactMap { waiters.removeValue(forKey: $0) }
        var holders = 1
        while holders < waiting.count, await entry.session.retain() {
            holders += 1
        }
        for (index, waiter) in waiting.enumerated() {
            if index < holders {
                waiter.resume(returning: Acquired(session: entry.session, id: id(key, entry)))
            } else {
                waiter.resume(throwing: TransportError.sshUnreachable(
                    detail: "the SSH connection closed"))
            }
        }
    }

    private func cancelWaiter(key: String, waiterID: UInt64) {
        for effect in machine.handle(.cancelWaiter(key: key, waiter: waiterID)) {
            switch effect {
            case .cancelWaiter(let id):
                waiters.removeValue(forKey: id)?.resume(throwing: TransportError.cancelled)
            case .cancelDial(let id):
                dialTasks.removeValue(forKey: id)?.cancel()
            default:
                continue
            }
        }
    }

#if DEBUG
    /// Acquirers waiting on the dial in flight for `key`.
    func waiterCountForTesting(key: String) -> Int {
        machine.waiterCount(key: key)
    }
#endif
}
