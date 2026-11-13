import Foundation

/// Whether the Console may use mosh on each Host, and the probes that find
/// out (#105). Per Host it keeps four independent facets:
///
/// - **Known**: what this connection's probe, a mosh session's proof or the
///   memory for this network said, under the connection generation it was
///   learned on (`outcome`). Unknown reads the network's memory.
/// - **Invalidated**: an automatic fallback for one generation, or the
///   user's "Use SSH Instead", which holds across generations and networks
///   until the capsule's re-probe asks again. A probe or proof landing for
///   an invalidated generation cannot mark it available.
/// - **Settled**: the generation already probed or answered from memory, so
///   rebuilds do not pile up probes. A connect probe whose answer no longer
///   counts (the network changed) gives its generation back, unless it was
///   cancelled: whatever cancelled it holds the claim.
/// - **Re-probing**: the capsule's re-probe whose task has not ended
///   (testing); its token fences a Host removed and added back meanwhile.
///
/// A probe's answer is newest-generation-wins: one landing for an older
/// generation than the one known, or for an invalidated one, is dropped.
/// Connect probes carry no token: they are fenced by their generation, as
/// before. (MOSH-02.)
struct MoshEligibilityMachine: StateMachine {
    struct Outcome: Equatable, Sendable {
        let generation: UInt64
        let available: Bool
    }

    struct Invalidation: Equatable, Sendable {
        let generation: UInt64
        let cause: MoshInvalidationCause
    }

    struct HostEntry: Equatable, Sendable {
        var outcome: Outcome?
        var invalidation: Invalidation?
        var settledGeneration: UInt64?
        var reprobe: UInt64?

        var isEmpty: Bool {
            outcome == nil && invalidation == nil && settledGeneration == nil && reprobe == nil
        }
    }

    typealias State = [Host.ID: HostEntry]

    enum ProbeKind: Equatable, Sendable {
        /// The connect-time probe of one generation.
        case connect(generation: UInt64)
        /// The capsule's re-probe.
        case reprobe(token: UInt64, generation: UInt64)
    }

    enum Event: Equatable, Sendable {
        /// A mosh failure (`automaticFallback`) or the user's "Use SSH
        /// Instead" on `generation`.
        case invalidate(Host.ID, generation: UInt64, cause: MoshInvalidationCause)
        /// A session's first contact on the network the device is still on.
        case recordOutcome(Host.ID, generation: UInt64, available: Bool)
        /// The capsule's tap on a connected Host.
        case reprobe(Host.ID, generation: UInt64)
        /// A rebuild's look at the Host's mosh-capable projection.
        /// `remembered` is what this network's memory holds (read only when
        /// the generation is not settled); `canProbe` whether the
        /// projection is connected, has its first snapshot and no attach
        /// bootstraps mosh on the Host.
        case reconcile(Host.ID, generation: UInt64, remembered: Bool?, canProbe: Bool)
        /// A connect probe's answer: nil when it no longer counts;
        /// `cancelled` whether its task was cancelled.
        case connectProbeFinished(Host.ID, generation: UInt64, available: Bool?, cancelled: Bool)
        /// A re-probe's task ended, with its answer if it got one that counts.
        case reprobeEnded(Host.ID, token: UInt64, generation: UInt64, available: Bool?)
        /// A new network reading; `hasPath` false when the path was lost.
        case networkChanged(hasPath: Bool)
        /// The Host was removed or edited; `keepsTarget` when its connection
        /// target is unchanged (a rename keeps the user's SSH choice).
        case hostChanged(Host.ID, keepsTarget: Bool)
        /// The Host's herdr projection ended: the probes move to tmux's.
        case primaryProjectionEnded(Host.ID)
    }

    enum Effect: Equatable, Sendable {
        /// Start the probe (cancelling the Host's probe in flight).
        case startProbe(Host.ID, ProbeKind)
        /// mosh is proven: move the Host's SSH terminals onto it.
        case upgrade(Host.ID, connectingOnly: Bool)
        case cancelProbe(Host.ID)
        case cancelAllProbes
        /// Look at every Host again.
        case reconcileAll
    }

    private(set) var state: State = [:]
    private var lastToken: UInt64 = 0

    // MARK: Reading

    /// What is known without the network's memory: false after the user's
    /// SSH choice, else this connection's outcome; nil when unknown.
    func knownAvailability(of hostID: Host.ID) -> Bool? {
        guard let entry = state[hostID] else { return nil }
        if entry.invalidation?.cause == .userChoseSSH { return false }
        return entry.outcome?.available
    }

    func outcome(of hostID: Host.ID) -> Outcome? {
        state[hostID]?.outcome
    }

    func invalidation(of hostID: Host.ID) -> Invalidation? {
        state[hostID]?.invalidation
    }

