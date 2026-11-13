import Foundation
import WaycarSSH

// Launch Prompt Files: prompts a launch reads from a Host file instead of
// its typed command line (`LaunchPromptFile`, `LaunchPromptWriter`).
extension HostSSHSession {
    /// Writes every file in one exec and returns their absolute paths, in
    /// order. A Codex profile goes to the Codex home the capability probe
    /// resolved, running the probe first if this connection has not.
    /// Link failures surface as the exec's `TransportError`; a Host write
    /// that fails or reports an unexpected path, or a Codex profile with no
    /// probed Codex home, is a `LaunchPromptStagingError`.
    func stageLaunchPromptFiles(
        _ files: [LaunchPromptFile]
    ) async throws -> [StagedLaunchPromptFile] {
        guard !files.isEmpty else { return [] }
        var codexHome: String?
        if files.contains(where: { $0.destination == .codexProfile }) {
            guard let home = await launchPromptProbeAnswer()?.codexHome else {
                throw LaunchPromptStagingError.writeFailed
            }
            codexHome = home
        }
        let plan = try LaunchPromptWriter.plan(for: files, codexHome: codexHome)
        let result = try await runExec(Self.cLocaleCommand(plan.command), input: plan.input)
        guard result.exitStatus == 0, result.reachedEOF else {
            SSHDiagnostics.note(
                "launch prompt write exited \(result.exitStatus): \(Self.preview(result.stderr))")
            throw LaunchPromptStagingError.writeFailed
        }
        return try LaunchPromptWriter.stagedFiles(files, from: result.stdout)
    }

    /// The Host's harness CLIs' file routes, probed once per connection.
    /// Never throws: a failed or timed-out probe reads as `.none` and is
    /// asked again next time.
    func launchPromptCapabilities() async -> LaunchPromptCapabilities {
        await launchPromptProbeAnswer()?.capabilities ?? .none
    }

    /// The cached probe answer, or a fresh probe's; nil when it failed.
    private func launchPromptProbeAnswer() async -> LaunchPromptWriter.ProbeAnswer? {
        guard connected else { return nil }
        let probe = launchPromptCapabilityProbe
        let run = launchPromptCapabilityRun()
        return try? await withRequestDeadline(LaunchPromptWriter.capabilityProbeBudget) {
            try await probe.value(startingIfNeeded: run)
        }
    }

    private nonisolated func launchPromptCapabilityRun()
        -> @Sendable () async throws -> LaunchPromptWriter.ProbeAnswer
    {
        { [self] in
            let result = try await runExec(
                Self.cLocaleCommand(launchPromptProbeCommand),
                timeout: LaunchPromptWriter.capabilityProbeBudget)
            guard
                result.exitStatus == 0, result.reachedEOF,
                let answer = LaunchPromptWriter.probeAnswer(from: result.stdout)
            else {
                throw TransportError.malformedResponse(
                    "launch prompt probe exited \(result.exitStatus): \(Self.preview(result.stdout))")
            }
            return answer
        }
    }
}
