import Foundation
import Synchronization

/// The app-side abstraction that executes herdr API requests over SSH.
/// UI code talks to Transport, never to SSH primitives (ADR 0011).
protocol Transport: Sendable {
    /// Server chat session links (`ServerSessionLinks`) derived from the last
    /// inventory; no Host requests.
    func serverSessionLinkFacts() async -> ServerSessionLinkFacts

    /// The sessions a server chat runtime keeps archived, which Closed
    /// Sessions lists (OpenCode, card 1530 1a), as of the last inventory; no
    /// Host requests.
    func archivedServerSessions() async -> [ArchivedServerSession]

    func closedZellijSessions(refreshAge: Bool) async throws -> [ZellijClosedSession]
    func deleteZellijSession(_ name: String) async throws

    /// Open board questions to the user, keyed by the project's leader pane id.
    func ultimateOpenQuestions() async -> [String: Int]
    /// Active Ultimate branches, keyed by their project's leader pane id.
    func ultimateConversationChildren() async -> [String: [UltimateChildInfo]]

    /// Verifies the server speaks a protocol version we support and returns
    /// its identity. Must be the first herdr API call on every new connection
    /// path; Host-local session discovery may run before it.
    func ping() async throws -> ServerInfo

    /// The foreground re-proof (`EventsSession.revalidate()`): a `ping()`
    /// that also re-checks whatever the keepalive's pings deliberately skip
    /// (tmux on a dual Host: whether sessions appeared).
    func revalidate() async throws -> ServerInfo

    /// Completes, before ``EventsSession.measureLatency`` starts its clock,
    /// any connection-scoped work the transport's first request would
    /// otherwise pay for — herdr's socket path, resolved once per session
    /// over exec. Awaiting it before the clock keeps the Hosts-list badge a
    /// measurement of the ping alone (#87). The default does nothing: a
    /// Transport whose first request carries no such prerequisite is ready
    /// immediately.
    func awaitSocketPathReadiness() async

    /// Lists the local herdr sessions visible to this SSH account. This is a
    /// Host-level capability and does not depend on the currently selected
    /// API socket, so onboarding can recover from a stale manual selection.
    func listSessions() async throws -> [HerdrSession]

    /// Lists the Agents herdr has detected across all workspaces.
    func listAgents() async throws -> [Agent]

    /// Lists the supported Agent kinds whose canonical executables are
    /// currently available on this Host. SSH transports probe the Host's
    /// effective PATH; alternative transports without a Host process
    /// environment report no detected kinds by default.
    func availableAgentKinds() async throws -> [SupportedAgentKind]

    /// The full session tree in one call: agents plus the workspace context
    /// (labels, worktrees) that `listAgents()` lacks. The Console's snapshot
    /// source (#8) — re-fetched on every events-session `.connected`.
    func sessionSnapshot() async throws -> SessionSnapshot

    /// Reads a Pane's recent terminal output for the Console card snippet.
    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult

    /// Reads an Agent's terminal output. Unlike `pane.read`, this preserves
    /// history semantics for alternate-screen Agents: history-capable sources
    /// fail honestly while the Agent is working instead of silently degrading
    /// to the visible screen.
    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult

    /// Delivers one complete local draft through `agent.prompt`. The request
    /// deliberately omits `wait`: the response acknowledges delivery into
    /// the Agent's pane, while Agent Status events report subsequent work.
    /// A prompt held back, nothing sent, until a launch's TUI takes input
    /// fails `AgentInputNotReadyError`. A prompt refused, nothing sent,
    /// because the pane shows a sign-in screen or a folder-trust dialog the
    /// prompt would answer fails `AgentSignInRequiredError` or
    /// `AgentFolderTrustRequiredError`. A link failure that provably came
    /// before the request's first byte was written fails
    /// `RequestNotSentError`, so a sender knows it may go again.
    func promptAgent(_ params: AgentPromptParams) async throws -> Agent

    /// Fails `AgentSignInRequiredError` or `AgentFolderTrustRequiredError`
    /// while `target`'s Agent shows the screen `promptAgent` refuses for
    /// its kind (`AgentScreen.InputReadiness`); sends nothing. The
    /// Composer asks it before typing into a Blocked Agent's Attach,
    /// since tmux and herdr read some of those screens as Blocked.
    func checkAgentInputScreen(target: String) async throws

    /// Stops `target`'s current run, leaving queued follow-ups in place.
    /// Only Ultimate conversations and Codex threads support this; every
    /// other backend refuses without side effects.
    func abortAgentRun(target: String) async throws

    /// What `target` is waiting on, as structured requests its backend
    /// raised (Codex app-server approvals and questions), oldest first.
    /// Backends that only show a Blocked screen answer none; their Blocked
    /// card reads the screen instead.
    func pendingAgentRequests(target: String) async throws -> [AgentPendingRequest]

    /// Answers one of `pendingAgentRequests(target:)`. A request already
    /// answered elsewhere (at the desk) fails `agent_request_resolved`,
    /// nothing sent.
    func answerAgentRequest(
        target: String, requestID: String, answer: AgentRequestAnswer
    ) async throws

    /// Sends control keys to an Agent (`agent.send_keys`). Key names are
    /// herdr's own spellings, shared with `pane.send_keys` / `pane.send_input`.
    func sendAgentKeys(_ params: AgentSendKeysParams) async throws

    /// Types into any Pane's PTY through `pane.send_input`: `text` is
    /// inserted without submitting unless `keys` follow it, and
    /// `{text, keys: ["enter"]}` is an atomic type-and-submit (verified live
    /// on 0.8.0). Unlike `agent.prompt` this works on an ordinary shell, so
    /// it is the shell row Composer's delivery path.
    func sendPaneInput(_ params: PaneSendInputParams) async throws

    /// Starts a new Agent: the new-agent flow (#12, User Story 8 — dispatch
    /// work from the road). Creates a fresh herdr tab in the chosen workspace,
    /// starts the requested agent in its root pane, and returns the Agent once
    /// the server acknowledges. The new pane also surfaces in the
    /// Console through the normal snapshot/delta machinery (a membership
    /// event triggers a re-snapshot), so callers do not thread the return
    /// value into the list themselves.
    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent

    /// Creates one ordinary shell tab in an existing Workspace. The concrete
    /// directory is mandatory so herdr cannot inherit an unrelated focused
    /// Pane's cwd. The returned identity is sufficient to attach the shell;
    /// no Agent is started and the Pane is not projected into the Console.
    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity

