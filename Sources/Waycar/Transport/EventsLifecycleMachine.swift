import Foundation

/// The herdr events session's lifecycle (HERDR-01): whether it is suspended,
/// active or ended, which activation is current, whether a teardown runs,
/// where the current activation's run loop stands, and the dial, redial and
/// backoff bookkeeping that lets a returning network path cut a reconnect
/// short.
///
/// The dimensions are kept apart because they are apart in time. A
/// suspension turns the session suspended at once, while its run loop goes
/// on until the teardown that follows cancels it, and a dial or a backoff
/// begun before can still finish meanwhile; a Reconnect's teardown runs
/// while the session stays active. `stage` names the state a reader means:
/// suspended, connecting, connected, backingOff, failed, windingDown or
/// ended.
///
/// Every activation (`resume()` from suspended, a Reconnect) mints the next
/// activation token, and a run loop or its work counts only under the token
/// it was spawned with. A dial gets its own token, so a redial cancels only
/// the dial it found stuck, and a dial a redial started (`afterRedial`) is
/// left to the link that came back. A backoff's sleep gets a timer token;
/// only the backoff still current clears itself when it wakes.
struct EventsLifecycleMachine: StateMachine {
    enum Phase: Equatable, Sendable {
        case suspended, active, ended
    }

    /// What the current activation's run loop last announced.
    enum Connection: Equatable, Sendable {
        /// `.connecting`: establishing its first connection and channel.
        case connecting
        /// `.connected`: the events channel is live.
        case connected
        /// `.reconnecting`: the backoff after a retryable failure, and the
        /// dial that follows it.
        case backingOff
        /// `.failed`: stopped on a failure no retry can repair.
        case failed
    }

    enum Stage: Equatable, Sendable {
        case suspended, connecting, connected, backingOff, failed, windingDown, ended
    }

    struct Dial: Equatable, Sendable {
        let id: UInt64
        /// Started after a redial, with the link already known to be back.
        let afterRedial: Bool
    }

    struct State: Equatable, Sendable {
        var phase: Phase = .suspended
        var connection: Connection = .connecting
        /// The current activation (`activationGeneration`).
        var activation: UInt64 = 0
        /// A teardown runs (`isWindingDown`).
        var windingDown = false
        /// The current activation's run loop is spawned and not yet
        /// cancelled by a teardown (`runTask != nil`).
        var running = false
        /// The backoff sleeping now, by its timer token.
        var backoff: UInt64?
        /// The dial the run loop waits on.
        var dial: Dial?
        /// A redial came since the last dial started: the next dial is the
        /// redial's own. Cleared once the events channel is live.
        var redialSinceLastDial = false
        /// A redial cancelled the dial in flight: the run loop dials again
        /// at once instead of treating the cancellation as a failure.
        var redialRequested = false
        /// What set the next connect off, for its report (#105).
        var trigger: NetworkAnalytics.ConnectTrigger = .launch
        var hasActivated = false
    }

    enum Event: Equatable, Sendable {
        /// `resume()`, or a Reconnect (`trigger` `.retry`) while not active.
        case activate(trigger: NetworkAnalytics.ConnectTrigger?)
        /// A Reconnect while active: a new activation before the teardown.
        case restart
        /// The Reconnect's teardown finished for `activation`.
        case restartWoundDown(activation: UInt64)
        /// `suspend()`.
        case suspend
        /// The suspension's teardown finished.
        case suspendWoundDown
        /// `end()`.
        case end
        /// The end's teardown finished.
        case endWoundDown
        case windDownStarted
        /// The teardown stops the backoff.
        case backoffAbandoned
        /// The teardown stops the run loop.
        case runAbandoned
        case windDownEnded
        /// The run loop starts a dial.
        case dialStarted
        /// The dial returned a connection.
        case dialSucceeded
        /// The dial under `id` returned or threw.
        case dialEnded(id: UInt64)
        /// The link is back (`redialNow()`); `channelLive` while the events
        /// channel is live.
        case redial(channelLive: Bool, trigger: NetworkAnalytics.ConnectTrigger)
        /// The pool stopped joining the dial `id` that the redial found.
        case dialAbandoned(id: UInt64)
        /// The run loop's connect or subscribe failed.
        case connectFailed
        /// The events channel went live.
        case wentLive
        /// The run loop stopped on `failure`, which no retry repairs.
        case failed(TransportError)
        /// The run loop backs off before attempt `attempt`.
        case backoffStarted(attempt: Int, delay: Duration, failure: TransportError)
        /// The backoff under `timer` woke.
        case backoffElapsed(timer: UInt64)
    }

