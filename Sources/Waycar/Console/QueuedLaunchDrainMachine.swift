/// One Host's Queued Launch drain. Only a verified foreground connection
/// supplies a generation. Enqueue, Retry and foreground reset its allowance;
/// an outstanding drain still owns its turn until its token finishes.
struct QueuedLaunchDrainMachine: StateMachine {
    enum State: Equatable, Sendable {
        case ready
        case attempted(generation: UInt64)
        /// The allowance may be reset while the old request awaits an
        /// answer. Keep its token, but do not suppress the next drain.
        case draining(token: UInt64, lastAttemptedGeneration: UInt64?)
    }
    enum Event: Equatable, Sendable {
        case wake(generation: UInt64?)
        case invalidate
        case finished(UInt64)
        case cancel
    }
    enum Effect: Equatable, Sendable {
        case start(UInt64)
        case finish(UInt64)
        case cancel(UInt64)
        case redrain
    }

    private(set) var state: State = .ready
    private var lastToken: UInt64 = 0

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .invalidate), (_, .wake(generation: nil)):
            switch state {
            case .draining(let token, _):
                state = .draining(token: token, lastAttemptedGeneration: nil)
            case .ready, .attempted:
                state = .ready
            }
            return []
        case (_, .cancel):
            let effects: [Effect]
            if case .draining(let token, _) = state {
                effects = [.cancel(token)]
            } else {
                effects = []
            }
            state = .ready
            return effects
        case (.ready, .wake(.some(let generation))):
            return start(on: generation)
        case (.attempted(let previous), .wake(.some(let generation))) where previous != generation:
            return start(on: generation)
        case (.draining(let token, let generation), .finished(let finished)) where token == finished:
            state = generation.map { .attempted(generation: $0) } ?? .ready
            return [.finish(token), .redrain]
        case (.ready, .finished), (.attempted, .finished), (.draining, .finished),
             (.attempted, .wake), (.draining, .wake):
            return []
        }
    }

    private mutating func start(on generation: UInt64) -> [Effect] {
        lastToken &+= 1
        state = .draining(token: lastToken, lastAttemptedGeneration: generation)
        return [.start(lastToken)]
    }
}