    /// Starts a new Agent in a fresh git worktree (#97): `worktree.create`
    /// resolves the repository from the source workspace's cwd (a non-git cwd
    /// fails with `not_git_worktree`) and returns a new workspace whose root
    /// pane already runs a shell, so this variant skips `tab.create` and
    /// starts the agent in that pane directly (the `agent_pane_busy`
    /// readiness retry still applies). `request.workspaceID` is the *source*
    /// workspace; the started agent lives in the returned worktree workspace
    /// and surfaces through the normal snapshot/delta machinery.
    ///
    /// `attempt` spans every try of one launch: a try never sends
    /// `worktree.create` once an earlier try did, and continues in the
    /// worktree that try made. A typed branch already checked out in an
    /// open linked worktree is reused instead: the Agent already running in
    /// its Workspace, or a new tab there. Steps go to `LaunchProgress`.
    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec,
        attempt: WorktreeLaunchAttempt
    ) async throws -> Agent

    /// Starts a new Agent in a freshly created Workspace (#230):
    /// `workspace.create` opens the remote directory as its own Workspace
    /// (no existing Workspace required) and returns a root pane already
    /// running a shell, so this variant skips `tab.create` and starts the
    /// agent in that pane directly (the `agent_pane_busy` readiness retry
    /// still applies). `request.workspaceID` is unused; the started agent
    /// lives in the returned Workspace and surfaces through the normal
    /// snapshot/delta machinery.
    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent

    /// Launches a plain shell in the chosen Workspace (`tab.create` only —
    /// the root pane already runs the Host's default shell, so no
    /// `agent.start` follows). As with `startAgent`, a nil directory lets
    /// herdr use the chosen Workspace's focused pane cwd.
    func startShellTerminal(
        _ request: ShellLaunchRequest
    ) async throws -> ShellLaunchResult

    /// Launches a plain shell in a fresh git worktree: `worktree.create`
    /// resolves the repository from the source workspace's cwd (a non-git
    /// cwd fails with `not_git_worktree`) and returns a root pane already
    /// running a shell. `request.workspaceID` is the *source* workspace.
    /// `attempt` works as in `startAgentInNewWorktree`; a reused worktree
    /// gets a new shell tab.
    func startShellTerminalInNewWorktree(
        _ request: ShellLaunchRequest, worktree: WorktreeSpec,
        attempt: WorktreeLaunchAttempt
    ) async throws -> ShellLaunchResult

    /// Launches a plain shell in a freshly created Workspace:
    /// `workspace.create` opens the remote directory as its own Workspace
    /// (no existing Workspace required) and returns a root pane already
    /// running a shell. `request.workspaceID` is unused.
    func startShellTerminalInNewWorkspace(
        _ request: ShellLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> ShellLaunchResult

    /// Closes a Pane (`pane.close`): the Agent detail screen's destructive
    /// close action (#13, User Story 9 — a Done agent must not be destroyed
    /// by a stray swipe, so the UI gates this behind an explicit
    /// confirmation). herdr removes the pane and its agent everywhere; the
    /// removal surfaces in the Console through the normal snapshot/delta
    /// machinery (a `pane.closed` membership event triggers a re-snapshot),
    /// so callers do not prune the list themselves. Targeted by the Pane's
    /// id; returns once the server acknowledges. With `closesWorktreeGroup`
    /// (a Close the user asked for), the last pane of a repo's main-checkout
    /// Workspace closes its worktree group, as herdr's desktop does once
    /// confirmed; without it herdr's `confirmation_required` refusal stands.
    /// Backends without worktree groups ignore the flag.
    func closePane(_ params: PaneTarget, closesWorktreeGroup: Bool) async throws

    /// Closes a Tab (`tab.close`): the Console row's swipe-to-close action.
    /// herdr removes the tab and every pane in it; when it was the
    /// workspace's last tab, herdr also closes the workspace server-side, so
    /// no compensation call is needed. The removal surfaces in the Console
    /// through the normal snapshot/delta machinery. Targeted by the Tab's
    /// id; returns once the server acknowledges. A main-checkout
    /// Workspace's last tab closes its worktree group, as in `closePane`.
    func closeTab(_ params: TabTarget) async throws

    /// Moves a Pane into a new Workspace or Tab (`pane.move`): the Console
    /// row's drag-to-workspace action. `destination` selects the target:
    /// an existing Workspace (new tab in it), a brand-new Workspace, or an
    /// existing Tab (with an optional split target). herdr auto-closes the
    /// emptied source Tab (and Workspace when it was its last Tab), and the
    /// moved Pane's id changes — the reply's `pane` carries the new id, so
    /// callers re-key local state (pins, selection) from it. The move
    /// surfaces in the Console through the normal snapshot/delta machinery
    /// (the confirmation events trigger a re-snapshot).
    func movePane(_ params: PaneMoveParams) async throws -> PaneMoveResponse

    /// Lists git worktrees for the repository containing `workspaceID`.
    /// Console detail uses this only to obtain branch presentation because
    /// `session.snapshot` already carries repository and checkout identity.
    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse

    /// Removes one exact confirmed linked Worktree. `authorize` is invoked
    /// after the stream-local channel opens but before its first request byte;
    /// `onDispatched` runs only after the complete request line is written.
    /// Both receive the immutable request that crosses this Transport seam.
    func removeWorktree(
        _ request: WorktreeRemovalRequest,
        authorize: @escaping @Sendable (WorktreeRemovalRequest) async throws -> Void,
        onDispatched: @escaping @Sendable (WorktreeRemovalRequest) async -> Void
    ) async throws -> WorktreeRemovedResponse

    /// Marks the viewed Agent seen through `agent.focus`. herdr 0.9.0 also
    /// focuses its Tab and marks every Pane in that Tab seen. Callers must
    /// refresh the entire Host rather than synthesize a selected-row status.
    func focusAgent(_ target: AgentTarget) async throws

    /// Renames an Agent (`agent.rename`): the Console management action
    /// (#98). A nil name clears the custom name back to the detected kind
    /// (verified live against herdr 0.7.5: omitting the key clears). The
    /// server enforces `^[a-z][a-z0-9_-]{0,31}$` on non-nil names and
    /// rejects violations with `invalid_agent_name`; non-agent targets fail
    /// with `agent_not_found`. The new name does NOT travel on events — the
    /// `pane.updated` this fires omits the agent name (verified live) — so
    /// consumers re-snapshot after the call instead of mutating local state
    /// or waiting on a delta.
    func renameAgent(_ params: AgentRenameParams) async throws

    /// Renames a workspace (`workspace.rename`): the Console management
    /// action (#98). The server accepts any label — empty, whitespace, and
    /// very long labels all pass (verified live against herdr 0.7.5); the
    /// only rejection is `workspace_not_found`. The new label surfaces
    /// through `workspace.renamed`, so callers do not mutate local state
    /// themselves.
    func renameWorkspace(_ params: WorkspaceRenameParams) async throws

    /// Opens this Host's dedicated long-lived events channel and subscribes.
    /// Returns once the server acknowledges the subscription; the stream then
    /// carries events in canonical naming until `end()` closes the channel
    /// explicitly. One events channel per Host: a second call while one is
    /// live throws `.eventsChannelAlreadyOpen`.
    ///
    /// Await subscription acknowledgement before requesting the initial
    /// snapshot, and consume events throughout the snapshot request. Repeat
    /// this sequence after reconnect or subscription replacement. herdr 0.9.0
    /// lifecycle subscriptions are live-only (version-tagged source review);
    /// they do not replay retained events from before request acceptance.
    /// The live-observed replay on 0.7.5 (absent on 0.7.4) is historical, not
    /// a recovery guarantee. Use snapshots for authoritative convergence.
    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream

    /// Opens an interactive PTY Attach. Each target permits one live channel;
    /// a duplicate target throws `.terminalChannelAlreadyOpen`. Distinct
    /// targets share the bounded Host channel admission budget.
    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession

    /// Probes whether this Host can serve a mosh (UDP) terminal:
    /// `mosh-server` must be on the Host's effective PATH. Console-side
    /// callers run this once per connection generation and cache the
    /// outcome — including a thrown probe as unavailable — so Attach never
    /// pays it per session. SSH stays the backbone either way: the probe
    /// only gates whether the mosh runner may attempt a bootstrap.
    func probeMoshServer() async throws -> Bool

    /// Bootstraps one mosh session for an interactive Attach: runs
    /// `mosh-server new` for the request's target over a PTY-less exec
    /// (mosh-server allocates its own PTY for the wrapped command), parses
    /// the `MOSH CONNECT` banner, and returns the UDP endpoint plus session
    /// key. mosh-server keeps running on the Host after this returns; the
    /// returned bootstrap's `host` is the numeric address the SSH connection
    /// reached when known (`moshUDPHost`), else the Host name (`sshHost`).
    /// Throws — and the caller falls back to ``attachTerminal`` — when
    /// mosh-server is absent or its banner never arrives.
    func runMoshBootstrap(_ request: TerminalAttachRequest) async throws -> MoshBootstrap

    /// Backend-specific checked handoff after the UDP client starts (Zellij focus claim).
    func prepareMoshTerminal(
        _ terminal: TerminalAttachSession, request: TerminalAttachRequest
    ) async throws -> TerminalAttachSession

    /// Stages one normalized app-owned image in private Host temporary
    /// storage. Concrete transports own destination selection, restrictive
    /// permissions, partial-file handling, and atomic completion (ADR 0006).
    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage

    /// Stages one app-owned file in private Host temporary storage. The file
    /// follows the same SFTP, permission, and atomic-completion policy as images.
    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile

    /// Writes a launch's Launch Prompt Files on the Host in one exec, never
    /// over SFTP: `.stageDirectory` files into one fresh private
    /// `waycar.*` directory, Codex profiles into the Codex home the Host's
    /// panes resolve. Returns each file's absolute path, in request order
    /// (plain for stage files); an empty list writes nothing. Waycar never
    /// deletes them (ADR 0005) except its `waycar-<uuid>` Codex profiles
    /// older than ten minutes, swept by the next write.
    func stageLaunchPromptFiles(
        _ files: [LaunchPromptFile]
    ) async throws -> [StagedLaunchPromptFile]

    /// Which file prompt routes the Host's harness CLIs support, read once
    /// per connection. Never throws: anything unknown reads unsupported.
    func launchPromptCapabilities() async -> LaunchPromptCapabilities

    /// Reads the Notification Registration file (v1, `plugin/README.md`)
    /// from the `waycar` herdr plugin's config dir on this Host; nil when no
    /// device has registered yet. Throws
    /// `NotificationRegistrationError.pluginNotInstalled` when the plugin is
    /// absent, so the ceremony can tell "install the plugin" apart from a
    /// broken read (#72).
    func readNotificationRegistration() async throws -> Data?

    /// Atomically replaces the Notification Registration file with
    /// `contents` (temp file + rename per the v1 contract), creating it when
    /// absent. Same plugin gate as the read.
    func replaceNotificationRegistration(_ contents: Data) async throws

    /// Reads the plugin's `notify.json` config from this Host's Waycar
    /// plugin config dir (the registration file's sibling; `plugin/README.md`);
    /// nil when the plugin has no config file yet. Same plugin gate as the
    /// registration read. Carries the custom Push Relay base URL (#76).
    func readNotificationConfig() async throws -> Data?

    /// Atomically replaces the plugin's `notify.json` config with `contents`
    /// (temp file + rename), creating it when absent. Same plugin gate as the
    /// registration write.
    func replaceNotificationConfig(_ contents: Data) async throws

    /// Reads the plugin's `sidebar.json` snapshot (v1, `plugin/README.md`)
    /// from this Host's `waycar` herdr plugin config dir; nil when the file is
    /// absent, including Hosts whose plugin predates the snapshot. Throws
    /// `NotificationRegistrationError.pluginNotInstalled` when the plugin
    /// itself is absent, matching the other plugin-config reads.
    func readSidebarLayout() async throws -> Data?

    /// Reads every Agent Summary the `waycar` plugin keeps in this Host's
    /// plugin config dir (`summaries/`, one file per pane; `plugin/README.md`)
    /// in one exec, keyed by pane id. Empty when the directory is absent.
    /// Throws `NotificationRegistrationError.pluginNotInstalled` when the
    /// plugin itself is absent, matching the other plugin-config reads.
    func readAgentSummaries() async throws -> [String: AgentSummary]

    /// Shell Activity for the given Shell panes. Absent key = unknown for that pane. Throws only cancellation and link/transport failures.
    func shellActivities(paneIDs: [String]) async throws -> [String: ShellActivity]

    /// Asks this Host's `waycar` plugin to refresh its Agent Summaries
    /// (`AgentSummary.refreshCommand`). Returns once herdr has started the
    /// action, not when the summaries are written. Throws
    /// `AgentSummaryRefreshError.actionUnavailable` when the plugin or herdr
    /// predates the action, and `NotificationRegistrationError.pluginNotInstalled`
    /// when the plugin is absent.
    func refreshAgentSummaries() async throws

    /// Reads every Chat Marker the `waycar` plugin config dir holds
    /// (`chat/`, one file per pane) in one exec. Unreadable files are
    /// skipped; empty when the directory is absent. Throws
    /// `NotificationRegistrationError.pluginNotInstalled` when the plugin
    /// itself is absent, matching the other plugin-config reads.
    func readChatModeMarkers() async throws -> [ChatModeMarker]

    /// Atomically writes `marker` to `chat/<ChatModeMarker.fileName>` in the
    /// plugin config dir (temp file, mode 0600, rename), creating `chat/`
    /// when absent. Same plugin gate as the read.
    func writeChatModeMarker(_ marker: ChatModeMarker) async throws

    /// Deletes `chat/<ChatModeMarker.fileName(paneID:)>` from the plugin
    /// config dir, retiring a closed chat Agent's marker; an absent file is
    /// not an error.
    func deleteChatModeMarker(paneID: String) async throws

    /// Runs the plugin's transcript reader (`src/chat-read.js`, or
    /// `waycar chat-read` on a native Host) for one
    /// Agent and decodes its NDJSON. Throws
    /// `NotificationRegistrationError.pluginNotInstalled` when the plugin is
    /// absent and `ChatTranscriptError.readerUnavailable` when it predates
    /// the reader.
    func readChatTranscript(_ request: ChatTranscriptRequest) async throws -> ChatTranscriptSnapshot

    /// Runs the plugin's media reader (`src/chat-media.js`, or
    /// `waycar chat-media` on a native Host) for one inline
    /// image a transcript line holds as base64 and returns its decoded
    /// bytes. Throws ``ChatMediaError/pluginOutdated`` when the plugin
    /// predates the reader, ``ChatMediaError/unavailable`` when the line,
    /// pointer or string is not there, and ``ChatMediaError/tooLarge`` past
    /// `request.maxBytes`.
    func readChatMedia(_ request: ChatMediaRequest) async throws -> Data

    /// Lists the skills / custom slash commands installed for a kind on this
    /// Host: global sources under the remote home plus project sources under
    /// the query's project root, per `SkillSourceCatalog`. Kinds without a
    /// catalog entry return empty. Reads the filesystem over exec, so
    /// alternative transports without a Host process environment report
    /// nothing by default.
    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill]

    /// Reads one skill document in full (capped) for the on-demand content
    /// view; `path` is what the skills probe reported. Same transport caveat
    /// as `listSkills`.
    func readSkillFile(atPath path: String) async throws -> String

    /// Reads one byte range of a Host file. A file that only ever grows — an
    /// Agent's session transcript — is followed by asking for what has not
    /// been read yet, so a screen can show a running figure without pulling
    /// the whole file on every look.
    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice

    /// Reads a whole Host file for a user-requested preview: at most
    /// `maxBytes`, regular files only. `path` is absolute and untrusted — a
    /// path printed by remote output — and is never interpreted by a shell
    /// (see ``RemoteFilePreview``). Throws ``RemoteFilePreviewError`` for
    /// paths that cannot be previewed.
    func readPreviewFile(atPath path: String, maxBytes: Int) async throws -> Data

    /// The context window, in tokens, of the model an Agent's session names
    /// as `provider/model`, as the Agent's own CLI on the Host reports it.
    /// `nil` when the CLI is absent or does not know the model; a session
    /// figure is then shown without its window (#325).
    func modelContextWindow(selector: String) async throws -> Int?

    /// The branch checked out at `path` on the Host, or the short SHA when
    /// detached, for the Agent Footer (#169); `nil` when `path` is not in a
    /// git work tree, git is missing, or `GitBranchProbe` refuses the path.
    func gitBranch(atPath path: String) async throws -> String?

    /// Finds the CodexBar CLI on this Host for AI Usage: `customPath` alone
    /// when set, else `command -v` under the Host PATH fix and then the app
    /// bundle (`CodexBarCommand`). nil when there is none — an answer, not a
    /// failure. Throws `CodexBarError.invalidPath` for an unusable custom
    /// path and `CodexBarError.timedOut`, not a link failure, when the probe
    /// runs out of time.
    func locateCodexBar(customPath: String?) async throws -> String?

    /// Runs `<executablePath> usage --format json` and decodes the report.
    /// The CLI exits nonzero whenever any provider failed, so its output is
    /// read regardless of the exit status; per-provider errors are rows of
    /// the report. Bounded by `CodexBarCommand.usageTimeout` on the app side
    /// and a shorter watchdog on the Host; running out is
    /// `CodexBarError.timedOut`, never a link failure.
    func codexBarUsage(executablePath: String) async throws -> AIUsageReport

    /// Samples the Host's CPU, memory and swap use with one Host command
    /// (`HostResourceUsage.command`, about one second on the Host). Throws
    /// `HostResourceUsage.Unsupported` when the Host's OS answers in neither
    /// the Linux nor the macOS shape.
    func hostResourceUsage() async throws -> HostResourceUsage

    /// The Host's remote home directory, resolved over exec once per
    /// connection and cached. The New Workspace directory browser starts
    /// there (#280).
    func remoteHomeDirectory() async throws -> String

    /// Lists one absolute remote path's subdirectories for the New Workspace
    /// directory browser (#280). Invalid paths are refused before any
    /// channel opens.
    func listDirectories(at path: String) async throws -> RemoteDirectoryListing

    /// Renames a Shell row: its name is its tab label. herdr renames the tab
    /// (`tab.rename`, since `agent.rename` refuses a pane with no Agent);
    /// tmux renames the window.
    func renameShellTab(tabID: String, label: String) async throws

    /// The Host tools' report on Waycar's agent status hooks
    /// (`waycar hooks status --json`, design §4.5). tmux and herdr-core only
    /// (both through `HostToolsTransport`): the herdr TUI reports Agent
    /// Status itself.
    func statusHooksReport() async throws -> StatusHooksReport

    /// Installs Waycar's agent status hooks on the Host
    /// (`waycar hooks install --json`) and returns the resulting report.
    func installStatusHooks() async throws -> StatusHooksReport

    /// Starts a plain tmux session named `main` (or `main-2`… when taken) at
    /// the Host's home directory, for a Host whose tmux runs no session
    /// (design §2 scenario 8). tmux only.
    func startMainSession() async throws

    /// Moves a pane's view `rows` rows through its history in tmux copy mode,
    /// for a pane whose application is neither on the alternate screen nor
    /// tracking the mouse (inline agents, shells): a tmux attach shows only
    /// tmux's redraw, so the terminal has no scrollback of its own. Older
    /// enters copy mode (`copy-mode -e`, which leaves it at the bottom);
    /// zero rows only reports where the view is. tmux only.
    func scrollPaneHistory(
        paneID: String, towardOlderContent: Bool, rows: Int
    ) async throws -> PaneHistoryScroll

    /// Leaves the copy mode ``scrollPaneHistory(paneID:towardOlderContent:rows:)``
    /// entered, so the pane takes input again. tmux only.
    func leavePaneHistory(paneID: String) async throws

    /// Whether the underlying connection to the Host is still alive. The
    /// reconnect machinery (#18) decides "re-subscribe on this connection or
    /// re-establish it" from this flag.
    var isConnected: Bool { get async }

    /// Tears the connection down explicitly, ending every channel it
    /// carries. Terminal: a closed Transport is not reusable.
    func close() async throws

    /// EventsSession stopped handing this Transport out after a link
    /// failure, without closing it: Terminals opened on it may still be
    /// using it. A Transport that holds per-connection resources a
    /// replacement on the same connection needs (tmux's one control slot)
    /// gives them up here; everything else stays usable until `close()`.
    func transportDistrusted() async
}

