import Testing

@testable import Waycar

/// `TmuxWorktreeTargetMachine`: where one try of a tmux worktree launch
/// continues, recognising worktrees by their exact branch only.
@Suite("tmux worktree target machine")
struct TmuxWorktreeTargetMachineTests {
    typealias Machine = TmuxWorktreeTargetMachine

    private let t0 = ContinuousClock.now
    private let found = Machine.Found(path: "/w/feat-x", openWorkspaceID: "tmux:$2")

    private func machine(branch: String? = "feat/x", minted: Bool = false) -> Machine {
        Machine(
            branch: branch, branchIsGenerated: minted, reconcileBudget: .seconds(10),
            reconcileInterval: .seconds(2))
    }

    private func listing(_ machine: Machine) -> Machine {
        machine.after([.begin(knownWorktreePath: nil)])
    }

    private func adding(_ machine: Machine) -> Machine {
        listing(machine).after([
            .listed(createDispatched: false, onBranch: nil, sourceIsLinked: false, now: t0),
            .addReady,
        ])
    }

    // MARK: Earlier tries

    @Test func aWorktreeAnEarlierTrySettledIsReusedWithoutAnyRead() {
        var target = machine()
        #expect(target.handle(.begin(knownWorktreePath: "/w/own"))
            == [.settle(.own(path: "/w/own", continuing: true))])
    }

    @Test func aDispatchedAddIsReconciledFromTheFirstListing() {
        var minted = listing(machine(branch: "worktree/a", minted: true))
        #expect(minted.handle(
            .listed(createDispatched: true, onBranch: found, sourceIsLinked: false, now: t0))
            == [
                .report(.checkingForCreatedWorktree),
                .recordWorktree(path: "/w/feat-x", workspaceID: "tmux:$2"),
                .settle(.own(path: "/w/feat-x", continuing: true)),
            ])
        var typed = listing(machine())
        #expect(typed.handle(
            .listed(createDispatched: true, onBranch: found, sourceIsLinked: false, now: t0))
            == [
                .report(.checkingForCreatedWorktree), .report(.usingExistingWorktree),
                .settle(.adopted(path: "/w/feat-x")),
            ])
    }

    @Test func aDispatchedAddWithoutABranchIsUnconfirmed() {
        var target = listing(machine(branch: nil))
        #expect(target.handle(
            .listed(createDispatched: true, onBranch: nil, sourceIsLinked: false, now: t0))
            == [.fail(.createUnconfirmed)])
    }

    // MARK: Existing worktrees

    @Test func aTypedBranchAlreadyCheckedOutIsAdopted() {
        var target = listing(machine())
        #expect(target.handle(
            .listed(createDispatched: false, onBranch: found, sourceIsLinked: false, now: t0))
            == [.report(.usingExistingWorktree), .settle(.adopted(path: "/w/feat-x"))])
    }

    @Test func aMintedBranchAlreadyCheckedOutIsOwned() {
        var target = listing(machine(branch: "worktree/a", minted: true))
        #expect(target.handle(
            .listed(createDispatched: false, onBranch: found, sourceIsLinked: false, now: t0))
            == [
                .report(.usingExistingWorktree),
                .recordWorktree(path: "/w/feat-x", workspaceID: "tmux:$2"),
                .settle(.own(path: "/w/feat-x", continuing: true)),
            ])
    }

    @Test func aLinkedSourceIsRefused() {
        var target = listing(machine())
        #expect(target.handle(
            .listed(createDispatched: false, onBranch: nil, sourceIsLinked: true, now: t0))
            == [.fail(.linkedWorktreeSource)])
    }

    // MARK: The add

    @Test func theAddIsDispatchedOnceItsBaseAndCommandAreReady() {
        var target = listing(machine())
        #expect(target.handle(
            .listed(createDispatched: false, onBranch: nil, sourceIsLinked: false, now: t0))
            == [.resolveBase])
        #expect(target.handle(.addReady)
            == [.report(.creatingWorktree), .recordCreateDispatched, .add])
        #expect(target.state == .adding)
    }

    @Test func anAnsweredAddIsThisTrysOwnFreshWorktree() {
        var target = adding(machine())
        #expect(target.handle(.added(path: "/w/new"))
            == [.recordWorktree(path: "/w/new", workspaceID: ""),
                .settle(.own(path: "/w/new", continuing: false))])
    }

    @Test func aRefusedAddLooksForTheBranchOnce() {
        var adopted = adding(machine())
        #expect(adopted.handle(.addRefused) == [.relist])
        #expect(adopted.handle(.relisted(onBranch: found))
            == [.report(.usingExistingWorktree), .settle(.adopted(path: "/w/feat-x"))])

        var refused = adding(machine())
        _ = refused.handle(.addRefused)
        #expect(refused.handle(.relisted(onBranch: nil)) == [.fail(.addRefused)])

        var branchless = adding(machine(branch: nil))
        #expect(branchless.handle(.addRefused) == [.fail(.addRefused)])
    }

    @Test func anUnansweredAddIsPolledForUntilTheBudgetRunsOut() {
        var target = adding(machine(branch: "worktree/a", minted: true))
        #expect(target.handle(.addUnanswered(now: t0))
            == [.report(.checkingForCreatedWorktree), .poll(after: nil)])
        #expect(target.state == .reconciling(branch: "worktree/a", deadline: t0 + .seconds(10)))
        #expect(target.handle(.polled(onBranch: nil, now: t0 + .seconds(1)))
            == [.poll(after: .seconds(2))])
        #expect(target.handle(.polled(onBranch: nil, now: t0 + .seconds(8)))
            == [.fail(.createUnconfirmed)])
    }

    @Test func aPollThatFindsTheMintedBranchOwnsIt() {
        var target = adding(machine(branch: "worktree/a", minted: true))
        _ = target.handle(.addUnanswered(now: t0))
        #expect(target.handle(.polled(onBranch: found, now: t0 + .seconds(3))) == [
            .recordWorktree(path: "/w/feat-x", workspaceID: "tmux:$2"),
            .settle(.own(path: "/w/feat-x", continuing: true)),
        ])
    }

    @Test func anUnansweredAddWithoutABranchIsUnconfirmed() {
        var target = adding(machine(branch: nil))
        #expect(target.handle(.addUnanswered(now: t0)) == [.fail(.createUnconfirmed)])
    }

    // MARK: Ignored

    @Test func aSettledOrFailedTargetIgnoresEverything() {
        let settled = machine().after([.begin(knownWorktreePath: "/w/own")])
        let failed = listing(machine(branch: nil)).after([
            .listed(createDispatched: true, onBranch: nil, sourceIsLinked: false, now: t0)
        ])
        for ended in [settled, failed] {
            var target = ended
            #expect(target.handle(.addReady).isEmpty)
            #expect(target.handle(.added(path: "/x")).isEmpty)
            #expect(target.handle(.polled(onBranch: found, now: t0)).isEmpty)
            #expect(target.handle(.begin(knownWorktreePath: nil)).isEmpty)
            #expect(target.state == ended.state)
        }
    }

    @Test func outOfOrderStepsAreIgnored() {
        var unstarted = machine()
        #expect(unstarted.handle(.addReady).isEmpty)
        #expect(unstarted.handle(
            .listed(createDispatched: false, onBranch: nil, sourceIsLinked: false, now: t0)).isEmpty)
        var added = adding(machine())
        #expect(added.handle(.addReady).isEmpty)
        #expect(added.handle(.relisted(onBranch: found)).isEmpty)
        #expect(added.state == .adding)
    }
}
