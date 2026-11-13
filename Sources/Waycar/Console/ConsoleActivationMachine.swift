/// The Console's activation and the device's network path (#105).
///
/// Activation: resume, reactivate and suspend are each several awaits long,
/// so they run one at a time in call order, each behind the last one
/// enqueued; a transition makes the Console active or inactive as it
/// begins, not as it is enqueued. Without the chain a resume racing a
/// suspend could finish first and leave every Host suspended.
///
/// Network path: each follow's first reading is its baseline: it seeds the
/// offline flag but is no change. Every later reading is a change, one that
/// comes back after none is a recovery. A reading of none settles offline
/// waiters at once. Each follow keeps its own last reading, so a follow
/// replaced while a reading was still buffered for it judges that reading
/// against its own, as before. What a change re-proves, and whether the
/// Console is active then, is the owner's, in a Task of its own per change.
struct ConsoleActivationMachine: StateMachine {
    enum Path: Equatable, Sendable {
        case awaitingBaseline
        case known(NetworkPathKey?)
    }

    struct State: Equatable, Sendable {
        var isActive = false
        /// The last transition enqueued, until it finishes.
        var tail: UInt64?
        /// Each follow's last reading, by its token.
        var follows: [UInt64: Path] = [:]
    }

    enum Event: Equatable, Sendable {
        case enqueued
        /// A transition began: `active` for resume and reactivate.
        case began(active: Bool)
        case finished(UInt64)
        case followed
        case pathRead(follow: UInt64, path: NetworkPathKey?)
        case followEnded(UInt64)
    }

    enum Effect: Equatable, Sendable {
        /// Run the transition `token` once `after` (if any) has finished.
        case run(UInt64, after: UInt64?)
        /// Drop the finished transition's Task.
        case release(UInt64)
        /// Follow the path's readings under this token.
        case follow(UInt64)
        case setOffline(Bool)
        /// The path is gone: settle what fails fast offline.
        case lostPath
        case pathChanged(NetworkPathKey?, recovered: Bool)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var isActive: Bool { state.isActive }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .enqueued:
            let previous = state.tail
            lastToken &+= 1
            state.tail = lastToken
            return [.run(lastToken, after: previous)]
        case .began(let active):
            state.isActive = active
            return []
        case .finished(let token):
            if state.tail == token { state.tail = nil }
            return [.release(token)]
        case .followed:
            lastToken &+= 1
            state.follows[lastToken] = .awaitingBaseline
            return [.follow(lastToken)]
        case .pathRead(let follow, let path):
            guard let previous = state.follows[follow] else { return [] }
            state.follows[follow] = .known(path)
            var effects: [Effect] = [.setOffline(path == nil)]
            if path == nil { effects.append(.lostPath) }
            if case .known(let last) = previous {
                effects.append(.pathChanged(path, recovered: last == nil && path != nil))
            }
            return effects
        case .followEnded(let follow):
            state.follows[follow] = nil
            return []
        }
    }
}
