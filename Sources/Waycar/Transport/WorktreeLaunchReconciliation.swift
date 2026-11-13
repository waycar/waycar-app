import Foundation

/// Pure lookups that find a launch's worktree in a `worktree.list` result by
/// its exact branch, never by what changed between listings: another Agent
/// may create a worktree at the same moment. Only linked worktrees open in a
/// Workspace qualify: the main checkout is never a launch target, and a
/// worktree without a Workspace cannot host a tab yet.
enum WorktreeLaunchReconciliation {
    /// A linked worktree and the Workspace it is open in.
    struct OpenWorktree: Equatable, Sendable {
        let workspaceID: String
        /// The checkout on the Host.
        let path: String
    }

    /// The one linked worktree on exactly `branch` that is open in a
    /// Workspace; nil when there is none, or several (git allows that only
    /// with `--force`, and then which one is meant is unknown).
    static func existingWorktree(in worktrees: [WorktreeInfo], branch: String) -> OpenWorktree? {
        let matches: [OpenWorktree] = worktrees.compactMap { worktree in
            guard worktree.isLinkedWorktree, worktree.branch == branch,
                let workspaceID = worktree.openWorkspaceID
            else { return nil }
            return OpenWorktree(workspaceID: workspaceID, path: worktree.path)
        }
        return matches.count == 1 ? matches.first : nil
    }
}
