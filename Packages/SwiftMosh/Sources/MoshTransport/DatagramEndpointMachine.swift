/// The lifecycle of `NetworkDatagramEndpoint`'s UDP connection: stopped,
/// connecting, open, or failed (held until `stop()`, so a second start is
/// refused as before). Every start mints a connection token that the
/// connection's state and receive callbacks carry back; a callback whose
/// token is not the held connection's belongs to a connection `stop()` let
/// go of and is ignored (B-28, patch 18). (Waycar patch.)
package struct DatagramEndpointMachine: StateMachine {
    package enum State: Equatable, Sendable {
        /// No connection: never started, or stopped.
        case stopped
        /// `start()` waits for the connection to report ready.
        case connecting(connection: UInt64)
        /// Ready: `start()` returned and arms the receive loop.
        case open(connection: UInt64)
        /// The connection failed or was cancelled by the system. It stays
        /// the endpoint's until `stop()`: a start is refused, sends and
        /// receives still go to it, and its receive callbacks still count.
        case failed(connection: UInt64)
    }

    /// What `NWConnection`'s state handler reported, as far as the endpoint
    /// cares.
    package enum Report: Equatable, Sendable {
        case ready
        case failed(String)
        case cancelled
        /// `.setup`, `.preparing`, `.waiting`: nothing to do.
        case other
    }

    package enum Failure: Equatable, Sendable {
        case network(String)
        case cancelled
    }

    package enum Event: Equatable, Sendable {
        /// `start()` passed its checks and opens a connection.
        case start
        /// The connection's state handler fired.
        case reported(connection: UInt64, Report)
        /// `start()` returned from its wait for this connection.
        case startReturned(connection: UInt64)
        /// The connection completed a receive.
        case receiveCompleted(connection: UInt64)
        case stop
    }

    package enum Effect: Equatable, Sendable {
        /// Make, hand the token to, and start a new connection.
        case open(connection: UInt64)
        /// `start()`'s wait ends: it returns.
        case resumeStart
        /// Fail `start()`'s wait (if any) and every waiting receive.
        case failAll(Failure)
        /// Ask the held connection for its next datagram.
        case armReceive(connection: UInt64)
        /// Deliver the completed receive's datagram or error.
        case deliverReceive
        /// Cancel the held connection, fail `start()`'s wait and every
        /// waiting receive as cancelled, drop buffered datagrams.
        case close
    }

    package private(set) var state: State = .stopped
    private var lastConnection: UInt64 = 0

    package init() {}

    /// The token of the connection the endpoint holds, if any.
    package var connection: UInt64? {
        switch state {
        case .stopped: nil
        case .connecting(let connection), .open(let connection), .failed(let connection): connection
        }
    }

    package mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.stopped, .start):
            lastConnection += 1
            state = .connecting(connection: lastConnection)
            return [.open(connection: lastConnection)]
        case (.connecting, .start), (.open, .start), (.failed, .start):
            // The owner refuses a start unless stopped, before its port checks.
            return []

        case (.connecting(let held), .reported(let connection, let report)) where connection == held:
            switch report {
            case .ready:
                state = .open(connection: held)
                return [.resumeStart]
            case .failed(let message):
                state = .failed(connection: held)
                return [.failAll(.network(message))]
            case .cancelled:
                state = .failed(connection: held)
                return [.failAll(.cancelled)]
            case .other:
                return []
            }
        case (.open(let held), .reported(let connection, let report)) where connection == held,
             (.failed(let held), .reported(let connection, let report)) where connection == held:
            switch report {
            case .failed(let message):
                state = .failed(connection: held)
                return [.failAll(.network(message))]
            case .cancelled:
                state = .failed(connection: held)
                return [.failAll(.cancelled)]
            case .ready, .other:
                return []
            }
        case (.stopped, .reported), (.connecting, .reported), (.open, .reported), (.failed, .reported):
            // A connection the endpoint no longer holds (B-28).
            return []

        case (.open(let held), .startReturned(let connection)) where connection == held,
             (.failed(let held), .startReturned(let connection)) where connection == held:
            return [.armReceive(connection: held)]
        case (.stopped, .startReturned), (.connecting, .startReturned), (.open, .startReturned),
             (.failed, .startReturned):
            return []

        case (.connecting(let held), .receiveCompleted(let connection)) where connection == held,
             (.open(let held), .receiveCompleted(let connection)) where connection == held,
             (.failed(let held), .receiveCompleted(let connection)) where connection == held:
            return [.deliverReceive, .armReceive(connection: held)]
        case (.stopped, .receiveCompleted), (.connecting, .receiveCompleted), (.open, .receiveCompleted),
             (.failed, .receiveCompleted):
            // A connection the endpoint no longer holds (B-28).
            return []

        case (.stopped, .stop), (.connecting, .stop), (.open, .stop), (.failed, .stop):
            state = .stopped
            return [.close]
        }
    }
}