    enum Effect: Equatable, Sendable {
        case announce(EventsSessionStatus)
        /// Spawn the run loop for `activation`.
        case spawnRun(activation: UInt64)
        /// Cancel the run loop without waiting for it.
        case cancelRun
        /// Tear down (`windDown`): the activation's work, channel and Transport.
        case windDown
        /// Track the dial starting under `id`.
        case dialing(id: UInt64)
        /// Stop tracking the dial.
        case forgetDial
        /// Ask the pool to stop joining the dial `id`.
        case abandonDial(id: UInt64)
        /// Cancel the dial the redial found stuck.
        case cancelDial
        /// Wake the backoff now, without clearing it.
        case cutBackoff
        /// Sleep `delay` under `timer`.
        case sleep(timer: UInt64, delay: Duration)
        /// Cancel and forget the backoff's sleep.
        case cancelBackoff
        /// Forget the backoff's sleep, which woke.
        case forgetBackoff
        /// The run loop dials again at once: no backoff, no status.
        case dialAgain
    }

    private(set) var state = State()
    private var lastDial: UInt64 = 0
    private var lastTimer: UInt64 = 0

    init() {}

    var stage: Stage {
        if state.windingDown { return .windingDown }
        switch state.phase {
        case .suspended: return .suspended
        case .ended: return .ended
        case .active:
            switch state.connection {
            case .connecting: return .connecting
            case .connected: return .connected
            case .backingOff: return .backingOff
            case .failed: return .failed
            }
        }
    }

    var phase: Phase { state.phase }
    var activation: UInt64 { state.activation }
    var isWindingDown: Bool { state.windingDown }

    /// Whether work spawned under `activation` still belongs to the session.
    func isCurrent(_ activation: UInt64) -> Bool {
        state.phase == .active && state.activation == activation
    }

    /// Whether a request may wait for the Transport the run loop installs
    /// next.
    var acceptsWaiters: Bool {
        state.phase == .active && !state.windingDown && state.running
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .activate(let trigger):
            guard state.phase == .suspended else { return [] }
            state.phase = .active
            state.trigger = trigger ?? (state.hasActivated ? .foreground : .launch)
            state.hasActivated = true
            state.redialSinceLastDial = false
            state.activation &+= 1
            state.connection = .connecting
            state.running = true
            return [.announce(.connecting), .spawnRun(activation: state.activation)]

        case .restart:
            guard state.phase == .active else { return [] }
            state.activation &+= 1
            state.trigger = .retry
            state.connection = .connecting
            return [.announce(.connecting), .windDown]

        case .restartWoundDown(let activation):
            guard isCurrent(activation) else { return [] }
            state.running = true
            return [.spawnRun(activation: activation)]

        case .suspend:
            guard state.phase == .active else { return [] }
            state.phase = .suspended
            return [.windDown]

        case .suspendWoundDown:
            return [.announce(.suspended)]

        case .end:
            guard state.phase != .ended else { return [] }
            state.phase = .ended
            return [.windDown]

        case .endWoundDown:
            return [.announce(.ended)]

        case .windDownStarted:
            state.windingDown = true
            return []

        case .backoffAbandoned:
            state.backoff = nil
            return [.cancelBackoff]

        case .runAbandoned:
            state.running = false
            return [.cancelRun]

        case .windDownEnded:
            state.redialRequested = false
            state.windingDown = false
            return []

        case .dialStarted:
            lastDial &+= 1
            state.dial = Dial(id: lastDial, afterRedial: state.redialSinceLastDial)
            state.redialSinceLastDial = false
            return [.dialing(id: lastDial)]

        case .dialSucceeded:
            state.redialRequested = false
            return []

        case .dialEnded(let id):
            guard state.dial?.id == id else { return [] }
            state.dial = nil
            return [.forgetDial]

        case .redial(let channelLive, let trigger):
            guard state.phase == .active, !state.windingDown, !channelLive else { return [] }
            if state.dial?.afterRedial == true { return [] }
            state.trigger = trigger
            state.redialSinceLastDial = true
            guard let stuck = state.dial else { return [.cutBackoff] }
            state.redialRequested = true
            return [.abandonDial(id: stuck.id)]

        case .dialAbandoned(let id):
            guard state.dial?.id == id else { return [.cutBackoff] }
            return [.cancelDial, .cutBackoff]

        case .connectFailed:
            guard state.redialRequested else { return [] }
            state.redialRequested = false
            return [.dialAgain]

        case .wentLive:
            state.connection = .connected
            state.redialSinceLastDial = false
            return [.announce(.connected)]

        case .failed(let failure):
            state.connection = .failed
            return [.announce(.failed(failure))]

        case .backoffStarted(let attempt, let delay, let failure):
            state.trigger = .retry
            state.connection = .backingOff
            lastTimer &+= 1
            state.backoff = lastTimer
            return [
                .announce(.reconnecting(attempt: attempt, delay: delay, failure: failure)),
                .sleep(timer: lastTimer, delay: delay),
            ]

        case .backoffElapsed(let timer):
            guard state.backoff == timer else { return [] }
            state.backoff = nil
            return [.forgetBackoff]
        }
    }
}