extension Transport {
    func ultimateOpenQuestions() async -> [String: Int] { [:] }

    /// Backends without a run to stop refuse; nothing is sent.
    func abortAgentRun(target: String) async throws {
        throw TransportError.apiRejected(
            code: "unsupported", message: "This Host cannot stop a run.")
    }

    /// Screen-read backends raise no structured requests.
    func pendingAgentRequests(target: String) async throws -> [AgentPendingRequest] { [] }

    func answerAgentRequest(
        target: String, requestID: String, answer: AgentRequestAnswer
    ) async throws {
        throw TransportError.apiRejected(
            code: "unsupported", message: "This Host has no requests to answer.")
    }
    func serverSessionLinkFacts() async -> ServerSessionLinkFacts { ServerSessionLinkFacts() }
    func prepareMoshTerminal(
        _ terminal: TerminalAttachSession, request: TerminalAttachRequest
    ) async throws -> TerminalAttachSession { terminal }

    func archivedServerSessions() async -> [ArchivedServerSession] { [] }
    func closedZellijSessions(refreshAge: Bool) async throws -> [ZellijClosedSession] { [] }
    func deleteZellijSession(_ name: String) async throws {
        throw HerdrAPIError(code: "unsupported", message: "This Backend has no saved Zellij sessions.")
    }
    func ultimateConversationChildren() async -> [String: [UltimateChildInfo]] { [:] }

