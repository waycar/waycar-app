import Foundation

/// Admission of SSH channels on one Host connection (ADR 0011): the counts
/// of admitted channels per class, the acquirers parked for a slot in
/// arrival order, and the requests still inside `acquire`.
///
/// A request is granted at once when its class has room under its own
/// budget, the shared ordinary-session budget (`control`, `core` and
/// `zellij` each spend one of its slots) and the connection ceiling;
/// otherwise it parks. A release hands slots to the parked requests it now
/// admits, first in arrival order, passing over any whose class is still
/// full. A parked request leaves the queue when its deadline passes or its
/// task is cancelled; a cancellation that finds the request no longer
/// parked (granted, its `acquire` not yet returned) is remembered until
/// the request finishes, and the acquirer gives the slot back itself.
/// Request ids are the owner's, never reused.
struct ChannelAdmissionMachine: StateMachine {
    typealias ChannelClass = SSHChannelAdmission.ChannelClass

    struct Waiter: Equatable, Sendable {
        let id: UInt64
        let channelClass: ChannelClass
    }

    struct State: Equatable, Sendable {
        var counts = SSHChannelAdmission.Snapshot(
            ordinaryForwarding: 0, events: 0, ordinarySession: 0, attach: 0, control: 0,
            core: 0, connection: 0)
        /// Parked requests, in arrival order.
        var waiters: [Waiter] = []
        /// Requests between `requested` and `finished`.
        var pending: Set<UInt64> = []
        /// Pending requests cancelled while not parked.
        var cancelledUnparked: Set<UInt64> = []
    }

    enum Event: Equatable, Sendable {
        /// `acquire` took request `id`.
        case requested(id: UInt64)
        /// Request `id` asks for a slot; `deadline` bounds a wait.
        case register(id: UInt64, ChannelClass, deadline: Duration?)
        case cancel(id: UInt64)
        /// Request `id`'s deadline passed.
        case expire(id: UInt64)
        /// One admitted channel of the class closed (a lease, or a grant its
        /// cancelled acquirer gave back).
        case release(ChannelClass)
        /// `acquire` for request `id` returned or threw.
        case finished(id: UInt64)
    }

    enum Effect: Equatable, Sendable {
        /// The slot is request `id`'s: end its wait and its deadline.
        case grant(id: UInt64)
        /// Request `id` was cancelled before it asked: fail it as cancelled.
        case refuse(id: UInt64)
        /// Fail parked request `id` as cancelled and end its deadline.
        case cancelWait(id: UInt64)
        /// Fail parked request `id` as timed out.
        case timeOut(id: UInt64)
        /// Fail parked request `id` with `TransportError.timedOut` after
        /// `after`, unless it leaves the queue first.
        case armDeadline(id: UInt64, after: Duration)
    }

    let limits: SSHChannelAdmission.Limits
    private(set) var state = State()

    init(limits: SSHChannelAdmission.Limits) {
        self.limits = limits
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .requested(let id):
            state.pending.insert(id)
            return []

        case .register(let id, let channelClass, let deadline):
            if state.cancelledUnparked.contains(id) { return [.refuse(id: id)] }
            if canAcquire(channelClass) {
                increment(channelClass)
                return [.grant(id: id)]
            }
            state.waiters.append(Waiter(id: id, channelClass: channelClass))
            return deadline.map { [.armDeadline(id: id, after: $0)] } ?? []

        case .cancel(let id):
            guard state.pending.contains(id) else { return [] }
            if let index = state.waiters.firstIndex(where: { $0.id == id }) {
                state.waiters.remove(at: index)
                return [.cancelWait(id: id)]
            }
            state.cancelledUnparked.insert(id)
            return []

        case .expire(let id):
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return [] }
            state.waiters.remove(at: index)
            return [.timeOut(id: id)]

        case .release(let channelClass):
            decrement(channelClass)
            var effects: [Effect] = []
            while let index = state.waiters.firstIndex(where: { canAcquire($0.channelClass) }) {
                let waiter = state.waiters.remove(at: index)
                increment(waiter.channelClass)
                effects.append(.grant(id: waiter.id))
            }
            return effects

        case .finished(let id):
            state.pending.remove(id)
            state.cancelledUnparked.remove(id)
            return []
        }
    }

    private func canAcquire(_ channelClass: ChannelClass) -> Bool {
        let counts = state.counts
        guard counts.connection < limits.connection else { return false }
        // Held control, core and zellij channels each spend one ordinary
        // session slot.
        let sessions = counts.ordinarySession + counts.control + counts.core + counts.zellij
        switch channelClass {
        case .ordinaryForwarding:
            return counts.ordinaryForwarding < limits.ordinaryForwarding
        case .events:
            return counts.events < limits.events
        case .ordinarySession:
            return sessions < limits.ordinarySession
        case .attach:
            return counts.attach < limits.attach
        case .control:
            return counts.control < limits.control && sessions < limits.ordinarySession
        case .core:
            return counts.core < limits.core && sessions < limits.ordinarySession
        case .zellij:
            return counts.zellij < limits.zellij && sessions < limits.ordinarySession
        }
    }

    private mutating func increment(_ channelClass: ChannelClass) {
        adjust(channelClass, by: 1)
    }

    private mutating func decrement(_ channelClass: ChannelClass) {
        precondition(state.counts.connection > 0)
        adjust(channelClass, by: -1)
    }

    private mutating func adjust(_ channelClass: ChannelClass, by delta: Int) {
        let counts = state.counts
        state.counts = SSHChannelAdmission.Snapshot(
            ordinaryForwarding: counts.ordinaryForwarding
                + (channelClass == .ordinaryForwarding ? delta : 0),
            events: counts.events + (channelClass == .events ? delta : 0),
            ordinarySession: counts.ordinarySession
                + (channelClass == .ordinarySession ? delta : 0),
            attach: counts.attach + (channelClass == .attach ? delta : 0),
            control: counts.control + (channelClass == .control ? delta : 0),
            core: counts.core + (channelClass == .core ? delta : 0),
            zellij: counts.zellij + (channelClass == .zellij ? delta : 0),
            connection: counts.connection + delta)
    }
}
