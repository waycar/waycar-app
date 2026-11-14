import Foundation

/// The post-start settle of each pane a herdr Transport launched an Agent
/// in (`WaycarSSHTransport.scheduleLaunchSettle`): herdr 0.9.1 promotes a
/// pending launch only on a reconcile, so the Transport asks `agent.get`
/// from `delay` after the start, every `interval` while the launch is still
/// pending, and dispatches nothing past `window` after the start, queue
/// wait included (AGENTS.md, the launch_pending reconcile). The launch
/// itself never waits for it.
///
/// One settle runs per pane, under a token the machine mints: a new one
/// replaces the pane's running settle, whose Task the owner cancels, and
/// only the current token's poll or end changes the pane, so a replaced
/// settle never clears its replacement's slot. Closing cancels every
/// running settle; a settle scheduled after the close still starts, as it
/// always did (its requests fail on the closed Transport).
struct LaunchSettleMachine: StateMachine {
    /// The Transport's settle timings (`SSHTransportSettings`).
    struct Timing: Equatable, Sendable {
        var delay: Duration
        var interval: Duration
        var window: Duration
    }

    enum Phase: Equatable, Sendable {
        /// Waiting out the delay or an interval before the next `agent.get`.
        case delayed
        /// One `agent.get` is out.
        case polling
        /// herdr reported the launch no longer pending.
        case settled
        /// The `agent.get` failed (other than `agent_not_found`), or could
        /// not be dispatched inside the window.
        case failed
        /// The window ended before the next poll.
        case expired
        /// The Transport closed while it ran.
        case cancelled

        /// The settle's Task still runs or is about to start a poll.
        var isRunning: Bool {
            switch self {
            case .delayed, .polling: true
            case .settled, .failed, .expired, .cancelled: false
            }
        }
    }

    /// One pane's settle: the token of the settle that last ran there.
    struct PaneSettle: Equatable, Sendable {
        let token: UInt64
        var phase: Phase
    }

    /// What one settle `agent.get` found.
    enum PollResult: Equatable, Sendable {
        /// Still `launch_pending`, or `agent_not_found` (registration can
        /// lag the ack).
        case pending
        case notPending
        case failed
    }

    /// Why a settle's Task left its loop.
    enum Ending: Equatable, Sendable {
        /// Its last poll did not ask for another.
        case stopped
        /// The window ended before the next poll.
        case expired
        /// Its Task was cancelled.
        case cancelled
    }

    struct State: Equatable, Sendable {
        var settles: [String: PaneSettle] = [:]
        var isClosed = false
    }

    enum Event: Equatable, Sendable {
        /// Settle `pane`'s launch, started at `startedAt` (the ack, or an
        /// earlier try's dispatch); `immediately` (a recovery) skips the
        /// delay.
        case scheduled(
            pane: String, startedAt: ContinuousClock.Instant, now: ContinuousClock.Instant,
            immediately: Bool)
        /// The settle's Task is about to ask `agent.get`.
        case pollStarted(pane: String, token: UInt64)
        case polled(pane: String, token: UInt64, PollResult)
        /// The settle's Task left its loop.
        case ended(pane: String, token: UInt64, Ending)
        /// The Transport closed.
        case closed
    }

    enum Effect: Equatable, Sendable {
        /// Cancel the Task in the pane's slot, if any.
        case cancelTask(pane: String)
        /// Start the pane's settle Task: sleep `firstPause`, then poll every
        /// `interval` while told to, never once `windowEnd` has passed.
        case startTask(
            pane: String, token: UInt64, firstPause: Duration, interval: Duration,
            windowEnd: ContinuousClock.Instant)
        /// The poll found the launch pending: sleep `interval`, poll again.
        case pollAgain
        /// The settle is over: drop the pane's Task slot.
        case releaseSlot(pane: String)
        /// Cancel every running settle Task and drop every slot.
        case cancelAllTasks
    }

    let timing: Timing
    private(set) var state = State()
    private var lastToken: UInt64 = 0

    init(timing: Timing) {
        self.timing = timing
    }

    subscript(_ pane: String) -> PaneSettle? { state.settles[pane] }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .scheduled(let pane, let startedAt, let now, let immediately):
            // Whatever Task still holds the pane's slot, a running one or
            // one finishing after its last poll, stops being its owner.
            var effects: [Effect] = [.cancelTask(pane: pane)]
            lastToken += 1
            state.settles[pane] = PaneSettle(token: lastToken, phase: .delayed)
            let firstPause = immediately
                ? .zero : max(.zero, now.duration(to: startedAt + timing.delay))
            effects.append(
                .startTask(
                    pane: pane, token: lastToken, firstPause: firstPause,
                    interval: timing.interval, windowEnd: startedAt + timing.window))
            return effects

        case .pollStarted(let pane, let token):
            guard state.settles[pane] == PaneSettle(token: token, phase: .delayed) else {
                return []
            }
            state.settles[pane]?.phase = .polling
            return []

        case .polled(let pane, let token, let result):
            guard state.settles[pane] == PaneSettle(token: token, phase: .polling) else {
                return []
            }
            switch result {
            case .pending:
                state.settles[pane]?.phase = .delayed
                return [.pollAgain]
            case .notPending:
                state.settles[pane]?.phase = .settled
                return []
            case .failed:
                state.settles[pane]?.phase = .failed
                return []
            }

        case .ended(let pane, let token, let ending):
            // A replaced settle's slot is its replacement's, and a closed
            // one's is gone with the rest.
            guard let settle = state.settles[pane], settle.token == token,
                settle.phase != .cancelled
            else { return [] }
            if settle.phase.isRunning {
                switch ending {
                case .expired: state.settles[pane]?.phase = .expired
                case .stopped, .cancelled: state.settles[pane]?.phase = .cancelled
                }
            }
            return [.releaseSlot(pane: pane)]

        case .closed:
            state.isClosed = true
            for (pane, settle) in state.settles where settle.phase.isRunning {
                state.settles[pane]?.phase = .cancelled
            }
            return [.cancelAllTasks]
        }
    }
}
