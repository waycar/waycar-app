import Foundation
import Observation
import Synchronization
import SwiftUI
import os

/// The new-agent flow's form logic (#12, User Story 8): pick a Host, pick a
/// launch target (an existing Workspace, or a new one at a remote directory),
/// detect and select an installed Agent, parse its native arguments, and
/// dispatch it via the Transport launch flow. The started pane surfaces in
/// the Console through the store's normal snapshot/delta machinery; on
/// success the store reports the started row's Console identity — an
/// Agent's, or a plain shell's, which is just another row — so the owning
/// screen can open it right away.
///
/// Opened by the New Chat quick action, it is in quick chat: Chat Mode on,
/// preset from the New Chat defaults, and submitted once on its own when
/// they resolve against the Host's live workspaces (`runQuickChat()`).
///
/// Opened with an `AgentLaunchPreset` (Help's Ask an Agent, the Keychain
/// Fix), it is prefilled but never starts on its own: the preset's Host and
/// name, every other field at its usual default, every detected Agent kind
/// but no Default Shell, and a Host the user can't change when the preset
/// locks it. Start hands the Agent the preset's first message as a Launch
/// Prompt File its launch line points at, or, for a kind with no
/// first-message flag, as a Queued Message its Composer sends once the
/// Agent takes input; never in Chat Mode — the user should see every
/// command the Agent runs — and leaves Last Used alone.
///
/// The Agent picker shows the Host's Agent kinds as last detected
/// (`cachedAgentKinds`) while it asks the Host again, so a Host out of reach
/// still offers them. Start builds a `LaunchDraft` from the form and
/// launches it (`launch(_:)`); with no verified connection to the Host it
/// keeps the draft on the device as a Queued Launch instead, sending
/// nothing, and the Console replays it through the same `launch(_:)` once
/// the Host is back (CONTEXT.md **Queued Launch**). A first message typed
/// here, with its images and files, reaches the started Agent as a Queued
/// Message.
///
/// Kept off the SSH types (standing repo rule): it talks to injected closures
/// over the `ConsoleStore`, so it is testable against a scripted transport.

@MainActor
@Observable
final class StartAgentStore {
    typealias State = LaunchSubmissionMachine.Presentation

    /// How `launch(_:)` ended, for a Queued Launch's replay.
    enum LaunchOutcome: Equatable {
        /// `keepsAttachmentCopies` when the first message typed in the
        /// sheet could not be kept as a Queued Message: its attachment
        /// copies stay for the Composer's Retry or Edit Draft.
        case started(ConsoleAgent.ID, keepsAttachmentCopies: Bool)
        /// Nothing reached the Host: its connection or verified rows were
        /// gone before the launch was dispatched. The message is
        /// user-facing.
        case notSent(String)
        /// The link failed while the launch was being dispatched, so the
        /// Host may have started it.
        case uncertain
        /// The launch may have reached the Host; the message is user-facing.
        case failed(String)
    }

    /// The Console's side of Queued Launches: where a launch's first-message
    /// attachments are prepared, and how a Start with no verified connection
    /// is kept (`ConsoleStore.enqueueLaunch`).
    struct LaunchQueue {
        let store: QueuedLaunchStore
        /// Saves the launch and lists it; throws when it is not on disk.
        let enqueue: @MainActor (QueuedLaunch) throws -> Void
    }

    enum AgentDiscoveryState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Context inherited when the flow opens from an agent's own screen: the
    /// launch reuses that agent's Host, workspace, and working directory
    /// instead of asking for all three again. The new agent lands in a fresh
    /// tab beside the one it was started from, in the same directory.
    struct LaunchOrigin: Equatable, Sendable {
        let hostID: Host.ID
        let workspaceID: String
        let cwd: String
    }

    /// Where a Console-originated launch should create the Agent (#230).
    /// Origin launches skip this choice: they inherit the origin Workspace.
    enum LaunchTarget: Equatable, Hashable {
        case existingWorkspace
        case newWorkspace
    }

    /// The Transport variant `submit()` dispatches. Invalid combinations
    /// (a Worktree of a Workspace that does not exist yet) cannot be
    /// represented.
    enum LaunchDestination: Codable, Equatable, Sendable {
        case existingWorkspace
        case newWorktree(WorktreeSpec)
        case newWorkspace(NewWorkspaceSpec)
    }

    /// What the "Agent" picker selects: a plain shell or a detected Agent
    /// kind.
    enum LaunchSelection: Codable, Hashable, Sendable {
        case shell
        case agent(SupportedAgentKind)
    }

    /// What `submit()` assembled from the form: one Transport variant and
    /// the launch it targets. A plain shell dispatches the shell variants
    /// (no `agent.start` follows); an Agent dispatches the agent ones.
    /// `backend` is the herdr | tmux choice for a new Workspace on a Host
    /// with both; nil lets the Console route by the Workspace's owner.
    struct Dispatch: Codable, Equatable, Sendable {
        let destination: LaunchDestination
        let launch: LaunchSelection
        var backend: HostBackend?
    }

