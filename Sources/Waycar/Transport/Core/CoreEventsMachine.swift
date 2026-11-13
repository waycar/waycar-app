import Foundation

/// The events of one `CoreTransport`, in two parts.
///
/// The remote subscription: core pushes every terminal's events, so one
/// `events.subscribe` per connection feeds the inventory for the
/// connection's whole life, through a pump identified by its token. It ends
/// only with the connection.
///
/// The consumer: the one `HerdrEventStream` handed out at a time.
/// `EventsSession` ends and asks again whenever its pane set changes; a new
/// consumer of a subscribed connection needs no round trip. While a
/// `subscribeToEvents` call runs (`opening`), another is refused.
struct CoreEventsMachine: StateMachine {
    enum Remote: Equatable, Sendable {
        case unsubscribed
        case subscribing(token: UInt64)
        case subscribed(pump: UInt64)
    }

    enum Consumer: Equatable, Sendable {
        case none
        case opening
        case delivering(stream: UInt64)
    }

    struct State: Equatable, Sendable {
        var remote: Remote = .unsubscribed
        var consumer: Consumer = .none
    }

    enum Event: Equatable, Sendable {
        /// `subscribeToEvents` was called on an open transport.
        case subscribeRequested
        /// The call has the connection.
        case connected
        /// `events.subscribe` under `token` answered and the transport is
        /// still open: its notifications feed the inventory from now on.
        case subscribed(token: UInt64)
        /// It failed, or the transport ended while it ran.
        case subscribeFailed(token: UInt64)
        /// The call is handing out its stream.
        case attach
        /// The call returned or threw.
        case openingEnded
        /// The consumer called `end()`.
        case consumerEnded(stream: UInt64)
        /// The consumer stopped iterating (the stream terminated).
        case consumerTerminated(stream: UInt64)
        /// The pump under `pump` ran out: the connection is gone.
        case connectionEnded(pump: UInt64, TransportError)
        /// The transport closed or was distrusted.
        case linkClosed
    }

    enum Effect: Equatable, Sendable {
        case refuse(TransportError)
        /// Call `events.subscribe` under `token`.
        case subscribe(token: UInt64)
        /// Install the inventory from the answer and run its pump under `pump`.
        case startPump(pump: UInt64)
        case cancelPump
        /// Hand out a new stream under `stream`.
        case deliver(stream: UInt64)
        /// Finish the current stream: cleanly, or with the connection's failure.
        case finishStream(failure: TransportError?)
        /// Forget the current stream, which already terminated.
        case forgetStream
        case cancelResyncs
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    init() {}

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .subscribeRequested:
            guard state.consumer == .none else { return [.refuse(.eventsChannelAlreadyOpen)] }
            state.consumer = .opening
            return []
        case .connected:
            guard state.consumer == .opening, state.remote == .unsubscribed else { return [] }
            let token = mint()
            state.remote = .subscribing(token: token)
            return [.subscribe(token: token)]
        case .subscribed(let token):
            guard state.remote == .subscribing(token: token) else { return [] }
            state.remote = .subscribed(pump: token)
            return [.startPump(pump: token)]
        case .subscribeFailed(let token):
            guard state.remote == .subscribing(token: token) else { return [] }
            state.remote = .unsubscribed
            return []
        case .attach:
            guard state.consumer == .opening else { return [] }
            let stream = mint()
            state.consumer = .delivering(stream: stream)
            return [.deliver(stream: stream)]
        case .openingEnded:
            if state.consumer == .opening { state.consumer = .none }
            return []
        case .consumerEnded(let stream):
            guard state.consumer == .delivering(stream: stream) else { return [] }
            state.consumer = .none
            return [.finishStream(failure: nil), .cancelResyncs]
        case .consumerTerminated(let stream):
            guard state.consumer == .delivering(stream: stream) else { return [] }
            state.consumer = .none
            return [.forgetStream, .cancelResyncs]
        case .connectionEnded(let pump, let failure):
            guard state.remote == .subscribed(pump: pump) else { return [] }
            state.remote = .unsubscribed
            return endConsumer(failure: failure) + [.cancelResyncs]
        case .linkClosed:
            let ended = endConsumer(failure: nil)
            state.remote = .unsubscribed
            return ended + [.cancelResyncs, .cancelPump]
        }
    }

    private mutating func endConsumer(failure: TransportError?) -> [Effect] {
        guard case .delivering = state.consumer else { return [] }
        state.consumer = .none
        return [.finishStream(failure: failure)]
    }

    private mutating func mint() -> UInt64 {
        lastToken += 1
        return lastToken
    }
}
