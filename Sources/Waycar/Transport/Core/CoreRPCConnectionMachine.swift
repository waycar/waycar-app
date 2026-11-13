import Foundation

/// One framed `herdr-core connect`, as `CoreRPCClient` runs it: opened once
/// (marker, then `hello`), open with at most one events subscription, or
/// failed for good with the first reason (design §5).
///
/// The subscription is explicit: `requested` (sent, no reply read yet) and
/// `closed` (core sent CLOSE on the events channel) are the two states with
/// no events channel, and both refuse a second `events.subscribe`; only
/// `live` routes frames to the notification stream and runs the silence
/// check. A failed subscribe goes back to `none` and may be retried.
struct CoreRPCConnectionMachine: StateMachine {
    enum Subscription: Equatable, Sendable {
        case none
        case requested
        case live(channel: UInt32)
        case closed
    }

    enum State: Equatable, Sendable {
        case new
        case opening
        case open(Subscription)
        case failed(TransportError)
    }

    enum Event: Equatable, Sendable {
        case openRequested
        /// `hello` was answered and the bytes after it are frames.
        case handshakeFinished
        case subscribeRequested
        /// The subscribe reply named the events channel.
        case subscribeReplied(channel: UInt32)
        /// The subscribe call failed (an error reply, a reply with no
        /// channel, a timeout or cancellation).
        case subscribeFailed
        /// A CLOSE frame on the events channel.
        case eventsClosed
        /// `close()`, EOF, a read or write error, a malformed stream or
        /// silence: the connection ends.
        case failed(TransportError)
    }

    enum Effect: Equatable, Sendable {
        /// The request is refused with this error; nothing is written.
        case refuse(TransportError)
        /// Start the writer and the reader; frames count from now.
        case startIO
        /// Frames on the events channel count from now; arm the silence check.
        case startLiveness
        case stopLiveness
        /// Forget the notification stream without finishing it (the failed
        /// subscribe finishes its own).
        case forgetEvents
        /// Finish the notification stream with this failure.
        case endEvents(TransportError)
        /// Stop reading and writing, fail every pending call and the
        /// notification stream with this reason, and close the channel.
        case tearDown(TransportError)
    }

    static let notOpen = TransportError.channelFailed(detail: "the herdr-core connection is not open")
    static let alreadyOpened = TransportError.channelFailed(
        detail: "the herdr-core connection was already opened")
    static let eventsStreamClosed = TransportError.channelFailed(
        detail: "herdr-core closed the events stream")

    private(set) var state: State = .new

    init() {}

    var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    var isOpening: Bool { state == .opening }

    /// The channel whose DATA frames are notifications.
    var eventsChannel: UInt32? {
        if case .open(.live(let channel)) = state { return channel }
        return nil
    }

    /// Why a call cannot go now; nil while open.
    var callRefusal: TransportError? {
        switch state {
        case .open: nil
        case .failed(let error): error
        case .new, .opening: Self.notOpen
        }
    }

    /// The reason the connection ended, or `notOpen` while it has not.
    var failure: TransportError {
        if case .failed(let error) = state { return error }
        return Self.notOpen
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.new, .openRequested):
            state = .opening
            return []
        case (.opening, .openRequested), (.open, .openRequested):
            return [.refuse(Self.alreadyOpened)]
        case (.failed(let error), .openRequested):
            return [.refuse(error)]

        case (.opening, .handshakeFinished):
            state = .open(.none)
            return [.startIO]
        case (.new, .handshakeFinished), (.open, .handshakeFinished), (.failed, .handshakeFinished):
            return []

        case (.open(.none), .subscribeRequested):
            state = .open(.requested)
            return []
        case (.open, .subscribeRequested):
            return [.refuse(.eventsChannelAlreadyOpen)]
        case (.new, .subscribeRequested), (.opening, .subscribeRequested):
            return [.refuse(Self.notOpen)]
        case (.failed(let error), .subscribeRequested):
            return [.refuse(error)]

        case (.open(.requested), .subscribeReplied(let channel)):
            state = .open(.live(channel: channel))
            return [.startLiveness]
        case (.open, .subscribeReplied), (.new, .subscribeReplied), (.opening, .subscribeReplied),
            (.failed, .subscribeReplied):
            return []

        case (.open, .subscribeFailed):
            state = .open(.none)
            return [.forgetEvents, .stopLiveness]
        case (.new, .subscribeFailed), (.opening, .subscribeFailed), (.failed, .subscribeFailed):
            return []

        case (.open(.live), .eventsClosed):
            state = .open(.closed)
            return [.endEvents(Self.eventsStreamClosed), .stopLiveness]
        case (.open, .eventsClosed), (.new, .eventsClosed), (.opening, .eventsClosed),
            (.failed, .eventsClosed):
            return []

        case (.new, .failed(let error)), (.opening, .failed(let error)), (.open, .failed(let error)):
            state = .failed(error)
            return [.tearDown(error)]
        case (.failed, .failed):
            return []
        }
    }
}
