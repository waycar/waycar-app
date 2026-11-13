import Foundation

/// The lifetime of one `CoreTransport`: its one connection (dialed once,
/// joined by every caller while it dials, lost for good once it ends, since
/// `EventsSession` replaces the transport) and how the transport itself
/// ends (distrusted, keeping its hold on the shared SSH connection, or
/// closed).
///
/// Nothing here starts a core: a dial runs the connect line, which probes
/// core's socket and exits 125 (`.coreNotRunning`) when no core runs.
struct CoreLinkMachine: StateMachine {
    enum State: Equatable, Sendable {
        /// No dial yet.
        case idle
        /// A dial is in flight under `token`; callers join it.
        case connecting(token: UInt64)
        /// The dial under `token` is the link.
        case open(token: UInt64)
        /// The link ended or the dial failed; never redialed.
        case lost(TransportError)
        /// `EventsSession` replaced the transport; it still holds the
        /// connection until `close()` or deinit.
        case distrusted
        /// Closed, or a failed open abandoned.
        case closed
    }

    enum Event: Equatable, Sendable {
        /// A caller needs the connection and none is dialing or open.
        case connect
        case dialed(token: UInt64)
        case dialFailed(token: UInt64, TransportError)
        /// A caller found the open client no longer open.
        case clientEnded(TransportError)
        /// The connection's notification pump ended.
        case connectionEnded(TransportError)
        case distrust
        /// `close()` releases the hold; abandoning a failed open does not.
        case close(releasesHold: Bool)
    }

    enum Effect: Equatable, Sendable {
        /// Dial under `token`.
        case dial(token: UInt64)
        /// The dial under `token` is the link: keep its client.
        case keep(token: UInt64)
        /// The dial under `token` landed after the transport ended: close
        /// its client and fail the caller as cancelled.
        case discard(token: UInt64)
        /// End the events and close the client or cancel the dial.
        case closeLink
        /// Return the hold on the shared SSH connection.
        case release
    }

    static let replaced = TransportError.sshUnreachable(detail: "the herdr-core transport was replaced")

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    init() {}

    /// Why nothing may use the transport now; nil while it is in service.
    var refusal: TransportError? {
        switch state {
        case .closed: .cancelled
        case .distrusted: Self.replaced
        case .idle, .connecting, .open, .lost: nil
        }
    }

    var isClosed: Bool { state == .closed }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .connect):
            lastToken += 1
            state = .connecting(token: lastToken)
            return [.dial(token: lastToken)]
        case (.connecting, .connect), (.open, .connect), (.lost, .connect), (.distrusted, .connect),
            (.closed, .connect):
            return []

        case (.connecting(let current), .dialed(let token)) where current == token:
            state = .open(token: token)
            return [.keep(token: token)]
        case (.idle, .dialed(let token)), (.connecting, .dialed(let token)), (.open, .dialed(let token)),
            (.lost, .dialed(let token)), (.distrusted, .dialed(let token)), (.closed, .dialed(let token)):
            return [.discard(token: token)]

        case (.connecting(let current), .dialFailed(let token, let failure)) where current == token:
            state = .lost(failure)
            return []
        case (.idle, .dialFailed), (.connecting, .dialFailed), (.open, .dialFailed), (.lost, .dialFailed),
            (.distrusted, .dialFailed), (.closed, .dialFailed):
            return []

        // A caller that saw the client end names the failure, also over one
        // the pump recorded first.
        case (.open, .clientEnded(let failure)), (.lost, .clientEnded(let failure)):
            state = .lost(failure)
            return []
        case (.idle, .clientEnded), (.connecting, .clientEnded), (.distrusted, .clientEnded),
            (.closed, .clientEnded):
            return []

        case (.open, .connectionEnded(let failure)):
            state = .lost(failure)
            return []
        case (.idle, .connectionEnded), (.connecting, .connectionEnded), (.lost, .connectionEnded),
            (.distrusted, .connectionEnded), (.closed, .connectionEnded):
            return []

        case (.idle, .distrust), (.connecting, .distrust), (.open, .distrust), (.lost, .distrust):
            state = .distrusted
            return [.closeLink]
        case (.distrusted, .distrust), (.closed, .distrust):
            return []

        case (.idle, .close(let releases)), (.connecting, .close(let releases)),
            (.open, .close(let releases)), (.lost, .close(let releases)),
            (.distrusted, .close(let releases)):
            state = .closed
            return releases ? [.closeLink, .release] : [.closeLink]
        case (.closed, .close):
            return []
        }
    }
}
