import Foundation
import Testing

@testable import Waycar

@Suite("Worktree launch machine")
struct WorktreeLaunchMachineTests {
    private let worktree = WorktreeLaunchAttempt.Worktree(
        workspaceID: "w2", tabID: "t2", rootPaneID: "w2:p1", path: "/repo-worktree")

    @Test func createIsUnconfirmedUntilTheExactWorktreeIsRecorded() {
        var machine = WorktreeLaunchMachine()
        #expect(machine.state == .ready(.untouched))
        #expect(machine.handle(.createDispatched).isEmpty)
        #expect(machine.state == .ready(.createUnconfirmed))
        #expect(!machine.state.mayRemoveWorktreeOnFailure)
        #expect(machine.handle(.worktreeRecorded(worktree)).isEmpty)
        #expect(machine.state == .ready(.created(worktree)))
        #expect(machine.state.mayRemoveWorktreeOnFailure)
    }

    @Test func adoptedBranchStartNeverConfersOwnershipAndLatestDispatchWins() {
        let first = ContinuousClock.now
        let latest = first.advanced(by: .seconds(1))
        var machine = WorktreeLaunchMachine().after([.agentStartDispatched(at: first)])
        #expect(machine.state == .agentMayRun(.untouched, at: first))
        #expect(!machine.state.mayRemoveWorktreeOnFailure)
        #expect(machine.handle(.agentStartDispatched(at: latest)).isEmpty)
        #expect(machine.state == .agentMayRun(.untouched, at: latest))
    }

    @Test func shellAndAgentEvidenceNeverEraseEachOther() {
        let first = ContinuousClock.now
        let latest = first.advanced(by: .seconds(1))
        var shellFirst = WorktreeLaunchMachine().after([
            .createDispatched, .worktreeRecorded(worktree), .shellTabDispatched,
        ])
        #expect(shellFirst.state == .shellTabMayExist(.created(worktree)))
        #expect(shellFirst.state.mayRemoveWorktreeOnFailure)
        #expect(shellFirst.handle(.shellTabDispatched).isEmpty)
        #expect(shellFirst.handle(.agentStartDispatched(at: first)).isEmpty)
        #expect(shellFirst.state == .agentAndShellMayExist(.created(worktree), at: first))
        #expect(!shellFirst.state.mayRemoveWorktreeOnFailure)
        #expect(shellFirst.handle(.agentStartDispatched(at: latest)).isEmpty)
        #expect(shellFirst.handle(.shellTabDispatched).isEmpty)
        #expect(shellFirst.state.agentStartDispatchedAt == latest)
        let agentFirst = WorktreeLaunchMachine().after([
            .createDispatched, .worktreeRecorded(worktree),
            .agentStartDispatched(at: latest), .shellTabDispatched,
        ])
        #expect(agentFirst.state == shellFirst.state)
    }

    @Test func ownershipUpdatesPreserveEveryDispatchPhase() {
        let instant = ContinuousClock.now
        let phases: [[WorktreeLaunchMachine.Event]] = [
            [], [.agentStartDispatched(at: instant)], [.shellTabDispatched],
            [.agentStartDispatched(at: instant), .shellTabDispatched],
        ]
        for phase in phases {
            var machine = WorktreeLaunchMachine().after(phase)
            let agent = machine.state.agentStartDispatchedAt
            let shell = machine.state.shellTabDispatched
            #expect(machine.handle(.worktreeRecorded(worktree)).isEmpty)
            #expect(machine.state.ownership == .known(worktree))
            #expect(machine.handle(.createDispatched).isEmpty)
            #expect(machine.state.ownership == .created(worktree))
            #expect(machine.handle(.worktreeRecorded(worktree)).isEmpty)
            #expect(machine.handle(.createDispatched).isEmpty)
            #expect(machine.state.agentStartDispatchedAt == agent)
            #expect(machine.state.shellTabDispatched == shell)
            #expect(machine.state.mayRemoveWorktreeOnFailure == (agent == nil))
        }
    }
}
