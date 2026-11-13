import Foundation

/// How to reach one Host, authenticate against it, and find its herdr socket.
struct SSHTransportSettings: Sendable {
    static let defaultSessionListCommand = "herdr session list --json"
    static let defaultStageDirectoryCommand =
        "/bin/sh -c 'umask 077; "
        + "directory=$(mktemp -d \"${TMPDIR:-/tmp}/waycar.XXXXXXXX\") || exit 1; "
        + "printf \"__WAYCAR_STAGE_DIR__=%s\\n\" \"$directory\"'"
    static let defaultWakeCommand = "herdr remote-client-bridge"
    static let defaultAttachCommand = "herdr agent attach"
    static let defaultTerminalAttachCommand = "herdr terminal attach"
    static let defaultHomeCommand =
        "/bin/sh -c 'printf \"__WAYCAR_HOME__=%s\\n\" \"$HOME\"'"
    static let defaultPluginListCommand = "herdr plugin list --json"
    static let agentAvailabilityMarker = "__WAYCAR_AGENT_KIND__="

    /// The `waycar` herdr plugin (ADR 0007/0008) whose config dir holds the
    /// Notification Registration file.
    static let notificationPluginID = "waycar"
    /// Ids the plugin shipped under before, newest first. A Host still running
    /// one keeps accepting Notification Registration: the matched id decides
    /// which config dir the registration file lands in, so it is the directory
    /// that Host's plugin actually reads. Only these fixed literals are ever
    /// substituted into the probe command; ids reported by the Host are not.
    static let legacyNotificationPluginIDs = ["herdr-mobile.pairing"]
    /// Replaced with the matched plugin id before the config-dir probe runs.
    /// A command injected without the token is used verbatim.
    static let notificationPluginIDToken = "__WAYCAR_PLUGIN_ID__"

    static let defaultNotificationConfigDirCommand =
        "/bin/sh -c '\(HerdrHostPath.pathExport); "
        + "printf \"__WAYCAR_PLUGIN_CONFIG_DIR__=%s\\n\" "
        + "\"$(herdr plugin config-dir \(notificationPluginIDToken))\"'"

    /// The default of ``requestTimeout``, named so budgets derived from it
    /// cannot drift out of step with it.
    static let defaultRequestTimeout: Duration = .seconds(15)

    /// The default of ``shellReadinessBudget``. It covers a slow shell boot
    /// observed on a real Host (>10 s before the prompt).
    static let defaultShellReadinessBudget: Duration = .seconds(30)
    /// The default of ``shellReadinessRetryDelay``.
    static let defaultShellReadinessRetryDelay: Duration = .milliseconds(500)
    /// The defaults of ``launchSettleDelay``, ``launchSettleInterval`` and
    /// ``launchSettleWindow``. herdr 0.9.1 promotes a launch only on a
    /// reconcile from 3 s after `agent.start`, and a reconcile from 30 s
    /// clears its name instead; the window stays well inside that.
    static let defaultLaunchSettleDelay: Duration = .milliseconds(3500)
    static let defaultLaunchSettleInterval: Duration = .seconds(1)
    static let defaultLaunchSettleWindow: Duration = .seconds(20)
    /// The default of ``inputReadyTimeout``. opencode drew its input box
    /// 11–42 s after `agent.start` on a 2-vCPU test Host, the slow
    /// end under memory pressure.
    static let defaultInputReadyTimeout: Duration = .seconds(60)
    /// The defaults of ``worktreeCreateTimeout``, ``worktreeReconcileBudget``
    /// and ``worktreeReconcileInterval``. herdr answers `worktree.create` only
    /// after `git worktree add` finishes, which can outlast
    /// ``defaultRequestTimeout`` on a large repository.
    static let defaultWorktreeCreateTimeout: Duration = .seconds(60)
    static let defaultWorktreeReconcileBudget: Duration = .seconds(45)
    static let defaultWorktreeReconcileInterval: Duration = .seconds(2)

    static var defaultAgentDiscoveryCommand: String {
        let checks = SupportedAgentKind.allCases.map { kind in
            "command -v \(kind.executable) >/dev/null 2>&1"
                + " && printf \"\(agentAvailabilityMarker)%s\\n\" \"\(kind.rawValue)\""
        }
        return "/bin/sh -c '\(HerdrHostPath.pathExport); "
            + "\(checks.joined(separator: "; ")); exit 0'"
    }

    static var defaultLaunchPromptProbeCommand: String {
        LaunchPromptWriter.capabilityProbeCommand
    }

    /// `codex --help`, stopped after `HostBackendDetection.probeLimitSeconds`
    /// like detection's probes, so a Codex that never starts costs a launch a
    /// few seconds, not the exec's whole deadline.
    static var defaultCodexHelpCommand: String {
        "/bin/sh -c " + ShellWord.quoted(
            HerdrHostPath.pathExport + "; " + codexHelpScript)
    }

    /// The `codex --help` line every terminal Backend's `--no-daemon` probe
    /// runs, after `HerdrHostPath.pathExport`; holds no single quote.
    static let codexHelpScript = "\(HostWatchdog.definition); "
        + "waycar_watch \(HostBackendDetection.probeLimitSeconds) codex --help 2>&1 </dev/null"