    /// Most Transports re-prove a connection the way the keepalive does.
    func revalidate() async throws -> ServerInfo { try await ping() }

    /// Default: no first-request prerequisite.
    func awaitSocketPathReadiness() async {}

    /// Test doubles and alternative transports that do not expose Host-level
    /// session discovery can opt out without inventing sessions.
    func listSessions() async throws -> [HerdrSession] { [] }

    /// Most Transports hold nothing a replacement waits for.
    func transportDistrusted() async {}

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        []
    }

    func startMainSession() async throws {
        throw TransportError.channelFailed(
            detail: "This transport cannot start tmux sessions.")
    }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        throw TransportError.channelFailed(
            detail: "This transport cannot create shell terminals.")
    }

    func startShellTerminal(
        _ request: ShellLaunchRequest
    ) async throws -> ShellLaunchResult {
        throw TransportError.channelFailed(
            detail: "This transport cannot launch shells.")
    }

    func startShellTerminalInNewWorktree(
        _ request: ShellLaunchRequest, worktree: WorktreeSpec,
        attempt: WorktreeLaunchAttempt
    ) async throws -> ShellLaunchResult {
        throw TransportError.channelFailed(
            detail: "This transport cannot launch shells.")
    }

    func startShellTerminalInNewWorkspace(
        _ request: ShellLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> ShellLaunchResult {
        throw TransportError.channelFailed(
            detail: "This transport cannot launch shells.")
    }

    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill] {
        []
    }

    func readSkillFile(atPath path: String) async throws -> String {
        throw TransportError.channelFailed(
            detail: "This transport cannot read skill files.")
    }

    /// Test doubles and alternative transports without Host files can decline
    /// without emulating an SSH library; a follower then shows only what the
    /// Host reports elsewhere.
    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        throw TransportError.channelFailed(
            detail: "This transport cannot read Host files.")
    }

    func readPreviewFile(atPath path: String, maxBytes: Int) async throws -> Data {
        throw TransportError.channelFailed(
            detail: "This transport cannot read Host files.")
    }

    /// A transport without Host commands knows no model windows.
    func modelContextWindow(selector: String) async throws -> Int? { nil }

    /// A transport without Host commands knows no branches.
    func gitBranch(atPath path: String) async throws -> String? { nil }

    /// A transport without Host commands has no CodexBar to find.
    func locateCodexBar(customPath: String?) async throws -> String? { nil }

    func codexBarUsage(executablePath: String) async throws -> AIUsageReport {
        throw TransportError.channelFailed(
            detail: "This transport cannot run Host commands.")
    }

    func hostResourceUsage() async throws -> HostResourceUsage {
        throw TransportError.channelFailed(
            detail: "This transport cannot run Host commands.")
    }

    /// Non-SSH test doubles and alternative transports can state that SFTP is
    /// unavailable without importing or emulating an SSH library.
    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        throw AttachmentStagingError.sftpUnavailable
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        throw AttachmentStagingError.sftpUnavailable
    }

    /// A transport without Host commands writes no Launch Prompt Files.
    func stageLaunchPromptFiles(
        _ files: [LaunchPromptFile]
    ) async throws -> [StagedLaunchPromptFile] {
        throw LaunchPromptStagingError.unavailable
    }

    func launchPromptCapabilities() async -> LaunchPromptCapabilities { .none }

    /// Test doubles and alternative transports without a Host-side plugin
    /// can report its absence without emulating the plugin CLI.
    func readNotificationRegistration() async throws -> Data? {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func readNotificationConfig() async throws -> Data? {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    /// Test doubles and alternative transports without a Host-side plugin
    /// report an absent snapshot rather than emulating the plugin CLI.
    func readSidebarLayout() async throws -> Data? { nil }

    /// Test doubles and alternative transports without a Host-side plugin
    /// have no summaries to report.
    func readAgentSummaries() async throws -> [String: AgentSummary] { [:] }

    /// Test doubles and alternative transports report no Shell Activity:
    /// every pane is unknown.
    func shellActivities(paneIDs: [String]) async throws -> [String: ShellActivity] { [:] }

    /// Test doubles and alternative transports without a Host-side plugin
    /// cannot ask one to refresh.
    func refreshAgentSummaries() async throws {
        throw AgentSummaryRefreshError.actionUnavailable
    }

    /// Test doubles and alternative transports without a Host-side plugin
    /// know no Chat Markers and cannot write one.
    func readChatModeMarkers() async throws -> [ChatModeMarker] { [] }

    func writeChatModeMarker(_ marker: ChatModeMarker) async throws {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func deleteChatModeMarker(paneID: String) async throws {}

    func readChatTranscript(_ request: ChatTranscriptRequest) async throws -> ChatTranscriptSnapshot {
        throw ChatTranscriptError.readerUnavailable
    }

    func readChatMedia(_ request: ChatMediaRequest) async throws -> Data {
        throw TransportError.channelFailed(
            detail: "This transport cannot read chat media.")
    }

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        throw TransportError.channelFailed(
            detail: "This transport cannot list worktrees.")
    }

    func removeWorktree(
        _ request: WorktreeRemovalRequest,
        authorize: @escaping @Sendable (WorktreeRemovalRequest) async throws -> Void,
        onDispatched: @escaping @Sendable (WorktreeRemovalRequest) async -> Void
    ) async throws -> WorktreeRemovedResponse {
        throw TransportError.channelFailed(
            detail: "This transport cannot remove worktrees.")
    }

    /// Transports without a Host shell have no home directory to browse.
    func remoteHomeDirectory() async throws -> String {
        throw TransportError.sshUnreachable(detail: "This Host cannot list remote directories.")
    }

    func listDirectories(at path: String) async throws -> RemoteDirectoryListing {
        throw TransportError.sshUnreachable(detail: "This Host cannot list remote directories.")
    }

    func renameShellTab(tabID: String, label: String) async throws {
        throw TransportError.sshUnreachable(detail: "This Host cannot rename tabs.")
    }

    /// Transports without Waycar's Host tools have no status hooks (tmux and
    /// herdr-core read them through `HostToolsTransport`).
    func statusHooksReport() async throws -> StatusHooksReport {
        throw TransportError.channelFailed(detail: "This Host has no status hooks.")
    }

    func installStatusHooks() async throws -> StatusHooksReport {
        throw TransportError.channelFailed(detail: "This Host has no status hooks.")
    }

    /// Only tmux scrolls a pane's history for the app.
    func scrollPaneHistory(
        paneID: String, towardOlderContent: Bool, rows: Int
    ) async throws -> PaneHistoryScroll {
        PaneHistoryScroll(position: .unavailable)
    }

    func leavePaneHistory(paneID: String) async throws {}
}

/// Where a tmux pane's view sits after a
/// ``Transport/scrollPaneHistory(paneID:towardOlderContent:rows:)``.
enum PaneHistoryPosition: Sendable, Equatable {
    /// Nothing to scroll this way: the application is on the alternate
    /// screen (no history behind it), or the pane is in another mode.
    case unavailable
    /// At live output, out of copy mode.
    case live
    /// In copy mode, above live output: typed input must leave it first.
    case inHistory
}

/// One ``Transport/scrollPaneHistory(paneID:towardOlderContent:rows:)``
/// answer: where the view now sits, and whether this call took it into
/// copy mode. A view already in copy mode (a desk client's, another
/// device's) was not entered by this call, whatever the caller last saw.
struct PaneHistoryScroll: Sendable, Equatable {
    var position: PaneHistoryPosition
    var enteredHistory = false
}

/// What `waycar status --json` / `waycar hooks status --json` print on a
/// Host (`plugin/rust`): the Host tools, the backends they found, and
/// Waycar's status hooks per agent CLI.
struct StatusHooksReport: Sendable, Equatable, Decodable {
    struct HostTools: Sendable, Equatable, Decodable {
        let version: String
        let pluginRoot: String
    }

    struct Backends: Sendable, Equatable, Decodable {
        let herdr: Bool
        let tmux: String?
        /// herdr-core's version (plugin 2.2.0 on); nil when core is absent
        /// and in a report from an older plugin, which has no such key.
        var core: String? = nil
        /// Host Tools 2.6.0 on; older reports decode without this field.
        var zellij: String? = nil
    }

    struct AgentHooks: Sendable, Equatable, Decodable {
        let agent: String
        let installed: Bool
        /// Whether the agent's CLI (or config directory) exists on the Host.
        /// nil from a report that predates the field; treated as detected.
        var detected: Bool? = nil
        let configPath: String?
        /// Codex keeps new hooks inactive until the user reviews them once in
        /// its `/hooks` screen.
        let needsCodexReview: Bool?
    }

    let version: Int
    let hostTools: HostTools
    let backends: Backends
    let configDir: String?
    let agents: [AgentHooks]
}

/// Waycar's catalog of interactive Agent kinds.
///
/// The raw value is the canonical `agent.start.kind`; `executable` mirrors
/// the command herdr launches for that kind. Keeping both explicit matters
/// for kinds such as Cursor and Kiro whose executable is not their canonical
/// protocol label.
enum SupportedAgentKind: String, CaseIterable, Identifiable, Sendable, Equatable {
    case pi
    case claude
    case codex
    case gemini
    case cursor
    case devin
    case antigravity = "agy"
    case cline
    case omp
    case mastracode
    case opencode
    case copilot
    case kimi
    case kiro
    case droid
    case amp
    case grok
    case hermes
    case kilo
    case qodercli
    case maki
    case muse
    case qwen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pi: "Pi"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .cursor: "Cursor Agent"
        case .devin: "Devin CLI"
        case .antigravity: "Antigravity"
        case .cline: "Cline"
        case .omp: "OMP"
        case .mastracode: "Mastra Code"
        case .opencode: "OpenCode"
        case .copilot: "GitHub Copilot CLI"
        case .kimi: "Kimi CLI"
        case .kiro: "Kiro CLI"
        case .droid: "Droid"
        case .amp: "Amp"
        case .grok: "Grok Build"
        case .hermes: "Hermes Agent"
        case .kilo: "Kilo Code"
        case .qodercli: "Qoder CLI"
        case .maki: "Maki"
        case .muse: "Muse"
        case .qwen: "Qwen Code"
        }
    }

    var executable: String {
        switch self {
        case .cursor: "cursor-agent"
        case .kiro: "kiro-cli"
        default: rawValue
        }
    }
}

