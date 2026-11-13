import Foundation

/// A mosh-server started ahead of its attach (#105, ADR decision 1): its
/// wrapped command — the Agent attach — waits for the first client datagram
/// before it runs (mosh-server 1.4.0), so until a client uses it the Host
/// sees no attach at all, and the server exits by itself 60 s after start
/// with no client. A client started at it needs no SSH: the bootstrap is
/// already done.
struct StandbyMosh: Equatable, Sendable {
    /// Why it was started.
    enum Origin: Sendable, Equatable {
        /// At Background Grace expiry, for a live mosh attach.
        case graceExpiry
        /// Ahead of time, for the Host's last-viewed or named Agent.
        case speculative
    }

    /// Where the server listens (the SSH peer address it was started over)
    /// and its session key.
    let bootstrap: MoshBootstrap
    let origin: Origin
    let createdAt: ContinuousClock.Instant
}

/// One Agent attach target a standby can be kept for.
struct StandbyMoshKey: Hashable, Sendable {
    let hostID: Host.ID
    let backend: HostBackend
    let target: TerminalAttachTarget
}

/// What the store holds for each attach target: a standby ready, one being
/// prepared (a renewal keeps the ready one until its replacement is), or
/// attach bootstraps in flight. The two never start for the same target at
/// once: a preparation is refused while an attach bootstraps, and an attach
/// waits for a preparation in flight and uses it. One overlap stays
/// possible, as before: a preparation started in the moment between the
/// one an attach waited for finishing and that attach claiming the target
/// runs beside the attach's bootstrap (`bootstrappingBeside*`). Preparation
/// tokens fence a preparation dropped or replaced meanwhile. Time arrives
/// in events (`now`). (MOSH-03.)
struct StandbyMoshMachine: StateMachine {
    typealias Key = StandbyMoshKey

    enum Slot: Equatable, Sendable {
        case preparing(token: UInt64)
        case ready(StandbyMosh)
        /// The ready standby stays usable while its renewal is prepared.
        case refreshing(StandbyMosh, token: UInt64)
        /// Attach bootstraps in flight on the target.
        case bootstrapping(count: Int)
        case bootstrappingBesidePreparation(count: Int, token: UInt64)
        case bootstrappingBesideStandby(count: Int, StandbyMosh)
    }

    /// The targets with something held; an absent target has nothing.
    typealias State = [Key: Slot]

    enum Event: Equatable, Sendable {
        /// Start a standby for the target, unless one is being prepared
        /// (joined) or an attach bootstraps it (refused).
        case prepare(Key)
        /// A preparation ended: the standby it made, or nil when its
        /// bootstrap failed or ran past its budget.
        case prepared(Key, token: UInt64, StandbyMosh?)
        /// Take the target's standby, single use.
        case take(Key, now: ContinuousClock.Instant)
        /// An attach about to bootstrap the target: takes the standby, or
        /// registers its own bootstrap.
        case claimAttachBootstrap(Key, now: ContinuousClock.Instant)
        case finishAttachBootstrap(Key)
        /// Drop the Host's standbys and preparations (not its bootstraps).
        case discardHost(Host.ID)
        /// Drop one target's standby and preparation.
        case discard(Key)
    }

    enum Effect: Equatable, Sendable {
        /// Run the target's bootstrap under this token.
        case startPreparation(Key, token: UInt64)
        /// The preparation already running for the target.
        case joinPreparation(token: UInt64)
        /// An attach bootstraps the target: no preparation.
        case refusePreparation
        case cancelPreparation(token: UInt64)
        /// What `take` or `claimAttachBootstrap` returns.
        case handOut(StandbyMosh?)
        /// The Host's last attach bootstrap finished.
        case attachBootstrapsSettled(Host.ID)
    }

    /// How old a standby may be when its client starts.
    static let maxAge = StandbyMoshStore.maxAge

    private(set) var state: State = [:]
    private var lastToken: UInt64 = 0

