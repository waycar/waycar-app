/// A `CodexTransport`'s lifetime (CODEX-01): open until the server ends the
/// connection (lost), SSH trust is withdrawn (distrusted) or it is closed.
///
/// Only Close releases the shared SSH hold, once, whatever came before; a
/// failed open is abandoned, closed without releasing, because its caller
/// still owns the hold. Distrust after Close keeps it closed but stops the
/// reader and closes the RPC channel again, as it always did.
struct CodexConnectionMachine: StateMachine {
    enum State: Equatable, Sendable {
        /// Opening or open: requests and events go through.
        case open
        /// Codex ended the connection; the connector replaces the transport.
        case lost
        /// SSH trust was withdrawn: nothing goes through, the hold is kept.
        case distrusted
        /// Closed, or abandoned by a failed open.
        case closed
    }

    enum Event: Equatable, Sendable {
        /// The RPC reader ended, or a blocked thread could not be resumed.
        case connectionEnded
        case distrust
        case close
        /// The open failed: its caller keeps the SSH hold.
        case abandon
    }

    enum Effect: Equatable, Sendable {
        /// Fail the event subscriber with "Codex ended its connection."
        case failEvents
        case stopReader
        case cancelResumes
        /// Finish the event subscriber without an error.
        case endEvents
        case closeRPC
        case release
    }

    private(set) var state: State = .open

    static let ended = TransportError.channelFailed(detail: "Codex ended its connection.")

    var isLive: Bool { state == .open }

    /// What a request is refused with, or nil while open.
    var refusal: TransportError? {
        switch state {
        case .open: nil
        case .lost: Self.ended
        case .distrusted, .closed: .cancelled
        }
    }

    /// Whether the transport still owns the hold it would release on deinit.
    var releasesOnDeinit: Bool { state != .closed }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.open, .connectionEnded):
            state = .lost
            return [.failEvents]
        case (.lost, .connectionEnded), (.distrusted, .connectionEnded), (.closed, .connectionEnded):
            return []
        case (.closed, .distrust):
            return [.stopReader, .endEvents, .closeRPC]
        case (.open, .distrust), (.lost, .distrust), (.distrusted, .distrust):
            state = .distrusted
            return [.stopReader, .endEvents, .closeRPC]
        case (.closed, .close):
            return []
        case (.open, .close), (.lost, .close), (.distrusted, .close):
            state = .closed
            return [.stopReader, .cancelResumes, .endEvents, .closeRPC, .release]
        case (.open, .abandon), (.lost, .abandon), (.distrusted, .abandon), (.closed, .abandon):
            state = .closed
            return [.closeRPC]
        }
    }
}
