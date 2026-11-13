/// Who owns what in one Jump Host byte transport (`DirectTCPIPByteTransport`):
/// the socketpair's two descriptors, each handed out once (the inner one to
/// the nested session's driver, the pump one to the forwarding pump), and
/// whether the pump has started.
///
/// Aborting closes the descriptors the transport still holds; the pump's
/// own descriptor is the pump's once it started (it closes it when it ends),
/// so an abort then only cancels the pump. Closing waits for the pump
/// outside the machine, bounded by its timeout (B-27).
struct ByteTransportMachine: StateMachine {
    enum Descriptor: Equatable, Sendable {
        case held(Int32)
        /// Handed out or closed.
        case released
    }

    enum Pump: Equatable, Sendable {
        case unstarted
        case started
    }

    struct State: Equatable, Sendable {
        var inner: Descriptor
        var pumpDescriptor: Descriptor
        var pump: Pump = .unstarted
    }

    enum Event: Equatable, Sendable {
        case takeInner
        case takePumpDescriptor
        case startPump
        case abort
    }

    enum Effect: Equatable, Sendable {
        /// Hand the caller this descriptor.
        case hand(Int32)
        /// Refuse the take with `SSHError.connectionInvalidated`.
        case refuse
        case closeDescriptor(Int32)
        case cancelPump
    }

    private(set) var state: State

    init(inner: Int32, pump: Int32) {
        state = State(inner: .held(inner), pumpDescriptor: .held(pump))
    }

    var isPumpStarted: Bool { state.pump == .started }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state.pump, event) {
        case (_, .takeInner):
            guard case .held(let descriptor) = state.inner else { return [.refuse] }
            state.inner = .released
            return [.hand(descriptor)]

        case (_, .takePumpDescriptor):
            guard case .held(let descriptor) = state.pumpDescriptor else { return [.refuse] }
            state.pumpDescriptor = .released
            return [.hand(descriptor)]

        case (.unstarted, .startPump):
            state.pump = .started
            return []
        case (.started, .startPump):
            preconditionFailure("a byte transport's pump starts once")

        case (.unstarted, .abort):
            var effects: [Effect] = []
            if case .held(let descriptor) = state.inner { effects.append(.closeDescriptor(descriptor)) }
            if case .held(let descriptor) = state.pumpDescriptor {
                effects.append(.closeDescriptor(descriptor))
            }
            state.inner = .released
            state.pumpDescriptor = .released
            return effects
        case (.started, .abort):
            var effects: [Effect] = []
            if case .held(let descriptor) = state.inner { effects.append(.closeDescriptor(descriptor)) }
            state.inner = .released
            return effects + [.cancelPump]
        }
    }
}