    /// The target's preparation in flight, if any.
    func preparation(for key: Key) -> UInt64? {
        switch state[key] {
        case .preparing(let token), .refreshing(_, let token), .bootstrappingBesidePreparation(_, let token):
            token
        case .ready, .bootstrapping, .bootstrappingBesideStandby, nil:
            nil
        }
    }

    /// The target's ready standby, fresh or not.
    func readyStandby(for key: Key) -> StandbyMosh? {
        switch state[key] {
        case .ready(let standby), .refreshing(let standby, _), .bootstrappingBesideStandby(_, let standby):
            standby
        case .preparing, .bootstrapping, .bootstrappingBesidePreparation, nil:
            nil
        }
    }

    func attachBootstraps(for key: Key) -> Int {
        switch state[key] {
        case .bootstrapping(let count), .bootstrappingBesidePreparation(let count, _),
             .bootstrappingBesideStandby(let count, _):
            count
        case .preparing, .ready, .refreshing, nil:
            0
        }
    }

    func hasAttachBootstrap(on hostID: Host.ID) -> Bool {
        state.keys.contains { $0.hostID == hostID && attachBootstraps(for: $0) > 0 }
    }

    static func isFresh(_ standby: StandbyMosh, now: ContinuousClock.Instant) -> Bool {
        now - standby.createdAt < maxAge
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .prepare(let key):
            return prepare(key)
        case .prepared(let key, let token, let standby):
            return prepared(key, token: token, standby)
        case .take(let key, let now):
            return [.handOut(take(key, now: now))]
        case .claimAttachBootstrap(let key, let now):
            if let standby = take(key, now: now) { return [.handOut(standby)] }
            let slot: Slot
            switch state[key] {
            case nil: slot = .bootstrapping(count: 1)
            case .bootstrapping(let count): slot = .bootstrapping(count: count + 1)
            case .preparing(let token): slot = .bootstrappingBesidePreparation(count: 1, token: token)
            case .bootstrappingBesidePreparation(let count, let token):
                slot = .bootstrappingBesidePreparation(count: count + 1, token: token)
            // `take` just emptied the target's standby, so these three are
            // never reached; each keeps what it holds and counts the claim.
            case .ready(let standby): slot = .bootstrappingBesideStandby(count: 1, standby)
            case .refreshing(_, let token): slot = .bootstrappingBesidePreparation(count: 1, token: token)
            case .bootstrappingBesideStandby(let count, let standby):
                slot = .bootstrappingBesideStandby(count: count + 1, standby)
            }
            state[key] = slot
            return [.handOut(nil)]
        case .finishAttachBootstrap(let key):
            return finishAttachBootstrap(key)
        case .discardHost(let hostID):
            var effects: [Effect] = []
            for key in state.keys.sorted(by: { "\($0)" < "\($1)" }) where key.hostID == hostID {
                effects += discard(key)
            }
            return effects
        case .discard(let key):
            return discard(key)
        }
    }

    private mutating func prepare(_ key: Key) -> [Effect] {
        switch state[key] {
        case .preparing(let token), .refreshing(_, let token), .bootstrappingBesidePreparation(_, let token):
            return [.joinPreparation(token: token)]
        case .bootstrapping, .bootstrappingBesideStandby:
            return [.refusePreparation]
        case nil:
            lastToken += 1
            state[key] = .preparing(token: lastToken)
            return [.startPreparation(key, token: lastToken)]
        case .ready(let standby):
            lastToken += 1
            state[key] = .refreshing(standby, token: lastToken)
            return [.startPreparation(key, token: lastToken)]
        }
    }

    private mutating func prepared(_ key: Key, token: UInt64, _ made: StandbyMosh?) -> [Effect] {
        switch state[key] {
        case .preparing(let current) where current == token:
            state[key] = made.map(Slot.ready)
        case .refreshing(let previous, let current) where current == token:
            state[key] = .ready(made ?? previous)
        case .bootstrappingBesidePreparation(let count, let current) where current == token:
            state[key] = made.map { .bootstrappingBesideStandby(count: count, $0) } ?? .bootstrapping(count: count)
        case .preparing, .refreshing, .bootstrappingBesidePreparation, .ready, .bootstrapping,
             .bootstrappingBesideStandby, nil:
            // Dropped or replaced meanwhile: its standby is not kept.
            break
        }
        return []
    }

    /// Removes the target's standby and returns it when still fresh.
    private mutating func take(_ key: Key, now: ContinuousClock.Instant) -> StandbyMosh? {
        let standby: StandbyMosh
        switch state[key] {
        case .ready(let ready):
            standby = ready
            state[key] = nil
        case .refreshing(let ready, let token):
            standby = ready
            state[key] = .preparing(token: token)
        case .bootstrappingBesideStandby(let count, let ready):
            standby = ready
            state[key] = .bootstrapping(count: count)
        case .preparing, .bootstrapping, .bootstrappingBesidePreparation, nil:
            return nil
        }
        return Self.isFresh(standby, now: now) ? standby : nil
    }

    private mutating func finishAttachBootstrap(_ key: Key) -> [Effect] {
        switch state[key] {
        case .bootstrapping(let count) where count > 1:
            state[key] = .bootstrapping(count: count - 1)
            return []
        case .bootstrappingBesidePreparation(let count, let token) where count > 1:
            state[key] = .bootstrappingBesidePreparation(count: count - 1, token: token)
            return []
        case .bootstrappingBesideStandby(let count, let standby) where count > 1:
            state[key] = .bootstrappingBesideStandby(count: count - 1, standby)
            return []
        case .bootstrapping:
            state[key] = nil
        case .bootstrappingBesidePreparation(_, let token):
            state[key] = .preparing(token: token)
        case .bootstrappingBesideStandby(_, let standby):
            state[key] = .ready(standby)
        case .preparing, .ready, .refreshing, nil:
            return []
        }
        return hasAttachBootstrap(on: key.hostID) ? [] : [.attachBootstrapsSettled(key.hostID)]
    }

    private mutating func discard(_ key: Key) -> [Effect] {
        switch state[key] {
        case .preparing(let token), .refreshing(_, let token):
            state[key] = nil
            return [.cancelPreparation(token: token)]
        case .bootstrappingBesidePreparation(let count, let token):
            state[key] = .bootstrapping(count: count)
            return [.cancelPreparation(token: token)]
        case .ready:
            state[key] = nil
            return []
        case .bootstrappingBesideStandby(let count, _):
            state[key] = .bootstrapping(count: count)
            return []
        case .bootstrapping, nil:
            return []
        }
    }
}

