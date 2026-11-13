import Foundation
import Synchronization

/// Separates OpenSSH forwarding and session admission while enforcing one
/// finite ceiling over every live SSH channel on a Host connection.
///
/// Session categories leave headroom under sshd's default `MaxSessions` of 10
/// (ADR 0011). That server-side limit is the real binding constraint for exec,
/// PTY, and SFTP channels, and the app cannot observe it: an abandoned channel
/// teardown still releases the app admission lease unconditionally, while the
/// server session slot can remain occupied (#148). App counters and
/// `isConnected` may therefore still look available after the server has
/// already spent the slot; they cannot promise MaxSessions safety.
actor SSHChannelAdmission {
    enum ChannelClass: Sendable {
        case ordinaryForwarding
        case events
        case ordinarySession
        case attach
        /// The long-lived, non-PTY exec channel tmux control mode runs on
        /// (ADR 0026). It is a session channel taken out of the ordinary
        /// session budget: while one is held, `ordinarySession` admits one
        /// fewer.
        case control
        /// The long-lived, non-PTY exec channel herdr-core's framed
        /// connection runs on (ADR 0031). Like `control` it is a session
        /// channel taken out of the ordinary session budget, and it has its
        /// own class so a Host running core and tmux together opens both
        /// without either waiting for the other.
        case core
        /// One non-PTY change feed, sharing the ordinary session pool.
        case zellij
    }

    struct Limits: Sendable, Equatable {
        let ordinaryForwarding: Int
        let events: Int
        let ordinarySession: Int
        let attach: Int
        let control: Int
        let core: Int
        let zellij: Int
        let connection: Int

        init(
            ordinaryForwarding: Int,
            events: Int,
            ordinarySession: Int,
            attach: Int,
            control: Int = 1,
            core: Int = 1,
            zellij: Int = 1,
            connection: Int
        ) {
            self.ordinaryForwarding = ordinaryForwarding
            self.events = events
            self.ordinarySession = ordinarySession
            self.attach = attach
            self.control = control
            self.core = core
            self.zellij = zellij
            self.connection = connection
        }

        /// Production budgets. `connection` restates the sum of the four
        /// category budgets (8+1+4+5), so the connection-level guard does not
        /// bind under these categories — it only constrains a future category
        /// that would otherwise grow without a connection cap. Per-category
        /// budgets are the live admission limits today; do not treat 18 as a
        /// tighter guarantee than those budgets or than server `MaxSessions`.
        ///
        /// `control`, `core` and `zellij` share the ordinary session budget:
        /// together with ordinary sessions they never exceed 4,
        /// so session channels stay at most 9, one under sshd's default
        /// `MaxSessions` (ADR 0017's headroom): control 1 + ordinary 3 +
        /// attach 5 on a tmux Host, core 1 + ordinary 3 + attach 5 on a core
        /// Host, and control 1 + core 1 + ordinary 2 + attach 5 on a Host
        /// running both; with Zellij too, 1 + 1 + 1 + ordinary 1 + attach 5.
        /// A connection that opens none admits exactly as
        /// before.
        static let production = Limits(
            ordinaryForwarding: 8,
            events: 1,
            ordinarySession: 4,
            attach: 5,
            control: 1,
            core: 1,
            connection: 18)
    }

    struct Snapshot: Sendable, Equatable {
        let ordinaryForwarding: Int
        let events: Int
        let ordinarySession: Int
        let attach: Int
        let control: Int
        let core: Int
        let zellij: Int
        let connection: Int

        init(
            ordinaryForwarding: Int, events: Int, ordinarySession: Int, attach: Int,
            control: Int, core: Int = 0, zellij: Int = 0, connection: Int
        ) {
            self.ordinaryForwarding = ordinaryForwarding
            self.events = events
            self.ordinarySession = ordinarySession
            self.attach = attach
            self.control = control
            self.core = core
            self.zellij = zellij
            self.connection = connection
        }
    }

    /// The counts, the parked requests and the pending ones
    /// (`ChannelAdmissionMachine`); the actor keeps each request's
    /// continuation and deadline Task by its id.
    private var machine: ChannelAdmissionMachine
    private var continuations: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    /// Fails a parked wait with `TransportError.timedOut`; none waits forever.
    private var deadlines: [UInt64: Task<Void, Never>] = [:]
    private var nextRequestID: UInt64 = 0

    init(limits: Limits = .production) {
        precondition(limits.ordinaryForwarding > 0)
        precondition(limits.events > 0)
        precondition(limits.ordinarySession > 0)
        precondition(limits.attach > 0)
        precondition(limits.control > 0)
        precondition(limits.core > 0)
        precondition(limits.connection > 0)
        machine = ChannelAdmissionMachine(limits: limits)
    }

    func withChannel<Value: Sendable>(
        _ channelClass: ChannelClass,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let lease = try await acquire(channelClass)
        do {
            let value = try await operation()
            await lease.release()
            return value
        } catch {
            await lease.release()
            throw error
        }
    }

    /// `withChannel` for a channel that outlives `operation`: a one-shot
    /// whose close finishes in the background after the call has returned
    /// (`SSHConnection.exchangeStreamLocal`'s `onChannelReleased`). The
    /// lease is held until the `release` handed to `operation` runs — which
    /// the SSH layer does once the channel is really gone — so channels whose
    /// close is still pending keep counting against the budget. `operation`
    /// throwing releases the lease on the way out; the SSH layer has cleaned
    /// up by then. A `release` that never runs still returns the slot when
    /// the last reference to it goes, as an unreleased lease always has.
    func withChannel<Value: Sendable>(
        _ channelClass: ChannelClass,
        releasedBy operation: @escaping @Sendable (
            _ release: @escaping @Sendable () async -> Void
        ) async throws -> Value
    ) async throws -> Value {
        let lease = try await acquire(channelClass)
        do {
            return try await operation { await lease.release() }
        } catch {
            await lease.release()
            throw error
        }
    }

    /// Admits one channel of `channelClass`, waiting for a slot. With a
    /// `deadline`, a wait that outlasts it throws `TransportError.timedOut`
    /// instead of parking until some holder releases; an immediate grant is
    /// never refused. Cancellation throws `CancellationError`.
    func acquire(
        _ channelClass: ChannelClass, within deadline: Duration? = nil
    ) async throws -> SSHChannelAdmissionLease {
        try Task.checkCancellation()
        nextRequestID &+= 1
        let requestID = nextRequestID
        send(.requested(id: requestID))
        defer { send(.finished(id: requestID)) }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                continuations[requestID] = continuation
                send(.register(id: requestID, channelClass, deadline: deadline))
            }
        } onCancel: {
            Task { await self.send(.cancel(id: requestID)) }
        }

        if Task.isCancelled {
            release(channelClass)
            throw CancellationError()
        }
        return SSHChannelAdmissionLease(admission: self, channelClass: channelClass)
    }

    func snapshot() -> Snapshot { machine.state.counts }

