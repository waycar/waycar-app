import Foundation

/// Where one try of a tmux worktree launch continues (design §4.3, phase
/// 4), running `git worktree add` at most once per launch: what an earlier
/// try did lives in its ``WorktreeLaunchAttempt`` (LAUNCH-09). A worktree is
/// recognised only by its exact branch: on a minted branch it is this
/// launch's own, on a typed one it is adopted, never owned or removed.
///
/// 1. A worktree an earlier try settled as its own is reused as is.
/// 2. After an add that may have run without an answer, the listing is
///    polled for its branch every `reconcileInterval` until
///    `reconcileBudget` runs out; a launch without a branch has nothing to
///    look for and stops unconfirmed.
/// 3. A branch already checked out in a linked worktree is reused.
/// 4. Otherwise the base is resolved and the add run. git refusing it while
///    the typed branch shows up in a linked worktree is step 3; no answer
///    at all is step 2.
struct TmuxWorktreeTargetMachine: StateMachine {
    /// A linked, present worktree on exactly the launch's branch.
    struct Found: Equatable, Sendable {
        let path: String
        /// The first shown session in it, app id.
        let openWorkspaceID: String?
    }

    enum State: Equatable, Sendable {
        case unstarted
        /// The source Workspace's checkout and its worktree list are read.
        case listing
        /// The new branch's base is resolved.
        case resolvingBase
        /// `git worktree add` runs.
        case adding
        /// git refused the add; the typed branch is looked for once more.
        case relisting
        /// An add that may have run is looked for on `branch` until
        /// `deadline`.
        case reconciling(branch: String, deadline: ContinuousClock.Instant)
        case settled(TmuxTransport.WorktreeTarget)
        case failed
    }

    enum Failure: Equatable, Sendable {
        /// `WorktreeLaunchError.createUnconfirmed`.
        case createUnconfirmed
        /// `WorktreeBaseResolutionError.linkedWorktreeSource`.
        case linkedWorktreeSource
        /// git's own refusal of the add.
        case addRefused
    }

    enum Event: Equatable, Sendable {
        /// The try begins; `knownWorktreePath` is the worktree an earlier
        /// try settled as its own.
        case begin(knownWorktreePath: String?)
        /// The listing came; `createDispatched` is the attempt's record as
        /// it stands now.
        case listed(
            createDispatched: Bool, onBranch: Found?, sourceIsLinked: Bool,
            now: ContinuousClock.Instant)
        /// The add's command is built (a ref git would refuse ran nothing).
        case addReady
        case added(path: String)
        /// git answered no.
        case addRefused
        /// No answer: git may still have made it.
        case addUnanswered(now: ContinuousClock.Instant)
        /// The listing after a refusal; nil when it failed.
        case relisted(onBranch: Found?)
        case polled(onBranch: Found?, now: ContinuousClock.Instant)
    }

    enum Effect: Equatable, Sendable {
        /// Read the source Workspace's checkout and its worktree list.
        case list
        case resolveBase
        case report(LaunchStep)
        case recordCreateDispatched
        case add
        case relist
        /// List again, after `delay` when there is one.
        case poll(after: Duration?)
        case recordWorktree(path: String, workspaceID: String)
        case settle(TmuxTransport.WorktreeTarget)
        case fail(Failure)
    }

    let branch: String?
    let branchIsGenerated: Bool
    let reconcileBudget: Duration
    let reconcileInterval: Duration

    private(set) var state: State = .unstarted

    init(
        branch: String?, branchIsGenerated: Bool,
        reconcileBudget: Duration = SSHTransportSettings.defaultWorktreeReconcileBudget,
        reconcileInterval: Duration = SSHTransportSettings.defaultWorktreeReconcileInterval
    ) {
        self.branch = branch
        self.branchIsGenerated = branchIsGenerated
        self.reconcileBudget = reconcileBudget
        self.reconcileInterval = reconcileInterval
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.unstarted, .begin(let known)):
            guard let known else {
                state = .listing
                return [.list]
            }
            return settle(.own(path: known, continuing: true))

        case (.listing, .listed(let createDispatched, let onBranch, let sourceIsLinked, let now)):
            if createDispatched { return reconcile(now: now, first: .some(onBranch)) }
            if let onBranch { return [.report(.usingExistingWorktree)] + continueIn(onBranch) }
            // herdr refuses a linked worktree as the source; so does tmux,
            // since the new branch would start from the main checkout's
            // HEAD instead.
            guard !sourceIsLinked else { return fail(.linkedWorktreeSource) }
            state = .resolvingBase
            return [.resolveBase]

        case (.resolvingBase, .addReady):
            state = .adding
            return [.report(.creatingWorktree), .recordCreateDispatched, .add]

        case (.adding, .added(let path)):
            // tmux has no Workspace for it until the session opens.
            return [.recordWorktree(path: path, workspaceID: "")]
                + settle(.own(path: path, continuing: false))
        case (.adding, .addRefused):
            // Nothing was made. The branch may have been checked out
            // meanwhile: continue there instead.
            guard branch != nil else { return fail(.addRefused) }
            state = .relisting
            return [.relist]
        case (.adding, .addUnanswered(let now)):
            return reconcile(now: now, first: nil)

        case (.relisting, .relisted(let onBranch)):
            guard let onBranch else { return fail(.addRefused) }
            return [.report(.usingExistingWorktree)] + continueIn(onBranch)

        case (.reconciling(let branch, let deadline), .polled(let onBranch, let now)):
            return poll(branch: branch, deadline: deadline, onBranch: onBranch, now: now)

        case (.unstarted, _), (.listing, _), (.resolvingBase, _), (.adding, _), (.relisting, _),
            (.reconciling, _), (.settled, _), (.failed, _):
            return []
        }
    }

    /// Looks for the worktree an add of this launch may have made; `first`
    /// is the listing already in hand, when there is one.
    private mutating func reconcile(now: ContinuousClock.Instant, first: Found??) -> [Effect] {
        guard let branch else { return fail(.createUnconfirmed) }
        let deadline = now + reconcileBudget
        state = .reconciling(branch: branch, deadline: deadline)
        guard let first else { return [.report(.checkingForCreatedWorktree), .poll(after: nil)] }
        return [.report(.checkingForCreatedWorktree)]
            + poll(branch: branch, deadline: deadline, onBranch: first, now: now)
    }

    private mutating func poll(
        branch: String, deadline: ContinuousClock.Instant, onBranch: Found?,
        now: ContinuousClock.Instant
    ) -> [Effect] {
        if let onBranch {
            return (branchIsGenerated ? [] : [.report(.usingExistingWorktree)]) + continueIn(onBranch)
        }
        guard now + reconcileInterval < deadline else { return fail(.createUnconfirmed) }
        return [.poll(after: reconcileInterval)]
    }

    /// `found` is on the launch's branch: adopted when the branch is typed,
    /// this launch's own when it is minted, since no one else knows that
    /// name.
    private mutating func continueIn(_ found: Found) -> [Effect] {
        guard branchIsGenerated else { return settle(.adopted(path: found.path)) }
        return [.recordWorktree(path: found.path, workspaceID: found.openWorkspaceID ?? "")]
            + settle(.own(path: found.path, continuing: true))
    }

    private mutating func settle(_ target: TmuxTransport.WorktreeTarget) -> [Effect] {
        state = .settled(target)
        return [.settle(target)]
    }

    private mutating func fail(_ failure: Failure) -> [Effect] {
        state = .failed
        return [.fail(failure)]
    }
}
