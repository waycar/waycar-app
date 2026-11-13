import Foundation
import Testing

@testable import Waycar

@Suite("Worktree launch attempt ownership")
struct WorktreeLaunchAttemptTests {
    private let worktree = WorktreeLaunchAttempt.Worktree(
        workspaceID: "w2", tabID: "t2", rootPaneID: "w2:p1", path: "/repo-worktree")

    @Test func ownershipSurvivesRepeatedCreateAndDispatchRecords() {
        let attempt = WorktreeLaunchAttempt()
        #expect(!attempt.current.createDispatched)
        #expect(!attempt.current.mayRemoveWorktreeOnFailure)
        attempt.recordCreateDispatched()
        #expect(attempt.current.createDispatched)
        #expect(attempt.current.worktree == nil)
        attempt.recordWorktree(worktree)
        #expect(attempt.current.worktree == worktree)
        #expect(attempt.current.mayRemoveWorktreeOnFailure)

        let first = ContinuousClock.now
        let latest = first.advanced(by: .seconds(1))
        attempt.recordAgentStartDispatched(at: first)
        attempt.recordCreateDispatched()
        attempt.recordWorktree(worktree)
        attempt.recordAgentStartDispatched(at: latest)
        #expect(attempt.current.agentStartDispatchedAt == latest)
        #expect(attempt.current.createDispatched)
        #expect(!attempt.current.mayRemoveWorktreeOnFailure)
    }

    @Test func anAdoptedBranchDispatchDoesNotBecomeOwned() {
        let attempt = WorktreeLaunchAttempt()
        let instant = ContinuousClock.now
        attempt.recordAgentStartDispatched(at: instant)
        #expect(attempt.current.agentStartDispatchedAt == instant)
        #expect(attempt.current.worktree == nil)
        #expect(!attempt.current.createDispatched)
        #expect(!attempt.current.mayRemoveWorktreeOnFailure)
    }

    @Test func aShellDispatchRetainsTheExistingCleanupRule() {
        let attempt = WorktreeLaunchAttempt()
        attempt.recordCreateDispatched()
        attempt.recordWorktree(worktree)
        attempt.recordShellTabDispatched()
        #expect(attempt.current.shellTabDispatched)
        #expect(attempt.current.agentStartDispatchedAt == nil)
        // The transport captures permission before its own dispatch. This
        // value has always prohibited cleanup for agent.start, not tab.create.
        #expect(attempt.current.mayRemoveWorktreeOnFailure)
    }

    @Test func recordingOwnershipLateNeverErasesPossibleAgentStart() {
        let attempt = WorktreeLaunchAttempt()
        let instant = ContinuousClock.now
        attempt.recordAgentStartDispatched(at: instant)
        attempt.recordShellTabDispatched()
        attempt.recordWorktree(worktree)
        attempt.recordCreateDispatched()
        #expect(attempt.current.worktree == worktree)
        #expect(attempt.current.createDispatched)
        #expect(attempt.current.shellTabDispatched)
        #expect(attempt.current.agentStartDispatchedAt == instant)
        #expect(!attempt.current.mayRemoveWorktreeOnFailure)
    }
}
