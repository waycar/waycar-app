import Foundation

extension CoreTransport {
    // MARK: Attach

    /// An interactive PTY Attach: `herdr-core attach <address>` on a PTY
    /// (design §8), through the same `HostSSHSession.attachTerminal` and
    /// bootstrap-marker gate herdr's Attach uses. There is no takeover on
    /// core: viewers share the terminal, and the PTY follows the newest
    /// typing one, so `request.takeover` is ignored. A binary that is gone
    /// exits 127 with the not-installed text (`coreNotInstalled`).
    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        let address = try attachAddress(request.target)
        let command = try CoreConnectCommand.attach(
            address: address, path: corePath, loginPATH: loginPATH)
        return try await session.attachTerminal(command: command, request: request)
    }

    /// The address an Attach target names: a pane id (`hc:<address>`) or a
    /// terminal id (`hc:<core prefix>:<address>`). A terminal id from
    /// another core state (the state was wiped, so addresses restarted) is
    /// not found rather than attached to whatever holds that address now.
    func attachAddress(_ target: TerminalAttachTarget) throws -> String {
        switch target {
        case .agentPane(let id):
            return try Self.address(ofPane: id)
        case .terminal(let id):
            guard let parts = CoreID.parts(ofTerminal: id) else {
                return try Self.address(ofPane: id)
            }
            if let hello, !hello.coreID.isEmpty, !hello.coreID.hasPrefix(parts.corePrefix) {
                throw HerdrAPIError(
                    code: "pane_not_found", message: "\(id) belongs to another herdr-core state")
            }
            return parts.address
        }
    }

    /// herdr-core has no mosh path in this release: reporting no mosh-server
    /// keeps the mosh runner from trying, and Attach stays on SSH.
    func probeMoshServer() async throws -> Bool { false }

    func runMoshBootstrap(_ request: TerminalAttachRequest) async throws -> MoshBootstrap {
        throw TransportError.moshSessionFailed(detail: "mosh is not available on herdr-core yet")
    }

    // MARK: Not on herdr-core yet

    /// What a member herdr-core cannot do yet reports: the UI is gated by
    /// capability, so this is the backstop.
    static func unsupported(_ what: String) -> HerdrAPIError {
        HerdrAPIError(code: "unsupported", message: "\(what) is not available on herdr-core yet.")
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec, attempt: WorktreeLaunchAttempt
    ) async throws -> Agent {
        throw Self.unsupported("Worktrees")
    }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        throw Self.unsupported("Starting a terminal")
    }

    func startShellTerminal(_ request: ShellLaunchRequest) async throws -> ShellLaunchResult {
        throw Self.unsupported("Starting a terminal")
    }

    func startShellTerminalInNewWorktree(
        _ request: ShellLaunchRequest, worktree: WorktreeSpec, attempt: WorktreeLaunchAttempt
    ) async throws -> ShellLaunchResult {
        throw Self.unsupported("Worktrees")
    }

    func startShellTerminalInNewWorkspace(
        _ request: ShellLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> ShellLaunchResult {
        throw Self.unsupported("New Workspaces")
    }

    func movePane(_ params: PaneMoveParams) async throws -> PaneMoveResponse {
        throw Self.unsupported("Moving a terminal to another Workspace")
    }

    func renameAgent(_ params: AgentRenameParams) async throws {
        throw Self.unsupported("Renaming an agent")
    }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        throw Self.unsupported("Renaming a Workspace")
    }

    func renameShellTab(tabID: String, label: String) async throws {
        throw Self.unsupported("Renaming a tab")
    }

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        throw Self.unsupported("Worktrees")
    }

    func removeWorktree(
        _ request: WorktreeRemovalRequest,
        authorize: @escaping @Sendable (WorktreeRemovalRequest) async throws -> Void,
        onDispatched: @escaping @Sendable (WorktreeRemovalRequest) async -> Void
    ) async throws -> WorktreeRemovedResponse {
        throw Self.unsupported("Worktrees")
    }

    // MARK: Host services

    func remoteHomeDirectory() async throws -> String { try await session.remoteHomeDirectory() }

    func listDirectories(at path: String) async throws -> RemoteDirectoryListing {
        try await session.listDirectories(at: path)
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        try await session.availableAgentKinds()
    }

    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill] {
        try await session.listSkills(query)
    }

    func readSkillFile(atPath path: String) async throws -> String {
        try await session.readSkillFile(atPath: path)
    }

    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        try await session.readFileSlice(range)
    }

    func readPreviewFile(atPath path: String, maxBytes: Int) async throws -> Data {
        try await session.readPreviewFile(atPath: path, maxBytes: maxBytes)
    }

    func modelContextWindow(selector: String) async throws -> Int? {
        try await session.modelContextWindow(selector: selector)
    }

    func gitBranch(atPath path: String) async throws -> String? {
        try await session.gitBranch(atPath: path)
    }

    func locateCodexBar(customPath: String?) async throws -> String? {
        try await session.locateCodexBar(customPath: customPath)
    }

    func codexBarUsage(executablePath: String) async throws -> AIUsageReport {
        try await session.codexBarUsage(executablePath: executablePath)
    }

    func hostResourceUsage() async throws -> HostResourceUsage {
        try await session.hostResourceUsage()
    }

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        try await session.stageImage(image, progress: progress)
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        try await session.stageFile(file, progress: progress)
    }

    func stageLaunchPromptFiles(
        _ files: [LaunchPromptFile]
    ) async throws -> [StagedLaunchPromptFile] {
        try await session.stageLaunchPromptFiles(files)
    }

    func launchPromptCapabilities() async -> LaunchPromptCapabilities {
        await session.launchPromptCapabilities()
    }
}
