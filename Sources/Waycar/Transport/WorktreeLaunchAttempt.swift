import Foundation
import Synchronization

/// What one worktree launch from the New Agent sheet has already done on the
/// Host.
///
/// After a link failure `EventsSession.withTransport` replays the whole
/// Transport call on a fresh link, and herdr may already have acted on the
/// lost try: `worktree.create` answers only after `git worktree add` finishes,
/// which can outlive the request budget. The Console makes one attempt per
/// launch, outside that replay, and hands the same instance to every try, so
/// a replay continues in the worktree the lost try created (or the Agent it
/// started) instead of creating a second one.
final class WorktreeLaunchAttempt: Sendable {
    /// Read-only evidence projected from the machine. A typed-branch
    /// adoption is never recorded as ownership; only a create answer or
    /// reconciliation by this launch's exact minted branch records it.
    typealias State = WorktreeLaunchMachine.State

    /// The worktree Workspace a launch continues in.
    struct Worktree: Equatable, Sendable {
        let workspaceID: String
        /// The Workspace's first tab, which `worktree.create` opened.
        let tabID: String
        let rootPaneID: String
        /// The checkout on the Host; a plain-shell launch opens its tab here.
        let path: String
    }

    private let machine = Mutex(WorktreeLaunchMachine())

    init() {}

    var current: State {
        machine.withLock { $0.state }
    }

    func recordCreateDispatched() {
        machine.withLock { _ = $0.handle(.createDispatched) }
    }

    func recordWorktree(_ worktree: Worktree) {
        machine.withLock { _ = $0.handle(.worktreeRecorded(worktree)) }
    }

    /// Keeps the latest dispatch: a refused `agent.start` is retried, and
    /// only the last one can have started the Agent.
    func recordAgentStartDispatched(at instant: ContinuousClock.Instant) {
        machine.withLock { _ = $0.handle(.agentStartDispatched(at: instant)) }
    }

    func recordShellTabDispatched() {
        machine.withLock { _ = $0.handle(.shellTabDispatched) }
    }
}

/// Why a worktree launch stopped without knowing where its worktree is. It
/// follows a `worktree.create` that herdr may have acted on, so the launch
/// never sends another one: the user checks the Console first.
enum WorktreeLaunchError: Error, Equatable, Sendable {
    /// herdr never confirmed the create, and no worktree on the launch's
    /// branch showed up within `worktreeReconcileBudget` (or the launch
    /// named no branch to look for).
    case createUnconfirmed

    /// User-facing copy for the New Agent sheet.
    var message: String {
        switch self {
        case .createUnconfirmed:
            "The Host didn't confirm the new worktree. "
                + "Check the Console for it before you try again."
        }
    }
}
