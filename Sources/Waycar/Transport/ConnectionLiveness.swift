import Foundation
import Synchronization

/// A Transport and the pooled connection it rides (#105); nil when the
/// Transport rides a private connection.
struct SharedTransport: Sendable {
    let transport: any Transport
    let connection: PooledConnectionID?
}

/// How an `EventsSession` reaches its Host's pooled SSH connection (#105).
/// It reports which connection each Transport rides and holds that
/// connection open across a suspension. It replaces a connection that stops
/// answering and stops sharing a dead one. Production is
/// `ConsoleStore.sshSessionFactory` over `HostSSHSessionPool`; `unshared`
/// keeps a plain connect closure, with nothing to keep.
struct SharedConnection: Sendable {
    typealias ID = PooledConnectionID

    /// A Transport on the Host's live connection, dialing one when there is
    /// none. `replacing` names a connection found unanswered: the Transport
    /// rides another one.
    var connect: @Sendable (_ replacing: ID?) async throws -> SharedTransport
    /// Holds the connection open while no Transport rides it; false when it
    /// is gone.
    var keep: @Sendable (ID) async -> Bool
    /// Gives `keep`'s hold back.
    var release: @Sendable (ID) async -> Void
    /// Stops sharing a dead connection: later connects dial anew.
    var retire: @Sendable (ID) async -> Void
    /// Later connects no longer join the Host's dial in flight.
    var abandonDial: @Sendable () async -> Void

    /// Every connect dials through `connect`; nothing is kept or shared.
    static func unshared(
        _ connect: @escaping @Sendable () async throws -> any Transport
    ) -> SharedConnection {
        SharedConnection(
            connect: { _ in SharedTransport(transport: try await connect(), connection: nil) },
            keep: { _ in false },
            release: { _ in },
            retire: { _ in },
            abandonDial: {})
    }
}

/// The clock behind liveness deadlines, hedge delays and the age of a kept
/// connection (#105); tests script it.
struct LivenessClock: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant
    var sleep: @Sendable (Duration) async throws -> Void

    static let continuous = LivenessClock(
        now: { ContinuousClock.now },
        sleep: { try await Task.sleep(for: $0) })
}

/// How long a liveness check waits, derived from the ping round trip the
/// connection last proved (#105). An unknown round trip gets the most
/// patient value.
enum LivenessTiming {
    /// A keepalive, revalidation or kept-connection ping counts as
    /// unanswered after clamp(4 × RTT + 1 s, 2 s, 5 s), well inside the
    /// 15 s RPC budget, so a dead link shows within seconds.
    static func deadline(roundTrip: Duration?) -> Duration {
        guard let roundTrip else { return .seconds(5) }
        return clamp(roundTrip * 4 + .seconds(1), .seconds(2), .seconds(5))
    }

    /// How long a probe of a connection that may have died gets before a
    /// fresh dial starts beside it: clamp(2 × RTT + 150 ms, 200 ms, 800 ms).
    static func hedgeDelay(roundTrip: Duration?) -> Duration {
        guard let roundTrip else { return .milliseconds(800) }
        return clamp(roundTrip * 2 + .milliseconds(150), .milliseconds(200), .milliseconds(800))
    }

    /// How long a probe may take to get the Transport its ping rides before
    /// it counts as unanswered: clamp(12 × RTT + 2 s, 3 s, 10 s). tmux's
    /// open on a kept connection runs backend detection, `tmux ls` and the
    /// control-mode startup, about a dozen round trips plus exec time, so
    /// the ping's own deadline and hedge delay start only after it.
    static func setupDeadline(roundTrip: Duration?) -> Duration {
        guard let roundTrip else { return .seconds(10) }
        return clamp(roundTrip * 12 + .seconds(2), .seconds(3), .seconds(10))
    }

    /// A connection kept across a suspension for longer than this is closed
    /// and redialed on return instead of probed: NAT mappings and server
    /// idle limits make an old one unlikely to answer.
    static let keptConnectionMaxAge: Duration = .seconds(600)

    private static func clamp(_ value: Duration, _ low: Duration, _ high: Duration) -> Duration {
        min(max(value, low), high)
    }
}

/// A liveness proof (a ping) raced against its deadline and, when hedged,
/// against a replacement connection that starts once the proof is slow or
/// has failed on the link (#105). The first success wins. The proof runs
/// under `AsyncDeadline` on the liveness clock, so the caller never waits
/// past the deadline for an operation that ignores cancellation: that work
/// is cancelled and left to finish on its own. A hedge that succeeds after
/// the race is decided is discarded.
enum LivenessRace {
    enum Outcome<Proof: Sendable, Hedge: Sendable>: Sendable {
        case proof(Proof)
        case hedge(Hedge)
    }

    struct Hedging<Hedge: Sendable>: Sendable {
        /// How long the proof may go unanswered before the hedge starts.
        var after: Duration
        /// Whether a proof that failed this way calls for the hedge at once.
        /// A failure that shows the link alive (a server's answer) does not:
        /// it is the race's outcome.
        var startsOn: @Sendable (any Error) -> Bool
        var start: @Sendable () async throws -> Hedge
        /// Disposes of a hedge that succeeded after the race was decided.
        var discard: @Sendable (Hedge) async -> Void
    }

