import Foundation

/// A tmux transport's control link (ADR 0026, design §4.3): one
/// `tmux -u -C attach` client at a time, anchored on an existing session,
/// or none while the server has no session to anchor on (idle: one-shot
/// execs only). A dial is single-flight: callers join the one running. It
/// lists the server's sessions, then opens a client on the anchor and
/// keeps it once its startup line is answered, closing the client it
/// replaces first. A client that ends is lost until the next caller dials;
/// one that ended with `%exit` (below tmux 3.6 the anchor's death
/// detaches it) is dialed again at once, reattaching or going idle.
///
/// Every dial and every distrust moves the generation on: a client's
/// events count only under the generation it was kept with, and a dial
/// whose generation moved on while it ran is discarded. Distrusted
/// (EventsSession replaced the transport) and closed transports never dial
/// again; a distrusted one still serves attach and exec work.
struct TmuxLinkMachine: StateMachine {
    enum Link: Equatable, Sendable {
        /// No session to anchor on.
        case idle
        /// The client kept under `generation` is the link.
        case control(generation: UInt64)
        /// The client ended, or was closed, and has not been replaced.
        case lost
    }

    enum Standing: Equatable, Sendable {
        case inService
        /// The control slot belongs to the replacement transport.
        case distrusted
        case closed
    }

    struct State: Equatable, Sendable {
        var link: Link = .idle
        /// The latest dial's generation, or past it after a distrust.
        var generation: UInt64 = 0
        /// A dial runs; callers join it.
        var dialing = false
        var standing: Standing = .inService
    }

    enum Event: Equatable, Sendable {
        /// A caller needs the link (`connect()`).
        case connect
        /// The dial's own work begins.
        case dialStarted
        /// The dial under `generation` listed the server's sessions;
        /// `anchored` when one can anchor a client.
        case sessionsListed(generation: UInt64, anchored: Bool)
        /// The client the dial under `generation` opened answered its
        /// startup line within the version floor.
        case startupAnswered(generation: UInt64)
        /// The dial returned or threw.
        case dialEnded
        /// The current client ended.
        case clientEnded(TmuxControlEnd)
        /// EventsSession replaced the transport (`transportDistrusted()`).
        case distrust
        /// `close()`, or an `open` that failed abandoning the transport.
        case close
    }

    enum Effect: Equatable, Sendable {
        /// Start a dial.
        case dial
        /// Join the dial that runs.
        case join
        /// Fail the caller: the transport is closed or replaced.
        case refuse(TransportError)
        /// Close the client kept under `generation`: a dial replaces it.
        case closeClient(generation: UInt64)
        /// List the server's sessions for the dial under `generation`.
        case listSessions(generation: UInt64)
        /// No session to anchor on: forget the panes' baseline and
        /// verdicts, and poll while events are wanted.
        case enterIdle
        /// Open a client on the anchor for the dial under `generation`.
        case openClient(generation: UInt64)
        /// Take the dialed server's version, identity and flags.
        case recordServer
        /// The dialed client is the link: reset the baseline, stop the idle
        /// poll, start its pump, resync.
        case keep(generation: UInt64)
        /// The dial was superseded: close its client and fail.
        case discard(generation: UInt64)
        /// End the event stream, in order (nil) or failing.
        case finishEvents(TransportError?)
        /// Dial again after `%exit`: reattach, or resync once idle.
        case reattach
        /// End the event stream, its work and the pump, then close the
        /// client kept under `closing`, if any.
        case endControl(closing: UInt64?)
    }

    static let closedError = TransportError.sshUnreachable(detail: "the tmux transport is closed")
    static let replacedError = TransportError.sshUnreachable(detail: "the tmux transport was replaced")

    private(set) var state = State()

    init() {}

    /// Why no client may be dialed now; nil while the transport serves.
    var refusal: TransportError? {
        switch state.standing {
        case .closed: Self.closedError
        case .distrusted: Self.replacedError
        case .inService: nil
        }
    }

    var isClosed: Bool { state.standing == .closed }

    /// Whether an event of the client kept under `generation` counts.
    func accepts(generation: UInt64) -> Bool {
        !isClosed && generation == state.generation
    }

    /// The generation of the client that is the link, if one is.
    var controlGeneration: UInt64? {
        guard case .control(let generation) = state.link else { return nil }
        return generation
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .connect:
            guard !state.dialing else { return [.join] }
            state.dialing = true
            return [.dial]

        case .dialStarted:
            if let refusal = self.refusal { return [.refuse(refusal)] }
            state.generation &+= 1
            let listing = Effect.listSessions(generation: state.generation)
            guard let previous = controlGeneration else { return [listing] }
            state.link = .lost
            return [.closeClient(generation: previous), listing]

        case .sessionsListed(let generation, let anchored):
            if let refusal = self.refusal { return [.refuse(refusal)] }
            guard anchored else {
                state.link = .idle
                return [.enterIdle]
            }
            return [.openClient(generation: generation)]

        case .startupAnswered(let generation):
            if let refusal = self.refusal { return [.refuse(refusal)] }
            // Superseded while it connected: distrusted (or, kept as a
            // guard, a second dial despite the single flight).
            guard generation == state.generation else {
                return [.recordServer, .discard(generation: generation)]
            }
            state.link = .control(generation: generation)
            return [.recordServer, .keep(generation: generation)]

        case .dialEnded:
            state.dialing = false
            return []

        case .clientEnded(let end):
            state.link = .lost
            switch end {
            case .closed:
                return [.finishEvents(nil)]
            case .lost(let detail):
                return [.finishEvents(.channelFailed(detail: "tmux control channel lost: \(detail)"))]
            case .exited:
                // The anchor died (below 3.6) or the server went away:
                // reattach when sessions remain, else idle. Neither is a
                // Host Connection Status change.
                return [.reattach]
            }

        case .distrust:
            guard state.standing == .inService else { return [] }
            state.standing = .distrusted
            // A dial in flight sees itself superseded and closes its client.
            state.generation &+= 1
            let closing = controlGeneration
            state.link = .lost
            return [.endControl(closing: closing)]

        case .close:
            guard state.standing != .closed else { return [] }
            state.standing = .closed
            let closing = controlGeneration
            state.link = .lost
            return [.endControl(closing: closing)]
        }
    }
}
