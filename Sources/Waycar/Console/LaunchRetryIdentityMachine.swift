/// What a New Agent form's Retry reuses. A try's minted worktree branch is
/// kept for a retry from the same Host, source Workspace and base, so the
/// retry finds and continues in the worktree that try may have made; other
/// inputs mint a new one. Otherwise every form try is a new launch with a
/// new Launch Tag and session (the owner mints the Tag per submit, and
/// `StartAgentStore.prepareLaunchDraft` pins a fresh draft's session).
///
/// One exception (B-40): an OpenCode launch on OpenCode's own Backend that
/// failed may have created its session, whose minted id is OpenCode's Launch
/// Tag (O11). A Retry with the same form inputs sends that id and name
/// again: the create answers with the session it made, and the Chat Prompt
/// write finishes it. The user never sees a second session.
///
/// A launch that started, or that was kept as a Queued Launch, ends the
/// retry, and the form's next Start mints anew. A kept draft owns its
/// branch, Tag, name and session from then on: durable replay prepares it
/// again with every one of them pinned and never asks this machine.
struct LaunchRetryIdentityMachine: StateMachine {
    /// The inputs a minted branch belongs to.
    struct Inputs: Equatable, Sendable {
        let hostID: Host.ID
        let workspaceID: String
        let base: WorktreeBase
    }

    /// The form inputs an OpenCode session was created for: a Retry that
    /// changed any of them is a different launch.
    struct SessionInputs: Equatable, Sendable {
        let hostID: Host.ID
        let dispatch: StartAgentStore.Dispatch
        let workspaceID: String?
        let originCwd: String?
        let name: String?
        let suggestedName: String?
        let chatMode: Bool
    }

    enum State: Equatable, Sendable {
        /// No try to retry: the next branch is minted.
        case fresh
        /// A try sent this minted branch; a retry with the same inputs
        /// sends it again.
        case retrying(branch: String, inputs: Inputs)
        /// An OpenCode try failed after minting this session id and name; a
        /// retry with the same inputs finishes that session (B-40).
        case retryingOpenCodeSession(sessionID: String, launchName: String?, inputs: SessionInputs)
    }

    enum Event: Equatable, Sendable {
        /// A try with an empty Branch field needs a branch for these inputs.
        case branchNeeded(Inputs)
        case minted(String, inputs: Inputs)
        /// An OpenCode try is about to pin its session.
        case openCodeSessionNeeded(SessionInputs)
        /// An OpenCode try with this session and name failed.
        case openCodeLaunchFailed(sessionID: String, launchName: String?, inputs: SessionInputs)
        case launchStarted
        /// The launch became a Queued Launch, which takes its branch along.
        case launchKept
    }

    enum Effect: Equatable, Sendable {
        case reuse(String)
        case mint
        /// Pin this session id and name instead of minting.
        case reuseOpenCodeSession(sessionID: String, launchName: String?)
    }

    private(set) var state: State = .fresh

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.retrying(let branch, let kept), .branchNeeded(let inputs)) where kept == inputs:
            return [.reuse(branch)]
        case (.fresh, .branchNeeded), (.retrying, .branchNeeded), (.retryingOpenCodeSession, .branchNeeded):
            return [.mint]
        case (_, .minted(let branch, let inputs)):
            state = .retrying(branch: branch, inputs: inputs)
            return []
        case (.retryingOpenCodeSession(let id, let name, let kept), .openCodeSessionNeeded(let inputs))
            where kept == inputs:
            return [.reuseOpenCodeSession(sessionID: id, launchName: name)]
        case (.fresh, .openCodeSessionNeeded), (.retrying, .openCodeSessionNeeded),
             (.retryingOpenCodeSession, .openCodeSessionNeeded):
            return []
        case (_, .openCodeLaunchFailed(let id, let name, let inputs)):
            state = .retryingOpenCodeSession(sessionID: id, launchName: name, inputs: inputs)
            return []
        case (_, .launchStarted), (_, .launchKept):
            state = .fresh
            return []
        }
    }
}