/// Native settings for a new Codex app-server thread.
struct CodexLaunchOptions: Sendable, Equatable {
    var developerInstructions: String? = nil
    var model: String? = nil
    var reasoningEffort: String? = nil
    /// An explicit Closed Session resume loads this durable thread instead
    /// of creating another. Native resumes keep its existing configuration.
    var resumeThreadID: String? = nil
}

/// Native settings for an OpenCode 2 server session.
struct OpenCodeLaunchOptions: Sendable, Equatable {
    /// A Closed Session's Resume unarchives this session instead of
    /// creating another.
    var resumeSessionID: String? = nil
    /// The session id New Agent minted once, when the launch was first
    /// requested (`OpenCodeSessionID.mint()`), and kept with its Queued
    /// Launch: it is the Launch Tag, so every retry creates the same
    /// session (O11).
    var sessionID: String? = nil
    /// Settings › Chat Mode's OpenCode model, `provider/model`.
    var model: String? = nil
    /// The Chat Prompt, as the session's `waycar-chat-prompt` instruction
    /// entry (`OpenCodeTransport.chatPromptEntryKey`).
    var instructions: String? = nil
}

/// App-domain request for launching a fresh coding agent.
///
/// herdr protocol 17 split the old topology-changing `agent.start` into
/// `tab.create` followed by a pane-targeted `agent.start`. Keeping that wire
/// choreography behind `Transport` prevents UI code from depending on the
/// server's transport-level request shapes.
struct AgentLaunchRequest: Sendable, Equatable {
    let kind: String
    let name: String
    let arguments: [String]
    let workspaceID: String?
    /// Working directory for the fresh tab, carried when the launch starts
    /// from another agent's screen and should land in the same place. Nil
    /// lets herdr fall back to the workspace's own directory.
    let cwd: String?
    /// Variables set for the Agent before it starts (a Chat Prompt route
    /// such as Copilot's instructions directory or Hermes's ephemeral
    /// system prompt). tmux sets them on the Agent alone, through an `env`
    /// prefix; herdr's `agent.start` takes no env (protocol 22), so they ride
    /// `tab.create`/`workspace.create` `env` and stay in the tab's shell
    /// after the Agent exits. Empty for most launches.
    let environment: [String: String]
    /// The Launch Tag: the launch's own id, left on the Host with what it
    /// creates so a later try can find it. Nil for a launch nothing retries.
    let launchID: UUID?
    /// An earlier try of this launch may have reached the Host (its answer
    /// was lost): look for what carries `launchID` first and use it, and
    /// start only what is missing.
    let mayHaveStarted: Bool
    /// Native app-server settings; terminal backends ignore these.
    let codex: CodexLaunchOptions?
    /// Native OpenCode 2 server settings; terminal backends ignore these.
    let opencode: OpenCodeLaunchOptions?
    /// A resume pane for a shared-server thread must join that server.
    /// Every other terminal Codex launch opts out when supported.
    let joinsCodexServer: Bool

    init(
        kind: String, name: String, arguments: [String] = [], workspaceID: String? = nil,
        cwd: String? = nil, environment: [String: String] = [:],
        launchID: UUID? = nil, mayHaveStarted: Bool = false, codex: CodexLaunchOptions? = nil,
        joinsCodexServer: Bool = false, opencode: OpenCodeLaunchOptions? = nil
    ) {
        self.kind = kind
        self.name = name
        self.arguments = arguments
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.environment = environment
        self.launchID = launchID
        self.mayHaveStarted = mayHaveStarted
        self.codex = codex
        self.joinsCodexServer = joinsCodexServer
        self.opencode = opencode
    }
}

/// One structured request an Agent is waiting on (`Transport.pendingAgentRequests`):
/// a Codex app-server approval or question, answered natively rather than by
/// keys typed into a terminal.
struct AgentPendingRequest: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        /// Run `command` (shell-wrapped as Codex shows it) in `cwd`.
        case command(command: String, cwd: String?, reason: String?)
        /// Write files; `paths` lists what the change touches, when known.
        case fileChange(reason: String?, paths: [String])
        /// Questions with options (Codex `item/tool/requestUserInput`).
        case questions(ChatQuestionCard)
        /// A request kind Waycar cannot answer; the terminal can.
        case unsupported(method: String)
    }

    /// Opaque, stable for the request's life; `answerAgentRequest` echoes it.
    let id: String
    let kind: Kind
}

/// How the user answered an `AgentPendingRequest`.
enum AgentRequestAnswer: Sendable, Equatable {
    /// Allow this once.
    case allow
    /// Refuse and stop the turn, as Esc does in the Codex TUI.
    case cancel
    /// Answers to `.questions`, keyed by question `ref`: the chosen option
    /// labels, or typed text.
    case answers([String: [String]])
}

/// App-domain request for launching a plain shell from the new-agent flow:
/// the chosen launch destination's own fresh pane, running the Host's
/// default shell — no agent is started on it. Identical to
/// `AgentLaunchRequest` minus the agent-only fields, so the form can offer
/// both under one "Agent" picker.
struct ShellLaunchRequest: Sendable, Equatable {
    /// Optional tab label; nil lets herdr apply its default.
    let name: String?
    let workspaceID: String?
    /// Working directory for the fresh tab, carried when the launch starts
    /// from another agent's screen and should land in the same place. Nil
    /// lets herdr fall back to the workspace's own directory.
    let cwd: String?
    /// The Launch Tag, as on `AgentLaunchRequest`.
    let launchID: UUID?
    /// As on `AgentLaunchRequest`.
    let mayHaveStarted: Bool

    init(
        name: String? = nil, workspaceID: String? = nil, cwd: String? = nil,
        launchID: UUID? = nil, mayHaveStarted: Bool = false
    ) {
        self.name = name
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.launchID = launchID
        self.mayHaveStarted = mayHaveStarted
    }
}

/// The one-shot API request behind Agent Detail's Open Terminal action.
/// `cwd` is concrete by construction; callers disable the action when they
/// cannot resolve one honestly.
struct ShellTerminalCreationRequest: Sendable, Equatable {
    let workspaceID: String
    let cwd: String

