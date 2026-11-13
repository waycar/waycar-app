import Foundation

extension ZellijTransport {
    static func unsupported(_ what: String) -> HerdrAPIError {
        HerdrAPIError(code: "unsupported", message: "\(what) is not available on Zellij yet.")
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec, attempt: WorktreeLaunchAttempt
    ) async throws -> Agent { throw Self.unsupported("Worktrees") }
    func startShellTerminalInNewWorktree(
        _ request: ShellLaunchRequest, worktree: WorktreeSpec, attempt: WorktreeLaunchAttempt
    ) async throws -> ShellLaunchResult { throw Self.unsupported("Worktrees") }
    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        throw Self.unsupported("Rename Workspace")
    }
    func movePane(_ params: PaneMoveParams) async throws -> PaneMoveResponse {
        throw Self.unsupported("Move to Workspace")
    }

    // These shared services use the same remembered HOME, admission and deadlines as tmux.
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
    func gitBranch(atPath path: String) async throws -> String? { try await session.gitBranch(atPath: path) }
    func locateCodexBar(customPath: String?) async throws -> String? {
        try await session.locateCodexBar(customPath: customPath)
    }
    func codexBarUsage(executablePath: String) async throws -> AIUsageReport {
        try await session.codexBarUsage(executablePath: executablePath)
    }
    func hostResourceUsage() async throws -> HostResourceUsage { try await session.hostResourceUsage() }
    func stageImage(
        _ image: PreparedImage, progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage { try await session.stageImage(image, progress: progress) }
    func stageFile(
        _ file: PreparedFile, progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile { try await session.stageFile(file, progress: progress) }
    func stageLaunchPromptFiles(_ files: [LaunchPromptFile]) async throws -> [StagedLaunchPromptFile] {
        try await session.stageLaunchPromptFiles(files)
    }
    func launchPromptCapabilities() async -> LaunchPromptCapabilities {
        await session.launchPromptCapabilities()
    }
}
