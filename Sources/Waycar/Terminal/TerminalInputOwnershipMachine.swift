import Foundation

/// Owns the live Attach generation and the decision to hold user input while
/// tmux leaves history. The owner keeps the buffered bytes and Task as
/// resources: appending bytes must not copy a growing queue through State.
struct TerminalInputOwnershipMachine: StateMachine {
    struct Generation: Sendable, Hashable {
        fileprivate let value: UInt64
    }

    struct Input: Equatable, Sendable {
        let data: Data
        let source: AttachUserMessageIndex.OutgoingSource
    }

    enum State: Equatable, Sendable {
        case detached
        case live(Generation)
        case releasingHeldInput(Generation)
    }

    enum Event: Equatable, Sendable {
        case beginSession
        case endSession(Generation)
        case detachSession
        case input(Input, isTerminalReport: Bool, historyHoldsInput: Bool)
        case historyLeft(Generation)
    }

    enum Effect: Equatable, Sendable {
        case deliver(Input)
        case hold(Input)
        case leaveHistory(Generation)
        case releaseHeldInput
    }

    private(set) var state: State = .detached
    private var lastGeneration: UInt64 = 0

    /// The token minted by the latest begin, including after it has ended.
    var latestGeneration: Generation { Generation(value: lastGeneration) }

    var liveGeneration: Generation? {
        switch state {
        case .detached: nil
        case .live(let generation), .releasingHeldInput(let generation): generation
        }
    }

    var isHoldingInput: Bool {
        if case .releasingHeldInput = state { true } else { false }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .beginSession):
            lastGeneration &+= 1
            state = .live(latestGeneration)
            return []
        case (_, .detachSession):
            state = .detached
            return []
        case (.live(let generation), .endSession(let ended)),
             (.releasingHeldInput(let generation), .endSession(let ended)):
            guard generation == ended else { return [] }
            state = .detached
            return []
        case (.live(let generation), .input(let input, let isReport, let holdsInput)):
            guard !isReport, holdsInput else { return [.deliver(input)] }
            state = .releasingHeldInput(generation)
            return [.hold(input), .leaveHistory(generation)]
        case (.releasingHeldInput, .input(let input, let isReport, _)):
            return isReport ? [.deliver(input)] : [.hold(input)]
        case (.releasingHeldInput(let generation), .historyLeft(let finished)):
            guard generation == finished else { return [] }
            state = .live(generation)
            return [.releaseHeldInput]
        case (.detached, .endSession), (.detached, .input), (.detached, .historyLeft),
             (.live, .historyLeft):
            return []
        }
    }
}