    init(workspaceID: String, cwd: String) {
        self.workspaceID = workspaceID
        self.cwd = cwd
    }
}

/// Stable remote identity retained after `tab.create` succeeds. Attach retry
/// and Host-generation replacement use `terminalID`; Pane and Tab ids remain
/// available without inventing a `ConsoleAgent` for the shell.
struct ShellTerminalIdentity: Sendable, Equatable, Hashable {
    let paneID: String
    let tabID: String
    let terminalID: String

    init(paneID: String, tabID: String, terminalID: String) {
        self.paneID = paneID
        self.tabID = tabID
        self.terminalID = terminalID
    }
}

/// What a plain-shell launch lands in: the created tab's root pane joined
/// with the Workspace it belongs to (its own when the launch made one). The
/// Pane is an ordinary shell — the Console lists it as a shell row until an
/// Agent starts in it.
struct ShellLaunchResult: Sendable, Equatable {
    let paneID: String
    let tabID: String
    let terminalID: String
    let workspaceID: String

    init(paneID: String, tabID: String, terminalID: String, workspaceID: String) {
        self.paneID = paneID
        self.tabID = tabID
        self.terminalID = terminalID
        self.workspaceID = workspaceID
    }
}

/// What the skills probe needs to know: whose sources to walk and where the
/// agent's project lives. The project root is the *launch* directory context
/// (worktree checkout or agent cwd), deliberately not the live foreground
/// cwd — agents load project skills from where they started, and a `cd`
/// inside the session does not change that set.
struct SkillListQuery: Sendable, Equatable {
    let kind: SupportedAgentKind
    /// Absolute project root, or nil when the agent's project is unknown;
    /// nil skips project sources rather than failing the probe.
    let projectRoot: String?

    init(kind: SupportedAgentKind, projectRoot: String? = nil) {
        self.kind = kind
        self.projectRoot = projectRoot
    }
}

/// A byte range of one Host file, addressed from its start.
struct RemoteFileRange: Sendable, Equatable {
    let path: String
    let offset: UInt64
    let maxBytes: Int

    init(path: String, offset: UInt64, maxBytes: Int) {
        self.path = path
        self.offset = offset
        self.maxBytes = maxBytes
    }
}

/// One ranged read's answer: the bytes that range holds, and the file's size
/// at that moment. `length` is nil only when the file is absent, which is how
/// a follower tells "nothing appended yet" from "the file is gone".
struct RemoteFileSlice: Sendable, Equatable {
    let data: Data
    let length: UInt64?

    init(data: Data, length: UInt64?) {
        self.data = data
        self.length = length
    }
}

/// A late-bound ranged read. Resolved per call rather than captured, so a
/// reconnect cannot leave a follower reading through a dead transport.
typealias SessionFileReader = @Sendable (RemoteFileRange) async throws -> RemoteFileSlice

/// A late-bound `readPreviewFile(atPath:maxBytes:)`, resolved per call for
/// the same reason as `SessionFileReader`.
typealias PreviewFileReader = @Sendable (_ path: String, _ maxBytes: Int) async throws -> Data

/// A late-bound `modelContextWindow(selector:)`, resolved per call for the
/// same reason as `SessionFileReader`.
typealias ModelContextWindowResolver = @Sendable (String) async throws -> Int?

/// Where a new worktree's branch starts.
enum WorktreeBase: Codable, Sendable, Equatable {
    /// herdr's default: the source checkout's current HEAD (no fetch).
    case sourceHead
    /// A user-typed commit-ish, passed to herdr verbatim.
    case ref(String)
    /// Ask origin for its default branch's commit (`git ls-remote origin
    /// HEAD`), download it into the source checkout with a ref-less fetch,
    /// and start from that SHA. `refs/remotes/origin/HEAD` is never used.
    case latestDefaultBranch
}

/// App-domain refinements for the fresh-worktree launch variant (#97). A nil
/// branch and `.sourceHead` use herdr's defaults, verified live against
/// 0.7.5: branch `worktree/<generated-name>` off HEAD, checkout under
/// herdr's worktree root. An existing branch is checked out, not rejected;
/// it only fails when another worktree already has it checked out.
///
/// The sheet never leaves the branch to herdr: when the Branch field is
/// empty it mints one in herdr's own `worktree/<adjective>-<noun>-<hex>`
/// format and sets `branchIsGenerated`. A name only this launch knows is
/// what lets a retry or replay recognise the worktree it made, and tell it
/// apart from one the user or another Agent opened on a typed branch.
struct WorktreeSpec: Codable, Sendable, Equatable {
    let branch: String?
    let base: WorktreeBase
    /// True when `branch` was minted by this launch rather than typed, so a
    /// worktree found on it is this launch's own.
    let branchIsGenerated: Bool

    init(branch: String? = nil, base: WorktreeBase = .sourceHead, branchIsGenerated: Bool = false) {
        self.branch = branch
        self.base = base
        self.branchIsGenerated = branchIsGenerated
    }
}

/// App-domain refinements for the new-Workspace launch variant (#230).
/// `directory` is the remote path `workspace.create` opens; `label` is
/// optional and omitted on the wire when nil so herdr applies its default.
struct NewWorkspaceSpec: Codable, Sendable, Equatable {
    let directory: String
    let label: String?

    init(directory: String, label: String? = nil) {
        self.directory = directory
        self.label = label
    }
}

/// Server identity as reported by `ping`: herdr's version and protocol, or
/// for tmux its version with protocol 0 (tmux has no protocol to negotiate).
struct ServerInfo: Sendable, Equatable {
    let version: String
    let protocolVersion: Int
    /// The Host speaks a protocol newer than the schema snapshot this build
    /// was generated against. Purely advisory: the connection is usable, and
    /// herdr's additions have been additive, but features introduced after
    /// this build cannot be driven. Consumers surface it, never refuse on it.
    let exceedsGeneratedProtocol: Bool
    /// Which backend answered (ADR 0026).
    let backend: HostBackend

    init(
        version: String, protocolVersion: Int, exceedsGeneratedProtocol: Bool = false,
        backend: HostBackend = .herdr
    ) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.exceedsGeneratedProtocol = exceedsGeneratedProtocol
        self.backend = backend
    }
}

/// One entry from `herdr session list --json` on a Host.
struct HerdrSession: Sendable, Equatable, Decodable {
    let name: String
    let isDefault: Bool
    let isRunning: Bool

    init(name: String, isDefault: Bool, isRunning: Bool) {
        self.name = name
        self.isDefault = isDefault
        self.isRunning = isRunning
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case isDefault = "default"
        case isRunning = "running"
    }
}

/// The grammar enforced by herdr 0.7.4 for named sessions. Keeping it at the
/// transport boundary prevents malformed discovery output from becoming part
/// of a remote socket path; forms reuse it for immediate feedback.
enum HerdrSessionName {
    static let maximumUTF8Length = 64

    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard name.utf8.count <= maximumUTF8Length else { return false }
        return name.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }
}

/// Paths passed through the Host's login shell use the conservative quoting
/// subset shared by POSIX shells and fish. Spaces are safe inside single
/// quotes; quote, backslash, and control characters are refused because their
/// single-quote behavior differs across those shells.
enum RemoteShellPath {
    static func quotedAbsolute(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        guard path.unicodeScalars.allSatisfy(isQuotable) else { return nil }
        return "'\(path)'"
    }

    static func isQuotableAbsolute(_ path: String) -> Bool {
        quotedAbsolute(path) != nil
    }

    private static func isQuotable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F
            && scalar.value != 0x27 && scalar.value != 0x5C
    }
}

/// Directories-only listing of one remote directory, for the remote
/// directory browser (#280). Names are sorted; `truncated` reports that more
/// directories exist than fit in the surfaced cap.
struct RemoteDirectoryListing: Sendable, Equatable {
    let directories: [String]
    let truncated: Bool
}

/// What a Shell pane's foreground is doing. Never an Agent Status. nil (absent) = unknown.
enum ShellActivity: Sendable, Equatable {
    case idle
    case running(command: String)

    static let commandLimit = 80

    /// The Host's command line as one display line (see `HostText.normalizedLine`).
    static func runningCommand(_ raw: String) -> ShellActivity? {
        HostText.normalizedLine(raw, limit: commandLimit).map { .running(command: $0) }
    }
}

/// The one sanitizer for Host-supplied text shown on a single line.
enum HostText {
    /// Drops control and format scalars (C0/C1, bidi, zero-width, tags), keeps at most 2 combining marks per base, collapses whitespace runs to one space, trims, caps at `limit` grapheme clusters (append "…" when cut). Scans at most ~4×limit kept scalars. Returns nil when nothing is left.
    static func normalizedLine(_ raw: String, limit: Int) -> String? {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        var kept = 0
        var marks = 0
        let scalarBudget = limit * 4
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format:
                continue
            case .nonspacingMark, .enclosingMark:
                guard marks < 2 else { continue }
                marks += 1
            default:
                marks = 0
            }
            if kept >= scalarBudget { break }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
            kept += 1
        }
        let text = String(scalars)
        guard !text.isEmpty else { return nil }
        guard text.count > limit || kept >= scalarBudget else { return text }
        return text.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A coding agent process running inside a herdr Pane.
