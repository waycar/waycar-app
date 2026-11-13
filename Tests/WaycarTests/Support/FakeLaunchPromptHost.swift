import Foundation

@testable import Waycar

/// A Host's launch-prompt services in memory: it reports `capabilities`,
/// keeps every batch it is asked to write, and answers each file with
/// `path(for:)`, or fails every write with `failure`. Its `$HOME` is
/// `FakeLaunchPromptHost.home`.
actor FakeLaunchPromptHost {
    nonisolated static let home = "/home/you"

    private(set) var stagedBatches: [[LaunchPromptFile]] = []
    private(set) var capabilityReads = 0
    private(set) var homeReads = 0
    private let capabilities: LaunchPromptCapabilities
    private let failure: (any Error)?

    init(
        capabilities: LaunchPromptCapabilities = LaunchPromptCapabilities(
            claudeAppendSystemPromptFile: true, codexProfileFile: true),
        failure: (any Error)? = nil
    ) {
        self.capabilities = capabilities
        self.failure = failure
    }

    /// Where the fake writes `file`.
    nonisolated static func path(for file: LaunchPromptFile) -> String {
        switch file.destination {
        case .stageDirectory: "/tmp/waycar.test/\(file.name)"
        case .codexProfile: "/home/you/.codex/\(file.name).config.toml"
        }
    }

    /// `files` as the fake writes them.
    nonisolated static func staged(_ files: [LaunchPromptFile]) -> [StagedLaunchPromptFile] {
        files.map { StagedLaunchPromptFile(file: $0, path: path(for: $0)) }
    }

    /// Every file written so far, in order.
    var stagedFiles: [LaunchPromptFile] { stagedBatches.flatMap { $0 } }

    nonisolated var host: LaunchPromptHost {
        LaunchPromptHost(
            capabilities: { await self.readCapabilities() },
            stage: { try await self.stage($0) },
            homeDirectory: { await self.readHome() })
    }

    private func readHome() -> String {
        homeReads += 1
        return Self.home
    }

    private func readCapabilities() -> LaunchPromptCapabilities {
        capabilityReads += 1
        return capabilities
    }

    private func stage(_ files: [LaunchPromptFile]) throws -> [StagedLaunchPromptFile] {
        if let failure { throw failure }
        stagedBatches.append(files)
        return Self.staged(files)
    }
}
