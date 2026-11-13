/// An `OpenCodeTransport`'s lifetime and its one event stream (OPENCODE-01,
/// OPENCODE-02). The stream replays nothing (O14), so every
/// `server.connected` re-lists everything; the first complete re-list opens
/// the transport. Before it any failure fails the open; after it a failed
/// stream reconnects after each of `retryDelays` in turn, and a complete
/// re-list restores the whole budget. A 401 re-reads the password once and
/// reconnects at once; a 401 right after that re-read is an auth failure.
/// Running out of retries, or the auth failure, loses the transport and the
/// connector replaces it.
///
/// Only Close releases the shared SSH hold, once; a failed open is abandoned
/// with the hold left to its caller. Close and distrust forget the password.
struct OpenCodeConnectionMachine: StateMachine {
    enum Stream: Equatable, Sendable {
        /// Before the first complete re-list.
        case opening(reread: Bool)
        /// Connecting or connected after it, `failures` in a row so far.
        case live(failures: Int, reread: Bool)
        /// Waiting out a retry delay before reconnecting.
        case backingOff(failures: Int, reread: Bool)
        /// Re-reading the password after a 401.
        case rereading(opening: Bool, failures: Int)
        /// The open failed; the pump has stopped.
        case failed
    }

    enum State: Equatable, Sendable {
        case open(Stream)
        /// The stream ran out of retries or was refused its password.
        case lost
        /// SSH trust was withdrawn: nothing goes through, the hold is kept.
        case distrusted
        /// Closed, or abandoned by a failed open.
        case closed
    }

    enum Event: Equatable, Sendable {
        /// A `server.connected` was followed by a complete re-read.
        case relisted
        /// The stream (or its re-list) failed; `unauthorized` for an HTTP 401.
        case streamFailed(TransportError, unauthorized: Bool)
        /// The password re-read after a 401 finished, with its failure if any.
        case passwordRead(TransportError?)
        /// A new stream is about to be requested.
        case connecting
        case distrust
        case close
        case abandon
    }

    enum Effect: Equatable, Sendable {
        /// The first complete re-list: the open returns.
        case opened
        case reconnect
        case rereadPassword
        case wait(Duration)
        case failOpen(TransportError)
        /// The transport is lost: fail the event subscriber with `error`.
        case lose(TransportError)
        case stopPump
        case endEvents
        case forgetPassword
        case release
    }

    static let unauthorized = TransportError.apiRejected(
        code: "opencode_unauthorized", message: "The OpenCode server refused its password.")
    static let ended = TransportError.channelFailed(detail: "OpenCode ended its connection.")

    let retryDelays: [Duration]
    private(set) var state: State = .open(.opening(reread: false))

    init(retryDelays: [Duration]) {
        self.retryDelays = retryDelays
    }

    var isLive: Bool {
        if case .open = state { return true }
        return false
    }

    /// What a request is refused with, or nil while open.
    var refusal: TransportError? {
        switch state {
        case .open: nil
        case .lost: Self.ended
        case .distrusted, .closed: .cancelled
        }
    }

    var releasesOnDeinit: Bool { state != .closed }

    /// Whether a password read now may be kept in memory: never once Close
    /// or distrust forgot it (B-41).
    var keepsPassword: Bool {
        switch state {
        case .open, .lost: true
        case .distrusted, .closed: false
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.open(.opening), .relisted):
            state = .open(.live(failures: 0, reread: false))
            return [.opened]
        case (.open(.live), .relisted):
            state = .open(.live(failures: 0, reread: false))
            return []
        case (.open(.backingOff), .relisted), (.open(.rereading), .relisted), (.open(.failed), .relisted):
            return []

        case (.open(.opening(let reread)), .streamFailed(let failure, let unauthorized)):
            return failed(opening: true, failures: 0, reread: reread, failure, unauthorized: unauthorized)
        case (.open(.live(let failures, let reread)), .streamFailed(let failure, let unauthorized)):
            return failed(opening: false, failures: failures, reread: reread, failure, unauthorized: unauthorized)
        case (.open(.backingOff), .streamFailed), (.open(.rereading), .streamFailed), (.open(.failed), .streamFailed):
            return []

        case (.open(.rereading(let opening, let failures)), .passwordRead(nil)):
            state = .open(opening ? .opening(reread: true) : .live(failures: failures, reread: true))
            return [.reconnect]
        case (.open(.rereading(let opening, let failures)), .passwordRead(let failure?)):
            return decide(opening: opening, failures: failures, reread: true, failure)
        case (.open(.opening), .passwordRead), (.open(.live), .passwordRead), (.open(.backingOff), .passwordRead),
             (.open(.failed), .passwordRead):
            return []

        case (.open(.backingOff(let failures, let reread)), .connecting):
            state = .open(.live(failures: failures + 1, reread: reread))
            return []
        case (.open(.opening), .connecting), (.open(.live), .connecting), (.open(.rereading), .connecting),
             (.open(.failed), .connecting):
            return []

        case (.lost, .relisted), (.lost, .streamFailed), (.lost, .passwordRead), (.lost, .connecting),
             (.distrusted, .relisted), (.distrusted, .streamFailed), (.distrusted, .passwordRead),
             (.distrusted, .connecting),
             (.closed, .relisted), (.closed, .streamFailed), (.closed, .passwordRead), (.closed, .connecting):
            return []

        case (.closed, .distrust):
            return [.stopPump, .endEvents, .forgetPassword]
        case (.open, .distrust), (.lost, .distrust), (.distrusted, .distrust):
            state = .distrusted
            return [.stopPump, .endEvents, .forgetPassword]
        case (.closed, .close):
            return []
        case (.open, .close), (.lost, .close), (.distrusted, .close):
            state = .closed
            return [.stopPump, .endEvents, .forgetPassword, .release]
        case (.open, .abandon), (.lost, .abandon), (.distrusted, .abandon), (.closed, .abandon):
            state = .closed
            return [.stopPump]
        }
    }

    private mutating func failed(
        opening: Bool, failures: Int, reread: Bool, _ failure: TransportError, unauthorized: Bool
    ) -> [Effect] {
        guard unauthorized else { return decide(opening: opening, failures: failures, reread: false, failure) }
        guard reread else {
            state = .open(.rereading(opening: opening, failures: failures))
            return [.rereadPassword]
        }
        return decide(opening: opening, failures: failures, reread: true, Self.unauthorized)
    }

    private mutating func decide(opening: Bool, failures: Int, reread: Bool, _ failure: TransportError) -> [Effect] {
        if opening {
            state = .open(.failed)
            return [.failOpen(failure)]
        }
        guard failure != Self.unauthorized, failures < retryDelays.count else {
            state = .lost
            return [.lose(failure)]
        }
        state = .open(.backingOff(failures: failures, reread: reread))
        return [.wait(retryDelays[failures])]
    }
}