    /// Kinds reported by a Host `command -v` probe. Only marker-prefixed lines
    /// count, unknown labels are dropped, and the result is `allCases` order
    /// so the Start Agent picker stays stable across duplicate or noisy stdout.
    static func discoveredAgentKinds(from output: String) -> [SupportedAgentKind] {
        let discovered = Set(
            output.split(whereSeparator: \.isNewline)
                .compactMap { line -> SupportedAgentKind? in
                    guard line.hasPrefix(agentAvailabilityMarker) else {
                        return nil
                    }
                    return SupportedAgentKind(
                        rawValue: String(line.dropFirst(agentAvailabilityMarker.count)))
                })
        return SupportedAgentKind.allCases.filter(discovered.contains)
    }

    var host: String
    var port: Int
    var username: String
    var credentials: SSHCredentials
    /// TOFU host key policy (#2): the trusted-fingerprint store plus the
    /// first-connect confirmation the UI implements.
    var hostKeyPolicy: HostKeyPolicy
    /// Which herdr socket to reach on the Host.
    var socket: HerdrSocketLocation
    /// Optional Jump Host. When set, the Transport authenticates against the
    /// jump host first and opens the Host connection through it, so the Host
    /// needs no inbound reachability of its own. nil is a direct connection.
    var jump: SSHJumpSettings? = nil
    /// Command that wakes a stopped herdr server, run over a no-PTY exec
    /// channel when a request hits connection-refused (#6). The default is
    /// the strategy from spec #16: `herdr remote-client-bridge` ensures the
    /// server is running (spawn + wait for socket) before bridging, then
    /// exits on stdin EOF. Injectable so tests can substitute a script at
    /// the environment boundary. The exec wrapper already appends the
    /// well-known install prefixes to PATH; a per-Host override is for a
    /// binary that lives somewhere else, or for a test fixture.
    var wakeCommand: String = Self.defaultWakeCommand
    /// On a macOS Host with a logged-in user, run the wake as a one-shot
    /// launchd job in that user's `gui/<uid>` session, so the herdr server it
    /// starts, and every Agent in it, gets the login session: the unlocked
    /// Keychain, the session's SSH agent, no SSH variables
    /// (`WaycarSSHTransport.wakeExec`). Real-SSH fixtures turn it off: they
    /// run on a developer's Mac, where a job would land in the developer's
    /// own session.
    var wakesInLoginSession: Bool = true
    /// Official Host-local CLI command for discovering default and named
    /// sessions. It does not depend on a running API socket.
    var sessionListCommand: String = Self.defaultSessionListCommand
    /// Host-local availability probe for the protocol's canonical interactive
    /// Agent executables. It emits marker-delimited canonical kinds so login
    /// shell noise cannot become a false positive. Injectable only at the
    /// environment boundary for real-SSH tests.
    var agentDiscoveryCommand: String = Self.defaultAgentDiscoveryCommand
    /// Host-local probe for the harness CLIs' Launch Prompt File routes and
    /// the panes' Codex home (`LaunchPromptWriter.capabilityProbeCommand`).
    /// Injectable only at the environment boundary for real-SSH tests.
    var launchPromptProbeCommand: String = Self.defaultLaunchPromptProbeCommand
    /// Host-local `codex --help`, read for `--no-daemon` when detection has
    /// not vouched for the Host's Codex (`AgentLaunchBuilder.codexNoDaemonProbe`).
    /// Injectable only at the environment boundary for real-SSH tests.
    var codexHelpCommand: String = Self.defaultCodexHelpCommand
    /// Whether backend detection also searches the machine-wide install
    /// prefixes (`HerdrHostPath.systemExtraPATH`, Homebrew's among them)
    /// beside the exec's PATH and the account's own tool directories. Real-SSH
    /// fixtures turn it off: their sshd runs on the runner, whose Homebrew
    /// holds real CLIs (a codex macOS had not approved hung every detection
    /// exec in CI, 2026-11-12). Injectable only at the environment boundary.
    var detectionSearchesSystemDirectories: Bool = true
    /// Command that attaches interactively to a Pane, sent as the exec request
    /// on the Host's dedicated PTY channel (#11); the attach target and
    /// takeover flag are appended. Injectable so tests can substitute a script
    /// at the environment boundary. The exec wrapper already appends the
    /// well-known install prefixes to PATH; a per-Host override is for a
    /// binary that lives somewhere else, or for a test fixture.
    var attachCommand: String = Self.defaultAttachCommand
    /// Ordinary shell counterpart to ``attachCommand``. It is separate so
    /// fixtures can exercise command selection without teaching UI code how
    /// herdr spells either attach command.
    var terminalAttachCommand: String = Self.defaultTerminalAttachCommand
    /// Command used to print a marker-delimited remote home directory. Runs
    /// under POSIX sh because login shells do not share substitution syntax
    /// (#275: nushell never expands `$HOME` inside double quotes); the marker
    /// makes login-shell noise harmless. Injectable only at the environment
    /// boundary for real-SSH tests.
    var homeCommand: String = Self.defaultHomeCommand
    /// Creates one private directory beneath the Host operating system's
    /// selected temporary root. The marker makes login-shell noise harmless;
    /// callers never interpolate image names or paths into this command.
    var stageDirectoryCommand: String = Self.defaultStageDirectoryCommand
    /// Official Host-local CLI for listing installed plugins (offline, like
    /// session discovery). Notification Registration gates on the
    /// `waycar` herdr plugin being installed and enabled before touching its
    /// config dir — `herdr plugin config-dir` happily prints (and creates) a
    /// directory for any id, so it cannot carry the "is it installed" check.
    var pluginListCommand: String = Self.defaultPluginListCommand
    /// Prints the marker-delimited config dir of the `waycar` herdr plugin;
    /// herdr creates the directory if missing. Runs under POSIX sh because
    /// login shells do not share substitution syntax; the marker makes
    /// login-shell noise harmless. Any ``notificationPluginIDToken`` in the
    /// command is replaced with the plugin id matched from the Host's plugin
    /// list before the probe runs.
    var notificationConfigDirCommand: String = Self.defaultNotificationConfigDirCommand
    /// Per-request deadline covering the queue wait and the channel exchange;
    /// on expiry the request fails with `.timedOut` and its channel is
    /// closed. Short in tests, generous by default: a hung host should
    /// degrade gracefully, a slow one should still answer.
    ///
    /// It also bounds each individual PTY write and window-change on a live
    /// attach channel (`HostSSHSession.runAttachChannel`).
    var requestTimeout: Duration = Self.defaultRequestTimeout
    /// How long `agent.start` keeps retrying herdr's `agent_pane_busy` while a
    /// fresh pane's shell boots, and how long it sleeps between attempts
    /// (`WaycarSSHTransport.startAgentAwaitingShell`). Short in tests; the
    /// defaults must outlast a real Host's slowest shell boot.
    var shellReadinessBudget: Duration = Self.defaultShellReadinessBudget
    var shellReadinessRetryDelay: Duration = Self.defaultShellReadinessRetryDelay
    /// When the post-start `agent.get` settle first asks, how often it asks
    /// again while the launch is still pending, and how long after the
    /// `agent.start` ack it may still dispatch one
    /// (`WaycarSSHTransport.scheduleLaunchSettle`). Short in tests.
    var launchSettleDelay: Duration = Self.defaultLaunchSettleDelay
    var launchSettleInterval: Duration = Self.defaultLaunchSettleInterval
    var launchSettleWindow: Duration = Self.defaultLaunchSettleWindow
    /// How long after the `agent.start` of a kind with an input marker
    /// (opencode, kilo, cline: `AgentScreen.InputMarker`) its prompts wait
    /// for the marker on screen, after which they go out unread
    /// (`WaycarSSHTransport.promptAgent`). Short in tests.
    var inputReadyTimeout: Duration = Self.defaultInputReadyTimeout
    /// The request budget of `worktree.create` alone, in place of
    /// ``requestTimeout``. Short in tests.
    var worktreeCreateTimeout: Duration = Self.defaultWorktreeCreateTimeout
    /// After an unanswered `worktree.create`, how long a worktree launch
    /// keeps asking `worktree.list` for the worktree herdr may have made, and
    /// how often (`WaycarSSHTransport.reconcileCreatedWorktree`). Short in
    /// tests.
    var worktreeReconcileBudget: Duration = Self.defaultWorktreeReconcileBudget
    var worktreeReconcileInterval: Duration = Self.defaultWorktreeReconcileInterval
    /// Identifies the Host connection `HostSSHSessionPool` may share between
    /// this Host's backend Transports (ADR 0026): equal keys reuse one live
    /// SSH connection. nil dials a private connection, as every Transport did
    /// before tmux support and as tests with injected commands still need.
    /// Catalog Hosts set it from everything that decides where and how the
    /// connection goes (`init(host:credentials:hostKeyPolicy:)`), so an edit
    /// to any of those yields a new key and a fresh connection.
    var poolKey: String? = nil
    /// What earlier connections to this Host proved (#105): a remembered
    /// `$HOME` spares the dial-time home exec. nil remembers nothing, as
    /// tests and one-off connections (onboarding, Host checks) want.
    var connectionMemory: (any HostConnectionMemory)? = nil
}

/// The Jump Host in front of a Host: its own coordinates and credentials. Its
/// host key is verified under the same TOFU policy as the Host's, keyed by
/// its own endpoint, so both hops must be confirmed before either is trusted.
///
/// The Host's `address`/`port` are resolved from the Jump Host, which is
/// normally a loopback port held open by a reverse tunnel. Two Hosts behind
/// one Jump Host therefore need distinct tunnel ports: known-hosts entries are
/// keyed by endpoint, so a shared `127.0.0.1:12222` would collide.
struct SSHJumpSettings: Sendable {
    var host: String
    var port: Int
    var username: String
    var credentials: SSHCredentials

    init(host: String, port: Int = 22, username: String, credentials: SSHCredentials) {
        self.host = host
        self.port = port
        self.username = username
        self.credentials = credentials
    }
}