#if DEBUG
    /// Acquirers parked waiting for a slot.
    func waiterCountForTesting() -> Int { machine.state.waiters.count }
#endif

    fileprivate func release(_ channelClass: ChannelClass) {
        send(.release(channelClass))
    }

    private func send(_ event: ChannelAdmissionMachine.Event) {
        for effect in machine.handle(event) {
            switch effect {
            case .grant(let id):
                deadlines.removeValue(forKey: id)?.cancel()
                continuations.removeValue(forKey: id)?.resume()
            case .refuse(let id):
                continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
            case .cancelWait(let id):
                deadlines.removeValue(forKey: id)?.cancel()
                continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
            case .timeOut(let id):
                // The deadline Task is the one reporting this.
                deadlines.removeValue(forKey: id)
                continuations.removeValue(forKey: id)?.resume(throwing: TransportError.timedOut)
            case .armDeadline(let id, let budget):
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: budget) } catch { return }
                    await self?.send(.expire(id: id))
                }
            }
        }
    }
}

final class SSHChannelAdmissionLease: Sendable {
    private let admission: SSHChannelAdmission
    private let channelClass: SSHChannelAdmission.ChannelClass
    private let released = Mutex(false)

    fileprivate init(
        admission: SSHChannelAdmission,
        channelClass: SSHChannelAdmission.ChannelClass
    ) {
        self.admission = admission
        self.channelClass = channelClass
    }

    func release() async {
        let shouldRelease = released.withLock { released in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease { await admission.release(channelClass) }
    }

    deinit {
        let admission = admission
        let channelClass = channelClass
        let shouldRelease = released.withLock { released in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease {
            Task { await admission.release(channelClass) }
        }
    }
}
