import Foundation

/// One mosh attach session's lifecycle around its swift-mosh client
/// (MOSH-01), in four facets that move together under the session's lock:
///
/// - **Start**: `start()` runs in its own task, since it can wait forever
///   on a path that never becomes ready. Exactly one party settles it:
///   the start itself (started), or the watchdog or `end()` giving up on it
///   (abandoned); a start that succeeds after being abandoned shuts its own
///   session down.
/// - **First contact**: pending until the first server state (answered),
///   the watchdog's timeout in silence (timed out), or the run ending
///   (ended). The first to settle wins.
/// - **Ending**: `end()` was asked (with or without the shutdown
///   handshake). Nothing starts after it: no watchdog, no pump.
/// - **Link**: the connectivity last relayed, until the run ends.
///
/// The watchdog is armed once, under a token its elapse carries back.
/// Disarming it (an answer, the run's end, `end()`) cancels its sleep but,
/// as before, does not void it: a watchdog already past its sleep still
/// decides by the state (an answer or `end()` stops it; the run's end only
/// once first contact has settled). The session the user leaves or the app
/// suspends ends with the shutdown handshake; a first-contact timeout
/// abandons it (no server answered to acknowledge one).
struct MoshAttachMachine: StateMachine {
    enum Start: Equatable, Sendable {
        case starting
        case started
        /// The watchdog or `end()` stopped waiting for `start()`.
        case abandoned
    }

    struct State: Equatable, Sendable {
        var start: Start = .starting
        /// nil while pending.
        var firstContact: TerminalLinkFirstContact?
        var endRequested = false
        /// The armed watchdog's token.
        var watchdog: UInt64?
        var connectivity: TerminalLinkConnectivity?
        var linkEnded = false
    }

    /// How `start()` ended for the run waiting on it.
    enum StartReport: Equatable, Sendable {
        case started
        case failed
        case abandoned
    }

    enum Event: Equatable, Sendable {
        /// The run made its client session.
        case sessionCreated
        /// `start()` and the initial resize went through.
        case startSucceeded
        case startFailed
        /// `end()`; `abandoning` skips the shutdown handshake.
        case endRequested(abandoning: Bool)
        /// The watchdog's sleep ran out. It takes the start first, then,
        /// in a second step, first contact: as before, `end()` or the
        /// run's end can come between the two.
        case watchdogElapsed(token: UInt64)
        case firstContactTimedOut(abandonsStart: Bool)
        /// The first server state arrived.
        case firstHostOp
        /// The run is past its start and has the connectivity stream.
        case runReady
        /// The client's connectivity changed.
        case connectivity(TerminalLinkConnectivity)
        /// The run no longer needs the watchdog.
        case disarmWatchdog
        /// The run is over: first contact settles, if still pending, then,
        /// in a second step, the link ends.
        case runEnded
        case linkEnded
    }

    enum Effect: Equatable, Sendable {
        /// Arm the first-contact watchdog under this token.
        case armWatchdog(token: UInt64)
        /// The watchdog's second step: try to time first contact out.
        case timeOutFirstContact(abandonsStart: Bool)
        /// `end()` came first: finish the output and end the run.
        case skipRun
        case reportStart(StartReport)
        /// A start nobody waits for any more: shut its session down.
        case shutdownStartedSession
        case cancelWatchdog
        /// `end()`'s stop: the handshake, or abandon.
        case stopSession(abandoning: Bool)
        /// Resume everyone waiting for first contact.
        case settleFirstContact(TerminalLinkFirstContact)
        /// The watchdog's timeout: log it and fail the output.
        case failFirstContact
        /// Stop the session without the handshake: nothing answered to
        /// acknowledge one.
        case abandonSession
        /// Join the registry, relay connectivity, pump input.
        case startRelayAndPump
        case relayConnectivity(TerminalLinkConnectivity)
        /// Leave the registry, finish connectivity subscribers, stop the relay.
        case endLink
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var hostAnswered: Bool {
        state.firstContact == .answered
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .sessionCreated:
            guard !state.endRequested else { return [.skipRun] }
            lastToken += 1
            state.watchdog = lastToken
            return [.armWatchdog(token: lastToken)]

        case .startSucceeded:
            switch state.start {
            case .starting:
                state.start = .started
                return [.reportStart(.started)]
            case .started, .abandoned:
                return [.shutdownStartedSession]
            }

        case .startFailed:
            return [.reportStart(.failed)]

        case .endRequested(let abandoning):
            state.endRequested = true
            var effects: [Effect] = [.cancelWatchdog]
            switch state.start {
            case .starting:
                state.start = .abandoned
                effects.append(.reportStart(.abandoned))
            case .started, .abandoned:
                break
            }
            effects.append(.stopSession(abandoning: abandoning))
            return effects

        case .watchdogElapsed(let token):
            guard state.watchdog == token, !hostAnswered, !state.endRequested else { return [] }
            let abandonsStart = state.start == .starting
            if abandonsStart { state.start = .abandoned }
            return [.timeOutFirstContact(abandonsStart: abandonsStart)]

        case .firstContactTimedOut(let abandonsStart):
            // An answer or the run's end may have settled it meanwhile:
            // only the party that settles first contact fails the output.
            guard state.firstContact == nil else { return [] }
            state.firstContact = .timedOut
            var effects: [Effect] = [.settleFirstContact(.timedOut), .failFirstContact]
            if abandonsStart { effects.append(.reportStart(.abandoned)) }
            effects.append(.abandonSession)
            return effects

        case .firstHostOp:
            var effects: [Effect] = []
            if state.firstContact == nil {
                state.firstContact = .answered
                effects.append(.settleFirstContact(.answered))
            }
            effects.append(.cancelWatchdog)
            return effects

        case .runReady:
            return state.endRequested ? [] : [.startRelayAndPump]

        case .connectivity(let connectivity):
            guard !state.linkEnded, state.connectivity != connectivity else { return [] }
            state.connectivity = connectivity
            return [.relayConnectivity(connectivity)]

        case .disarmWatchdog:
            return [.cancelWatchdog]

        case .runEnded:
            guard state.firstContact == nil else { return [] }
            state.firstContact = .ended
            return [.settleFirstContact(.ended)]

        case .linkEnded:
            state.linkEnded = true
            return [.endLink]
        }
    }
}
