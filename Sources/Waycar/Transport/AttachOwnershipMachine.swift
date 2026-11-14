import Foundation

/// Which herdr Attach targets one Transport owns, and whether it still
/// takes Attaches (`WaycarSSHTransport.attachTerminal`, `close()`). Each
/// target has one owner at a time (ADR 0011: one reserved PTY exec channel
/// per target); each opening gets a reader id the machine mints, so the
/// session's report that a channel ended moves only that reader's target.
///
/// A channel can end before `attachTerminal` has recorded it: the opening
/// remembers that, and the open then frees the target instead of recording
/// a dead Attach. A closed Transport refuses an Attach before anything
/// opens (B-32). Closing takes the live Attaches for the owner to end once
/// its session hold is released; their targets stay taken until their
/// channels end. An opening that completes after the close is still
/// recorded live, as it always was: nothing ends it but its own channel.
struct AttachOwnershipMachine: StateMachine {
    enum Owner: Equatable, Sendable {
        case open
        /// `close()` has begun: nothing new attaches.
        case closing
        case closed
    }

    enum Target: Equatable, Sendable {
        /// `attachTerminal` is opening `reader`; `endedEarly` once its
        /// channel ended before the open returned.
        case opening(reader: UInt64, endedEarly: Bool)
        case live(reader: UInt64)
        /// `close()` took this live Attach to end it; its channel has not
        /// ended yet.
        case closing(reader: UInt64)
    }

    struct State: Equatable, Sendable {
        var owner: Owner = .open
        /// A target with no entry is free.
        var targets: [TerminalAttachTarget: Target] = [:]
    }

    enum Event: Equatable, Sendable {
        case attachRequested(TerminalAttachTarget)
        /// The session opened `reader`'s channel.
        case opened(TerminalAttachTarget, reader: UInt64)
        /// Opening `reader` failed; no channel exists.
        case openFailed(TerminalAttachTarget, reader: UInt64)
        /// The session closed `reader`'s channel.
        case channelEnded(TerminalAttachTarget, reader: UInt64)
        case closeRequested
        case closeFinished
    }

    enum Effect: Equatable, Sendable {
        /// Fail the Attach with this error; nothing opens.
        case refuse(TransportError)
        /// Open the channel as `reader`.
        case open(reader: UInt64)
        /// Record `reader`'s Attach so `close()` can end it.
        case keep(reader: UInt64)
        /// Drop `reader`'s recorded Attach.
        case forget(reader: UInt64)
        /// Begin closing: take every recorded Attach.
        case takeLiveAttaches
    }

    /// What a closed Transport answers, as every request on it does.
    static let closedError = TransportError.sshUnreachable(detail: "the SSH connection is closed")

    private(set) var state = State()
    private var lastReader: UInt64 = 0

    init() {}

    /// True from the start of `close()`.
    var isClosed: Bool { state.owner != .open }

    subscript(_ target: TerminalAttachTarget) -> Target? { state.targets[target] }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .attachRequested(let target):
            guard state.owner == .open else { return [.refuse(Self.closedError)] }
            guard state.targets[target] == nil else {
                return [.refuse(.terminalChannelAlreadyOpen)]
            }
            lastReader &+= 1
            state.targets[target] = .opening(reader: lastReader, endedEarly: false)
            return [.open(reader: lastReader)]

        case .opened(let target, let reader):
            switch state.targets[target] {
            case .opening(reader: reader, endedEarly: true):
                state.targets[target] = nil
                return []
            case .opening(reader: reader, endedEarly: false):
                state.targets[target] = .live(reader: reader)
                return [.keep(reader: reader)]
            case .opening, .live, .closing, nil:
                return []
            }

        case .openFailed(let target, let reader):
            guard case .opening(reader: reader, endedEarly: _) = state.targets[target] else {
                return []
            }
            state.targets[target] = nil
            return []

        case .channelEnded(let target, let reader):
            switch state.targets[target] {
            case .live(reader: reader), .closing(reader: reader):
                state.targets[target] = nil
            case .opening(reader: reader, endedEarly: _):
                state.targets[target] = .opening(reader: reader, endedEarly: true)
            case .opening, .live, .closing, nil:
                break
            }
            return [.forget(reader: reader)]

        case .closeRequested:
            guard state.owner == .open else { return [] }
            state.owner = .closing
            for (target, entry) in state.targets {
                if case .live(let reader) = entry {
                    state.targets[target] = .closing(reader: reader)
                }
            }
            return [.takeLiveAttaches]

        case .closeFinished:
            guard state.owner == .closing else { return [] }
            state.owner = .closed
            return []
        }
    }
}
