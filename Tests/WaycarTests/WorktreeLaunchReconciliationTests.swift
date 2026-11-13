import Foundation
import Testing

@testable import Waycar

@Suite("Worktree launch reconciliation")
struct WorktreeLaunchReconciliationTests {
    private static let mainCheckout = worktree(path: "/repo", branch: "main", linked: false, workspace: "w-main")

    private static func worktree(
        path: String,
        branch: String?,
        linked: Bool = true,
        workspace: String? = nil
    ) -> WorktreeInfo {
        WorktreeInfo(
            isBare: false,
            isDetached: false,
            isLinkedWorktree: linked,
            isPrunable: false,
            label: path,
            path: path,
            branch: branch,
            openWorkspaceID: workspace
        )
    }

    @Test func typedBranchOpenInWorkspaceIsFound() {
        let target = Self.worktree(path: "/repo-wt/agent-cache", branch: "agent-cache", workspace: "w2")
        let other = Self.worktree(path: "/repo-wt/other", branch: "other", workspace: "w3")
        #expect(
            WorktreeLaunchReconciliation.existingWorktree(
                in: [Self.mainCheckout, other, target], branch: "agent-cache")
                == WorktreeLaunchReconciliation.OpenWorktree(workspaceID: "w2", path: "/repo-wt/agent-cache"))
    }

    @Test func generatedBranchIsFoundByExactNameOnly() {
        // Another Agent's worktree appearing at the same moment must never
        // be taken for this launch's: only the minted name counts.
        let others = Self.worktree(path: "/repo-wt/w1", branch: "worktree/calm-river-1a2b", workspace: "w4")
        let ours = Self.worktree(path: "/repo-wt/w2", branch: "worktree/calm-river-1a2c", workspace: "w5")
        #expect(
            WorktreeLaunchReconciliation.existingWorktree(
                in: [Self.mainCheckout, others, ours], branch: "worktree/calm-river-1a2c")
                == WorktreeLaunchReconciliation.OpenWorktree(workspaceID: "w5", path: "/repo-wt/w2"))
    }

    @Test func branchWithoutAnOpenWorkspaceIsNotFound() {
        let pending = Self.worktree(path: "/repo-wt/agent-cache", branch: "agent-cache", workspace: nil)
        #expect(
            WorktreeLaunchReconciliation.existingWorktree(
                in: [Self.mainCheckout, pending], branch: "agent-cache") == nil)
    }

    @Test func branchNotListedIsNotFound() {
        let other = Self.worktree(path: "/repo-wt/other", branch: "other", workspace: "w3")
        #expect(
            WorktreeLaunchReconciliation.existingWorktree(
                in: [Self.mainCheckout, other], branch: "worktree/brave-stone-00ff") == nil)
    }

    @Test func mainCheckoutIsNeverFound() {
        #expect(WorktreeLaunchReconciliation.existingWorktree(in: [Self.mainCheckout], branch: "main") == nil)
    }

    @Test func twoOpenWorktreesOnOneBranchAreNotFound() {
        let a = Self.worktree(path: "/repo-wt/a", branch: "agent-cache", workspace: "w2")
        let b = Self.worktree(path: "/repo-wt/b", branch: "agent-cache", workspace: "w3")
        #expect(WorktreeLaunchReconciliation.existingWorktree(in: [a, b], branch: "agent-cache") == nil)
    }
}
