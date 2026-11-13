import Foundation

/// One visible step of a launch from the New Agent sheet, reported as it
/// begins so the sheet can say what is happening instead of showing a bare
/// spinner (getting the latest main alone can take up to 50 s).
enum LaunchStep: Equatable, Sendable {
    /// Asking origin for its newest default-branch commit and downloading it.
    case gettingLatestMain
    /// `worktree.create`: herdr checks out the new worktree.
    case creatingWorktree
    /// herdr did not confirm `worktree.create`; looking for the worktree it
    /// may have made before doing anything else.
    case checkingForCreatedWorktree
    /// The requested worktree already exists; the launch continues in it.
    case usingExistingWorktree
    /// `workspace.create`.
    case creatingWorkspace
    /// `tab.create` in an existing Workspace.
    case creatingTab
    /// `agent.start` is waiting for the new pane's shell to reach its prompt.
    case waitingForShell
    /// `agent.start` for the selected Agent.
    case startingAgent
    /// The requested worktree already runs an Agent; the launch opens that
    /// one instead of starting another. Not a new launch.
    case joiningRunningAgent
    /// Opening the marked tab of a plain-shell launch.
    case openingShell
    /// The launch succeeded; waiting for the Console to list the new row.
    case opening
}

/// Carries launch progress from the Transport to the sheet without threading
/// a callback through every layer: the sheet binds a reporter for its one
/// launch task, and the Transport reports steps from inside that task (task
/// locals follow awaits across actors, so the Console's session hop keeps it).
enum LaunchProgress {
    @TaskLocal static var reporter: (@Sendable (LaunchStep) -> Void)?

    /// Reports `step` to the launch bound to the current task, if any.
    static func report(_ step: LaunchStep) {
        reporter?(step)
    }
}
