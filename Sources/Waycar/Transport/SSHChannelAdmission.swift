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

    private struct Waiter {
        let id: UInt64
        let channelClass: ChannelClass
        let continuation: CheckedContinuation<Void, any Error>
        /// Fails the wait with `TransportError.timedOut`; nil waits forever.
        let deadline: Task<Void, Never>?
    }

    private let limits: Limits
    private var counts = Snapshot(
        ordinaryForwarding: 0,
        events: 0,
        ordinarySession: 0,
        attach: 0,
        control: 0,
        core: 0,
        connection: 0)
    private var waiters: [Waiter] = []
    private var pendingRequests: Set<UInt64> = []
    private var cancelledRequests: Set<UInt64> = []
    private var nextRequestID: UInt64 = 0

    init(limits: Limits = .production) {
        precondition(limits.ordinaryForwarding > 0)
        precondition(limits.events > 0)
        precondition(limits.ordinarySession > 0)
        precondition(limits.attach > 0)
        precondition(limits.control > 0)
        precondition(limits.core > 0)
        precondition(limits.connection > 0)
        self.limits = limits
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
        pendingRequests.insert(requestID)
        defer {
            pendingRequests.remove(requestID)
            cancelledRequests.remove(requestID)
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledRequests.contains(requestID) {
                    continuation.resume(throwing: CancellationError())
                } else if canAcquire(channelClass) {
                    increment(channelClass)
                    continuation.resume()
                } else {
                    let timer = deadline.map { budget in
                        Task { [weak self] in
                            do { try await Task.sleep(for: budget) } catch { return }
                            await self?.expire(requestID: requestID)
                        }
                    }
                    waiters.append(Waiter(
                        id: requestID,
                        channelClass: channelClass,
                        continuation: continuation,
                        deadline: timer))
                }
            }
        } onCancel: {
            Task { await self.cancel(requestID: requestID) }
        }

        if Task.isCancelled {
            release(channelClass)
            throw CancellationError()
        }
        return SSHChannelAdmissionLease(admission: self, channelClass: channelClass)
    }

    func snapshot() -> Snapshot { counts }

#if DEBUG
    /// Acquirers parked waiting for a slot.
    func waiterCountForTesting() -> Int { waiters.count }
#endif

    fileprivate func release(_ channelClass: ChannelClass) {
        decrement(channelClass)
        resumeEligibleWaiters()
    }

    private func cancel(requestID: UInt64) {
        guard pendingRequests.contains(requestID) else { return }
        if let index = waiters.firstIndex(where: { $0.id == requestID }) {
            let waiter = waiters.remove(at: index)
            waiter.deadline?.cancel()
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelledRequests.insert(requestID)
        }
    }

    /// A waiter's deadline passed before a slot freed.
    private func expire(requestID: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == requestID }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: TransportError.timedOut)
    }

    private func resumeEligibleWaiters() {
        while let index = waiters.firstIndex(where: { canAcquire($0.channelClass) }) {
            let waiter = waiters.remove(at: index)
            waiter.deadline?.cancel()
            increment(waiter.channelClass)
            waiter.continuation.resume()
        }
    }

    private func canAcquire(_ channelClass: ChannelClass) -> Bool {
        guard counts.connection < limits.connection else { return false }
        switch channelClass {
        case .ordinaryForwarding:
            return counts.ordinaryForwarding < limits.ordinaryForwarding
        case .events:
            return counts.events < limits.events
        case .ordinarySession:
            // Held control and core channels each spend one ordinary session
            // slot.
            return counts.ordinarySession + counts.control + counts.core + counts.zellij < limits.ordinarySession
        case .attach:
            return counts.attach < limits.attach
        case .control:
            return counts.control < limits.control
                && counts.ordinarySession + counts.control + counts.core + counts.zellij < limits.ordinarySession
        case .core:
            return counts.core < limits.core
                && counts.ordinarySession + counts.control + counts.core + counts.zellij < limits.ordinarySession
        case .zellij:
            return counts.zellij < limits.zellij
                && counts.ordinarySession + counts.control + counts.core + counts.zellij < limits.ordinarySession
        }
    }

    private func increment(_ channelClass: ChannelClass) {
        counts = Snapshot(
            ordinaryForwarding: counts.ordinaryForwarding
                + (channelClass == .ordinaryForwarding ? 1 : 0),
            events: counts.events + (channelClass == .events ? 1 : 0),
            ordinarySession: counts.ordinarySession
                + (channelClass == .ordinarySession ? 1 : 0),
            attach: counts.attach + (channelClass == .attach ? 1 : 0),
            control: counts.control + (channelClass == .control ? 1 : 0),
            core: counts.core + (channelClass == .core ? 1 : 0),
            zellij: counts.zellij + (channelClass == .zellij ? 1 : 0),
            connection: counts.connection + 1)
    }

    private func decrement(_ channelClass: ChannelClass) {
        precondition(counts.connection > 0)
        counts = Snapshot(
            ordinaryForwarding: counts.ordinaryForwarding
                - (channelClass == .ordinaryForwarding ? 1 : 0),
            events: counts.events - (channelClass == .events ? 1 : 0),
            ordinarySession: counts.ordinarySession
                - (channelClass == .ordinarySession ? 1 : 0),
            attach: counts.attach - (channelClass == .attach ? 1 : 0),
            control: counts.control - (channelClass == .control ? 1 : 0),
            core: counts.core - (channelClass == .core ? 1 : 0),
            zellij: counts.zellij - (channelClass == .zellij ? 1 : 0),
            connection: counts.connection - 1)
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
