import Foundation

/// A mosh-server started ahead of its attach (#105, ADR decision 1): its
/// wrapped command — the Agent attach — waits for the first client datagram
/// before it runs (mosh-server 1.4.0), so until a client uses it the Host
/// sees no attach at all, and the server exits by itself 60 s after start
/// with no client. A client started at it needs no SSH: the bootstrap is
/// already done.
struct StandbyMosh: Sendable {
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

/// The standbys this app holds, one per Agent attach target at most, and
/// the attach bootstraps in flight. The two never run for the same target
/// at once: a standby is not started while an attach bootstraps, and an
/// attach waits for a standby still being prepared and uses it.
@MainActor
final class StandbyMoshStore {
    struct Key: Hashable, Sendable {
        let hostID: Host.ID
        let backend: HostBackend
        let target: TerminalAttachTarget
    }

    /// How old a standby may be when its client starts: mosh-server gives
    /// up on a client at 60 s, and the attach still needs the rest.
    static let maxAge: Duration = .seconds(50)
    /// How long one standby bootstrap may take before it is skipped.
    static let bootstrapBudget: Duration = .seconds(3)

    private struct Preparation {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var ready: [Key: StandbyMosh] = [:]
    private var preparing: [Key: Preparation] = [:]
    private var attachBootstraps: [Key: Int] = [:]
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
        if let preparation = preparing[key] { return preparation.task }
        guard attachBootstraps[key, default: 0] == 0 else { return nil }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            let interval = NetworkInterval("standby mosh")
            let result = try? await AsyncDeadline.run(for: budget, operation: bootstrap)
            interval.end(result == nil ? "failed" : "ready")
            guard let self, self.preparing[key]?.token == token else { return }
            self.preparing[key] = nil
            if let result {
                self.ready[key] = StandbyMosh(bootstrap: result, origin: origin, createdAt: self.now())
            }
        }
        preparing[key] = Preparation(token: token, task: task)
        return task
    }

    /// Takes the target's standby: single use, and only while young enough
    /// for its server to still be waiting. One still being prepared is
    /// waited for (at most its budget).
    func take(_ key: Key) async -> StandbyMosh? {
        if let preparation = preparing[key] {
            await preparation.task.value
        }
        guard let standby = ready.removeValue(forKey: key) else { return nil }
        return isFresh(standby) ? standby : nil
    }

    /// For an attach about to bootstrap mosh itself: the target's standby
    /// if one is ready (or finishes preparing meanwhile), else nil — and
    /// then the attach's bootstrap is registered until
    /// `finishAttachBootstrap(_:)`, so no standby starts beside it.
    func claimAttachBootstrap(_ key: Key) async -> StandbyMosh? {
        if let standby = await take(key) { return standby }
        attachBootstraps[key, default: 0] += 1
        return nil
    }

    func finishAttachBootstrap(_ key: Key) {
        guard let count = attachBootstraps[key] else { return }
        if count > 1 {
            attachBootstraps[key] = count - 1
            return
        }
        attachBootstraps[key] = nil
        if !hasAttachBootstrap(on: key.hostID) {
            attachBootstrapsDidSettle(key.hostID)
        }
    }

    func hasAttachBootstrap(on hostID: Host.ID) -> Bool {
        attachBootstraps.keys.contains { $0.hostID == hostID }
    }

    /// The target's standby, if ready and still young enough; not taken.
    func standby(for key: Key) -> StandbyMosh? {
        ready[key].flatMap { isFresh($0) ? $0 : nil }
    }

    func isPreparing(_ key: Key) -> Bool {
        preparing[key] != nil
    }

    /// Drops the Host's standbys and preparations (it left, or its
    /// connection target changed); their servers time out unused.
    func discard(hostID: Host.ID) {
        ready = ready.filter { $0.key.hostID != hostID }
        for (key, preparation) in preparing where key.hostID == hostID {
            preparation.task.cancel()
            preparing[key] = nil
        }
    }

    /// Drops one target's standby.
    func discard(_ key: Key) {
        ready[key] = nil
        preparing.removeValue(forKey: key)?.task.cancel()
    }

    func age(of standby: StandbyMosh) -> Duration {
        now() - standby.createdAt
    }

    private func isFresh(_ standby: StandbyMosh) -> Bool {
        age(of: standby) < Self.maxAge
    }
}
