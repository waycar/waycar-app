/// Debounced phone-link readiness. Scene/reported reachability are inputs;
/// readiness, down and doubt are mutually exclusive verdicts, never flags.
struct WatchLinkMachine: StateMachine {
    enum Phase: Equatable, Sendable {
        case waiting
        case ready
        case down
        case settling(token: UInt64, doubt: Bool)
    }
    struct State: Equatable, Sendable {
        var active: Bool
        var reachable: Bool?
        var phase: Phase
    }
    struct Requests: Equatable, Sendable {
        var inFlight: Bool
        var paused: Bool
    }
    enum Event: Equatable, Sendable {
        case evaluate(Requests)
        case active(Bool, liveReachable: Bool, Requests)
        case reachable(Bool, Requests)
        case linkError(Requests)
        case elapsed(UInt64, liveReachable: Bool)
    }
    enum Effect: Equatable, Sendable {
        case cancelDebounce
        case armDebounce(UInt64)
        case pause
        case resume
        case transmitWaiting
        case losePaused
        case failWaiting
    }
    private(set) var state: State
    private var lastToken: UInt64 = 0

    init(active: Bool, reachable: Bool?) {
        state = State(active: active, reachable: reachable,
                      phase: active && reachable == true ? .ready : .waiting)
    }
    var isReady: Bool { state.phase == .ready }
    var isDown: Bool { state.phase == .down }
    private var doubt: Bool {
        if case .settling(_, let doubt) = state.phase { return doubt }
        return false
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .evaluate(let requests): return evaluate(requests, doubt: doubt)
        case .active(let active, let live, let requests):
            guard state.active != active else { return [] }
            state.active = active
            if active, state.reachable != nil { state.reachable = live }
            return evaluate(requests, doubt: active ? false : doubt)
        case .reachable(let reachable, let requests):
            guard state.reachable != reachable || doubt else { return [] }
            state.reachable = reachable
            return evaluate(requests, doubt: false)
        case .linkError(let requests): return evaluate(requests, doubt: true)
        case .elapsed(let token, let live):
            guard case .settling(let current, let doubt) = state.phase, current == token else { return [] }
            if doubt { state.reachable = live }
            if state.active, state.reachable == true {
                state.phase = .ready
                return [.resume, .transmitWaiting]
            }
            state.phase = state.active && state.reachable == false ? .down : .waiting
            return state.phase == .down ? [.losePaused, .failWaiting] : [.losePaused]
        }
    }

    private mutating func evaluate(_ requests: Requests, doubt: Bool) -> [Effect] {
        var effects: [Effect] = [.cancelDebounce]
        let wasReady = isReady
        let wasDown = isDown
        var paused = requests.paused
        if state.active && state.reachable == true && !doubt {
            if paused {
                state.phase = .ready
                return effects + [.resume, .transmitWaiting]
            }
            if wasReady { return effects }
        } else {
            if wasReady {
                paused = paused || requests.inFlight
                effects.append(.pause)
            }
            let staysDown = wasDown && state.active && state.reachable != true
            if !paused && (!state.active || staysDown) {
                state.phase = staysDown ? .down : .waiting
                return effects
            }
        }
        lastToken += 1
        state.phase = .settling(token: lastToken, doubt: doubt)
        return effects + [.armDebounce(lastToken)]
    }
}