    /// `operation` within `deadline` on `clock`, else
    /// `TransportError.timedOut`.
    static func withDeadline<Value: Sendable>(
        _ deadline: Duration, clock: LivenessClock,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            return try await AsyncDeadline.run(
                for: deadline, sleep: clock.sleep, operation: operation)
        } catch AsyncDeadlineError.timedOut {
            throw TransportError.timedOut
        }
    }

    /// The proof is a failure once `deadline` passes. If both the proof and
    /// the hedge fail, the hedge's failure is thrown.
    static func run<Proof: Sendable, Hedge: Sendable>(
        deadline: Duration,
        clock: LivenessClock,
        proof: @escaping @Sendable () async throws -> Proof,
        hedge: Hedging<Hedge>?
    ) async throws -> Outcome<Proof, Hedge> {
        let race = Race<Proof, Hedge>(hedge: hedge, clock: clock)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.begin(continuation) {
                    try await withDeadline(deadline, clock: clock, proof)
                }
            }
        } onCancel: {
            race.cancel()
        }
    }

    /// What a failed proof leads to.
    private enum AfterProofFailure: Sendable {
        case nothing, fail(any Error), startHedge
    }

    private final class Race<Proof: Sendable, Hedge: Sendable>: Sendable {
        typealias Continuation = CheckedContinuation<Outcome<Proof, Hedge>, any Error>

        private struct State {
            var continuation: Continuation?
            var settled = false
            var proofFailed = false
            var hedgeStarted = false
            var hedgeFailure: (any Error)?
            var tasks: [Task<Void, Never>] = []
        }

        private let state = Mutex(State())
        private let hedge: Hedging<Hedge>?
        private let clock: LivenessClock

        init(hedge: Hedging<Hedge>?, clock: LivenessClock) {
            self.hedge = hedge
            self.clock = clock
        }

        /// Starts `proof`, already bounded by its deadline, and the hedge
        /// timer.
        func begin(
            _ continuation: Continuation,
            proof: @escaping @Sendable () async throws -> Proof
        ) {
            let cancelled = state.withLock { state in
                guard !state.settled else { return true }
                state.continuation = continuation
                return false
            }
            guard !cancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            track(Task {
                do {
                    self.proofSucceeded(try await proof())
                } catch {
                    self.proofFailed(error)
                }
            })
            if let hedge {
                let clock = clock
                track(Task {
                    do { try await clock.sleep(hedge.after) } catch { return }
                    self.startHedge()
                })
            }
        }

        func cancel() {
            settle(with: .failure(CancellationError()))
        }

        private func proofSucceeded(_ value: Proof) {
            settle(with: .success(.proof(value)))
        }

        private func proofFailed(_ error: any Error) {
            let next = state.withLock { state -> AfterProofFailure in
                guard !state.settled else { return .nothing }
                // Latched, so a hedge that fails later fails the race at once.
                state.proofFailed = true
                guard let hedge, hedge.startsOn(error) else { return .fail(error) }
                if let hedgeFailure = state.hedgeFailure { return .fail(hedgeFailure) }
                guard !state.hedgeStarted else { return .nothing }
                state.hedgeStarted = true
                return .startHedge
            }
            switch next {
            case .nothing: break
            case .fail(let failure): settle(with: .failure(failure))
            case .startHedge: launchHedge()
            }
        }

        private func startHedge() {
            let starts = state.withLock { state in
                guard !state.settled, !state.hedgeStarted else { return false }
                state.hedgeStarted = true
                return true
            }
            if starts { launchHedge() }
        }

        private func launchHedge() {
            guard let hedge else { return }
            track(Task {
                let value: Hedge
                do {
                    value = try await hedge.start()
                } catch {
                    self.hedgeFailed(error)
                    return
                }
                if !self.settle(with: .success(.hedge(value))) {
                    await hedge.discard(value)
                }
            })
        }

        private func hedgeFailed(_ error: any Error) {
            let fails = state.withLock { state in
                guard !state.settled else { return false }
                state.hedgeFailure = error
                // While the proof is still out, it may yet answer.
                return state.proofFailed
            }
            if fails { settle(with: .failure(error)) }
        }

        /// Decides the race once; false when it was already decided.
        @discardableResult
        private func settle(with result: Result<Outcome<Proof, Hedge>, any Error>) -> Bool {
            let decided = state.withLock { state -> (Continuation?, [Task<Void, Never>])? in
                guard !state.settled else { return nil }
                state.settled = true
                defer {
                    state.continuation = nil
                    state.tasks = []
                }
                return (state.continuation, state.tasks)
            }
            guard let decided else { return false }
            let (continuation, tasks) = decided
            for task in tasks { task.cancel() }
            continuation?.resume(with: result)
            return true
        }

        /// Keeps `task` for cancellation at the end of the race; one that
        /// starts after the race is decided is cancelled at once.
        private func track(_ task: Task<Void, Never>) {
            let settled = state.withLock { state in
                guard !state.settled else { return true }
                state.tasks.append(task)
                return false
            }
            if settled { task.cancel() }
        }
    }
}
