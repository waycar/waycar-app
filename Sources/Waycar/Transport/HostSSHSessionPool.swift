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
actor SSHSessionPool<Session: SSHPooledSession> {
    typealias Dial = @Sendable () async throws -> Session

    /// A session handed out, held once for the caller, with the pooled
    /// connection it is; nil for a private (nil-key) dial.
    struct Acquired: Sendable {
        let session: Session
        let id: PooledConnectionID?
    }

    private struct Entry {
        let session: Session
        let serial: UInt64
    }

    private struct PendingDial {
        let id: UInt64
        let task: Task<Void, Never>
        /// The serial of the live connection this dial replaces, if one
        /// asked for a replacement.
        let replaces: UInt64?
        var waiters: [UInt64: CheckedContinuation<Acquired, any Error>]
    }

    private var live: [String: Entry] = [:]
    /// Connections held open across a suspension, one hold each (`keep`).
    private var kept: [String: Entry] = [:]
    /// A replacement that finished dialing while the connection it replaces
    /// was still live: it is shared only once that one is retired, since
    /// the one it replaces may still prove itself.
    private var replacements: [String: Entry] = [:]
    private var dials: [String: PendingDial] = [:]
    /// Dials new acquirers no longer join (`abandonDial`), by dial id. Each
    /// still serves the waiters it has and is cancelled when they leave.
    private var abandoned: [UInt64: (key: String, dial: PendingDial)] = [:]
    private var nextID: UInt64 = 0

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
        while let entry = live[key], entry.serial != staleSerial {
            if await entry.session.isConnected, await entry.session.retain() {
                return Acquired(session: entry.session, id: id(key, entry))
            }
            if live[key]?.serial == entry.serial { live[key] = nil }
        }
        if staleSerial != nil, let replacement = replacements[key],
            await replacement.session.isConnected, await replacement.session.retain()
        {
            return Acquired(session: replacement.session, id: id(key, replacement))
        }
        let replaces = staleSerial.flatMap { live[key]?.serial == $0 ? $0 : nil }
        nextID &+= 1
        let waiterID = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: TransportError.cancelled)
                    return
                }
                enqueue(
                    key: key, waiterID: waiterID, continuation: continuation,
                    replaces: replaces, dial: dial)
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
        if kept[key]?.serial == connection.serial { return true }
        guard let entry = live[key], entry.serial == connection.serial,
            await entry.session.retain()
        else { return false }
        guard live[key]?.serial == entry.serial else {
            // Retired while retain was in flight: do not restore its keep.
            await entry.session.release()
            return false
        }
        if kept[key]?.serial == connection.serial {
            // Another keep won while this one retained: one hold is enough.
            await entry.session.release()
            return true
        }
        if let previous = kept.updateValue(entry, forKey: key) {
            Task { await previous.session.release() }
        }
        return true
    }

    /// `keep`'s hold goes back: the kept connection answered, and the
    /// Transport that proved it holds it now. A replacement dialed for it
    /// meanwhile is never shared.
    func releaseKept(_ connection: PooledConnectionID) {
        let key = connection.key
        guard let entry = kept[key], entry.serial == connection.serial else { return }
        kept[key] = nil
        if live[key]?.serial == connection.serial { replacements[key] = nil }
        Task { await entry.session.release() }
    }

    /// Stops sharing `connection`: its user found it dead. A replacement
    /// already dialed for it becomes the key's live connection; otherwise
    /// the next acquire dials. Holders keep the retired session until they
    /// release it, and `keep`'s hold on it goes back. Nothing here waits for
    /// a close.
    func retire(_ connection: PooledConnectionID) async {
        let key = connection.key
        if let entry = kept[key], entry.serial == connection.serial {
            kept[key] = nil
            Task { await entry.session.release() }
        }
        guard live[key]?.serial == connection.serial else { return }
        live[key] = nil
        guard let replacement = replacements.removeValue(forKey: key),
            await replacement.session.isConnected, live[key] == nil
        else { return }
        live[key] = replacement
    }

    /// New acquirers of `key` no longer join the dial in flight: the network
    /// path it started on went away, and it may sit retrying a SYN there.
    /// It goes on for the waiters it has, and is cancelled once they leave.
    func abandonDial(key: String) {
        guard let pending = dials.removeValue(forKey: key) else { return }
        abandoned[pending.id] = (key, pending)
    }

    private func id(_ key: String, _ entry: Entry) -> PooledConnectionID {
        PooledConnectionID(key: key, serial: entry.serial)
    }

    private func enqueue(
        key: String,
        waiterID: UInt64,
        continuation: CheckedContinuation<Acquired, any Error>,
        replaces: UInt64?,
        dial: @escaping Dial
    ) {
        if var pending = dials[key] {
            pending.waiters[waiterID] = continuation
            dials[key] = pending
            return
        }
        nextID &+= 1
        let dialID = nextID
        let task = Task {
            let result: Result<Session, any Error>
            do {
                result = .success(try await dial())
            } catch {
                result = .failure(error)
            }
            await self.dialFinished(key: key, dialID: dialID, result: result)
        }
        dials[key] = PendingDial(
            id: dialID, task: task, replaces: replaces, waiters: [waiterID: continuation])
    }

    private func dialFinished(
        key: String, dialID: UInt64, result: Result<Session, any Error>
    ) async {
        var finished: PendingDial?
        if let pending = dials[key], pending.id == dialID {
            dials[key] = nil
            finished = pending
        } else if let orphan = abandoned.removeValue(forKey: dialID) {
            finished = orphan.dial
        }
        let waiters = finished.map { Array($0.waiters.values) } ?? []
        switch result {
        case .failure(let error):
            for waiter in waiters { waiter.resume(throwing: error) }
        case .success(let session):
            guard !waiters.isEmpty else {
                // Every waiter gave up; nobody takes the dial's hold.
                await session.release()
                return
            }
            nextID &+= 1
            let entry = Entry(session: session, serial: nextID)
            if let replaces = finished?.replaces, live[key]?.serial == replaces {
                replacements[key] = entry
            } else if let current = live[key], await current.session.isConnected {
                // A later dial got there first (this one was abandoned): it
                // stays the shared one, and these waiters keep their own.
            } else {
                live[key] = entry
            }
            // The dial's own hold goes to the first waiter; one more each.
            var holders = 1
            while holders < waiters.count, await session.retain() {
                holders += 1
            }
            for (index, waiter) in waiters.enumerated() {
                if index < holders {
                    waiter.resume(returning: Acquired(session: session, id: id(key, entry)))
                } else {
                    waiter.resume(throwing: TransportError.sshUnreachable(
                        detail: "the SSH connection closed"))
                }
            }
        }
    }

    private func cancelWaiter(key: String, waiterID: UInt64) {
        if var pending = dials[key], let waiter = pending.waiters.removeValue(forKey: waiterID) {
            waiter.resume(throwing: TransportError.cancelled)
            if pending.waiters.isEmpty {
                dials[key] = nil
                pending.task.cancel()
            } else {
                dials[key] = pending
            }
            return
        }
        for (dialID, orphan) in abandoned where orphan.key == key {
            var pending = orphan.dial
            guard let waiter = pending.waiters.removeValue(forKey: waiterID) else { continue }
            waiter.resume(throwing: TransportError.cancelled)
            if pending.waiters.isEmpty {
                abandoned[dialID] = nil
                pending.task.cancel()
            } else {
                abandoned[dialID] = (key, pending)
            }
            return
        }
    }

#if DEBUG
    /// Acquirers waiting on the dial in flight for `key`.
    func waiterCountForTesting(key: String) -> Int {
        dials[key]?.waiters.count ?? 0
    }
#endif
}
