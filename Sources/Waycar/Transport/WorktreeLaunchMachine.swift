import Foundation

/// Evidence retained across transport retries. Ownership and dispatch are
/// separate: an adopted typed branch can receive a start without ever becoming
/// this launch's worktree. No later record may erase possible Host-side work.
struct WorktreeLaunchMachine: StateMachine {
    enum Ownership: Equatable, Sendable {
        case untouched
        case createUnconfirmed
        /// The wrapper also accepts ownership recorded before the dispatch
        /// callback; retain whether that callback has actually run.
        case known(WorktreeLaunchAttempt.Worktree)
        case created(WorktreeLaunchAttempt.Worktree)

        var worktree: WorktreeLaunchAttempt.Worktree? {
            switch self {
            case .known(let worktree), .created(let worktree): worktree
            case .untouched, .createUnconfirmed: nil
            }
        }

        var createDispatched: Bool {
            switch self {
            case .createUnconfirmed, .created: true
            case .untouched, .known: false
            }
        }
    }

    enum State: Equatable, Sendable {
        case ready(Ownership)
        case agentMayRun(Ownership, at: ContinuousClock.Instant)
        case shellTabMayExist(Ownership)
        /// Keep both pieces of evidence if callers record both dispatches;
        /// neither is permission to forget an Agent or remove its worktree.
        case agentAndShellMayExist(Ownership, at: ContinuousClock.Instant)

        var ownership: Ownership {
            switch self {
            case .ready(let ownership), .agentMayRun(let ownership, _),
                 .shellTabMayExist(let ownership), .agentAndShellMayExist(let ownership, _):
                ownership
            }
        }

        /// Once true, retries reconcile instead of sending another create.
        var createDispatched: Bool { ownership.createDispatched }
        var worktree: WorktreeLaunchAttempt.Worktree? { ownership.worktree }
        var agentStartDispatchedAt: ContinuousClock.Instant? {
            switch self {
            case .agentMayRun(_, let instant), .agentAndShellMayExist(_, let instant): instant
            case .ready, .shellTabMayExist: nil
            }
        }
        var shellTabDispatched: Bool {
            switch self {
            case .shellTabMayExist, .agentAndShellMayExist: true
            case .ready, .agentMayRun: false
            }
        }
        /// Capture before this try dispatches agent.start. A prior dispatch
        /// may already have started an Agent, even if its answer was lost;
        /// only an owned worktree without that evidence may be removed.
        var mayRemoveWorktreeOnFailure: Bool {
            worktree != nil && agentStartDispatchedAt == nil
        }
    }

    enum Event: Equatable, Sendable {
        case createDispatched
        case worktreeRecorded(WorktreeLaunchAttempt.Worktree)
        case agentStartDispatched(at: ContinuousClock.Instant)
        case shellTabDispatched
    }
    enum Effect: Equatable, Sendable {
        static func == (lhs: Self, rhs: Self) -> Bool { switch lhs {} }
    }

    private(set) var state: State = .ready(.untouched)

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .createDispatched):
            let ownership: Ownership = state.worktree.map { .created($0) } ?? .createUnconfirmed
            replaceOwnership(ownership)
        case (_, .worktreeRecorded(let worktree)):
            replaceOwnership(state.createDispatched ? .created(worktree) : .known(worktree))
        case (.ready(let ownership), .agentStartDispatched(let instant)),
             (.agentMayRun(let ownership, _), .agentStartDispatched(let instant)):
            state = .agentMayRun(ownership, at: instant)
        case (.shellTabMayExist(let ownership), .agentStartDispatched(let instant)),
             (.agentAndShellMayExist(let ownership, _), .agentStartDispatched(let instant)):
            state = .agentAndShellMayExist(ownership, at: instant)
        case (.ready(let ownership), .shellTabDispatched):
            state = .shellTabMayExist(ownership)
        case (.agentMayRun(let ownership, let instant), .shellTabDispatched):
            state = .agentAndShellMayExist(ownership, at: instant)
        case (.shellTabMayExist, .shellTabDispatched), (.agentAndShellMayExist, .shellTabDispatched):
            break
        }
        return []
    }

    private mutating func replaceOwnership(_ ownership: Ownership) {
        switch state {
        case .ready: state = .ready(ownership)
        case .agentMayRun(_, let instant): state = .agentMayRun(ownership, at: instant)
        case .shellTabMayExist: state = .shellTabMayExist(ownership)
        case .agentAndShellMayExist(_, let instant):
            state = .agentAndShellMayExist(ownership, at: instant)
        }
    }
}