///
/// The domain view of the generated wire type `AgentInfo`: only the fields
/// the app consumes, with wire-level optionality resolved. `AgentStatus` is
/// the generated raw-string wrapper; Blocked drives sort order and (later)
/// notifications.
struct Agent: Sendable, Equatable {
    let terminalID: String
    /// The agent program herdr detected: "claude", "codex", ... Behavior
    /// stays keyed off this; labels prefer `displayName`.
    let kind: String
    /// The server-reported agent name the herdr TUI shows (`display_agent`,
    /// falling back to `name`); nil when the server reports neither.
    let name: String?
    /// Terminal title with spinner/status glyphs stripped.
    let title: String
    /// Raw OSC title, kept separately from the legacy `title` presentation.
    let terminalTitle: String?
    /// herdr's stripped title; an explicitly empty wire value stays empty.
    let terminalTitleStripped: String?
    /// Pane presentation/manual title (`AgentInfo.title`), not a pane id.
    let paneTitle: String?
    /// Where herdr says this Agent's own session lives, when it detects one.
    /// For `omp` that is the session transcript (#325).
    let agentSession: AgentSessionInfo?
    let tokens: [String: String]
    let stateLabels: [String: String]
    /// Recency inside the Console's status buckets, and the unread-mark
    /// check. It describes the snapshot's `status` only; see
    /// `statusStateChangeSeq`.
    let stateChangeSeq: Int?
    /// The Console folds `pane.agent_status_changed` deltas in place between
    /// snapshots, through `replaceStatus(_:)`.
    private(set) var status: AgentStatus
    /// Whether `status` was replaced after the snapshot that reported
    /// `stateChangeSeq` — a delta carries no sequence, so the snapshot's
    /// no longer belongs to the status shown.
    private(set) var statusReplacedSinceSnapshot = false
    let workspaceID: String
    let tabID: String
    /// The Pane address used for per-pane subscriptions and attach.
    let paneID: String
    let cwd: String
    let revision: Int

    /// The card's primary label (#41): the server-reported name when present,
    /// otherwise the detected kind.
    var displayName: String { name ?? kind }

    /// The `kind` of a plain herdr shell tab with no Agent in it. herdr has
    /// no agent entry for such a pane; the Console projects one so a shell is
    /// just another row — to herdr it is just another tab.
    static let shellKind = "shell"

    /// A projected plain shell, not a detected Agent: it attaches through
    /// `terminal attach`, receives input through `pane.send_input`, and has
    /// no Agent-only API (`agent.prompt`, `agent.read`, `agent.rename`).
    var isShell: Bool { kind == Self.shellKind }

    /// The `kind` of an Agent herdr lists before it has detected which one
    /// it is: a launch still pending reports no `agent` for a moment.
    static let unidentifiedKind = "unknown"

    /// `stateChangeSeq` while it still describes `status`; nil once the
    /// status was replaced after the snapshot (the next snapshot supplies
    /// the matching sequence). `stateChangeSeq` itself stays for recency.
    var statusStateChangeSeq: Int? { statusReplacedSinceSnapshot ? nil : stateChangeSeq }

    /// Shows `status` in place of the snapshot's, which leaves
    /// `stateChangeSeq` describing a status this row no longer shows.
    mutating func replaceStatus(_ status: AgentStatus) {
        self.status = status
        statusReplacedSinceSnapshot = true
    }

    init(
        terminalID: String, kind: String, title: String, status: AgentStatus,
        workspaceID: String, tabID: String, paneID: String, cwd: String, revision: Int,
        name: String? = nil,
        terminalTitle: String? = nil, terminalTitleStripped: String? = nil,
        paneTitle: String? = nil, agentSession: AgentSessionInfo? = nil,
        tokens: [String: String] = [:],
        stateLabels: [String: String] = [:], stateChangeSeq: Int? = nil
    ) {
        self.terminalID = terminalID
        self.kind = kind
        self.name = name
        self.title = title
        self.terminalTitle = terminalTitle
        self.terminalTitleStripped = terminalTitleStripped
            ?? terminalTitle.map(Self.strippedSidebarTitle)
        self.paneTitle = paneTitle
        self.agentSession = agentSession
        self.tokens = tokens
        self.stateLabels = stateLabels
        self.stateChangeSeq = stateChangeSeq
        self.status = status
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
        self.cwd = cwd
        self.revision = revision
    }

    /// Maps the generated wire type onto the domain view. Wire-optional
    /// fields degrade instead of failing: herdr's API has no stability
    /// guarantee, and a missing title must not drop the Agent from the list.
    init(_ info: AgentInfo) {
        self.init(
            terminalID: info.terminalID,
            kind: info.agent ?? Self.unidentifiedKind,
            title: TerminalTitleGlyphs.strip(
                info.terminalTitleStripped ?? info.terminalTitle ?? ""),
            status: info.agentStatus,
            workspaceID: info.workspaceID,
            tabID: info.tabID,
            paneID: info.paneID,
            cwd: info.cwd ?? "",
            revision: info.revision,
            name: Self.nonEmpty(info.displayAgent) ?? Self.nonEmpty(info.name),
            terminalTitle: info.terminalTitle,
            terminalTitleStripped: info.terminalTitleStripped,
            paneTitle: info.title,
            agentSession: info.agentSession,
            tokens: info.tokens ?? [:],
            stateLabels: info.stateLabels ?? [:],
            stateChangeSeq: info.stateChangeSeq
        )
    }

    /// herdr 0.8.2 removes one activity glyph only when followed by whitespace
    /// or end-of-title. Keep legacy `title` consumers on TerminalTitleGlyphs.
    private static func strippedSidebarTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first,
            (0x2800...0x28ff).contains(first.value) || "·✢✳✶✻✽◐◓◑◒".unicodeScalars.contains(first)
        else { return trimmed }
        let rest = String(trimmed.unicodeScalars.dropFirst())
        let startsWithWhitespace = rest.unicodeScalars.first.map {
            CharacterSet.whitespacesAndNewlines.contains($0)
        } ?? false
        guard rest.isEmpty || startsWithWhitespace
        else { return trimmed }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An empty wire string carries no name; treating it as missing keeps the
    /// fallback chain from rendering a blank card label.
    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Where the herdr API socket lives on a Host. Home-relative locations are
/// resolved against the remote home directory, which the Transport resolves
/// over exec once per Host and caches.
enum HerdrSocketLocation: Sendable, Equatable {
    /// The default herdr session: `~/.config/herdr/herdr.sock`.
    case defaultSession
    /// A named session: `~/.config/herdr/sessions/<name>/herdr.sock`.
    case namedSession(String)
    /// An absolute path known in advance; needs no remote resolution.
    case absolutePath(String)

