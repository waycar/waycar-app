import Foundation
import WaycarSSH

/// The SSH-level services one Host connection offers its backend transports
/// (ADR 0026, design §4.1 and §4.8). herdr's and tmux's transports take the
/// same instance, so a Host with both backends dials once and shares one
/// channel admission budget. `HostSSHSession` is the production conformer;
/// tests substitute fakes.
///
/// Nothing here speaks herdr: commands are passed in by the backend that
/// knows them. Errors are mapped to `TransportError` the way
/// `WaycarSSHTransport` maps them today.
protocol HostSSHServices: AnyObject, Sendable {
    /// The SSH host the connection dialed: where mosh-server runs, and
    /// where the mosh client sends its UDP traffic unless the dial pinned a
    /// numeric address for it (`HostSSHSession.moshUDPHost`, #122).
    var sshHost: String { get }

    /// The per-request deadline ordinary requests run under.
    var requestTimeout: Duration { get }

    /// Whether the shared connection is still alive.
    var isConnected: Bool { get async }

    /// Last side-effect-free detection on this shared connection. A modern
    /// detected Codex already vouches for --no-daemon, even off the SSH PATH.
    var codexPresence: CodexPresence? { get async }

    /// Last side-effect-free detection's OpenCode 2 presence on this shared
    /// connection (never a password).
    var opencodePresence: OpenCodePresence? { get async }

    /// Runs one short command over an ordinary exec channel (session budget)
    /// within the request deadline, or `timeout` when given. The caller adds
    /// `LC_ALL=C` and the Host PATH fix-up (`HerdrHostPath`) where it needs
    /// them.
    func runExec(_ command: String, input: Data, timeout: Duration?) async throws -> SSHExecResult

    /// A loopback HTTP connection to an Ultimate instance on this Host.
    func openUltimateChannel(port: UInt16) async throws -> any UltimateByteChannel

    /// Codex's WebSocket Unix socket, under an ordinary forwarding lease
    /// held until close. It must not take herdr's single `.events` slot.
    func openCodexChannel(socketPath: String) async throws -> any UltimateByteChannel

    /// A direct-tcpip channel to the OpenCode 2 server at `host:port`, under
    /// an ordinary forwarding lease held until close, as Codex's. A Host
    /// that refuses TCP forwarding fails with the sshd setting to change.
    func openOpenCodeChannel(host: String, port: UInt16) async throws -> any UltimateByteChannel

    /// Opens the long-lived, non-PTY channel tmux control mode runs on
    /// (admission class `.control`: one per connection). The channel holds
    /// its admission lease until `close()`.
    func openControlChannel(command: String) async throws -> any HostControlChannel

    /// Opens the long-lived, non-PTY channel herdr-core's framed connection
    /// runs on (admission class `.core`: one per connection, beside tmux's
    /// `.control`, ADR 0031). Same lease and error mapping as
    /// `openControlChannel(command:)`.
    func openCoreChannel(command: String) async throws -> any HostControlChannel

    /// Zellij's long-lived watch exec; one `.zellij` admission lease until close.
    func openZellijChannel(command: String) async throws -> any HostControlChannel

    /// Opens an interactive PTY Attach running `command` (already including
    /// the bootstrap marker `printf` and `exec`), with the same output gate,
    /// input queue, resize, exit-status and `AttachBootstrapHandshake` gating
    /// herdr's Attach uses (admission class `.attach`).
    func attachTerminal(
        command: String, request: TerminalAttachRequest
    ) async throws -> TerminalAttachSession

    /// Whether `mosh-server` is on the Host's effective PATH (and its
    /// handshake answers), as `Transport.probeMoshServer` documents.
    func probeMoshServer() async throws -> Bool

    /// Runs one PTY-less `mosh-server new` exec whose wrapped command is
    /// `attachCommand` (a shell command string run by mosh-server's PTY),
    /// parses `MOSH CONNECT`, and returns the bootstrap with `host` set to
    /// the numeric address the dial pinned for mosh, if any, else `sshHost`
    /// (`HostSSHSession.moshUDPHost` gives the rule and how mosh-server
    /// binds).
    func runMoshBootstrap(
        attachCommand: String, request: TerminalAttachRequest
    ) async throws -> MoshBootstrap

    /// The remote home directory, resolved once per connection and cached.
    func remoteHomeDirectory() async throws -> String

    func listDirectories(at path: String) async throws -> RemoteDirectoryListing
    func availableAgentKinds() async throws -> [SupportedAgentKind]
    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill]
    func readSkillFile(atPath path: String) async throws -> String
    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice
    func readPreviewFile(atPath path: String, maxBytes: Int) async throws -> Data
    func modelContextWindow(selector: String) async throws -> Int?
    func gitBranch(atPath path: String) async throws -> String?
    func locateCodexBar(customPath: String?) async throws -> String?
    func codexBarUsage(executablePath: String) async throws -> AIUsageReport
    func hostResourceUsage() async throws -> HostResourceUsage

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile

    /// Writes a launch's Launch Prompt Files in one exec
    /// (`HostSSHSession.stageLaunchPromptFiles(_:)`).
    func stageLaunchPromptFiles(
        _ files: [LaunchPromptFile]
    ) async throws -> [StagedLaunchPromptFile]

    /// The Host's file prompt routes, probed once per connection; `.none`
    /// when the probe fails.
    func launchPromptCapabilities() async -> LaunchPromptCapabilities

    /// Reads one file from a Host directory over SFTP; nil when absent. Same
    /// error mapping as the notification files (`NotificationRegistrationError`).
    func readConfigFile(named name: String, inDirectory directory: String) async throws -> Data?

    /// Atomically replaces one file (temp file + rename, file 0600, directory
    /// 0700, created when missing), optionally inside `subdirectory` of
    /// `directory`, exactly as the notification files are written today.
    func replaceConfigFile(
        named name: String, inDirectory directory: String, subdirectory: String?,
        contents: Data
    ) async throws

    /// Deletes one file; an absent file is not an error.
    func deleteConfigFile(
        named name: String, inDirectory directory: String, subdirectory: String?
    ) async throws

    /// Releases one transport's hold on the shared connection. The
    /// connection closes with its last holder.
    func release() async
}

extension HostSSHServices {
    var codexPresence: CodexPresence? { get async { nil } }
    var opencodePresence: OpenCodePresence? { get async { nil } }

    func openOpenCodeChannel(host: String, port: UInt16) async throws -> any UltimateByteChannel {
        throw TransportError.channelFailed(detail: "OpenCode forwarding is unavailable.")
    }

    func openUltimateChannel(port: UInt16) async throws -> any UltimateByteChannel {
        throw TransportError.channelFailed(detail: "Ultimate forwarding is unavailable.")
    }
}

/// The duplex byte channel tmux control mode and herdr-core's framed
/// connection speak over (a non-PTY exec channel plus its admission lease).
protocol HostControlChannel: Sendable {
    func write(_ data: Data, timeout: Duration) async throws
    /// Next stdout bytes; nil after orderly remote EOF.
    func read(maximumBytes: Int, timeout: Duration) async throws -> Data?
    /// How the command ended: its exit status, once the Host reports one
    /// (waits up to `timeout`). herdr-core's `connect` says why it ended
    /// through it (exit 127 is "not installed here").
    func exitStatus(timeout: Duration) async throws -> Int32
    /// The tail of what the command wrote to stderr, for the line `hc
    /// connect` prints when it fails before it answers. Never empty text
    /// that was not written.
    func standardErrorTail() async -> String
    /// Closes the channel and returns its admission lease. Idempotent.
    func close() async
}
