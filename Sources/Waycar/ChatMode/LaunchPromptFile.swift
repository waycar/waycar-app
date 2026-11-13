import Foundation

/// A launch-time prompt Waycar writes to a private file on the Host instead
/// of typing it into the pane. herdr types an Agent's launch command into a
/// fresh shell, and the tty's canonical input queue holds only `MAX_CANON`
/// (1024) bytes, Enter included, until the shell's line editor is up: a
/// longer line loses its tail and its closing quote, and the pane hangs.
struct LaunchPromptFile: Sendable, Equatable {
    enum Destination: Sendable, Equatable {
        /// A fresh 0700 `waycar.*` directory under the Host's `$TMPDIR`.
        /// Files there are never deleted by Waycar (ADR 0005).
        case stageDirectory
        /// `<name>.config.toml` in the Codex home the Host's panes resolve
        /// (`$CODEX_HOME` as their login shell sets it, else
        /// `$HOME/.codex`), holding the prompt as `developer_instructions`,
        /// for `codex -p <name>`.
        case codexProfile
    }

    let destination: Destination
    /// For `.stageDirectory`, a Waycar constant path relative to the stage
    /// directory, such as `chat-prompt.md` or Copilot's
    /// `.github/instructions/waycar.instructions.md`; for `.codexProfile`,
    /// the profile name (`waycar-<uuid>`). Never user text.
    let name: String
    /// The prompt text, unescaped.
    let contents: String
}

/// A `LaunchPromptFile` written on the Host.
struct StagedLaunchPromptFile: Sendable, Equatable {
    let file: LaunchPromptFile
    /// The file's absolute path on the Host.
    let path: String
}

/// Why `Transport.stageLaunchPromptFiles(_:)` wrote nothing usable; the
/// launch reports it as `LaunchPromptError.stagingFailed`. A failing
/// connection throws its own `TransportError` instead, which the launch
/// surfaces unchanged with the usual connection copy.
enum LaunchPromptStagingError: Error, Sendable, Equatable {
    /// This transport cannot write Host files.
    case unavailable
    /// A file name is not a plain Waycar constant (or repeats one), or a
    /// Codex profile name is not the `waycar-<uuid>` its sweep relies on.
    case invalidFile
    /// A stage file's Host path is not absolute and plain
    /// (`[A-Za-z0-9_./-]`), so it cannot ride the typed launch line, or the
    /// Codex home is not an absolute path Waycar can quote. The launch
    /// fails rather than go out without its prompt.
    case unusablePath
    /// The Host write failed, or wrote other bytes than were sent.
    case writeFailed
}

/// Which file-based prompt routes a Host's harness CLIs support, read once
/// per Host connection from their `--help`.
struct LaunchPromptCapabilities: Sendable, Equatable {
    /// `claude --append-system-prompt-file` (Claude Code 2.1.69+).
    var claudeAppendSystemPromptFile: Bool
    /// `codex -p <name>` layering `<name>.config.toml` from the Codex home.
    var codexProfileFile: Bool

    static let none = LaunchPromptCapabilities(
        claudeAppendSystemPromptFile: false, codexProfileFile: false)
}

/// One Host's launch-prompt services, late-bound to whichever transport is
/// live (`ConsoleStore.launchPromptHost(for:)`).
struct LaunchPromptHost: Sendable {
    let capabilities: @Sendable () async -> LaunchPromptCapabilities
    let stage: @Sendable ([LaunchPromptFile]) async throws -> [StagedLaunchPromptFile]
    /// The Host's `$HOME`, for a launch argument that needs an absolute
    /// path there (Cline's `--data-dir`): herdr and tmux both quote every
    /// argument, so `~` would reach the harness unexpanded.
    let homeDirectory: @Sendable () async throws -> String
}
