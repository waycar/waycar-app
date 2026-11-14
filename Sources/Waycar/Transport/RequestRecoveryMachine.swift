import Foundation

/// One `EventsSession.withTransport` request's recovery (HERDR-05): it waits
/// for a connection, runs, and after a link failure (the SSH connection
/// failed or swallowed the call) distrusts that connection when it is still
/// the installed one and replays once on the next one the run loop
/// installs.
///
/// A server's answer, a cancellation and any other failure are thrown as
/// they are. The replay happens at most once, and only for a request that
/// allows it: a link failure cannot say whether herdr already got the
/// request, so input that submits is never replayed (`retryOnLinkFailure:
/// false`) and the failure surfaces for a deliberate resend. A replay that
/// runs out its own time (`.timedOut`) reports the first failure instead.
/// Waiting for the replacement starts nothing on the Host: a run loop that
/// cannot connect releases the wait with its own failure.
struct RequestRecoveryMachine: StateMachine {
    enum Outcome: Equatable, Sendable {
        case succeeded
        /// The first attempt's failure is thrown.
        case firstFailure
        /// The replay's own failure is thrown.
        case replayFailure
    }

    enum State: Equatable, Sendable {
        /// Waiting for the installed Transport (or the run loop's next).
        case awaitingConnection
        /// The first attempt runs.
        case executing
        /// The first attempt failed on the link: waiting for the
        /// replacement to replay on.
        case replacing
        /// The one replay runs.
        case replaying
        case completed(Outcome)
    }

    enum Event: Equatable, Sendable {
        /// A Transport is in hand.
        case connected
        case succeeded
        /// The attempt failed. `linkFailure`: the connection failed or
        /// swallowed it (`isTransportLinkFailure`); `timedOut`: the failure
        /// is exactly `.timedOut`; `stillInstalled`: the Transport it ran
        /// on is still the installed one.
        case failed(linkFailure: Bool, timedOut: Bool, stillInstalled: Bool)
    }

    enum Effect: Equatable, Sendable {
        /// Record the proof of life and return the value.
        case noteActivity
        /// Distrust the installed connection, tell it, and end the live
        /// channel so the run loop re-dials silently.
        case distrust
        /// Wait for the Transport the run loop installs next.
        case awaitReplacement
        /// Throw the first attempt's failure.
        case throwFirstFailure
        /// Throw the replay's failure.
        case throwReplayFailure
    }

    private(set) var state: State = .awaitingConnection
    private let replaysLinkFailures: Bool

    init(replaysLinkFailures: Bool) {
        self.replaysLinkFailures = replaysLinkFailures
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.awaitingConnection, .connected):
            state = .executing
            return []
        case (.replacing, .connected):
            state = .replaying
            return []

        case (.executing, .succeeded), (.replaying, .succeeded):
            state = .completed(.succeeded)
            return [.noteActivity]

        case (.executing, .failed(let linkFailure, _, let stillInstalled)):
            guard linkFailure else {
                state = .completed(.firstFailure)
                return [.throwFirstFailure]
            }
            let distrust: [Effect] = stillInstalled ? [.distrust] : []
            guard replaysLinkFailures else {
                state = .completed(.firstFailure)
                return distrust + [.throwFirstFailure]
            }
            state = .replacing
            return distrust + [.awaitReplacement]

        case (.replaying, .failed(_, let timedOut, _)):
            // One replay only: whatever it failed with is the end.
            state = .completed(timedOut ? .firstFailure : .replayFailure)
            return [timedOut ? .throwFirstFailure : .throwReplayFailure]

        case (.awaitingConnection, .succeeded), (.awaitingConnection, .failed),
            (.replacing, .succeeded), (.replacing, .failed),
            (.executing, .connected), (.replaying, .connected),
            (.completed, _):
            return []
        }
    }
}