    func isReprobing(_ hostID: Host.ID) -> Bool {
        state[hostID]?.reprobe != nil
    }

    func isSettled(_ hostID: Host.ID, generation: UInt64) -> Bool {
        state[hostID]?.settledGeneration == generation
    }

    var outcomes: [Host.ID: Outcome] {
        state.compactMapValues(\.outcome)
    }

    var reprobingHosts: Set<Host.ID> {
        Set(state.filter { $0.value.reprobe != nil }.keys)
    }

    // MARK: Transitions

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .invalidate(let hostID, let generation, let cause):
            update(hostID) { entry in
                entry.outcome = Outcome(generation: generation, available: false)
                if cause == .automaticFallback, entry.invalidation?.cause == .userChoseSSH {
                    return
                }
                entry.invalidation = Invalidation(generation: generation, cause: cause)
            }
            return []

        case .recordOutcome(let hostID, let generation, let available):
            if available, isInvalidated(hostID, through: generation) { return [] }
            update(hostID) { $0.outcome = Outcome(generation: generation, available: available) }
            return []

        case .reprobe(let hostID, let generation):
            guard !isReprobing(hostID) else { return [] }
            lastToken += 1
            let token = lastToken
            update(hostID) { entry in
                entry.invalidation = nil
                entry.settledGeneration = generation
                entry.reprobe = token
            }
            return [.startProbe(hostID, .reprobe(token: token, generation: generation))]

        case .reconcile(let hostID, let generation, let remembered, let canProbe):
            guard !isSettled(hostID, generation: generation) else { return [] }
            if let remembered {
                update(hostID) { $0.settledGeneration = generation }
                guard !isInvalidated(hostID, through: generation) else { return [] }
                update(hostID) { $0.outcome = Outcome(generation: generation, available: remembered) }
                return []
            }
            guard canProbe, state[hostID]?.invalidation?.cause != .userChoseSSH else { return [] }
            update(hostID) { $0.settledGeneration = generation }
            return [.startProbe(hostID, .connect(generation: generation))]

        case .connectProbeFinished(let hostID, let generation, let available, let cancelled):
            guard let available else {
                if !cancelled, isSettled(hostID, generation: generation) {
                    update(hostID) { $0.settledGeneration = nil }
                }
                return []
            }
            guard !landsStale(hostID, generation: generation) else { return [] }
            update(hostID) { $0.outcome = Outcome(generation: generation, available: available) }
            return available ? [.upgrade(hostID, connectingOnly: true)] : []

        case .reprobeEnded(let hostID, let token, let generation, let available):
            var effects: [Effect] = []
            if let available, !landsStale(hostID, generation: generation) {
                update(hostID) { $0.outcome = Outcome(generation: generation, available: available) }
                if available { effects.append(.upgrade(hostID, connectingOnly: false)) }
            }
            if state[hostID]?.reprobe == token {
                update(hostID) { $0.reprobe = nil }
            }
            return effects

        case .networkChanged(let hasPath):
            guard hasPath else { return [.cancelAllProbes] }
            for hostID in state.keys where state[hostID]?.invalidation?.cause != .userChoseSSH {
                update(hostID) { entry in
                    entry.outcome = nil
                    entry.settledGeneration = nil
                    entry.invalidation = nil
                }
            }
            return [.cancelAllProbes, .reconcileAll]

        case .hostChanged(let hostID, let keepsTarget):
            update(hostID) { entry in
                if !keepsTarget { entry.invalidation = nil }
                entry.outcome = nil
                entry.settledGeneration = nil
                entry.reprobe = nil
            }
            return [.cancelProbe(hostID)]

        case .primaryProjectionEnded(let hostID):
            update(hostID) { entry in
                entry.outcome = nil
                entry.settledGeneration = nil
                entry.reprobe = nil
            }
            return []
        }
    }

    /// Whether mosh was invalidated for the Host on `generation` or later,
    /// or by the user on any generation.
    private func isInvalidated(_ hostID: Host.ID, through generation: UInt64) -> Bool {
        guard let invalidation = state[hostID]?.invalidation else { return false }
        return invalidation.cause == .userChoseSSH || invalidation.generation >= generation
    }

    /// A probe landing for a replaced connection must not override a newer
    /// generation's outcome, nor re-mark an invalidated generation.
    private func landsStale(_ hostID: Host.ID, generation: UInt64) -> Bool {
        if let outcome = state[hostID]?.outcome, outcome.generation > generation { return true }
        return isInvalidated(hostID, through: generation)
    }

    private mutating func update(_ hostID: Host.ID, _ change: (inout HostEntry) -> Void) {
        var entry = state[hostID] ?? HostEntry()
        change(&entry)
        state[hostID] = entry.isEmpty ? nil : entry
    }
}