    /// One step of the launch banner: a step the Transport reported, when it
    /// began, and how it ended. At most one row is `.running`, always the last.
    struct LaunchStepProgress: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case running
            case done
            case failed
        }

        let step: LaunchStep
        let startedAt: Date
        var status: Status
        /// The user-facing line for this step.
        let title: String
    }

    enum ArgumentError: Error, Equatable {
        case danglingEscape
        case unclosedSingleQuote
        case unclosedDoubleQuote
        case controlCharacter

        var message: String {
            switch self {
            case .danglingEscape:
                "Arguments end with an unfinished escape."
            case .unclosedSingleQuote:
                "Arguments contain an unclosed single quote."
            case .unclosedDoubleQuote:
                "Arguments contain an unclosed double quote."
            case .controlCharacter:
                "Arguments contain an unsupported control character."
            }
        }
    }

    /// The Hosts the user can dispatch to — the Host picker's options.
    let hosts: [Host]

    /// Non-nil when the flow was opened from an agent rather than the
    /// Console: Host, workspace, and working directory are already decided,
    /// so the form collapses to the agent fields.
    let origin: LaunchOrigin?

    var selectedHostID: Host.ID? {
        didSet {
            // A workspace belongs to one Host; switching Hosts drops a stale
            // pick so it can never target the wrong session.
            if selectedHostID != oldValue {
                noteEdit()
                programmatically {
                    pickedWorkspaceID = nil
                    pickedBackend = nil
                    _ = discovery.handle(.reset)
                    selectedAgentKind = nil
                    selectedLaunchIsShell = false
                    launchTarget = .existingWorkspace
                    newWorkspaceDirectory = ""
                    newWorkspaceLabel = ""
                    startsInNewWorktree = false
                    worktreeBranch = ""
                    worktreeBase = ""
                }
                foundBackend = nil
                // The preset's untouched name follows the Host it now
                // targets, so it stays unique there.
                refreshSuggestedName()
                // Another Host's failure must not stay in the launch banner.
                _ = submission.handle(.resetFailure)
            }
        }
    }

    /// The existing Workspace the agent starts in: what the user picked, else
    /// the one they last started an agent in on this Host, else the Host's
    /// first.
    ///
    /// Nil while the Host reports no Workspaces at all. Existing-Workspace
    /// and origin launches cannot submit until a concrete Workspace is
    /// available; New Workspace does not use this pick.
    var selectedWorkspaceID: String? {
        get {
            // The origin agent is living proof its workspace exists, so it
            // wins outright rather than being filtered against a snapshot
            // that may not have landed yet.
            if let origin { return origin.workspaceID }
            let available = workspaces
            if let pickedWorkspaceID,
                available.contains(where: { $0.id == pickedWorkspaceID })
            {
                return pickedWorkspaceID
            }
            if let selectedHostID, let remembered = recents.workspaceID(for: selectedHostID),
                available.contains(where: { $0.id == remembered })
            {
                return remembered
            }
            return available.first?.id
        }
        set { pickedWorkspaceID = newValue }
    }

    /// The user's explicit pick; nil means "follow the default above". Kept
    /// separate so a snapshot arriving after the sheet opens still gets to
    /// supply the default.
    private var pickedWorkspaceID: String? {
        didSet { noteEdit(pickedWorkspaceID != oldValue, destination: true) }
    }
    /// This sheet's runtime pick; nil follows recents, then the internal default.
    private var pickedBackend: HostBackend? {
        didSet { noteEdit(pickedBackend != oldValue, destination: true) }
    }
    /// The unique live-agent name required by herdr protocol 17. Optional in
    /// the form: empty falls back to a kind-derived name (`claude`,
    /// `claude-2`, …), mirroring how the herdr TUI labels unnamed agents.
    /// Agent launches rewrite input toward herdr's name rule as it is typed;
    /// a shell launch's name is a free-form tab label and is left alone.
    var name: String = "" {
        didSet {
            noteEdit(name != oldValue)
            normalizeNameForAgentLaunch()
        }
    }
    /// The canonical kind selected from the Host availability probe.
    var selectedAgentKind: SupportedAgentKind? {
        didSet { noteEdit(selectedAgentKind != oldValue) }
    }
    /// Whether the "Agent" picker currently targets a plain shell rather
    /// than a detected Agent kind. Shell needs no detection, so the picker
    /// offers it even while the probe is loading, failed, or empty.
    /// Deliberately not a name-normalizing hook: a Host switch clears it
    /// transiently before discovery restores a remembered shell, and a tab
    /// label must survive that. The places that actually select an Agent
    /// (`launchSelection`, `discoverAgents()`) bring the name under the rule.
    var selectedLaunchIsShell = false {
        didSet {
            if programmaticEditDepth == 0, selectedLaunchIsShell != oldValue {
                // A user pick of Shell or an Agent replaces the store's
                // empty-detection fallback with an explicit choice.
                shellAutoSelectedForEmptyDetection = false
            }
            noteEdit(selectedLaunchIsShell != oldValue)
        }
    }

    /// Whether Default Shell is selected only because detection found no
    /// Agents (the store's fallback, not the user's pick). A later
    /// detection that finds Agents replaces it, and a failed one still
    /// shows its error in the sheet.
    private(set) var shellAutoSelectedForEmptyDetection = false
    /// Optional native arguments, parsed into argv without invoking a shell.
    /// The editor disables smart punctuation at the UIKit input-trait layer;
    /// parsing still normalizes any smart characters supplied by paste or a
    /// third-party keyboard without mutating the live editing buffer.
    var arguments: String = "" {
        didSet { noteEdit(arguments != oldValue) }
    }
    /// Existing Workspace vs New Workspace on the Console-originated form.
    /// Switching target drops an incompatible Worktree request so it cannot
    /// ride along with a launch that has no source Workspace.
    var launchTarget: LaunchTarget = .existingWorkspace {
        didSet {
            if launchTarget != oldValue {
                noteEdit(destination: true)
                startsInNewWorktree = false
                worktreeBranch = ""
                worktreeBase = ""
            }
        }
    }
    /// Remote directory for a New Workspace launch. Optional: empty resolves
    /// to the Host's home directory at submit. Trimmed before use.
    var newWorkspaceDirectory: String = "" {
        didSet { noteEdit(newWorkspaceDirectory != oldValue, destination: true) }
    }
    /// Selecting a directory switches the draft destination without starting
    /// an Agent. Dismissing the browser never changes the current selection.
    func applyBrowsedDirectory(_ path: String) {
        guard offersNewWorkspace, RemoteShellPath.isQuotableAbsolute(path) else { return }
        newWorkspaceDirectory = path
        selectNewWorkspace()
    }

    /// Switches the draft destination to a New Workspace launch. Allowed
    /// without a browsed directory: a name-only workspace resolves to the
    /// Host's home directory at submit.
    func selectNewWorkspace() {
        guard offersNewWorkspace else { return }
        launchTarget = .newWorkspace
    }

    func selectExistingWorkspace(_ id: String) {
        guard origin == nil, workspaces.contains(where: { $0.id == id }) else { return }
        selectedWorkspaceID = id
        launchTarget = .existingWorkspace
        // herdr-core takes no Default Shell launch: moving the destination
        // onto a core Workspace drops a stale shell pick (review P2).
        if selectedLaunchIsShell,
            workspaces.first(where: { $0.id == id })?.backend == .core
        { selectedLaunchIsShell = false }
    }

    /// The backends the selected Host runs, herdr first; empty with no Host.
    var hostBackends: [HostBackend] {
        guard let selectedHostID else { return [] }
        let present = backendsProvider(selectedHostID)
        return HostBackend.allCases.filter(present.contains)
    }

    /// A server chat runtime (Codex, OpenCode) is offered when installed, even while
    /// its server is stopped.
    var launchableBackends: [HostBackend] {
        var present = hostBackends
        // Presence uses a placeholder herdr projection to report a missing
        // terminal runtime. That placeholder is not an installed choice.
        if let selectedHostID, let presence = backendPresence(selectedHostID) {
            present.removeAll { backend in
                switch backend {
                case .herdr: !presence.herdr
                case .core: !presence.coreFound
                case .tmux: !presence.tmuxUsable
                case .zellij: presence.zellij?.meetsFloor != true
                case .ultimate, .codex, .opencode: false
                }
            }
        }
        let servers = offeredServerChats
        for server in servers where !present.contains(server.backend) { present.append(server.backend) }
        return HostBackend.allCases.filter {
            present.contains($0) && $0.capabilities.startsAgents
                && ($0.serverChat.map { servers.contains($0) } ?? true)
        }
    }

    /// The server chat runtimes the selected Host shows and has installed.
    private var offeredServerChats: [ServerChatBackend] {
        guard let selectedHostID else { return [] }
        return ServerChatBackend.allCases.filter {
            showsServerChat(selectedHostID, $0) && serverRuntimeState(selectedHostID, $0).isAvailable
        }
    }

    /// The server chat runtime the form launches a session on; nil for a
    /// terminal launch.
    var launchingServerChat: ServerChatBackend? { probableTargetBackend?.serverChat }
    var launchesServerChat: Bool { launchingServerChat != nil }
    var selectedServerRuntimeState: ServerRuntimeState {
        guard let selectedHostID, let launchingServerChat else { return .notInstalled }
        return serverRuntimeState(selectedHostID, launchingServerChat)
    }
    func startServerRuntime() async {
        guard let selectedHostID, let launchingServerChat else { return }
        await startServer(selectedHostID, launchingServerChat)
    }

    /// Whether the Host lists a herdr runtime's Workspaces and tmux sessions
    /// together: the only case where the form marks tmux Workspaces and
    /// offers the herdr | tmux switch (herdr-core's name when core fills the
    /// slot). Hosts with one backend get neither.
    var listsBothBackends: Bool {
        let backends = hostBackends
        return backends.contains(where: \.fillsHerdrSlot) && backends.contains(.tmux)
    }

    /// The backend a launch from the form as it stands would land on; nil
    /// while no Host is picked or the Workspace is not chosen yet.
    var formTargetBackend: HostBackend? {
        guard let selectedHostID else { return nil }
        if origin != nil || launchTarget == .existingWorkspace {
            // Origin launches can inherit a native thread's Workspace,
            // which is deliberately absent from the terminal folder picker.
            return workspacesProvider(selectedHostID)
                .first(where: { $0.id == selectedWorkspaceID })?.backend
        }
        return launchBackend ?? launchableBackends.first ?? defaultBackendProvider(selectedHostID)
    }

    /// Whether New Agent offers its single runtime picker: a launch that
    /// creates a Workspace on a Host with multiple Backends. An
    /// existing Workspace already decides its backend, and an origin launch
    /// inherits its Agent's.
    var offersBackendChoice: Bool {
        origin == nil && launchTarget == .newWorkspace && launchableBackends.count >= 2
    }

    /// The new Workspace's runtime: this sheet's pick, the last pick on this
    /// Host, then the internal default. Existing Workspaces keep their owner.
    var newWorkspaceBackend: HostBackend {
        get {
            if let pickedBackend, launchableBackends.contains(pickedBackend) { return pickedBackend }
            if let selectedHostID, let remembered = recents.backend(for: selectedHostID),
                launchableBackends.contains(remembered) { return remembered }
            guard let selectedHostID else { return .herdr }
            let preferred = defaultBackendProvider(selectedHostID)
            return launchableBackends.contains(preferred) ? preferred : launchableBackends.first ?? preferred
        }
        set {
            guard offersBackendChoice, launchableBackends.contains(newValue) else { return }
            pickedBackend = newValue
            if let selectedHostID { recents.rememberBackend(newValue, for: selectedHostID) }
            pickedWorkspaceID = nil
            startsInNewWorktree = false
            if newValue == .core || newValue.isServerChat {
                selectedLaunchIsShell = false
                launchTarget = .newWorkspace
            }
        }
    }

    /// Whether `workspace` is a tmux session the picker marks `tmux`.
    func marksAsTmux(_ workspace: ConsoleWorkspace) -> Bool {
        listsBothBackends && workspace.backend == .tmux
    }

    /// The backend `submit()` passes: the switch's value while it shows,
    /// otherwise nil so the Console routes by the Workspace's owner (or the
    /// Host's only backend).
    private var launchBackend: HostBackend? {
        offersBackendChoice ? newWorkspaceBackend : nil
    }

    /// The backend `draft` lands on, for its Launch Prompt Files and failure
    /// copy.
    private func targetBackend(for draft: LaunchDraft) -> HostBackend {
        let hostID = draft.hostID
        if let backend = draft.dispatch.backend { return backend }
        if case .newWorkspace = draft.dispatch.destination { return defaultBackendProvider(hostID) }
        return workspacesProvider(hostID)
            .first(where: { $0.id == draft.workspaceID && $0.backend.capabilities.startsAgents })?
            .backend
            ?? defaultBackendProvider(hostID)
    }

    /// Optional label for a New Workspace launch. Empty or whitespace
    /// becomes nil so herdr applies its default.
    var newWorkspaceLabel: String = "" {
        didSet { noteEdit(newWorkspaceLabel != oldValue, destination: true) }
    }
    /// Whether the launch targets a fresh git worktree of the selected
    /// workspace's repository instead of the workspace itself (#97).
    var startsInNewWorktree = false {
        didSet { noteEdit(startsInNewWorktree != oldValue) }
    }
    /// Optional branch for the new worktree; empty sends a branch the sheet
    /// mints in herdr's generated `worktree/<words>-<hex>` format, which
    /// never shows here. Validated client-side because herdr folds
    /// every git failure into one raw-stderr error code. Rewritten toward a
    /// valid branch as it is typed, and mirrored into `name` until the user
    /// gives the name a value of its own.
    var worktreeBranch: String = "" {
        didSet {
            noteEdit(worktreeBranch != oldValue)
            let normalized = GitBranchName.normalizingInput(worktreeBranch)
            if normalized != worktreeBranch { worktreeBranch = normalized }
            mirrorWorktreeBranchIntoName()
        }
    }
    /// The `name` value last written by the branch mirror. While `name`
    /// still equals it (or is empty) the user has not diverged, so branch
    /// edits keep flowing into the name.
    @ObservationIgnored private var nameMirroredFromBranch = ""
    /// Optional base commit-ish for the new branch; empty branches off the
    /// source checkout's HEAD. Ignored while `startsFromLatestMain` is on,
    /// but kept so turning it off brings the typed value back. Not
    /// validated: any rev syntax is legal here, so the server's message
    /// passthrough is the honest feedback.
    var worktreeBase: String = "" {
        didSet { noteEdit(worktreeBase != oldValue) }
    }
    /// Whether a New Worktree fetches origin first and starts from its
    /// default branch. A device-wide preference, so Host and launch-target
    /// switches leave it alone; remembered only by a successful worktree
    /// launch.
    var startsFromLatestMain: Bool {
        didSet { noteEdit(startsFromLatestMain != oldValue) }
    }
    /// The switch's title, shared with the failure copy that names it.
    static let latestMainToggleTitle = "Start From Latest Main"
    /// Whether an Agent launch starts in Chat Mode: the harness gets the
    /// Chat Prompt, and a Chat Marker is recorded for the started Agent.
    /// Applies only while `showsChatModeToggle`; remembered by a successful
    /// launch of a Chat-Mode kind outside quick chat, and always on in it.
    /// Always off for a preset launch.
    var chatMode: Bool {
        didSet { noteEdit(chatMode != oldValue) }
    }

    /// Whether the form offers Chat Mode: a detected Agent (not the shell
    /// choice) whose kind the transcript reader understands, outside a
    /// preset launch, which the user watches in the terminal.
    var showsChatModeToggle: Bool {
        preset == nil && (launchesServerChat
            || (!selectedLaunchIsShell && selectedAgentKind?.supportsChatMode == true))
    }

    private var submission = LaunchSubmissionMachine()
    var state: State { submission.presentation }
    /// The Agent kind the successful launch started; nil for a plain shell
    /// and for a launch that joined an Agent already running in an adopted
    /// worktree, which is not a new launch. Set with `.started`, for the
    /// sheet's `agent_launched` count.
    var launchedAgentKind: SupportedAgentKind? { submission.report.launchedKind }
    /// Whether the launch that reached `.started` was a Chat Mode launch:
    /// a new Agent started with the Chat Mode arguments, so the owner can
    /// raise its Chat Prompt keyboard. False for a plain shell, Chat Mode
    /// off, and a launch that joined an Agent already running.
    var launchedChat: Bool { submission.report.launchedChat }
    /// Whether the sheet was opened by the New Chat quick action: Chat Mode
    /// on, preset from the New Chat defaults, and started on its own once
    /// they resolve (`runQuickChat()`).
    private(set) var isQuickChat: Bool
    /// The steps of the current or last failed launch, in the order they
    /// began. Cleared by every submit, so a finished launch never shows in
    /// the next one.
    var launchSteps: [LaunchStepProgress] { submission.report.steps }
    /// Whether the current or last Start keeps the launch on the device as
    /// a Queued Launch rather than launching it now. Set as Start decides,
    /// so its banner names what Start did, not what the Host's connection
    /// reads by the time it shows.
    var startKeepsLaunch: Bool { submission.report.keepsLaunch }
    /// The branch minted for an empty Branch field and the inputs it was
    /// minted for, kept for a Retry with the same inputs. Never written to
    /// `worktreeBranch`, so it never mirrors into `name`.
    @ObservationIgnored private var retryIdentity = LaunchRetryIdentityMachine()
    /// Mints a branch in herdr's generated format; injectable so tests can
    /// pin the names.
    @ObservationIgnored private let mintWorktreeBranch: () -> String
    private var discovery = AgentDiscoveryMachine()
    var agentDiscoveryState: AgentDiscoveryState {
        switch discovery.state {
        case .idle, .detached: .idle
        case .detecting: .loading
        case .refreshing, .live, .cached: .loaded
        case .failed(let message): .failed(message)
        }
    }
    var availableAgentKinds: [SupportedAgentKind] { discovery.kinds }
    /// Whether `availableAgentKinds` are the ones the Host's last detection
    /// found (`cachedAgentKinds`), because the Host has not answered this
    /// time yet, or could not. Start works with them all the same.
    var agentKindsAreCached: Bool { discovery.cachedKinds != nil }
    /// When the cached kinds were detected; nil while the kinds are live.
    var agentKindsSeenAt: Date? { discovery.cachedKinds?.verifiedAt }
    /// What the launched Agent is sent first, as a Queued Message once it
    /// takes input. Empty sends nothing; a shell gets none.
    var firstMessageText: String = "" {
        didSet { noteEdit(firstMessageText != oldValue) }
    }
    /// The first message's images and files. Never bound to an Attach: its
    /// items stay queued with their sources until Start prepares them. The
    /// sheet only draws it (`ComposerTrayView`); edits go through
    /// `addFirstMessageAttachments(_:)` and `removeFirstMessageAttachment(_:)`.
    let firstMessageTray = ComposerTray()

    private let workspacesProvider: (Host.ID) -> [ConsoleWorkspace]
    /// The agent names already live on a Host, so a generated default never
    /// collides with them. Names only: herdr's duplicate check ignores
    /// detected kind labels, but the Console reports those as names too, and
    /// skipping them merely bumps the suffix.
    private let existingAgentNames: (Host.ID) -> Set<String>
    /// herdr identifies a retried launch by its tab label, so a new label
    /// must also avoid tabs whose Agent has no managed name, and shell tabs.
    private let existingTabLabels: (Host.ID) -> Set<String>
    private let discoverAgentKinds: (Host.ID) async throws -> [SupportedAgentKind]
    /// The Host's Agent kinds as last detected (`ConsoleStore.cachedAgentKinds`);
    /// nil when none were kept.
    private let cachedAgentKinds: (Host.ID) -> CachedAgentKinds?
    /// Resolves the Host's home directory for a name-only New Workspace
    /// launch; fetched at submit so an unreachable Host never blocks editing.
    private let remoteHome: (Host.ID) async throws -> String
    /// Dispatches the assembled request through the matching Transport
    /// launch variant, on the given backend (nil: the Console routes by the
    /// Workspace's owner).
    typealias StartAgent =
        (AgentLaunchRequest, LaunchDestination, Host.ID, HostBackend?) async throws -> Agent
    /// Dispatches a plain-shell launch through the matching Transport shell
    /// variant. Separate from `start` so the shell path never needs the
    /// Agent-only closure's signature.
    typealias StartShell =
        (ShellLaunchRequest, LaunchDestination, Host.ID, HostBackend?) async throws
        -> ShellLaunchResult
    private let start: StartAgent
    private let startShell: StartShell
    /// The backends each Host runs, herdr first (`ConsoleStore.presentBackends`).
    private let backendsProvider: (Host.ID) -> [HostBackend]
    /// Each Host's New Agent default (`ConsoleStore.defaultNewAgentBackend`).
    private let defaultBackendProvider: (Host.ID) -> HostBackend
    private let showsServerChat: (Host.ID, ServerChatBackend) -> Bool
    private let serverRuntimeState: (Host.ID, ServerChatBackend) -> ServerRuntimeState
    private let startServer: (Host.ID, ServerChatBackend) async -> Void
    /// Creates an OpenCode 2 session alone, with no linked pane
    /// (`ConsoleStore.startAgent(_:on:backend:)` on `.opencode`): the session
    /// an opencode terminal launch then opens. Nil creates none.
    private let createServerSession: ((AgentLaunchRequest, Host.ID) async throws -> Agent)?
    /// Suspends (bounded) until the started row is visible in the Console —
    /// an Agent's or a plain shell's alike. The row the owner navigates to
    /// exists only after the post-start resync lands; waiting here keeps the
    /// opened detail from flashing its missing-Agent placeholder over a
    /// launch that just succeeded.
    private let awaitAgentVisible: (ConsoleAgent.ID) async -> Void
    /// Replay holds the pane's Composer before marker writes or visibility
    /// waits can let a new Send overtake its pending messages.
    @ObservationIgnored private let onAgentStarted: (@MainActor (ConsoleAgent.ID, Bool) -> Void)?
    /// Counts a successful Agent launch as real use for the Review Prompt;
    /// nil counts nothing.
    @ObservationIgnored private let reviewPrompt: ReviewPromptStore?
    @ObservationIgnored private let recents: RecentWorkspaceStore
    @ObservationIgnored private let selections: RecentSelectionsStore
    /// Records a Chat Marker for a Chat Mode launch, before the sheet
    /// reports it started.
    @ObservationIgnored private let recordChatMode: @MainActor (ChatModeMarker, Host.ID) async -> Void
    /// What a Chat Mode launch of a kind asks for (Chat Prompt, model,
    /// Quick thinking), read at submit for the kind dispatched.
    @ObservationIgnored private let chatOptions: (SupportedAgentKind) -> ChatModeLaunchOptions
    /// Writes a launch's prompts to its Host as Launch Prompt Files
    /// (`ConsoleStore.launchPromptHost(for:)`); nil while the Host has no
    /// connection, which fails a launch that carries a prompt.
    @ObservationIgnored private let launchPromptHost: (Host.ID) -> LaunchPromptHost?
    /// Hands a launch's first message to the started Agent's Composer as a
    /// Queued Message (`ConsoleStore.queueLaunchMessage`), for a kind that
    /// takes none on its launch line.
    @ObservationIgnored private let queueLaunchMessage:
        @MainActor (String, QueuedMessage.AgentIdentity, Host.ID) -> Void
    /// Hands the first message typed in the sheet, with its attachments
    /// read from the given directory, to the started Agent's Composer as a
    /// Queued Message (`ConsoleStore.queueLaunchMessage`), whatever the kind.
    /// Returns whether it is kept on the device.
    @ObservationIgnored private let queueFirstMessage:
        @MainActor (LaunchDraft.FirstMessage, URL?, QueuedMessage.AgentIdentity, Host.ID) -> Bool
    /// Where Queued Launches go; nil launches at once even with no verified
    /// connection, and prepares no first-message attachments.
    @ObservationIgnored private let launchQueue: LaunchQueue?
    /// In-flight guard flipped synchronously before the first await, so a
    /// double-tap cannot dispatch the same command twice through the window
    /// before `state == .starting` disables the button.
    private var preparation = LaunchPreparationMachine()
    private var isStarting: Bool { preparation.isPreparing }
    /// The New Chat defaults quick chat presets and auto-starts from; nil
    /// for the plain New Agent sheet.
    @ObservationIgnored private let quickChat: NewChatPreferences?
    /// What prefills the sheet for a launch that hands the Agent a document
    /// (Help's Ask an Agent, the Keychain Fix); nil for every other launch.
    /// Its first message goes to a Launch Prompt File that the launch points
    /// at (`LaunchPromptStager`), or, for a kind with no first-message flag,
    /// to the Agent's Composer queue. Never combined with `quickChat`.
    let preset: AgentLaunchPreset?
    /// The Host a preset pins the sheet to; nil unless the preset locks a
    /// Host this sheet knows.
    private let lockedHostID: Host.ID?
    /// Whether the Host's rows come from a snapshot taken on its current,
    /// connected session, so its workspace list is current. Quick chat
    /// plans against that list only.
    @ObservationIgnored private let hasLiveSnapshot: (Host.ID) -> Bool
    /// The Host's last detected backends (`ConsoleStore.backendPresence`);
    /// nil before any detection. Read live, so the panel's install and
    /// Check Again reach the form the moment the Console records them.
    @ObservationIgnored private let backendPresence: (Host.ID) -> HostBackendPresence?
    /// Whether quick chat may still start on its own. Cleared by any edit
    /// the user makes, by any submit, and when the window passes or the
    /// defaults do not resolve; never set again, so it starts at most once.
    @ObservationIgnored private var autoStartPending = false
    /// The preset's suggested name under the agent-name rule; nil without
    /// a preset.
    @ObservationIgnored private let presetSuggestedName: String?
    /// The suggestion last put in the name field; while the field still
    /// holds it, the user hasn't touched it and it is kept unique.
    @ObservationIgnored private var shownSuggestion: String?
    /// Whether the user edited the destination (Workspace, target, New
    /// Workspace directory or label). Unlike `autoStartPending`, the window
    /// passing or an unrelated edit leaves it alone, so quick chat still
    /// preselects New Chat's Workspace when detection loads late.
    @ObservationIgnored private var userChoseDestination = false
    /// Nonzero while the store itself rewrites form fields, so those writes
    /// are not taken for the user's edits.
    @ObservationIgnored private var programmaticEditDepth = 0
    /// How long quick chat waits for discovery and a live snapshot.
    private let quickChatWindow: Duration
    /// How often quick chat checks again while it waits.
    private let quickChatPollInterval: Duration
    /// How long `backendFound()` waits before detecting Agents again after a
    /// detection that failed: the Host's connection is still restarting.
    private let foundDiscoveryRetryDelay: Duration

    init(
        hosts: [Host],
        workspaces: @escaping (Host.ID) -> [ConsoleWorkspace],
        existingAgentNames: @escaping (Host.ID) -> Set<String>,
        existingTabLabels: @escaping (Host.ID) -> Set<String> = { _ in [] },
        discoverAgentKinds: @escaping (Host.ID) async throws -> [SupportedAgentKind],
        cachedAgentKinds: @escaping (Host.ID) -> CachedAgentKinds? = { _ in nil },
        remoteHome: @escaping (Host.ID) async throws -> String,
        start: @escaping StartAgent,
        startShell: StartShell? = nil,
        backends: @escaping (Host.ID) -> [HostBackend] = { _ in [.herdr] },
        defaultBackend: @escaping (Host.ID) -> HostBackend = { _ in .herdr },
        showsServerChat: @escaping (Host.ID, ServerChatBackend) -> Bool = { _, _ in true },
        serverRuntimeState: @escaping (Host.ID, ServerChatBackend) -> ServerRuntimeState = { _, _ in
            .notInstalled
        },
        startServerRuntime: @escaping (Host.ID, ServerChatBackend) async -> Void = { _, _ in },
        createServerSession: ((AgentLaunchRequest, Host.ID) async throws -> Agent)? = nil,
        awaitAgentVisible: @escaping (ConsoleAgent.ID) async -> Void,
        onAgentStarted: (@MainActor (ConsoleAgent.ID, Bool) -> Void)? = nil,
        origin: LaunchOrigin? = nil,
        reviewPrompt: ReviewPromptStore? = nil,
        recents: RecentWorkspaceStore = RecentWorkspaceStore(),
        selections: RecentSelectionsStore = RecentSelectionsStore(),
        mintWorktreeBranch: @escaping () -> String = { GeneratedWorktreeBranch.mint() },
        recordChatMode: @escaping @MainActor (ChatModeMarker, Host.ID) async -> Void = { _, _ in },
        chatOptions: @escaping (SupportedAgentKind) -> ChatModeLaunchOptions = {
            ChatModeSettings.launchOptions(for: $0)
        },
        launchPromptHost: @escaping (Host.ID) -> LaunchPromptHost? = { _ in nil },
        queueLaunchMessage: @escaping @MainActor (String, QueuedMessage.AgentIdentity, Host.ID) -> Void = { _, _, _ in },
        queueFirstMessage: @escaping @MainActor (
            LaunchDraft.FirstMessage, URL?, QueuedMessage.AgentIdentity, Host.ID
        ) -> Bool = { _, _, _, _ in true },
        launchQueue: LaunchQueue? = nil,
        quickChat: NewChatPreferences? = nil,
        preset: AgentLaunchPreset? = nil,
        hasLiveSnapshot: @escaping (Host.ID) -> Bool = { _ in true },
        backendPresence: @escaping (Host.ID) -> HostBackendPresence? = { _ in nil },
        quickChatWindow: Duration = .seconds(20),
        quickChatPollInterval: Duration = .milliseconds(200),
        foundDiscoveryRetryDelay: Duration = .seconds(1)
    ) {
        self.quickChatWindow = quickChatWindow
        self.quickChatPollInterval = quickChatPollInterval
        self.foundDiscoveryRetryDelay = foundDiscoveryRetryDelay
        self.recordChatMode = recordChatMode
        self.chatOptions = chatOptions
        self.launchPromptHost = launchPromptHost
        self.queueLaunchMessage = queueLaunchMessage
        self.queueFirstMessage = queueFirstMessage
        self.launchQueue = launchQueue
        self.mintWorktreeBranch = mintWorktreeBranch
        self.hosts = hosts
        self.origin = origin
        self.workspacesProvider = workspaces
        self.existingAgentNames = existingAgentNames
        self.existingTabLabels = existingTabLabels
        self.discoverAgentKinds = discoverAgentKinds
        self.cachedAgentKinds = cachedAgentKinds
        self.remoteHome = remoteHome
        self.start = start
        self.startShell =
            startShell
            ?? { _, _, _, _ in
                throw TransportError.channelFailed(
                    detail: "This flow cannot launch shells.")
            }
        self.backendsProvider = backends
        self.defaultBackendProvider = defaultBackend
        self.showsServerChat = showsServerChat
        self.serverRuntimeState = serverRuntimeState
        self.startServer = startServerRuntime
        self.createServerSession = createServerSession
        self.awaitAgentVisible = awaitAgentVisible
        self.onAgentStarted = onAgentStarted
        self.reviewPrompt = reviewPrompt
        self.recents = recents
        self.selections = selections
        self.startsFromLatestMain = selections.startsFromLatestMain
        // A preset wins over quick chat: it is never auto-started.
        self.quickChat = preset == nil ? quickChat : nil
        self.preset = preset
        self.hasLiveSnapshot = hasLiveSnapshot
        self.backendPresence = backendPresence
        self.isQuickChat = quickChat != nil && preset == nil
        // Quick chat is Chat Mode and leaves the sheet's remembered choice
        // alone. A preset launch is never Chat Mode: the user should see
        // every command its Agent runs on the Mac.
        self.chatMode = preset == nil && (quickChat != nil || selections.chatMode)
        // Quick chat goes to its destination's Host while that Host still
        // exists, and a preset to its Host likewise. Otherwise pre-select
        // when there is no choice to make; with several Hosts, the
        // last-used one wins if it still exists.
        let knownHosts = Set(hosts.map(\.id))
        let quickChatHostID = self.quickChat
            .flatMap { NewChatResolver.destination($0, knownHosts: knownHosts) }?.hostID
        let presetHostID = preset?.hostID.flatMap { knownHosts.contains($0) ? $0 : nil }
        self.lockedHostID = origin == nil && preset?.locksHost == true ? presetHostID : nil
        self.selectedHostID =
            origin?.hostID
            ?? quickChatHostID
            ?? presetHostID
            ?? (hosts.count == 1
                ? hosts.first?.id
                : hosts.first(where: { $0.id == selections.lastHostID })?.id)
        // The suggestion reads as if the user had typed it, made unique
        // among the Host's live Agents while the user leaves it alone.
        self.presetSuggestedName = preset?.suggestedName.map(AgentName.normalizingInput)
        // A preset is never auto-started, even if quick chat is passed too.
        self.autoStartPending = quickChat != nil && preset == nil
        if let presetSuggestedName {
            self.name = presetSuggestedName
            self.shownSuggestion = presetSuggestedName
            refreshSuggestedName()
        }
    }

    /// Whether the fresh-worktree variant is offered. An origin launch is
    /// defined by landing in the origin agent's directory, and a worktree
    /// launch lands in a brand-new checkout instead — the two cannot both
    /// hold, so the origin flow drops the option rather than silently
    /// ignoring the requested directory. New Workspace likewise has no
    /// source Workspace to branch from.
    var offersWorktree: Bool {
        origin == nil && launchTarget == .existingWorkspace
            && (probableTargetBackend?.capabilities.worktrees ?? true)
    }

    /// Whether the form offers Existing vs New Workspace. Origin launches
    /// inherit the origin agent's Workspace and directory, so the choice
    /// would contradict that inheritance. On herdr-core the "new Workspace"
    /// is a folder to start in (no worktrees, no name): offered wherever a
    /// backend of the Host starts agents.
    var offersNewWorkspace: Bool {
        origin == nil
            && (hostBackends.isEmpty || hostBackends.contains { $0.capabilities.startsAgents })
    }

    /// Whether the launch the form describes starts in a folder on
    /// herdr-core, whose Workspaces are folders: the form then shows the
    /// folder and no Workspace name, and has no Default Shell. A Host that
    /// reports no Workspace yet is judged by its only backend.
    var launchesIntoFolder: Bool {
        probableTargetBackend == .core || launchesServerChat
    }

    /// ``formTargetBackend``, else, while the Host reports no Workspace and
    /// the target is open, the Host's only backend.
    private var probableTargetBackend: HostBackend? {
        formTargetBackend ?? (launchableBackends.count == 1 ? launchableBackends.first : nil)
    }

    /// The Host a preset locks the sheet to, for the picker's footer; nil
    /// while the Host is the user's to choose.
    var lockedHost: Host? {
        guard let lockedHostID else { return nil }
        return hosts.first { $0.id == lockedHostID }
    }

    /// Whether the Host picker shows disabled: a preset locked it.
    var locksHost: Bool { lockedHostID != nil }

    /// The SwiftUI binding behind the Host picker. A write is ignored while
    /// a preset locks the Host, so the launch can't leave the Host it was
    /// prepared for.
    var hostSelection: Binding<Host.ID?> {
        Binding(
            get: { [self] in selectedHostID },
            set: { [self] hostID in
                guard lockedHostID == nil else { return }
                selectedHostID = hostID
            })
    }

    /// Whether the Agent picker offers Default Shell. A preset launch hands
    /// its Agent a first message, which a plain shell can't take, and
    /// herdr-core has no way to start a plain terminal yet.
    var offersShell: Bool { preset == nil && !launchesIntoFolder }

    /// What the selected Host lacks (WAY-338): neither herdr nor tmux, or
    /// tmux under 3.2 with no herdr. The form then shows the install panel,
    /// Default Shell unavailable, and Start off until the Console finds a
    /// backend. Nil for an origin launch (its Agent proves a backend), and
    /// while the Host's backends are undetected.
    var backendGap: HostBackendGap? {
        guard origin == nil, let selectedHostID else { return nil }
        if launchesServerChat { return nil }
        return HostBackendGap(presence: backendPresence(selectedHostID))
    }

    /// The backend an install or Check Again just found while this sheet was
    /// open; its footer says so. Cleared when the Host changes.
    private(set) var foundBackend: HostBackend?

    /// How many times `backendFound()` detects Agents before leaving a
    /// failure for the user's Retry.
    private static let foundDiscoveryAttempts = 5

    /// The gap closed while the sheet was open (an install or Check Again
    /// found a backend): detects the Host's Agents again, and with no
    /// Workspace to pick, aims the launch at a New Workspace, so Start
    /// works with no further tap and no restart. The Console restarts the
    /// Host's connection as it records the find, so a detection that fails
    /// first is tried again a moment later.
    func backendFound() async {
        guard let hostID = selectedHostID, origin == nil,
            let presence = backendPresence(hostID)
        else { return }
        for attempt in 1...Self.foundDiscoveryAttempts {
            await discoverAgents()
            guard selectedHostID == hostID else { return }
            guard case .failed = agentDiscoveryState, attempt < Self.foundDiscoveryAttempts else {
                break
            }
            try? await Task.sleep(for: foundDiscoveryRetryDelay)
            guard selectedHostID == hostID else { return }
        }
        foundBackend = presence.herdr ? .herdr : presence.coreFound ? .core
            : presence.tmuxUsable ? .tmux : presence.zellij?.meetsFloor == true ? .zellij : nil
        if workspaces.isEmpty, !userChoseDestination {
            programmatically { selectNewWorkspace() }
        }
    }

    /// Whether `kind` starts on a first message at launch, so a preset's
    /// Launch Prompt File reaches it; any other kind gets it through its
    /// Composer once it takes input.
    nonisolated private static func takesFirstMessage(_ kind: SupportedAgentKind) -> Bool {
        LaunchPromptStager.firstMessageArguments(kind: kind, pointer: "") != nil
    }

    /// The workspaces the selected Host knows; empty when no Host is picked.
    var workspaces: [ConsoleWorkspace] {
        guard let selectedHostID else { return [] }
        return workspacesProvider(selectedHostID).filter {
            $0.backend.hasTerminal && $0.backend.capabilities.startsAgents
        }
    }

    var parsedArguments: Result<[String], ArgumentError> {
        Self.parseArguments(Self.normalizeSmartPunctuation(arguments))
    }

    var argumentErrorMessage: String? {
        guard case .failure(let error) = parsedArguments else { return nil }
        return error.message
    }

    /// The first message's images and files, in add order.
    var firstMessageAttachments: [ComposerTray.Item] { firstMessageTray.items }

    /// Whether Start keeps the launch on the device as a Queued Launch
    /// rather than launching it now: the selected Host has no verified
    /// connection. Read live, so the sheet follows the Host dropping or
    /// coming back while it is open.
    var startsWhenHostConnects: Bool {
        guard launchQueue != nil, let selectedHostID else { return false }
        return !hasLiveSnapshot(selectedHostID)
    }

    /// Adds images and files to the first message, as many as fit in one
    /// message (`ComposerTray.capacity`); returns how many it took.
    @discardableResult
    func addFirstMessageAttachments(_ sources: [ComposerStagingStore.Source]) -> Int {
        noteEdit(!sources.isEmpty)
        return firstMessageTray.add(sources)
    }

    func removeFirstMessageAttachment(_ id: ComposerTray.Item.ID) {
        noteEdit()
        firstMessageTray.remove(id)
    }

    /// Empties the first message's tray as the sheet goes away, deleting
    /// the app's copies of pasted and dropped files (`ComposerTray.remove`)
    /// rather than leaving them until the next app start. A Start has
    /// already prepared its own copies; one still preparing keeps them.
    func discardFirstMessageAttachments() {
        guard !isStarting else { return }
        for item in firstMessageTray.items { firstMessageTray.remove(item.id) }
    }

    /// Brings `name` under herdr's agent-name rule unless the launch is a
    /// shell. A name still mirrored from the branch keeps mirroring: the
    /// baseline follows the rewrite, and it gets the mirror's leading-letter
    /// treatment.
    private func normalizeNameForAgentLaunch() {
        guard !selectedLaunchIsShell else { return }
        let isMirrored = name == nameMirroredFromBranch
        let normalized = isMirrored
            ? Self.mirroredAgentName(name) : AgentName.normalizingInput(name)
        guard normalized != name else { return }
        if isMirrored { nameMirroredFromBranch = normalized }
        name = normalized
    }

    /// Copies the branch into `name` while the user has not given the name
    /// a value of its own. A shell's tab label takes the branch verbatim; an
    /// Agent name is rewritten under the rule and additionally made to start
    /// with a letter, since nothing the user typed into the name is lost.
    private func mirrorWorktreeBranchIntoName() {
        guard name.isEmpty || name == nameMirroredFromBranch else { return }
        let mirrored = selectedLaunchIsShell
            ? worktreeBranch : Self.mirroredAgentName(worktreeBranch)
        nameMirroredFromBranch = mirrored
        name = mirrored
    }

    /// `value` under the agent-name rule with any leading characters other
    /// than `a-z` dropped, e.g. branch `97-fix-login` → `fix-login`.
    private static func mirroredAgentName(_ value: String) -> String {
        String(
            AgentName.normalizingInput(value)
                .drop(while: { !("a"..."z").contains($0) }))
    }

    /// A normalized field's value as sent: typing a space shows `-` at once,
    /// so a `-` the user stopped after is dropped rather than submitted. A
    /// `-` right after `/` or `.` stays: dropping it would leave a branch
    /// ending in `/` or `.`, which git rejects though `feat/-` is fine.
    private static func submittedTypedValue(_ value: String) -> String {
        var trimmed = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
        while trimmed.last == "-" {
            let rest = trimmed.dropLast()
            if let before = rest.last, before == "/" || before == "." { break }
            trimmed = rest
        }
        return String(trimmed)
    }

    /// User-facing name feedback; nil while the field is empty (empty means
    /// "use the generated default"). A shell launch's name is a tab label,
    /// not an agent name: herdr's agent-name rule does not govern it, so
    /// any non-empty label is accepted.
    var nameErrorMessage: String? {
        if selectedLaunchIsShell { return nil }
        let trimmed = Self.submittedTypedValue(name)
        guard !trimmed.isEmpty else { return nil }
        return AgentName.validationError(trimmed)
    }

    /// The name `submit()` falls back to while the field is empty; nil until
    /// a Host and Agent are selected. Shown as the field's placeholder so the
    /// fallback is never a surprise.
    var defaultAgentName: String? {
        guard let selectedHostID, let kind = launchingServerChat?.agentKind ?? selectedAgentKind else {
            return nil
        }
        return Self.defaultAgentName(for: kind, taken: existingAgentNames(selectedHostID))
    }

    /// The tab label a plain-shell launch falls back to while the field is
    /// empty: "Default Shell", then "Default Shell 2", "Default Shell 3", …
    /// skipping tab labels already live on the Host.
    var defaultShellName: String? {
        guard let selectedHostID else { return nil }
        return Self.defaultShellName(taken: existingAgentNames(selectedHostID))
    }

    /// User-facing branch feedback; nil while the toggle is off or the field
    /// is empty (empty means "mint a generated branch").
    var worktreeBranchErrorMessage: String? {
        guard startsInNewWorktree else { return nil }
        let branch = Self.submittedTypedValue(worktreeBranch)
        guard !branch.isEmpty else { return nil }
        return GitBranchName.validationError(branch)
    }

    /// Whether the form is complete enough to dispatch. Start stays off while
    /// the Host has no usable backend, whatever the form says.
    var canSubmit: Bool {
        selectedHostID != nil && hasLaunchTarget
            && backendGap == nil
            && nameErrorMessage == nil
            && worktreeBranchErrorMessage == nil
            && state != .starting
            && (launchesServerChat ? selectedServerRuntimeState == .running
                : (selectedLaunchIsShell
                    || (parsedArguments.isSuccess && selectedAgentKind != nil
                        && agentDiscoveryState == .loaded)))
    }

    /// Existing Workspace and origin launches need a reported Workspace;
    /// a New Workspace launch is complete as chosen, because a name-only
    /// launch resolves its directory at submit.
    private var hasLaunchTarget: Bool {
        if launchesServerChat { return true }
        if origin != nil { return selectedWorkspaceID != nil }
        switch launchTarget {
        case .existingWorkspace:
            return selectedWorkspaceID != nil
        case .newWorkspace:
            // Directory is optional: a name-only launch falls back to the
            // Host's home directory at submit.
            return true
        }
    }

    /// Whether the sheet may be dismissed without abandoning an in-flight
    /// launch whose server-side outcome may already be committed.
    var canDismiss: Bool {
        state != .starting
    }

    /// Detects the selected Host's Agents and preselects one: the last
    /// launched kind, or Default Shell when that was the last choice or no
    /// Agent was found (so Start stays usable with a quiet note). Quick
    /// chat preselects its New Chat kind instead, else a Chat Mode kind. A
    /// preset launch never preselects Default Shell: the last launched kind,
    /// else the first.
    /// These are the store's own picks, not the user's edits.
    ///
    /// The kinds the Host's last detection found (`cachedAgentKinds`) load
    /// at once, so Start works before the Host answers; the live answer then
    /// replaces them, keeping the pick while it is still offered. A failed
    /// live detection leaves cached kinds loaded (`agentKindsAreCached`).
    func discoverAgents() async {
        let hostID = selectedHostID
        await performDiscovery(discovery.handle(.begin(hostID, hostID.flatMap(cachedAgentKinds))))
    }

    private func performDiscovery(_ effects: [AgentDiscoveryMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .clearSelection:
                programmatically { selectedAgentKind = nil }
            case .applyKinds(let kinds, let hostID, let preservesPick):
                programmatically {
                    applyAgentKinds(kinds, hostID: hostID, preservesLoadedPick: preservesPick)
                }
            case .detect(let attempt):
                let completion: AgentDiscoveryMachine.Event
                do {
                    completion = .loaded(attempt, try await discoverAgentKinds(attempt.hostID))
                } catch is CancellationError {
                    completion = .cancelled(attempt)
                } catch {
                    completion = .failed(attempt, Self.discoveryMessage(for: error))
                }
                guard selectedHostID == attempt.hostID else { continue }
                await performDiscovery(discovery.handle(completion))
            }
        }
    }

    /// Lists `kinds` as the Host's Agents and preselects one by
    /// `discoverAgents()`'s rules. Over a list already loaded the pick stays
    /// while it is still offered, so a later detection never undoes the
    /// user's choice. Runs inside `programmatically`.
    private func applyAgentKinds(
        _ kinds: [SupportedAgentKind], hostID: Host.ID, preservesLoadedPick: Bool
    ) {
        if preservesLoadedPick, pickSurvives(kinds) {
            // Keep the form's explicit selection while it is still offered.
        } else if preset != nil {
            selectedAgentKind =
                kinds.first(where: { $0 == selections.lastAgentKind }) ?? kinds.first
            normalizeNameForAgentLaunch()
        } else if let quickChat {
            selectedAgentKind = Self.quickChatKind(
                among: kinds, preferred: NewChatResolver.kind(quickChat),
                last: selections.lastAgentKind)
            normalizeNameForAgentLaunch()
            // Never over a destination the user picked.
            if !userChoseDestination {
                preselectQuickChatWorkspace(quickChat, hostID: hostID)
            }
        } else {
            if selections.lastSelectionWasShell {
                selectedLaunchIsShell = true
            } else if kinds.isEmpty, offersShell {
                // No Agent CLI on this Host: preselect Default Shell
                // so Start works instead of reading as a dead end;
                // the picker shows a quiet note saying why. Only a
                // switch marks the fallback: a Shell the user already
                // chose stays an explicit choice.
                if !selectedLaunchIsShell {
                    shellAutoSelectedForEmptyDetection = true
                }
                selectedLaunchIsShell = true
            } else {
                if shellAutoSelectedForEmptyDetection {
                    // The fallback never outlives a detection that
                    // found Agents.
                    selectedLaunchIsShell = false
                    shellAutoSelectedForEmptyDetection = false
                }
                selectedAgentKind =
                    kinds.first(where: { $0 == selections.lastAgentKind }) ?? kinds.first
                normalizeNameForAgentLaunch()
            }
        }
        // A herdr-core Host with no terminal yet reports no Workspace
        // (a folder), so the launch starts in a folder, home until
        // one is chosen, rather than waiting on a pick of nothing.
        if origin == nil, launchesIntoFolder, workspaces.isEmpty, !userChoseDestination {
            launchTarget = .newWorkspace
        }
    }

    /// Whether the current pick is still offered among `kinds`: Default
    /// Shell the user or Last Used chose (never the empty-detection
    /// fallback), or a kind among them.
    private func pickSurvives(_ kinds: [SupportedAgentKind]) -> Bool {
        if selectedLaunchIsShell { return !shellAutoSelectedForEmptyDetection }
        return selectedAgentKind.map(kinds.contains) ?? false
    }

    /// Quick chat's preselected kind: the New Chat kind when the Host has
    /// it, else the last launched kind or the first one offering Chat Mode,
    /// so the sheet opens with Chat Mode showing whenever it can.
    private static func quickChatKind(
        among kinds: [SupportedAgentKind], preferred: SupportedAgentKind?,
        last: SupportedAgentKind?
    ) -> SupportedAgentKind? {
        if let preferred, kinds.contains(preferred) { return preferred }
        let chatKinds = kinds.filter(\.supportsChatMode)
        return chatKinds.first(where: { $0 == last }) ?? chatKinds.first
            ?? kinds.first(where: { $0 == last }) ?? kinds.first
    }

    /// Quick chat's Workspace as soon as detection loads: the New Chat
    /// plan's existing Workspace or New Workspace fields, so the sheet shows
    /// New Chat's destination even when the auto-start later stops. Runs
    /// inside `programmatically`.
    private func preselectQuickChatWorkspace(_ preferences: NewChatPreferences, hostID: Host.ID) {
        guard
            let plan = NewChatResolver.plan(
                preferences: preferences, knownHosts: Set(hosts.map(\.id)),
                workspaces: workspacesProvider(hostID)),
            plan.hostID == hostID
        else { return }
        switch plan.target {
        case .existingWorkspace(let id):
            launchTarget = .existingWorkspace
            pickedWorkspaceID = id
        case .newWorkspace(let directory, let label):
            launchTarget = .newWorkspace
            newWorkspaceDirectory = directory
            newWorkspaceLabel = label ?? ""
        }
    }

    /// Ends quick chat's auto-start for good: Cancel, the sheet going away,
    /// or the user opening the directory browser.
    func stopQuickChat() {
        autoStartPending = false
    }

    /// Quick chat's auto-start. Waits, for at most `quickChatWindow`, until
    /// the destination Host's Agents are detected and its snapshot is live;
    /// then plans the New Chat against that Host's workspaces, presets the
    /// form from the plan and submits once. Detection that failed is run
    /// again each time the Host's snapshot turns live. Stops for good on any
    /// edit by the user, on `stopQuickChat()`, when the window passes, or
    /// when the defaults do not resolve, leaving the form editing with Chat
    /// Mode on. A no-op outside quick chat and once it has stopped, so it
    /// never submits twice.
    func runQuickChat() async {
        guard let quickChat else { return }
        let deadline = ContinuousClock.now + quickChatWindow
        var wasLive = selectedHostID.map(hasLiveSnapshot) ?? false
        while autoStartPending, !Task.isCancelled {
            let isLive = selectedHostID.map(hasLiveSnapshot) ?? false
            defer { wasLive = isLive }
            if case .failed = agentDiscoveryState, isLive, !wasLive {
                // The Host connected after detection failed: detect again.
                await discoverAgents()
                continue
            }
            switch quickChatStep(quickChat) {
            case .wait:
                break
            case .stop:
                autoStartPending = false
                return
            case .start(let plan):
                autoStartPending = false
                apply(plan)
                // Unstructured, like Start: tearing the sheet down cancels
                // this wait, never a launch that has begun.
                await Task { await self.submit() }.value
                return
            }
            guard ContinuousClock.now < deadline else {
                autoStartPending = false
                return
            }
            try? await Task.sleep(for: quickChatPollInterval)
        }
    }

    /// What quick chat's auto-start does next.
    private enum QuickChatStep {
        /// Detection or the Host's live snapshot is still to come.
        case wait
        /// The defaults do not resolve; the user picks.
        case stop
        case start(NewChatPlan)
    }

    private func quickChatStep(_ preferences: NewChatPreferences) -> QuickChatStep {
        let knownHosts = Set(hosts.map(\.id))
        guard
            let destination = NewChatResolver.destination(preferences, knownHosts: knownHosts),
            NewChatResolver.kind(preferences) != nil,
            selectedHostID == destination.hostID,
            state == .editing, !isStarting
        else { return .stop }
        guard agentDiscoveryState == .loaded, hasLiveSnapshot(destination.hostID) else {
            return .wait
        }
        guard
            let plan = NewChatResolver.plan(
                preferences: preferences, knownHosts: knownHosts,
                workspaces: workspacesProvider(destination.hostID)),
            plan.hostID == destination.hostID,
            availableAgentKinds.contains(plan.kind)
        else { return .stop }
        return .start(plan)
    }

    /// Presets the form from a New Chat plan: its kind, Chat Mode, its
    /// existing Workspace or a New Workspace at its directory, and the
    /// generated default name.
    private func apply(_ plan: NewChatPlan) {
        programmatically {
            selectedLaunchIsShell = false
            selectedAgentKind = plan.kind
            switch plan.target {
            case .existingWorkspace(let id):
                launchTarget = .existingWorkspace
                pickedWorkspaceID = id
            case .newWorkspace(let directory, let label):
                launchTarget = .newWorkspace
                newWorkspaceDirectory = directory
                newWorkspaceLabel = label ?? ""
            }
            name = ""
            chatMode = true
        }
    }

    /// Runs `body`'s form writes as the store's own, not the user's edits.
    private func programmatically(_ body: () -> Void) {
        programmaticEditDepth += 1
        defer { programmaticEditDepth -= 1 }
        body()
    }

    /// Stops quick chat's auto-start when the user changed a form field, and
    /// records a destination edit; the store's own writes run inside
    /// `programmatically` and pass.
    private func noteEdit(_ changed: Bool = true, destination: Bool = false) {
        guard changed, programmaticEditDepth == 0 else { return }
        autoStartPending = false
        if destination { userChoseDestination = true }
    }

    /// Dispatches the assembled launch — an `agent.start` for a detected
    /// Agent kind, or a plain shell (the same fresh pane, no `agent.start`)
    /// for "Default Shell". Incomplete forms are ignored; on success the
    /// state flips to `.started` carrying the new Console identity for the
    /// screen to dismiss and open.
    ///
    /// With a `launchQueue` and no verified connection to the Host (none
    /// counts while the device has no network), nothing is sent: the launch
    /// waits on the device as a Queued Launch and the state is `.queued`.
    /// Otherwise the form becomes a `LaunchDraft` that `launch(_:)` runs;
    /// one that reached nothing on the Host, a name-only New Workspace
    /// whose home probe the link failed or a start whose Host dropped
    /// before it went out (`LaunchOutcome.notSent`), is queued the same way.
    /// A lost answer is kept too, with mayHaveStarted so reconnect checks it.
    func submit() async {
        // Any submit, the user's or quick chat's own, ends the auto-start.
        autoStartPending = false
        guard
            !isStarting,
            let hostID = selectedHostID,
            worktreeBranchErrorMessage == nil,
            // Quick chat submits without the Start button: a Host with no
            // backend has nowhere to launch either way.
            backendGap == nil,
            !launchesServerChat || selectedServerRuntimeState == .running,
            nameErrorMessage == nil
        else { return }
        // A shell's tab label is free-form, but one still mirroring the
        // Branch goes out in the Branch's submitted form so the two match.
        let trimmedName =
            selectedLaunchIsShell && name != nameMirroredFromBranch
            ? name.trimmingCharacters(in: .whitespacesAndNewlines)
            : Self.submittedTypedValue(name)
        // Agent launches need parseable arguments; a shell launch carries
        // none, so stale text left in the hidden Arguments field must not
        // block it.
        let userArguments: [String]
        if selectedLaunchIsShell || launchesServerChat {
            userArguments = []
        } else {
            guard case .success(let arguments) = parsedArguments else { return }
            userArguments = arguments
        }
        guard case .assemble(let preparationToken) = preparation.handle(.begin(hostID)).first
        else { return }
        defer { _ = preparation.handle(.finish(preparationToken)) }
        _ = submission.handle(.submissionBegan)
        // No verified connection or no network: nothing goes to the Host
        // now, not even the home probe of a name-only New Workspace.
        if let launchQueue, !hasLiveSnapshot(hostID) {
            await queueLaunch(
                hostID: hostID, trimmedName: trimmedName, userArguments: userArguments,
                preparationToken: preparationToken, into: launchQueue)
            return
        }
        _ = submission.handle(.keepsLaunch(false))
        // A name-only New Workspace launch has no browsed directory: fall
        // back to the Host's home directory, resolved at submit so an
        // unreachable Host is reported here instead of blocking the form.
        // isStarting flips before the first await so a double-tap cannot
        // dispatch twice while the probe is in flight.
        if origin == nil, launchTarget == .newWorkspace,
            Self.nonEmptyTrimmed(newWorkspaceDirectory) == nil
        {
            _ = submission.handle(.preparing)
            _ = preparation.handle(.resolvingHome(preparationToken))
            do {
                let home = try await remoteHome(hostID)
                // The form stays editable while the probe is in flight;
                // discard the answer if it no longer applies.
                let applies = selectedHostID == hostID
                    && launchTarget == .newWorkspace
                    && Self.nonEmptyTrimmed(newWorkspaceDirectory) == nil
                guard !preparation.handle(.homeResolved(preparationToken, applies: applies)).isEmpty
                else {
                    _ = submission.handle(.editing)
                    return
                }
                guard RemoteShellPath.isQuotableAbsolute(home) else {
                    _ = submission.handle(.failed(
                        "The Host's home directory is not a usable path: \(home)"))
                    return
                }
                newWorkspaceDirectory = home
            } catch {
                // A probe the link failed started nothing: the launch
                // waits for the Host and resolves its home then.
                if let launchQueue, EventsSession.isTransportLinkFailure(error),
                    selectedHostID == hostID
                {
                    _ = preparation.handle(.homeResolved(preparationToken, applies: true))
                    await queueLaunch(
                        hostID: hostID, trimmedName: trimmedName, userArguments: userArguments,
                        preparationToken: preparationToken, into: launchQueue)
                    return
                }
                _ = submission.handle(.failed(Self.homeProbeMessage(for: error)))
                return
            }
        }
        guard let dispatch = makeLaunchDispatch(hostID: hostID) else {
            _ = submission.handle(.editing)
            return
        }
        _ = submission.handle(.preparing)
        let target = preparationTarget(hostID: hostID, dispatch: dispatch)
        _ = preparation.handle(.preparing(preparationToken, target))
        let launchID = UUID()
        // The launch's attachment copies are the Queued Message's by now,
        // unless it could not be kept: they stay for its Retry.
        var keepsAttachmentCopies = false
        defer {
            if !keepsAttachmentCopies {
                launchQueue?.store.remove(hostID: hostID, launchID: launchID)
            }
        }
        let firstMessage: LaunchDraft.FirstMessage?
        do {
            firstMessage = try await preparedFirstMessage(
                for: dispatch, hostID: hostID, launchID: launchID)
        } catch {
            _ = submission.handle(.failed(Self.attachmentPreparationMessage))
            return
        }
        // Named before the launch: the form stays editable meanwhile.
        let assembled = makeLaunchDraft(
            id: launchID, target: target, trimmedName: trimmedName,
            userArguments: userArguments, firstMessage: firstMessage)
        guard case .useDraft(var accepted) = preparation.handle(.prepared(preparationToken, assembled)).first
        else { return }
        let sessionInputs = pinRetriedOpenCodeSession(&accepted)
        let draft = prepareLaunchDraft(accepted)
        let outcome = await launch(draft)
        switch outcome {
        case .started(_, let keepsCopies):
            keepsAttachmentCopies = keepsCopies
        case .notSent, .uncertain:
            // Keep the same identity and copies, whether nothing reached
            // the Host or its answer was lost. Reconnect checks the latter.
            guard let launchQueue else { return }
            var queued = draft
            queued.dispatch.backend = target.queuedBackend
            _ = submission.handle(.keepsLaunch(true))
            keepsAttachmentCopies = keep(
                queued, in: launchQueue, mayHaveStarted: outcome == .uncertain)
        case .failed:
            if let sessionInputs, let id = draft.opencodeSessionID {
                _ = retryIdentity.handle(.openCodeLaunchFailed(
                    sessionID: id, launchName: draft.launchName, inputs: sessionInputs))
            }
        }
    }

    /// A Retry of a failed OpenCode try finishes the session it may have
    /// made: same id (OpenCode's Launch Tag) and name (B-40), pinned before
    /// the draft is dispatched or kept as a Queued Launch. Returns the
    /// inputs a failure of this try is recorded under.
    private func pinRetriedOpenCodeSession(
        _ draft: inout LaunchDraft
    ) -> LaunchRetryIdentityMachine.SessionInputs? {
        guard let inputs = openCodeSessionInputs(draft) else { return nil }
        if case .reuseOpenCodeSession(let id, let launchName)? =
            retryIdentity.handle(.openCodeSessionNeeded(inputs)).first
        {
            draft.opencodeSessionID = id
            draft.launchName = launchName
        }
        return inputs
    }

    /// What an OpenCode launch on OpenCode's own Backend was created for;
    /// nil for any other launch, which never reuses a session on Retry.
    private func openCodeSessionInputs(_ draft: LaunchDraft) -> LaunchRetryIdentityMachine.SessionInputs? {
        guard case .agent(.opencode) = draft.dispatch.launch, targetBackend(for: draft) == .opencode
        else { return nil }
        return .init(
            hostID: draft.hostID, dispatch: draft.dispatch, workspaceID: draft.workspaceID,
            originCwd: draft.originCwd, name: draft.name, suggestedName: draft.suggestedName,
            chatMode: draft.chatMode)
    }

    /// Keeps the form's launch on the device as a Queued Launch, sending
    /// nothing. Its backend is the one the form shows, so the replay lands
    /// on that runtime whatever the Host's default is by then; a name-only
    /// New Workspace resolves its home at launch.
    private func queueLaunch(
        hostID: Host.ID, trimmedName: String, userArguments: [String],
        preparationToken: UInt64, into queue: LaunchQueue
    ) async {
        _ = submission.handle(.keepsLaunch(true))
        guard var dispatch = makeLaunchDispatch(hostID: hostID, resolvingHomeAtLaunch: true)
        else {
            _ = submission.handle(.editing)
            return
        }
        dispatch.backend = dispatch.backend ?? formTargetBackend
        let target = preparationTarget(hostID: hostID, dispatch: dispatch)
        _ = preparation.handle(.preparing(preparationToken, target))
        _ = submission.handle(.preparing)
        let launchID = UUID()
        let firstMessage: LaunchDraft.FirstMessage?
        do {
            firstMessage = try await preparedFirstMessage(
                for: dispatch, hostID: hostID, launchID: launchID)
        } catch {
            queue.store.remove(hostID: hostID, launchID: launchID)
            _ = submission.handle(.failed(Self.attachmentPreparationMessage))
            return
        }
        let assembled = makeLaunchDraft(
            id: launchID, target: target, trimmedName: trimmedName,
            userArguments: userArguments, firstMessage: firstMessage)
        guard case .useDraft(var draft) = preparation.handle(.prepared(preparationToken, assembled)).first
        else {
            queue.store.remove(hostID: hostID, launchID: launchID)
            return
        }
        // The Queued Launch takes a failed OpenCode try's session along.
        _ = pinRetriedOpenCodeSession(&draft)
        if !keep(draft, in: queue) {
            queue.store.remove(hostID: hostID, launchID: launchID)
        }
    }

    /// Lists `draft` as a waiting Queued Launch and moves the sheet to
    /// `.queued`; false, with the failure shown, when it is not on disk.
    private func keep(
        _ draft: LaunchDraft, in queue: LaunchQueue, mayHaveStarted: Bool = false
    ) -> Bool {
        do {
            try queue.enqueue(QueuedLaunch(
                draft: draft, state: .waiting, createdAt: Date(), mayHaveStarted: mayHaveStarted))
        } catch {
            _ = submission.handle(.failed("Waycar couldn't keep this launch on the device. Try again."))
            return false
        }
        // The branch is the Queued Launch's now: another Start mints anew.
        _ = retryIdentity.handle(.launchKept)
        _ = submission.handle(.queued(draft.id))
        return true
    }

    /// Bind the destination to its Host before preparing attachments. Other
    /// form values retain their existing capture timing in `makeLaunchDraft`.
    private func preparationTarget(
        hostID: Host.ID, dispatch: Dispatch
    ) -> LaunchPreparationMachine.Target {
        let workspaceID: String? =
            if case .newWorkspace = dispatch.destination { nil } else { selectedWorkspaceID }
        return .init(hostID: hostID, workspaceID: workspaceID, dispatch: dispatch,
            queuedBackend: dispatch.backend ?? formTargetBackend)
    }

    /// The draft `launch(_:)` runs: the bound target plus the form's late values.
    private func makeLaunchDraft(
        id: UUID, target: LaunchPreparationMachine.Target, trimmedName: String,
        userArguments: [String], firstMessage: LaunchDraft.FirstMessage?
    ) -> LaunchDraft {
        // A preset's suggestion the user left alone is kept unique at launch.
        let keepsSuggestion = !trimmedName.isEmpty && name == shownSuggestion
        return LaunchDraft(
            id: id, hostID: target.hostID, dispatch: target.dispatch, workspaceID: target.workspaceID,
            originCwd: origin?.cwd, name: Self.nonEmptyTrimmed(trimmedName),
            suggestedName: keepsSuggestion ? presetSuggestedName : nil,
            userArguments: userArguments, chatMode: chatMode && preset == nil,
            presetFirstMessage: preset?.firstMessage, firstMessage: firstMessage,
            remembersLaunch: preset == nil, isQuickChat: isQuickChat)
    }

    /// Pins name, branch and session before saving Starting or keeping a
    /// live sheet's try. An offline queue waits for live inventory first.
    /// Never remints against inventory that may already contain this launch.
    func prepareLaunchDraft(_ draft: LaunchDraft) -> LaunchDraft {
        var prepared = draft
        if prepared.launchName == nil {
            let backend = targetBackend(for: draft)
            // A server chat session also opens a resume pane, possibly on
            // herdr where the tab label is that half's Launch Tag.
            let usesTabLabel = backend == .herdr || backend.isServerChat
            let taken = existingAgentNames(draft.hostID)
                .union(usesTabLabel ? existingTabLabels(draft.hostID) : [])
            switch draft.dispatch.launch {
            case .agent(let kind):
                let name = draft.suggestedName.map {
                    Self.uniqueSuggestedName($0, taken: taken)
                } ?? draft.name ?? Self.defaultAgentName(for: kind, taken: taken)
                prepared.launchName = usesTabLabel
                    ? Self.uniqueSuggestedName(name, taken: taken) : name
            case .shell:
                prepared.launchName = draft.name.map {
                    usesTabLabel ? Self.uniqueSuggestedName($0, taken: taken) : $0
                }
            }
        }
        if case .agent(let kind) = draft.dispatch.launch, prepared.sessionPin == nil {
            prepared.sessionPin = ChatModeLaunch.sessionPin(
                kind: kind, userArguments: draft.userArguments)
        }
        if case .agent(.opencode) = draft.dispatch.launch, prepared.opencodeSessionID == nil,
            Self.mintsOpenCodeSession(
                backend: targetBackend(for: draft), opencode2: runsOpenCode2(draft.hostID),
                userArguments: draft.userArguments)
        {
            prepared.opencodeSessionID = OpenCodeSessionID.mint()
        }
        if case .newWorktree(let spec) = draft.dispatch.destination {
            prepared.worktreeBranch = draft.worktreeBranch ?? spec.branch ?? mintWorktreeBranch()
            prepared.dispatch = Dispatch(
                destination: .newWorktree(WorktreeSpec(
                    branch: prepared.worktreeBranch, base: spec.base,
                    branchIsGenerated: spec.branchIsGenerated || spec.branch == nil)),
                launch: draft.dispatch.launch, backend: draft.dispatch.backend)
        }
        return prepared
    }

    /// The first message as a draft carries it: the typed text, and the
    /// tray's items prepared into the launch's own directory exactly as a
    /// Queued Message's are. Nil when there is nothing to send, and for a
    /// shell. Without a `launchQueue` there is nowhere to keep attachments.
    private func preparedFirstMessage(
        for dispatch: Dispatch, hostID: Host.ID, launchID: UUID
    ) async throws -> LaunchDraft.FirstMessage? {
        guard case .agent = dispatch.launch else { return nil }
        let text = firstMessageText.contains(where: { !$0.isWhitespace }) ? firstMessageText : ""
        let sources =
            launchQueue == nil
            ? [] : firstMessageTray.items.compactMap { firstMessageTray.source(of: $0.id) }
        guard !text.isEmpty || !sources.isEmpty else { return nil }
        var attachments: [QueuedMessage.Attachment] = []
        if let launchQueue, !sources.isEmpty {
            let directory = try launchQueue.store.preparedDirectory(
                hostID: hostID, launchID: launchID)
            for source in sources {
                attachments.append(try await QueuedMessage.Attachment.prepare(source, into: directory))
            }
        }
        return LaunchDraft.FirstMessage(text: text, attachments: attachments)
    }

    /// Runs `draft`: the rest of Start once the form is decided, and the
    /// whole of a Queued Launch's replay. A name-only New Workspace first
    /// resolves the Host's home; then the Agent or plain shell is dispatched,
    /// and a started Agent gets its Chat Marker and first messages. The
    /// name, worktree branch and session were pinned by `prepareLaunchDraft(_:)`
    /// before the launch was saved or dispatched.
    ///
    /// A cancelled task (a replay whose Host was re-targeted or removed)
    /// dispatches nothing, and once started hands nothing on: no Chat
    /// Marker, no first message, no launch remembered for whatever answers
    /// by that Host's id now.
    @discardableResult
    func launch(_ draft: LaunchDraft, mayHaveStarted: Bool = false) async -> LaunchOutcome {
        guard case .launch(let launchToken) = submission.handle(.launchBegan).first
        else { preconditionFailure("A launch must mint its progress token") }
        let hostID = draft.hostID
        var dispatch = draft.dispatch
        if case .newWorkspace(let spec) = dispatch.destination, spec.directory.isEmpty {
            do {
                let home = try await remoteHome(hostID)
                guard RemoteShellPath.isQuotableAbsolute(home) else {
                    return failLaunch(
                        "The Host's home directory is not a usable path: \(home)",
                        error: nil, dispatched: false, token: launchToken)
                }
                dispatch = Dispatch(
                    destination: .newWorkspace(
                        NewWorkspaceSpec(directory: home, label: spec.label)),
                    launch: dispatch.launch, backend: dispatch.backend)
            } catch {
                return failLaunch(Self.homeProbeMessage(for: error), error: error, dispatched: false, token: launchToken)
            }
        }
        switch dispatch.launch {
        case .agent(let kind):
            // Chat Mode follows the kind actually dispatched: the form stays
            // editable through the home probe, so the draft is made after
            // it, and one kind's chat flags mean something else to another
            // (`-c` is claude's `--continue`). The Chat Mode options, read
            // once for the kind dispatched: the launch arguments and the
            // marker's `prompt` field use them. A preset launch is never
            // Chat Mode.
            let chatOptionsForKind: ChatModeLaunchOptions? =
                draft.chatMode && kind.supportsChatMode ? chatOptions(kind) : nil
            // Every launch of a kind that takes one pins its session id, so
            // its Closed Session resumes exactly where herdr reports none.
            let sessionPin = draft.sessionPin
            guard let agentName = draft.launchName else {
                return failLaunch("The launch has no name.", error: nil, dispatched: false, token: launchToken)
            }
            var dispatched = false
            do {
                // The prompts go to the Host as files before anything opens
                // a tab, so a failed write leaves nothing half-started.
                // A server chat session takes no terminal arguments, files
                // or Chat Marker; its launch options are its Backend's own.
                let launchServer = targetBackend(for: draft).serverChat
                // An opencode pane on an OpenCode 2 Host joins its shared
                // server on the session the launch minted, which has no
                // `-m` (O12): the model goes on the session instead.
                let joinedSession = launchServer == nil ? draft.opencodeSessionID : nil
                var terminalChatOptions = chatOptionsForKind
                if kind == .opencode, runsOpenCode2(hostID) { terminalChatOptions?.model = nil }
                let command = launchServer != nil ? AgentLaunchCommand(arguments: [])
                    : try await LaunchPromptStager.launchCommand(
                        kind: kind, chatOptions: terminalChatOptions,
                        sessionPin: sessionPin,
                        userArguments: joinedSession.map { ["--session", $0] + draft.userArguments }
                            ?? draft.userArguments,
                        initialPrompt: draft.presetFirstMessage, host: launchPromptHost(hostID),
                        hostName: hostName(hostID), backend: targetBackend(for: draft))
                let opencodeOptions = draft.opencodeSessionID.map { id in
                    OpenCodeLaunchOptions(
                        sessionID: id, model: chatOptionsForKind?.model,
                        instructions: chatOptionsForKind.map { ChatModePrompt.launchText(from: $0.prompt) })
                }
                if let joinedSession, let opencodeOptions {
                    try await createJoinedOpenCodeSession(
                        joinedSession, options: opencodeOptions, name: agentName,
                        directory: launchDirectory(dispatch.destination, originCwd: draft.originCwd),
                        hostID: hostID, mayHaveStarted: mayHaveStarted, launchID: draft.id)
                }
                let request = AgentLaunchRequest(
                    kind: kind.rawValue,
                    name: agentName,
                    arguments: command.arguments,
                    workspaceID: draft.workspaceID,
                    cwd: draft.originCwd,
                    environment: command.environment,
                    launchID: draft.id, mayHaveStarted: mayHaveStarted,
                    codex: launchServer == .codex ? chatOptionsForKind.map {
                        CodexLaunchOptions(
                            developerInstructions: ChatModePrompt.launchText(from: $0.prompt),
                            model: $0.model, reasoningEffort: $0.quickThinking ? "low" : nil)
                    } : nil,
                    opencode: launchServer == .opencode ? opencodeOptions : nil)
                let launchedAt = Date()
                try Task.checkCancellation()
                dispatched = true
                let agent = try await reportingSteps(token: launchToken, subject: .agent(kind)) { joinedRunningAgent in
                    let agent = try await start(request, dispatch.destination, hostID, dispatch.backend)
                    try Task.checkCancellation()
                    onAgentStarted?(
                        ConsoleAgent.ID(hostID: hostID, paneID: agent.paneID), joinedRunningAgent())
                    return agent
                }
                try Task.checkCancellation()
                let joinedRunningAgent = launchReported(.joiningRunningAgent)
                // A joined Agent was not started with the Chat Mode
                // arguments or the pin: it gets no marker and is no chat
                // launch. A plain launch's marker only records its pin.
                let isChatLaunch = chatOptionsForKind != nil && !joinedRunningAgent
                let launchCwd = launchDirectory(dispatch.destination, originCwd: draft.originCwd)
                // A joined OpenCode 2 session's marker links the pane to it
                // (`ServerSessionLinks`), where herdr shows no command line.
                let markerSession = sessionPin.map {
                    ChatModeMarker.Session(kind: "id", value: $0.uuidString.lowercased())
                } ?? joinedSession.map { ChatModeMarker.Session(kind: "id", value: $0) }
                if launchServer == nil, !joinedRunningAgent, chatOptionsForKind != nil || markerSession != nil {
                    await recordChatMode(
                        ChatModeMarker(
                            paneID: agent.paneID,
                            terminalID: agent.terminalID,
                            kind: kind.rawValue,
                            cwd: agent.cwd.isEmpty ? launchCwd : agent.cwd,
                            session: markerSession,
                            prompt: chatOptionsForKind?.prompt,
                            chatMode: chatOptionsForKind != nil,
                            launchedAt: launchedAt),
                        hostID)
                }
                // The Host may have been re-targeted during the marker write.
                try Task.checkCancellation()
                // A kind with no first-message flag gets the preset's from
                // its Composer, once the Agent takes input. A joined Agent
                // was not started with it.
                let launched = QueuedMessage.AgentIdentity(
                    paneID: agent.paneID, kind: kind.rawValue, session: nil)
                if !joinedRunningAgent, launchServer != nil || !Self.takesFirstMessage(kind),
                    let firstMessage = draft.presetFirstMessage
                {
                    queueLaunchMessage(firstMessage, launched, hostID)
                }
                // The sheet's own first message reaches every kind through
                // its Composer, after the preset's, with its attachments.
                // One not kept leaves its copies for the Composer's Retry;
                // the Agent runs, so nothing launches again.
                var keepsAttachmentCopies = false
                if !joinedRunningAgent, let firstMessage = draft.firstMessage,
                    !queueFirstMessage(
                        firstMessage,
                        launchQueue?.store.launchDirectory(hostID: hostID, launchID: draft.id),
                        launched, hostID)
                {
                    Self.log.error("A launch's first message was not kept; its copies stay")
                    keepsAttachmentCopies = !firstMessage.attachments.isEmpty
                }
                _ = retryIdentity.handle(.launchStarted)
                // An Agent that was already running is not a new launch:
                // the sheet did not start it.
                if !joinedRunningAgent {
                    reviewPrompt?.recordValueEvent()
                }
                // A preset launch (Ask an Agent, the Keychain Fix) is a
                // one-off: it leaves Last Used and the New Chat defaults alone.
                let remembersLaunch = draft.remembersLaunch
                if remembersLaunch {
                    selections.remember(hostID: hostID, kind: kind)
                    // Quick chat's Chat Mode is not the sheet's choice to keep.
                    if kind.supportsChatMode, !draft.isQuickChat {
                        selections.rememberChatMode(draft.chatMode)
                    }
                    rememberWorktreeStart(dispatch.destination)
                    if case .newWorkspace = dispatch.destination {
                        recents.remember(agent.workspaceID, for: hostID)
                    } else if let workspaceID = draft.workspaceID {
                        recents.remember(workspaceID, for: hostID)
                    }
                }
                let startedID = ConsoleAgent.ID(hostID: hostID, paneID: agent.paneID)
                // The wait is bounded; on timeout the owner still navigates and
                // the row catches up with the next resync. Titled from the
                // returned Agent: a joined one may be another kind.
                beginLaunchStep(
                    .opening, at: Date(), token: launchToken,
                    subject: .agent(SupportedAgentKind(rawValue: agent.kind)))
                await awaitAgentVisible(startedID)
                // After the wait, so a New Workspace's label has landed. A
                // joined Agent is not a chat this sheet started.
                let startedChat = isChatLaunch && !joinedRunningAgent
                if startedChat, remembersLaunch {
                    selections.rememberChat(
                        destination: chatDestination(
                            hostID: hostID, agent: agent, destination: dispatch.destination,
                            launchDirectory: launchCwd),
                        kind: kind)
                }
                _ = submission.handle(.started(
                    launchToken, startedID, .agent(joinedRunningAgent ? nil : kind, chat: startedChat)))
                return .started(startedID, keepsAttachmentCopies: keepsAttachmentCopies)
            } catch {
                return failLaunch(
                    Self.message(
                        for: error, launchedKind: kind, backend: targetBackend(for: draft)),
                    error: error, dispatched: dispatched, token: launchToken)
            }
        case .shell:
            // Nil keeps herdr's default tab label. It cannot reconcile an
            // unnamed shell, so retry may open one extra empty shell tab;
            // tmux and core can still identify it by the Launch Tag.
            let request = ShellLaunchRequest(
                name: draft.launchName,
                workspaceID: draft.workspaceID,
                cwd: draft.originCwd,
                launchID: draft.id, mayHaveStarted: mayHaveStarted)
            do {
                try Task.checkCancellation()
                let result = try await reportingSteps(token: launchToken, subject: .shell) { _ in
                    try await startShell(request, dispatch.destination, hostID, dispatch.backend)
                }
                try Task.checkCancellation()
                let joinedRunningAgent = launchReported(.joiningRunningAgent)
                _ = retryIdentity.handle(.launchStarted)
                selections.rememberShell(hostID: hostID)
                rememberWorktreeStart(dispatch.destination)
                if case .newWorkspace = dispatch.destination {
                    recents.remember(result.workspaceID, for: hostID)
                } else if let workspaceID = draft.workspaceID {
                    recents.remember(workspaceID, for: hostID)
                }
                let startedID = ConsoleAgent.ID(hostID: hostID, paneID: result.paneID)
                // The wait is bounded; on timeout the owner still navigates
                // and the shell row catches up with the next resync.
                beginLaunchStep(
                    .opening, at: Date(), token: launchToken,
                    subject: joinedRunningAgent ? .agent(nil) : .shell)
                await awaitAgentVisible(startedID)
                _ = submission.handle(.started(launchToken, startedID, .shell))
                return .started(startedID, keepsAttachmentCopies: false)
            } catch {
                // The shell's own dispatch is its first request.
                return failLaunch(
                    Self.message(for: error, launchedKind: nil, backend: targetBackend(for: draft)),
                    error: error, dispatched: true, token: launchToken)
            }
        }
    }

    /// Creates the session an OpenCode 2 pane is about to open, as New Agent
    /// › OpenCode does (metadata, model, Chat Prompt), while the Host's
    /// server runs and the launch's folder is known (not for a new
    /// Worktree). Best effort: otherwise the TUI creates it with that id at
    /// its first prompt (O12). A retry repeats the create, which OpenCode
    /// answers with the session it has (O11).
    private func createJoinedOpenCodeSession(
        _ id: String, options: OpenCodeLaunchOptions, name: String, directory: String?,
        hostID: Host.ID, mayHaveStarted: Bool, launchID: UUID
    ) async throws {
        guard let createServerSession, let directory, directory.hasPrefix("/"),
            serverRuntimeState(hostID, .opencode) == .running
        else { return }
        do {
            _ = try await createServerSession(
                AgentLaunchRequest(
                    kind: SupportedAgentKind.opencode.rawValue, name: name, cwd: directory,
                    launchID: launchID, mayHaveStarted: mayHaveStarted, opencode: options),
                hostID)
        } catch {
            try Task.checkCancellation()
            Self.log.error("The joined OpenCode session was not created first: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
    }

    /// Whether an opencode launch on `backend` mints its OpenCode 2 session
    /// id: always on OpenCode's own Backend; on a terminal Backend only when
    /// the Host's `opencode` is OpenCode 2 and the user's arguments pick no
    /// session, folder session or server of their own.
    nonisolated static func mintsOpenCodeSession(
        backend: HostBackend, opencode2: Bool, userArguments: [String]
    ) -> Bool {
        if backend == .opencode { return true }
        guard backend.hasTerminal, opencode2 else { return false }
        // A subcommand would follow the pin (`opencode --session <id> run`).
        if let first = userArguments.first, !first.hasPrefix("-"), !first.contains("/"), first != "." {
            return false
        }
        let own = ["--session", "-s", "--continue", "-c", "--standalone", "--server"]
        return !userArguments.contains { argument in
            own.contains { argument == $0 || argument.hasPrefix($0 + "=") }
        }
    }

    /// The Host's `opencode` is OpenCode 2, as last detected (O1).
    private func runsOpenCode2(_ hostID: Host.ID) -> Bool {
        backendPresence(hostID)?.opencode != nil
    }

    /// Ends a failed launch with `message`. It counts as not sent when
    /// nothing reached the Host: the dispatch failed `RequestNotSentError`
    /// (no verified rows to launch on), or a link failure came before it.
    /// A link failure during the dispatch is uncertain: the Host may have
    /// started it and the answer been lost.
    private func failLaunch(
        _ message: String, error: (any Error)?, dispatched: Bool, token: UInt64
    ) -> LaunchOutcome {
        _ = submission.handle(.launchFailed(token, message))
        guard let error else { return .failed(message) }
        if error is RequestNotSentError
            || (!dispatched && RequestNotSentError.wrapping(error) is RequestNotSentError)
        {
            return .notSent(message)
        }
        return dispatched && EventsSession.isTransportLinkFailure(error)
            ? .uncertain : .failed(message)
    }

    private static let log = Logger(subsystem: "com.otreva.waycar", category: "StartAgentStore")

    private static let attachmentPreparationMessage =
        "An attachment couldn't be prepared on this device. Remove it, or try again."

    /// What the launch banner's lines name: a plain shell, or an Agent of a
    /// kind (nil for one Waycar does not know).
    private enum LaunchSubject {
        case shell
        case agent(SupportedAgentKind?)
    }

    /// Runs `operation` with a progress reporter bound, applying each step
    /// on the main actor in the order the Transport reported it, stamped
    /// with when it was reported. Every step reported during `operation` is
    /// applied before this returns or throws; on a throw the running step
    /// is marked failed.
    private func reportingSteps<T>(
        token: UInt64, subject: LaunchSubject,
        _ operation: (_ joinedRunningAgent: @Sendable () -> Bool) async throws -> T
    ) async throws -> T {
        let joinedRunningAgent = Mutex(false)
        let (steps, continuation) = AsyncStream.makeStream(of: (LaunchStep, Date).self)
        let consumer = Task { @MainActor [weak self] in
            for await (step, reportedAt) in steps {
                self?.beginLaunchStep(step, at: reportedAt, token: token, subject: subject)
            }
        }
        do {
            let value = try await LaunchProgress.$reporter.withValue(
                { step in
                    // The start hook runs before the step consumer finishes.
                    if step == .joiningRunningAgent { joinedRunningAgent.withLock { $0 = true } }
                    _ = continuation.yield((step, Date()))
                }
            ) {
                try await operation { joinedRunningAgent.withLock { $0 } }
            }
            continuation.finish()
            await consumer.value
            return value
        } catch {
            continuation.finish()
            await consumer.value
            _ = submission.handle(.operationFailed(token))
            throw error
        }
    }

    /// Whether the current launch reported `step`.
    private func launchReported(_ step: LaunchStep) -> Bool {
        launchSteps.contains { $0.step == step }
    }

    /// Marks the running step done and appends `step` as the running one.
    /// A step equal to the running one adds nothing: a replayed Transport
    /// call reports its steps again.
    private func beginLaunchStep(
        _ step: LaunchStep, at startedAt: Date, token: UInt64, subject: LaunchSubject
    ) {
        _ = submission.handle(.step(token, step, startedAt, title: Self.title(for: step, subject: subject)))
    }

    /// The launch banner's line for `step`.
    private static func title(for step: LaunchStep, subject: LaunchSubject) -> String {
        switch step {
        case .gettingLatestMain: "Getting the latest main from origin"
        case .creatingWorktree: "Creating the worktree"
        case .checkingForCreatedWorktree: "Checking for the worktree the Host made"
        case .usingExistingWorktree: "Using the worktree that already exists"
        case .creatingWorkspace: "Creating the workspace"
        case .creatingTab: "Opening a new tab"
        case .waitingForShell: "Waiting for the shell to be ready"
        case .startingAgent: "Starting \(agentName(subject) ?? "the agent")"
        case .joiningRunningAgent: "Opening the agent already running there"
        case .openingShell: "Opening the shell"
        case .opening: openingTitle(subject)
        }
    }

    private static func agentName(_ subject: LaunchSubject) -> String? {
        guard case .agent(let kind) = subject else { return nil }
        return kind?.displayName
    }

    /// `.opening`'s line: the opened row is a terminal for a plain shell,
    /// otherwise the named Agent.
    private static func openingTitle(_ subject: LaunchSubject) -> String {
        switch subject {
        case .shell: "Opening the terminal"
        case .agent(let kind): kind.map { "Opening \($0.displayName)" } ?? "Opening the agent"
        }
    }

    /// Assembles the Transport variant from the current form. Nil when the
    /// chosen target is incomplete, so `submit()` is a no-op rather than
    /// inventing a Workspace id. A New Worktree with an empty Branch field
    /// carries the minted branch, minting one when none fits these inputs.
    /// With `resolvingHomeAtLaunch`, a New Workspace with no directory
    /// carries an empty one, which `launch(_:)` resolves to the Host's home.
    private func makeLaunchDispatch(
        hostID: Host.ID, resolvingHomeAtLaunch: Bool = false
    ) -> Dispatch? {
        let launch: LaunchSelection
        if let launchingServerChat {
            launch = .agent(launchingServerChat.agentKind)
        } else if selectedLaunchIsShell {
            launch = .shell
        } else if let kind = selectedAgentKind {
            launch = .agent(kind)
        } else {
            return nil
        }
        let destination: LaunchDestination
        if launchesServerChat {
            destination = .newWorkspace(NewWorkspaceSpec(
                directory: Self.nonEmptyTrimmed(newWorkspaceDirectory) ?? origin?.cwd ?? "", label: nil))
        } else if origin != nil {
            guard selectedWorkspaceID != nil else { return nil }
            destination = .existingWorkspace
        } else {
            switch launchTarget {
            case .existingWorkspace:
                guard let workspaceID = selectedWorkspaceID else { return nil }
                destination =
                    offersWorktree && startsInNewWorktree
                    ? .newWorktree(worktreeSpec(hostID: hostID, workspaceID: workspaceID))
                    : .existingWorkspace
            case .newWorkspace:
                let directory = Self.nonEmptyTrimmed(newWorkspaceDirectory)
                guard directory != nil || resolvingHomeAtLaunch else { return nil }
                destination = .newWorkspace(
                    NewWorkspaceSpec(
                        directory: directory ?? "",
                        // A herdr-core Workspace is its folder: no name.
                        label: launchesIntoFolder ? nil : Self.nonEmptyTrimmed(newWorkspaceLabel)))
            }
        }
        return Dispatch(
            destination: destination, launch: launch,
            backend: launchingServerChat?.backend ?? launchBackend)
    }

    /// The typed branch as sent, or else the branch minted for this Host,
    /// source Workspace and base: kept from an earlier try with the same
    /// inputs, freshly minted otherwise.
    private func worktreeSpec(hostID: Host.ID, workspaceID: String) -> WorktreeSpec {
        let base = worktreeSpecBase
        if let typed = Self.nonEmptyTrimmed(Self.submittedTypedValue(worktreeBranch)) {
            return WorktreeSpec(branch: typed, base: base)
        }
        let inputs = LaunchRetryIdentityMachine.Inputs(
            hostID: hostID, workspaceID: workspaceID, base: base)
        var branch = ""
        for effect in retryIdentity.handle(.branchNeeded(inputs)) {
            switch effect {
            case .reuse(let kept):
                branch = kept
            case .mint:
                branch = mintWorktreeBranch()
                _ = retryIdentity.handle(.minted(branch, inputs: inputs))
            case .reuseOpenCodeSession:
                break // Only `.openCodeSessionNeeded` asks for it.
            }
        }
        return WorktreeSpec(branch: branch, base: base, branchIsGenerated: true)
    }

    /// `.latestDefaultBranch` while the switch is on; otherwise the typed
    /// Base, or herdr's default (the source checkout's HEAD) when empty.
    private var worktreeSpecBase: WorktreeBase {
        if startsFromLatestMain { return .latestDefaultBranch }
        return Self.nonEmptyTrimmed(worktreeBase).map(WorktreeBase.ref) ?? .sourceHead
    }

    /// Keeps the latest-main choice a successful worktree launch used, so
    /// the next sheet opens with it. Other launches leave it untouched.
    private func rememberWorktreeStart(_ destination: LaunchDestination) {
        guard case .newWorktree(let spec) = destination else { return }
        selections.rememberStartsFromLatestMain(spec.base == .latestDefaultBranch)
    }

    /// The directory a launch asked for: a New Workspace's, else the
    /// origin Agent's; nil for an existing Workspace or a Worktree.
    private func launchDirectory(_ destination: LaunchDestination, originCwd: String?) -> String? {
        if case .newWorkspace(let spec) = destination { return spec.directory }
        return originCwd
    }

    /// Where a chat launch landed, for New Chat's Last Used: the started
    /// Agent's Workspace, labeled as the Console lists it (else as the New
    /// Workspace was named), and its directory, else the launch's own.
    private func chatDestination(
        hostID: Host.ID, agent: Agent, destination: LaunchDestination,
        launchDirectory: String?
    ) -> ChatDestination {
        let newWorkspaceLabel: String? =
            if case .newWorkspace(let spec) = destination { spec.label } else { nil }
        let label =
            workspacesProvider(hostID).first(where: { $0.id == agent.workspaceID })?.label
            ?? newWorkspaceLabel
        let cwd =
            agent.cwd.hasPrefix("/")
            ? agent.cwd : launchDirectory.flatMap { $0.hasPrefix("/") ? $0 : nil }
        return ChatDestination(
            hostID: hostID, workspaceID: agent.workspaceID.isEmpty ? nil : agent.workspaceID,
            workspaceLabel: label, cwd: cwd)
    }

    /// The SwiftUI binding behind the "Agent" picker. Optional on purpose:
    /// a nil selection (detection failed or found nothing, and the user has
    /// not chosen Default Shell) must read as "nothing chosen" rather than
    /// pretending an Agent kind is picked while Start stays disabled.
    /// Choosing an Agent brings a shell's free-form tab label under the
    /// agent-name rule. A preset launch refuses Default Shell.
    var launchSelection: Binding<LaunchSelection?> {
        Binding(
            get: { [self] in
                if selectedLaunchIsShell { return .shell }
                return selectedAgentKind.map(LaunchSelection.agent)
            },
            set: { [self] selection in
                switch selection {
                case .shell:
                    guard offersShell else { return }
                    selectedLaunchIsShell = true
                case .agent(let kind):
                    selectedLaunchIsShell = false
                    selectedAgentKind = kind
                    normalizeNameForAgentLaunch()
                case nil:
                    break
                }
            })
    }

    /// Parses a familiar shell-like argument string into argv without ever
    /// passing it through a shell. Quotes group whitespace, adjacent quoted
    /// and unquoted segments join one argument, and backslash escapes the next
    /// character. Empty quoted arguments are preserved.
    static func parseArguments(_ input: String) -> Result<[String], ArgumentError> {
        enum Quote {
            case single
            case double
        }

        var result: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Quote?
        var escaping = false

        for character in input {
            if escaping {
                guard !isControl(character) else {
                    return .failure(.controlCharacter)
                }
                current.append(character)
                hasCurrent = true
                escaping = false
                continue
            }

            switch quote {
            case .single:
                if character == "'" {
                    quote = nil
                } else {
                    guard !isControl(character) else {
                        return .failure(.controlCharacter)
                    }
                    current.append(character)
                }
                hasCurrent = true
            case .double:
                if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    escaping = true
                } else {
                    guard !isControl(character) else {
                        return .failure(.controlCharacter)
                    }
                    current.append(character)
                }
                hasCurrent = true
            case nil:
                if character == "'" {
                    quote = .single
                    hasCurrent = true
                } else if character == "\"" {
                    quote = .double
                    hasCurrent = true
                } else if character == "\\" {
                    escaping = true
                    hasCurrent = true
                } else if character.isWhitespace {
                    if hasCurrent {
                        result.append(current)
                        current = ""
                        hasCurrent = false
                    }
                } else {
                    guard !isControl(character) else {
                        return .failure(.controlCharacter)
                    }
                    current.append(character)
                    hasCurrent = true
                }
            }
        }

        guard !escaping else { return .failure(.danglingEscape) }
        switch quote {
        case .single: return .failure(.unclosedSingleQuote)
        case .double: return .failure(.unclosedDoubleQuote)
        case nil: break
        }
        if hasCurrent {
            result.append(current)
        }
        return .success(result)
    }

    /// The fallback for an empty name field: the kind itself, then `kind-2`,
    /// `kind-3`, … skipping names already live on the Host. Kind identifiers
    /// are lowercase ASCII, so the result always passes herdr's name rule.
    static func defaultAgentName(for kind: SupportedAgentKind, taken: Set<String>) -> String {
        guard taken.contains(kind.rawValue) else { return kind.rawValue }
        var suffix = 2
        while taken.contains("\(kind.rawValue)-\(suffix)") { suffix += 1 }
        return "\(kind.rawValue)-\(suffix)"
    }

    /// A preset's suggested name, kept while no live Agent on the Host has
    /// it, else `name-2`, `name-3`, … with the base cut so the whole stays
    /// within herdr's 32 characters.
    static func uniqueSuggestedName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var suffix = 2
        while true {
            let tail = "-\(suffix)"
            var stem = String(base.prefix(32 - tail.count))
            while stem.last == "-" { stem.removeLast() }
            let candidate = stem + tail
            if !taken.contains(candidate) { return candidate }
            suffix += 1
        }
    }

    /// Re-picks the preset's suggested name against the selected Host's
    /// live Agents while the field still holds the untouched suggestion.
    private func refreshSuggestedName() {
        guard let presetSuggestedName, let selectedHostID, name == shownSuggestion else { return }
        let unique = Self.uniqueSuggestedName(presetSuggestedName, taken: existingAgentNames(selectedHostID))
        shownSuggestion = unique
        programmatically { name = unique }
    }

    /// The fallback for an empty name field on a shell launch: "Default
    /// Shell", then "Default Shell 2", "Default Shell 3", … skipping names
    /// already carried by Agent tabs on the Host (an Agent's tab is labeled
    /// with its name), so the suggested label never reads as a second
    /// Agent. Tab labels are their own namespace on the wire — the dedup is
    /// purely against visual confusion.
    static func defaultShellName(taken: Set<String>) -> String {
        let base = "Default Shell"
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// Normalizes smart punctuation that arrives through paste or a
    /// third-party keyboard. The editor itself disables these substitutions;
    /// this is a defensive parse-boundary fallback, never an edit-time write.
    static func normalizeSmartPunctuation(_ text: String) -> String {
        guard text.contains(where: Self.isSmartPunctuation) else { return text }
        var result = ""
        result.reserveCapacity(text.count + 2)
        for character in text {
            switch character {
            case "\u{201C}", "\u{201D}":  // curly double quotes
                result.append("\"")
            case "\u{2018}", "\u{2019}":  // curly single quotes
                result.append("'")
            case "\u{2014}":  // em dash, iOS's replacement for "--"
                result.append("--")
            case "\u{2013}":  // en dash
                result.append("-")
            default:
                result.append(character)
            }
        }
        return result
    }

    private static func isSmartPunctuation(_ character: Character) -> Bool {
        switch character {
        case "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "\u{2014}", "\u{2013}":
            true
        default:
            false
        }
    }

    private static func nonEmptyTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func discoveryMessage(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "Agent detection timed out."
        default:
            "Detecting Agents failed: \(error)"
        }
    }

    /// User-facing copy for a failed home-directory probe: the same
    /// TransportError arms the launch path maps, with the probe's subject.
    private static func homeProbeMessage(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected, so its home directory could not be resolved."
        case TransportError.timedOut:
            "Resolving the Host's home directory timed out."
        default:
            "Could not determine the Host's home directory: \(error)"
        }
    }

    /// How launch failures name `hostID`'s Host.
    private func hostName(_ hostID: Host.ID) -> String {
        hosts.first { $0.id == hostID }?.displayName ?? "the Host"
    }

    /// User-facing copy for a failed launch; a Closed Session's resume
    /// reports its failures the same way. `backend` names who rejected it.
    static func message(
        for error: any Error, launchedKind: SupportedAgentKind?,
        backend: HostBackend = .herdr
    ) -> String {
        // A launch the Host's connection kept from going out reads as its
        // cause.
        let error = RequestNotSentError.unwrapped(error)
        return switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case LaunchPromptError.stagingFailed(let hostName, let chatPrompt):
            "Waycar couldn't write the \(chatPrompt ? "Chat Prompt" : "first message") to \(hostName)."
        case LaunchPromptError.launchLineTooLong(let bytes):
            "The launch command is \(bytes) bytes, more than the \(LaunchPromptStager.typedLineBudget) "
                + "a new pane can take. Shorten the Arguments or the model."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case WorktreeBaseResolutionError.linkedWorktreeSource:
            "This workspace is itself a worktree. "
                + "Start new worktrees from the repository's main workspace."
        case let error as WorktreeBaseResolutionError:
            "Couldn't get the latest main from origin: \(error.detail). "
                + "Try again, or turn off \(latestMainToggleTitle) "
                + "to use the Host's current checkout."
        case let error as WorktreeLaunchError:
            error.message
        case let apiError as HerdrAPIError where apiError.code == "not_git_worktree":
            // The one dedicated worktree.create error code (#97); everything
            // else collapses into worktree_create_failed with raw git stderr,
            // which the passthrough below surfaces as-is.
            "This workspace is not inside a Git repository, so no worktree can be created from it."
        case let apiError as HerdrAPIError where apiError.code == "worktree_create_failed":
            "Creating the worktree failed: \(apiError.message)"
        case let apiError as HerdrAPIError
            where apiError.code == "unsupported_agent_kind" && launchedKind == .muse
            && backend == .herdr:
            // Kind captured at submit, not the picker after await. Discovery
            // does not prove herdr supports Muse (#289); keep the server
            // reason and tell the user how to recover.
            "\(HostBackend.herdr.displayName) rejected the command: \(apiError.message). "
                + "Update herdr on this Host to v0.9.0 or later for Muse support, "
                + "or choose another supported Agent."
        case let apiError as HerdrAPIError
            where backend == .core
            && ["agent_start_failed", "folder_not_found", "invalid_argument"].contains(apiError.code):
            // herdr-core's launch failures are already worded for the user
            // ("claude is not installed on this Host, or is not on its PATH").
            apiError.message
        case let apiError as HerdrAPIError:
            "\(backend.displayName) rejected the command: \(apiError.message)"
        default:
            // A shell launch has no agent to blame: the failure is the Host
            // refusing the tab or workspace itself.
            launchedKind == nil
                ? "Starting the shell failed: \(error)"
                : "Starting the agent failed: \(error)"
        }
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
