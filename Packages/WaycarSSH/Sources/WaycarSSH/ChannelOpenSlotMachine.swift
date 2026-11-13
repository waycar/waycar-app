/// The channel-open slots of one session (README, "Session scheduling"):
/// how many opens are in flight, whether the one stock open (SFTP init, on
/// libssh2's session-owned `open_state`) is among them, the limit, and the
/// openers parked for a slot.
///
/// Up to `limit` opens may await their replies at once; a stock open waits
/// while another stock open is in flight, so an opener that releases the
/// session mutex between `open_finish` turns never lets a second stock open
/// resume the first one's state (patches 0003/0004). A released slot goes
/// straight to the first parked opener it can admit, interactive before
/// normal and in arrival order within each, so no admissible opener stays
/// parked while a slot is free. A parked opener leaves the queue on its
/// deadline or cancellation, and invalidation fails every one: a slot
/// already handed over cannot be taken back. Waiter ids are the driver's,
/// never reused.
struct ChannelOpenSlotMachine: StateMachine {
    /// `.stock` is SFTP init; `.pipelined` keeps its open state on its own
    /// channel.
    enum Kind: Equatable, Sendable {
        case pipelined
        case stock
    }

    struct Waiter: Equatable, Sendable {
        let id: UInt64
        let kind: Kind
    }

    struct State: Equatable, Sendable {
        var inFlight = 0
        var stockInFlight = false
        var limit: Int
        var waiters = PriorityWaiterQueue<Waiter>()
    }

    enum Event: Equatable, Sendable {
        /// The caller found a slot (`canAdmit`) and takes it.
        case take(Kind)
        /// The caller found none and parks under `id`.
        case park(id: UInt64, Kind, priority: SSHOperationPriority)
        case release(Kind)
        /// A parked opener's deadline passed or its task was cancelled.
        case withdraw(id: UInt64, SSHError)
        case invalidate
        case setLimit(Int)
    }

    enum Effect: Equatable, Sendable {
        /// The slot is `id`'s: end its deadline and resume it.
        case grant(id: UInt64)
        /// End `id`'s deadline and fail its wait.
        case fail(id: UInt64, SSHError)
    }

    private(set) var state: State

    init(limit: Int) {
        state = State(limit: limit)
    }

    func canAdmit(_ kind: Kind) -> Bool {
        guard state.inFlight < state.limit else { return false }
        return kind == .pipelined || !state.stockInFlight
    }

    var waiterCount: Int { state.waiters.count }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .take(let kind):
            take(kind)
            return []

        case .park(let id, let kind, let priority):
            state.waiters.append(Waiter(id: id, kind: kind), priority: priority)
            return []

        case .release(let kind):
            state.inFlight -= 1
            if kind == .stock { state.stockInFlight = false }
            return admit()

        case .withdraw(let id, let error):
            guard state.waiters.remove(where: { $0.id == id }) != nil else { return [] }
            return [.fail(id: id, error)]

        case .invalidate:
            return state.waiters.removeAll().map { .fail(id: $0.id, .connectionInvalidated) }

        case .setLimit(let limit):
            state.limit = max(1, limit)
            return admit()
        }
    }

    private mutating func take(_ kind: Kind) {
        state.inFlight += 1
        if kind == .stock { state.stockInFlight = true }
    }

    private mutating func admit() -> [Effect] {
        var effects: [Effect] = []
        while state.inFlight < state.limit {
            let stockInFlight = state.stockInFlight
            guard
                let next = state.waiters.remove(where: { waiter in
                    waiter.kind == .pipelined || !stockInFlight
                })
            else { break }
            take(next.kind)
            effects.append(.grant(id: next.id))
        }
        return effects
    }
}