    /// The absolute socket path, given the Host's home directory.
    func path(homeDirectory: String) -> String {
        let home =
            homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        switch self {
        case .defaultSession:
            return "\(home)/.config/herdr/herdr.sock"
        case .namedSession(let name):
            return "\(home)/.config/herdr/sessions/\(name)/herdr.sock"
        case .absolutePath(let path):
            return path
        }
    }
}

/// Transport-level failures: a closed taxonomy so every screen maps errors to
/// user guidance consistently instead of string-matching.
indirect enum TransportError: Error, Sendable, Equatable {
    /// The SSH server could not be reached: connection refused, no route,
    /// or the connection died before authentication.
    case sshUnreachable(detail: String)
    /// The first hop failed: the Host may be perfectly healthy, but the
    /// Jump Host in front of it is unreachable, rejected our key, or presented
    /// an unexpected host key. Carries the underlying failure so screens can
    /// reuse the existing guidance while naming the Jump Host as the culprit.
    case jumpHostFailed(TransportError)
    /// The Jump Host accepted SSH authentication but its server or key policy
    /// prohibits the direct-tcpip channel required to reach the Host.
    case tcpForwardingUnavailable
    /// The Host rejected our credentials (key not authorized, wrong
    /// password, or the offered auth method is unavailable).
    case authenticationFailed
    /// The device's stored Ed25519 private key cannot be decoded. Reconnecting
    /// cannot repair it; the user must explicitly replace the Device Key.
    case deviceKeyCorrupt
    /// The stored RSA identity cannot be decoded. It must be replaced
    /// explicitly and the replacement public key registered with every Host.
    case rsaKeyCorrupt
    /// RSA Key authentication found no RSA-SHA2-512 signature the Host would
    /// take: it advertised only other RSA signature algorithms, or none at
    /// all. No signature was sent, so registering the key again cannot help.
    case rsaSignatureUnsupported
    /// First connect to an unknown Host and the user declined its key
    /// fingerprint; nothing was stored.
    case hostKeyRejected(presented: HostKeyFingerprint)
    /// The Host presented a key that differs from the trusted fingerprint —
    /// possibly a man-in-the-middle. Hard failure; the stored fingerprint is
    /// left untouched.
    case hostKeyMismatch(known: HostKeyFingerprint, presented: HostKeyFingerprint)
    /// The herdr API socket path does not exist on the Host: herdr is not
    /// installed there, or the socket path is wrong.
    case socketNotFound(path: String)
    /// The herdr CLI is not on the SSH session's PATH and was not found in
    /// the well-known install prefixes. The API socket can still work — that
    /// is why the Console may list Agents while Attach fails (#206).
    case herdrBinaryNotFound
    /// libssh2 cannot distinguish a listening Unix socket rejected by SSH
    /// policy from a stale socket file. The Host needs either herdr started or
    /// stream-local forwarding enabled; presenting a narrower cause would be
    /// fabricated precision.
    case streamLocalOpenFailed(path: String)
    /// No socket at the path, but herdr is on the Host's PATH and the
    /// session exists (the default one, or a folder of its own): its server
    /// stopped, as it does when the Host restarts. Waycar never starts it on
    /// its own; the user's Start Herdr TUI does (#389).
    case herdrNotRunning(path: String)
    /// No socket at the path and no folder for its named session (or custom
    /// path), with herdr on the Host's PATH: the session does not exist.
    /// herdr would create it on start, so Waycar offers no start for it.
    case herdrSessionNotFound(path: String)
    /// The server speaks a herdr protocol version this build does not support.
    case protocolVersionMismatch(server: Int, supported: Int)
    /// The remote home directory could not be resolved, so a home-relative
    /// socket location has no path.
    case homeDirectoryUnresolvable(detail: String)
    /// A directory-browsing request carried a path that cannot be passed to
    /// the Host's login shell: empty, relative, or holding NUL, quote,
    /// backslash, or control characters. Rejected before any channel opens.
    case invalidDirectoryPath(path: String)
    /// A second events channel was requested while one is live; each Host
    /// keeps exactly one dedicated events channel (ADR 0011 headroom).
    case eventsChannelAlreadyOpen
    /// A second terminal channel was requested while one is live, or a
    /// second reader tried to consume a terminal session that already has
    /// one; each Host keeps exactly one interactive terminal surface at a
    /// time, and each session serves exactly one of them.
    case terminalChannelAlreadyOpen
    /// The request exceeded its per-request deadline; the channel it held was
    /// closed.
    case timedOut
    /// The request's task was cancelled before completing; any channel it
    /// held was closed.
    case cancelled
    /// The channel produced bytes that do not decode as a herdr response.
    case malformedResponse(String)
    /// herdr answered with an error envelope: the request arrived intact and
    /// the server rejected it on its own terms.
    case apiRejected(code: String, message: String)
    /// The mosh bootstrap produced a banner, but the UDP session itself
    /// failed: it could not start or the mosh client gave up on it. A real
    /// SSH failure on the same connection surfaces under its own cause —
    /// this case marks only the mosh path, which the Console invalidates
    /// and falls back from.
    case moshSessionFailed(detail: String)
    /// The channel failed outside the known failure shapes; carries the
    /// underlying description for diagnostics.
    case channelFailed(detail: String)
    /// tmux is not installed on the Host, or not on the SSH session's PATH
    /// (ADR 0026).
    case tmuxNotInstalled
    case zellijNotInstalled
    case zellijTooOld(found: String)
    /// The Host's tmux predates 3.2, the oldest release with the
    /// control-mode features Waycar drives (format subscriptions, attach
    /// flags). `found` is the version `tmux -V` reported.
    case tmuxTooOld(found: String)
    /// herdr-core is not installed on the Host: `herdr-core connect`'s exit
    /// 127 and its "not installed here" line (ADR 0031).
    case coreNotInstalled
    /// herdr-core is installed but no core listens on its socket: the connect
    /// line's probe (a plain connect, which starts nothing) found none, and
    /// it stops before `herdr-core connect`, which would start one. Waycar
    /// never starts a core on its own; the user's Start Herdr Core does
    /// (#389).
    case coreNotRunning
    /// The Host's herdr-core is below the floor, or lacks a method Waycar
    /// needs (`hello.methods`). `detail` says which.
    case coreNeedsUpdate(detail: String)
    /// herdr-core refused Waycar's protocol generation: this build is the
    /// one that needs updating.
    case coreNeedsWaycarUpdate
    /// `herdr-core connect` failed before it answered, with its own error
    /// line (`message` and `hint`).
    case coreRefused(message: String, hint: String)

    /// Whether reconnecting without user intervention can plausibly recover.
    /// Configuration, trust, authentication, and protocol failures instead
    /// stop so the UI can explain the required action.
    /// `.streamLocalOpenFailed` is configuration-class: neither of the two
    /// causes it cannot tell apart — a stopped herdr, disabled stream-local
    /// forwarding — resolves without the user acting on the Host (ADR 0011).
    var isRetryable: Bool {
        switch self {
        // A rejection is retryable because herdr's error codes are open-ended
        // and most of them describe a target that moved, not a broken setup.
        case .sshUnreachable, .timedOut, .cancelled, .channelFailed,
            .apiRejected, .moshSessionFailed:
            true
        case .authenticationFailed, .tcpForwardingUnavailable,
            .deviceKeyCorrupt, .rsaKeyCorrupt, .rsaSignatureUnsupported,
            .hostKeyRejected, .hostKeyMismatch,
            .socketNotFound, .herdrBinaryNotFound, .protocolVersionMismatch,
            .tmuxNotInstalled, .tmuxTooOld, .zellijNotInstalled, .zellijTooOld,
            .coreNotInstalled, .coreNotRunning, .coreNeedsUpdate, .coreNeedsWaycarUpdate,
            .coreRefused,
            .streamLocalOpenFailed, .herdrNotRunning, .herdrSessionNotFound,
            .homeDirectoryUnresolvable, .invalidDirectoryPath,
            .eventsChannelAlreadyOpen,
            .terminalChannelAlreadyOpen, .malformedResponse:
            false
        // A Jump Host is retryable exactly when the failure behind it is: a
        // rebooting VPS should reconnect on its own, a rejected key should not.
        case .jumpHostFailed(let underlying):
            underlying.isRetryable
        }
    }
}

/// An error returned by the herdr server inside a response envelope.
struct HerdrAPIError: Error, Sendable, Equatable {
    /// Normalized to a string; the wire schema promises `{"code","message"}`
    /// without pinning the code's JSON type.
    let code: String
    let message: String
}

/// A prompt the Transport held back, nothing sent, because the Agent's TUI
/// does not take input yet although herdr would accept the prompt: on herdr
/// 0.9.1 an opencode launch is promptable long before its input box draws,
/// and typed input is dropped until then (`WaycarSSHTransport.promptAgent`).
/// The Transport stops holding prompts at `opensAt`, so a sender retrying
/// until just past it gets one attempt the gate no longer holds.
struct AgentInputNotReadyError: Error, Sendable, Equatable {
    /// The launch's kind, e.g. `opencode`.
    let kind: String
    let target: String
    let opensAt: ContinuousClock.Instant

    /// What a sender shows once it stops retrying.
    var message: String {
        let name = SupportedAgentKind(rawValue: kind)?.displayName ?? kind
        return "\(name) is still starting. Try again in a moment."
    }
}

/// A request that never left this device: it failed before its first byte
/// was written to the Host (no connection, no installed Transport, a channel
/// that never opened, a launch check that failed first). Unlike a timeout
/// after the write, it cannot have reached herdr or tmux, so sending it again
/// cannot deliver it twice: the Composer queues such a prompt (CONTEXT.md
/// **Queued Message**). `cause` is the failure to present.
struct RequestNotSentError: Error, Sendable {
    let cause: any Error

    /// `error` marked unsent when it is a link-level failure raised before
    /// the request was written. A herdr answer, a malformed reply and a
    /// cancellation pass through unchanged: they are not link failures.
    static func wrapping(_ error: any Error) -> any Error {
        guard let transport = error as? TransportError else { return error }
        switch transport {
        case .apiRejected, .malformedResponse, .cancelled:
            return error
        default:
            return RequestNotSentError(cause: transport)
        }
    }

    /// The failure behind `error`: its cause when it is unsent.
    static func unwrapped(_ error: any Error) -> any Error {
        (error as? RequestNotSentError)?.cause ?? error
    }
}

/// Set once a request reaches the point where its bytes may have gone out:
/// the classification `RequestNotSentError` rests on.
final class RequestWriteMark: Sendable {
    private let marked = Mutex(false)

    func mark() {
        marked.withLock { $0 = true }
    }

    var isMarked: Bool {
        marked.withLock { $0 }
    }
}

extension PaneSendInputParams {
    /// True when this input submits what it types — Enter in `keys`, or a
    /// line break in `text`, which the PTY treats the same way. A shell runs
    /// a submitted command on receipt, so a submitting send must never be
    /// replayed after a link failure that cannot say whether herdr got it.
    var submitsInput: Bool {
        if keys?.contains("enter") == true { return true }
        return text?.contains(where: \.isNewline) == true
    }
}