/// The standbys this app holds, one per Agent attach target at most, and
/// the attach bootstraps in flight (`StandbyMoshMachine`). The two never
/// run for the same target at once: a standby is not started while an
/// attach bootstraps, and an attach waits for a standby still being
/// prepared and uses it.
@MainActor
final class StandbyMoshStore {
    typealias Key = StandbyMoshKey

    /// How old a standby may be when its client starts: mosh-server gives
    /// up on a client at 60 s, and the attach still needs the rest.
    nonisolated static let maxAge: Duration = .seconds(50)
    /// How long one standby bootstrap may take before it is skipped.
    static let bootstrapBudget: Duration = .seconds(3)

    private var machine = StandbyMoshMachine()
    /// Each preparation's task, by the machine's token.
    private var preparations: [UInt64: Task<Void, Never>] = [:]
    private let now: @MainActor () -> ContinuousClock.Instant
    /// Told when the last attach bootstrap on a Host finishes.
    var attachBootstrapsDidSettle: @MainActor (Host.ID) -> Void = { _ in }

    init(now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// Starts a standby for `key` with `bootstrap`, unless an attach is
    /// bootstrapping that target or a standby for it is already being
    /// prepared (whose preparation is returned instead). A bootstrap that
    /// fails or runs past `budget` leaves no standby; one that succeeds
    /// replaces the target's previous standby, whose server just times out
    /// unused.
    @discardableResult
    func prepare(
        _ key: Key, origin: StandbyMosh.Origin, budget: Duration = StandbyMoshStore.bootstrapBudget,
        bootstrap: @escaping @Sendable () async throws -> MoshBootstrap
    ) -> Task<Void, Never>? {
        var preparation: Task<Void, Never>?
        for effect in machine.handle(.prepare(key)) {
            switch effect {
            case .joinPreparation(let token):
                preparation = preparations[token]
            case .startPreparation(_, let token):
                let task = Task { @MainActor [weak self] in
                    let interval = NetworkInterval("standby mosh")
                    let result = try? await AsyncDeadline.run(for: budget, operation: bootstrap)
                    interval.end(result == nil ? "failed" : "ready")
                    guard let self else { return }
                    self.preparations[token] = nil
                    let standby = result.map {
                        StandbyMosh(bootstrap: $0, origin: origin, createdAt: self.now())
                    }
                    self.perform(self.machine.handle(.prepared(key, token: token, standby)))
                }
                preparations[token] = task
                preparation = task
            case .refusePreparation, .cancelPreparation, .handOut, .attachBootstrapsSettled:
                perform([effect])
            }
        }
        return preparation
    }

    /// Takes the target's standby: single use, and only while young enough
    /// for its server to still be waiting. One still being prepared is
    /// waited for (at most its budget).
    func take(_ key: Key) async -> StandbyMosh? {
        await awaitPreparation(for: key)
        return handOut(machine.handle(.take(key, now: now())))
    }

    /// For an attach about to bootstrap mosh itself: the target's standby
    /// if one is ready (or finishes preparing meanwhile), else nil — and
    /// then the attach's bootstrap is registered until
    /// `finishAttachBootstrap(_:)`, so no standby starts beside it.
    func claimAttachBootstrap(_ key: Key) async -> StandbyMosh? {
        await awaitPreparation(for: key)
        return handOut(machine.handle(.claimAttachBootstrap(key, now: now())))
    }

    func finishAttachBootstrap(_ key: Key) {
        perform(machine.handle(.finishAttachBootstrap(key)))
    }

    func hasAttachBootstrap(on hostID: Host.ID) -> Bool {
        machine.hasAttachBootstrap(on: hostID)
    }

    /// The target's standby, if ready and still young enough; not taken.
    func standby(for key: Key) -> StandbyMosh? {
        machine.readyStandby(for: key).flatMap {
            StandbyMoshMachine.isFresh($0, now: now()) ? $0 : nil
        }
    }

    func isPreparing(_ key: Key) -> Bool {
        machine.preparation(for: key) != nil
    }

    /// Drops the Host's standbys and preparations (it left, or its
    /// connection target changed); their servers time out unused.
    func discard(hostID: Host.ID) {
        perform(machine.handle(.discardHost(hostID)))
    }

    /// Drops one target's standby.
    func discard(_ key: Key) {
        perform(machine.handle(.discard(key)))
    }

    func age(of standby: StandbyMosh) -> Duration {
        now() - standby.createdAt
    }

    /// Waits for the target's preparation in flight, if any.
    private func awaitPreparation(for key: Key) async {
        if let token = machine.preparation(for: key), let task = preparations[token] {
            await task.value
        }
    }

    private func handOut(_ effects: [StandbyMoshMachine.Effect]) -> StandbyMosh? {
        var standby: StandbyMosh?
        for effect in effects {
            if case .handOut(let handed) = effect {
                standby = handed
            } else {
                perform([effect])
            }
        }
        return standby
    }

    private func perform(_ effects: [StandbyMoshMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .cancelPreparation(let token):
                preparations.removeValue(forKey: token)?.cancel()
            case .attachBootstrapsSettled(let hostID):
                attachBootstrapsDidSettle(hostID)
            case .startPreparation, .joinPreparation, .refusePreparation, .handOut:
                // Answered by the call that asked: `prepare`, `take`, `claimAttachBootstrap`.
                break
            }
        }
    }
}
