/// Which logical libssh2 call owns the session's pending outbound packet
/// (README, "Session scheduling"): libssh2 keeps one partially sent packet
/// per session, and only the exact call that produced it can drain it.
///
/// A call that returns `EAGAIN` while the session reports an outbound block
/// becomes the owner, unless another call already is. Only the owner's own
/// later non-`EAGAIN` result ends its ownership: a success, or a failure with
/// nothing outbound any more, clears it; a failure with outbound still
/// reported asks for the session to be invalidated and keeps the owner until
/// that completes. Cancellation and timeouts never clear it; closing or
/// invalidating the session does. Call identities are the driver's, never
/// reused.
struct TransportSendOwnerMachine: StateMachine {
    enum State: Equatable, Sendable {
        case free
        case owned(call: UInt64)
    }

    enum Event: Equatable, Sendable {
        /// `call` returned `EAGAIN`; `outboundPending` is libssh2's report.
        case wouldBlock(call: UInt64, outboundPending: Bool)
        /// `call` returned `result`, not `EAGAIN`.
        case finished(call: UInt64, result: Int32, outboundPending: Bool)
        /// The session was closed or invalidated, freeing its packet.
        case sessionReleased
    }

    enum Effect: Equatable, Sendable {
        /// The owner finished; the send is free.
        case cleared
        /// The owner failed with the packet still pending: invalidate.
        case invalidate
    }

    private(set) var state: State = .free

    init() {}

    var owner: UInt64? {
        if case .owned(let call) = state { return call }
        return nil
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.free, .wouldBlock(let call, let outboundPending)):
            if outboundPending { state = .owned(call: call) }
            return []
        case (.owned, .wouldBlock):
            return []

        case (.owned(let owner), .finished(let call, let result, let outboundPending))
        where owner == call:
            switch SessionDriver.transportSendOwnerDisposition(
                result: result, isCurrentOwner: true, hasOutbound: outboundPending)
            {
            case .clear:
                state = .free
                return [.cleared]
            case .invalidate:
                return [.invalidate]
            case .unchanged:
                return []
            }
        case (.free, .finished), (.owned, .finished):
            return []

        case (_, .sessionReleased):
            state = .free
            return []
        }
    }
}
