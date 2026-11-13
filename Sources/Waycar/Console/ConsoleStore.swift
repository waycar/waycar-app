import Foundation
import Observation
import Synchronization
import os

/// A note left for one Agent's next screen, taken once: a new note
/// replaces the last, and one older than `lifetime` is dropped unread.
struct AgentOneShot<Value> {
    let lifetime: TimeInterval
    private var pending: (id: ConsoleAgent.ID, value: Value, at: Date)?

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    mutating func leave(_ value: Value, for id: ConsoleAgent.ID, at now: Date) {
        pending = (id, value, now)
    }

    mutating func take(for id: ConsoleAgent.ID, at now: Date) -> Value? {
        guard let note = pending, note.id == id else { return nil }
        pending = nil
        return now.timeIntervalSince(note.at) <= lifetime ? note.value : nil
    }
}

/// The Console aggregate: reconciles the Host catalog and publishes one
/// Agent list ordered by Agent Status across Hosts, with Pins first. Each HostConsoleProjection
/// owns its own convergence, retry, snippets and Host-scoped RPC behavior.
@MainActor
@Observable
final class ConsoleStore {
    struct AgentStatusUpdate: Sendable, Equatable {
        let status: AgentStatus?
        let liveUpdatesAvailable: Bool
    }

    private(set) var agents: [ConsoleAgent] = []
    /// The Agent whose Chat view raises its keyboard next (New Chat).
    @ObservationIgnored private var chatInputFocusRequest = AgentOneShot<Void>(
        lifetime: ConsoleStore.chatInputFocusLifetime)
    /// The Agent the New Agent sheet just opened: its terminal's Ignition
    /// echoes the launch (#96).
    @ObservationIgnored private var agentLaunchNote = AgentOneShot<AgentLaunchNote>(
        lifetime: ConsoleStore.agentLaunchLifetime)
    /// The one-shot slots' clock; tests replace it.
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    /// Per Host, the connection the Host presents (`leadProjection`). On a
    /// Host running herdr and tmux (ADR 0026) that is herdr's while the tmux
    /// projection lists no sessions, so a herdr user whose OS ships tmux sees
    /// exactly today's states; otherwise Connected while either projection
    /// is, and Failed only when both are, presenting herdr's failure. The
    /// same projection supplies the Host's Standing Failure, latency, sync
    /// error and verification below; `scopeStatuses` and friends keep each
    /// projection's own.
    private(set) var hostStatuses: [Host.ID: EventsSessionStatus] = [:]
    private(set) var hostStandingFailures: [Host.ID: TransportError] = [:]
    private(set) var hostLatencies: [Host.ID: Duration] = [:]
    private(set) var hostSyncErrors: [Host.ID: String] = [:]
    /// The connection generation of each Host's primary projection (herdr
    /// when present, else tmux): the one Host-level exec features ride.
    /// `scopeConnectionGenerations` has every projection's.
    private(set) var hostConnectionGenerations: [Host.ID: UInt64] = [:]
    /// Hosts whose rows still await verification by a snapshot taken on
    /// their current connection. Until then the rows are the last-known Agent
    /// Inventory (or, with none, an unknown one), not proof of what the Host
    /// has now.
    private(set) var hostsAwaitingSnapshot: Set<Host.ID> = []
    /// Unverified Hosts whose last-known rows are on screen and whose
    /// connection work is still inside `reconnectGrace`. Their ordinary
    /// connecting, reconnecting and loading conditions stay quiet; a failure
    /// that needs the user shows regardless.
    private(set) var hostsWithinReconnectGrace: Set<Host.ID> = []
    /// Hosts whose connection is held because the Host (or its Jump Host)
    /// answered with a key not trusted yet. The Console row asks the user to
    /// trust it on the Host page; the session connects on its own once a key
    /// is trusted.
    private(set) var hostKeyTrustHolds: [Host.ID: HostKeyTrustHold] = [:]
    /// Each Console projection's own connection status, Standing Failure,
    /// connection generation and verification (ADR 0026): a Host whose herdr
    /// failed while its tmux serves shows herdr's failure from these.
    private(set) var scopeStatuses: [ConsoleScope: EventsSessionStatus] = [:]
    private(set) var scopeStandingFailures: [ConsoleScope: TransportError] = [:]
    /// The backend whose projection each Host presents (`hostStatuses`).
    private(set) var hostLeadBackends: [Host.ID: HostBackend] = [:]
    private(set) var scopeConnectionGenerations: [ConsoleScope: UInt64] = [:]
    private(set) var scopesAwaitingSnapshot: Set<ConsoleScope> = []
    /// Each Host's backends as last detected, or as the last detection left
    /// them in the inventory cache. Absent until either says.
    private var backendDetections: [Host.ID: BackendDetectionMachine] = [:]
    var backendPresences: [Host.ID: HostBackendPresence] {
        backendDetections.compactMapValues(\.presence)
    }
    /// The user's starts of a stopped runtime (#389) in flight: the start
    /// itself, then the reconnect it asks for, until that settles.
    private var runtimeStarts: [ConsoleScope: RuntimeStartMachine] = [:]
    var runtimeStartsInFlight: Set<ConsoleScope> {
        Set(runtimeStarts.compactMap { $0.value.isStarting ? $0.key : nil })
    }
    /// What the last failed start of each scope's runtime said. A new start
    /// clears it, and so do the scope connecting and the Host leaving.
    var runtimeStartErrors: [ConsoleScope: String] {
        runtimeStarts.compactMapValues(\.error)
    }
    /// The scopes that have a projection now: `presentBackends(on:)`'s
    /// observable source.
    private var projectedScopes: Set<ConsoleScope> = []
    /// Latest snapshot workspaces by Host, herdr's then tmux's. This is
    /// observable state rather than a projection lookup so an open New Agent
    /// picker refreshes when a snapshot arrives or a workspace membership
    /// event resyncs the Host.
    private(set) var workspacesByHost: [Host.ID: [ConsoleWorkspace]] = [:]
    /// Successful or snapshot-reconciled removals keyed by the exact Agents
    /// that belonged to the validated worktree. This survives their rows
    /// disappearing so Agent detail can show a stable result.
    private(set) var removedWorktreesByAgent: [
        ConsoleAgent.ID: WorktreeRemovalReceipt
    ] = [:]
    /// One projection per Host and present backend (ADR 0026).
    @ObservationIgnored var projections: [ConsoleScope: HostConsoleProjection] = [:] {
        didSet {
            let scopes = Set(projections.keys)
            if projectedScopes != scopes { projectedScopes = scopes }
        }
    }
    /// The Host catalog as last set: what a projection a detection asks for
    /// starts with.
    @ObservationIgnored var catalog: [Host.ID: Host] = [:]
    /// Effects only; scheduling, cache age and ownership live in the machine.
    @ObservationIgnored private var detectionTasks: [Host.ID: [UInt64: Task<Void, Never>]] = [:]
    /// Terminal runtimes share notify.json: one FIFO owns their writes and the
    /// once-per-launch core default claim. Tasks are token-keyed effects only.
    @ObservationIgnored private var notificationVisibilityWrites:
        [Host.ID: NotificationVisibilityWriteMachine] = [:]
    @ObservationIgnored private var notificationConfigWrites:
        [Host.ID: [UInt64: Task<Void, Never>]] = [:]
    /// Skills probed per Host connection: keyed on the connection generation
    /// so a reconnect naturally invalidates, and evicted per Host on insert
    /// so stale generations cannot accumulate.
    @ObservationIgnored private var skillsCache: [SkillsCacheKey: [AgentSkill]] = [:]
    /// Each Host's mosh eligibility (MOSH-02): what is known per connection
    /// generation, the automatic fallback or the user's SSH choice, the
    /// generation already probed or answered from memory, and the capsule's
    /// re-probe in flight. `sendMosh` feeds it.
    @ObservationIgnored var moshEligibility = MoshEligibilityMachine()
    /// mosh availability per Host, as `moshEligibility` knows it: the
    /// connection generation's probe, the outcome remembered for the network
    /// the device is on (#105), or what a mosh session's first contact
    /// proved. A thrown probe caches unavailable — SSH stays the backbone,
    /// mosh only upgrades the Agent terminal when it is demonstrably there.
    /// Tracked on purpose: mosh compatibility is a Host property, so the
    /// Console index's per-Host capsule reads this dict live. Only
    /// `sendMosh` writes it.
    var moshStates: [Host.ID: MoshProbeOutcome] = [:]
    /// Remembered mosh outcomes, standbys, the network path and the running
    /// mosh sessions (#105); `installMoshFastPath` puts in the app's.
    @ObservationIgnored var moshFastPath = MoshFastPath()
    /// The Agent each Host's speculative standby is kept for: the one last
    /// opened, or named by a notification or link (#105).
    @ObservationIgnored var standbyAgents: [Host.ID: ConsoleAgent.ID] = [:]
    /// The layout of the window each Host's standby Agent was last opened
    /// in; none for one a notification or link named.
    @ObservationIgnored var standbyLayouts:
        [Host.ID: @MainActor () -> TerminalGridSizeMemory.Layout?] = [:]
    @ObservationIgnored var speculativeStandbys: [Host.ID: SpeculativeStandby] = [:]

    /// Mosh availability invalidated by a failed handshake or the user's
    /// "Use SSH Instead" (`invalidateMosh(for:cause:)`), and for which
    /// connection generation (`moshInvalidations`, from `moshEligibility`).
    /// The in-flight background probe for that generation must not override
    /// the invalidation; only the next connection generation may re-probe
    /// after an automatic fallback. The user's choice holds across
    /// connection generations and network changes alike — it is not the
    /// connection's or the network's — until the capsule's re-probe asks
    /// again (#105).
    struct MoshInvalidationRecord {
        let generation: UInt64
        let cause: MoshInvalidationCause
    }

    /// When each Host last redialled because its mosh server answered again
    /// after a stall (#105), and how soon after one it may ask again: the
    /// debounce of `moshServerAnsweredAfterStall(on:)`.
    @ObservationIgnored var moshRecoveryRedials: [Host.ID: ContinuousClock.Instant] = [:]
    @ObservationIgnored var moshRecoveryRedialInterval: Duration = .seconds(2)

    /// The Hosts with a capsule re-probe in flight, as `moshEligibility`
    /// holds them: a second tap is a no-op instead of piling up duplicate
    /// probes, and each re-probe's token fences a Host removed and re-added
    /// mid-probe, so the stale probe does not end the new one. Tracked: the
    /// capsule renders its spinner from this. Only `sendMosh` writes it.
    var moshReprobingHosts: Set<Host.ID> = []

    /// Each Host's in-flight mosh probe; a network change cancels them all
    /// (#105): what they would find held for the network they began on.
    @ObservationIgnored var moshProbeTasks: [Host.ID: Task<Void, Never>] = [:]

    /// Status events already converge through each Host's one pane-scoped
    /// subscription. Composers consume this fan-out instead of opening a
    /// second events channel that could outlive the connection snapshot.
    @ObservationIgnored private var agentStatusObservers: [
        ConsoleAgent.ID: [UUID: AsyncStream<AgentStatusUpdate>.Continuation]
    ] = [:]
    /// Composer ownership sits above the detail branch so a transient
    /// missing-Agent placeholder during reconnect cannot destroy a draft.
    @ObservationIgnored private var composerStores: [
        ConsoleAgent.ID: AgentComposerStore
    ] = [:]
    /// Shell row Composers, kept apart from Agent Composers: a shell Pane
    /// that later runs an Agent must not inherit a `pane.send_input`
    /// delivery, nor an Agent Composer lose its `agent.prompt` one.
    @ObservationIgnored private var shellComposerStores: [
        ConsoleAgent.ID: AgentComposerStore
    ] = [:]
    /// Where Agent Composers keep their Queued Messages (CONTEXT.md
    /// **Queued Message**): Application Support in the app, a scratch folder
    /// deleted with this store otherwise.
    @ObservationIgnored let queuedMessageStore: QueuedMessageStore
    @ObservationIgnored private nonisolated let queuedMessageScratch: URL?
    /// Each Agent's queued and held messages, for its row badge.
    private(set) var queuedMessageCounts: [ConsoleAgent.ID: Int] = [:]
    /// The connection generation each Composer's queue last drained on: a
    /// verified projection on a new one (a reconnect) drains it again.
    @ObservationIgnored private var queueDrainGenerations: [ConsoleAgent.ID: UInt64] = [:]
    /// Hosts whose Queued Messages were read from the device this launch.
    @ObservationIgnored private var queueRestoredHosts: Set<Host.ID> = []
    /// Where New Agent Starts taken while their Host had no verified
    /// connection wait (CONTEXT.md **Queued Launch**): Application Support
    /// in the app, a scratch folder deleted with this store otherwise.
    @ObservationIgnored let queuedLaunchStore: QueuedLaunchStore
    @ObservationIgnored private nonisolated let queuedLaunchScratch: URL?
    /// Every catalogued Host's Queued Launches, oldest first.
    private(set) var queuedLaunches: [QueuedLaunch] = []
    /// Kept separate from live Composers: no status observer, badge or Host
    /// reconciliation may touch a launch's entirely local queue.
    @ObservationIgnored private var pendingComposerStores: [QueuedLaunch.ID: AgentComposerStore] = [:]
    /// Lets a pending detail follow the Agent its launch actually started.
    private(set) var startedAgentsByQueuedLaunch: [QueuedLaunch.ID: ConsoleAgent.ID] = [:]
    /// Scheduling and generation allowance for each Host's Queued Launches.
    @ObservationIgnored private var launchDrainMachines: [Host.ID: QueuedLaunchDrainMachine] = [:]
    /// Each Host's Queued Launch replay, one at a time per Host. Cancelled
    /// when the Host's launches are deleted (a new address or user, or the
    /// Host removed), so none of them starts on what replaced it.
    @ObservationIgnored private var launchDrains:
        [Host.ID: (token: UInt64, task: Task<Void, Never>)] = [:]
    /// Hosts whose Queued Launches were read from the device this launch.
    @ObservationIgnored private var launchRestoredHosts: Set<Host.ID> = []
    /// Waits out a Queued Message retry backoff; tests replace it.
    @ObservationIgnored var queueRetrySleep: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }
    /// Allow and Deny answers taken while a Host could not be reached, sent
    /// once it can and the same prompt is still on screen (CONTEXT.md
    /// **Queued Answer**).
    let blockedAnswers = BlockedAnswerQueue()
    /// The connection generation each Queued Answer last tried on: one try
    /// per verified connection, like the Composer's queue.
    @ObservationIgnored private var blockedAnswerGenerations: [UUID: UInt64] = [:]
    /// Queued Answers with a replay running.
    @ObservationIgnored private var blockedAnswersInFlight: Set<UUID> = []
    @ObservationIgnored private let makeSession:
        @Sendable (Host, HostBackend, [EventSubscription]) -> EventsSession
    @ObservationIgnored private let backendDetector:
        @Sendable (Host) async throws -> HostBackendPresence
    /// Whether a stopped server chat runtime now answers, without a
    /// detection exec (`sshServerRuntimeProbe`).
    @ObservationIgnored private let serverRuntimeProbe:
        @Sendable (Host, ServerChatBackend, HostBackendPresence) async throws -> Bool
    /// Starts a stopped runtime on a Host (#389). Only `startRuntime(_:on:)`
    /// calls it, on the user's Start Herdr TUI, Herdr Core or Start … server
    /// of a server chat runtime (Codex).
    @ObservationIgnored private let runtimeStarter:
        @Sendable (Host, HostBackend) async throws -> Void
    @ObservationIgnored private let snapshotRetryDelay: Duration
    @ObservationIgnored private let summaryRefreshTiming: AgentSummaryRefreshTiming
    /// Handed to every Host's projection: Agent Summaries refresh only with
    /// the app in the foreground and AI summaries on.
    @ObservationIgnored private var summaryRefreshGate = AgentSummaryRefreshGate()
    @ObservationIgnored private let shellActivityTiming: ShellActivityTiming
    /// Handed to every Host's projection: Shell Activity is swept only while
    /// a phone or iPad window is on screen, whatever the summaries setting.
    /// Off until the window's `.active` scene phase says so, so a CarPlay-only
    /// launch never sweeps.
    @ObservationIgnored private var isShellActivityForeground = false
    var isActive: Bool { activation.isActive }
    /// Whether the Console is active, its chain of lifecycle transitions,
    /// and each network path follow's last reading.
    @ObservationIgnored private var activation = ConsoleActivationMachine()
    /// The lifecycle transitions not yet finished, by token. Suspend and
    /// resume are each several awaits long, so without a chain a resume
    /// racing a suspend can finish first and leave every Host suspended with
    /// nothing left to re-activate it.
    @ObservationIgnored private var lifecycleTasks: [UInt64: Task<Void, Never>] = [:]
    /// Follows the app's network path (`followNetworkPath`, #105).
    @ObservationIgnored private var networkPathTask: Task<Void, Never>?
    /// The followed path, from its baseline reading on, is none: the device
    /// has no usable network, so a Composer prompt queues at once
    /// (`VerificationPatience.failsFastOffline`) and a terminal that cannot
    /// connect says the device is offline. Observed, so a screen showing
    /// that follows the network coming and going.
    private(set) var hasLostNetworkPath = false

    /// The device has a usable network. True where no path is followed (the
    /// unit-test host, a demo): the app then never claims to be offline.
    var hasNetwork: Bool { !hasLostNetworkPath }
    /// Shared with the Console list: a pin toggle must re-sort `agents` in
    /// the same turn, so the store lives here rather than only on the view.
    let pins: PinnedAgentsStore
    /// Same-turn re-sort as `pins`: marking an Agent unread moves its row
    /// into the Done bucket at once.
    let unread: UnreadAgentsStore
    /// Agents that left their Pane (CONTEXT.md **Closed Session**): each
    /// projection's captures land here, and every rebuild tells it which
    /// sessions the listed rows run, so a live one is not listed as closed.
    let closedSessions: ClosedSessionsStore
    /// Which Agents run in Chat Mode: each Host's Chat Markers, refreshed
    /// on its connection (`scheduleChatModeMarkerReads`), plus the ones
    /// this device just launched, less the ones whose chat Agent closed
    /// (`agentsDidClose`).
    let chatMode: ChatModeStore
    let rowLayouts: AgentRowLayoutStore
    /// Per Host: the New Agent default and whether tmux sessions are listed
    /// (ADR 0026). Outside `Host`, so changing them keeps the Host's
    /// projections and terminals.
    let backendPreferences: HostBackendPreferences
    let sidebarSnapshots = HerdrSidebarSnapshotStore()
    let agentTerminals: AgentTerminalCache
    @ObservationIgnored private var terminalSnapshotRevisions: [ConsoleScope: UInt64] = [:]
    @ObservationIgnored private var terminalTransportGenerations: [ConsoleScope: UInt64] = [:]
    @ObservationIgnored private let inventoryCache: ConsoleInventoryCache?
    /// Each Agent's last transcript, kept on this device so a chat opens with
    /// its bubbles before the Host answers and the terminal screen can offer
    /// the conversation to read offline; nil keeps none.
    @ObservationIgnored let chatTranscriptCache: ChatTranscriptCache?
    /// Counts what each Agent's kept transcript changed, so a screen offering
    /// it to read (`savedTranscript(for:)`) knows when to look again.
    private(set) var savedTranscriptRevisions: [ConsoleAgent.ID: Int] = [:]
    /// Reads the transcripts of the Agents most recently finished, for
    /// offline reading; nil without `chatTranscriptCache`.
    @ObservationIgnored private var transcriptPrefetcher: ChatTranscriptPrefetcher?
    /// The images and videos chats have shown, kept on this device; nil
    /// fetches every time into `chatMediaScratchDirectory`.
    @ObservationIgnored let chatMediaCache: ChatMediaCache?
    /// Where fetched chat media land without a cache: private to this store
    /// and deleted with it (`deinit`), so no store leaves files behind.
    @ObservationIgnored private nonisolated let chatMediaScratchDirectory = FileManager.default
        .temporaryDirectory
        .appending(path: "ChatMedia-\(UUID().uuidString)", directoryHint: .isDirectory)
    /// Chat media fetches in flight by cache key, so one item shown twice
    /// (or tapped while its thumbnail loads) is fetched once.
    @ObservationIgnored private var chatMediaLoads: [String: Task<URL, any Error>] = [:]
    /// Each Host's home, for `~/` chat media paths; a Host's home does not change.
    @ObservationIgnored private var chatMediaHomes: [Host.ID: String] = [:]
    /// Each Host's chat media transfer limit.
    @ObservationIgnored private var chatMediaTransfers: [Host.ID: ChatMediaTransfers] = [:]
    /// Resolves a Host's home for `~/` chat media paths; tests replace it.
    @ObservationIgnored var resolveChatMediaHome: @MainActor (Host.ID) async throws -> String = { _ in
        throw ChatMediaError.unavailable
    }
    @ObservationIgnored private var persistedInventories: [ConsoleScope: PersistedInventory] = [:]
    @ObservationIgnored private let reconnectGrace: Countdown
    @ObservationIgnored private let verificationTimeout: Countdown
    @ObservationIgnored private var reconnectGraceStates: [Host.ID: ReconnectGraceState] = [:]
    /// Each Host's Chat Marker reads: when the last one started, and the
    /// read or the wait for the next one in flight.
    @ObservationIgnored private var chatModeMarkerReads: [Host.ID: ChatModeMarkerReads] = [:]
    /// Host-scoped work waiting for its Host's rows to be verified.
    @ObservationIgnored private var verificationWaiters: [UUID: VerificationWaiter] = [:]
    /// Swiped Closes by row. The row renders the countdown from this.
    /// `undoTabClose` removes a counting entry; a sent close stays `.closing`
    /// until its row leaves `agents` (`rebuild` prunes it then) or
    /// `tab.close` fails, so the closed row never flashes back to a card.
    /// Published from `tabCloses` only when its Closes change, so a Close
    /// event that changes nothing re-renders nothing.
    private(set) var pendingTabCloses: [ConsoleAgent.ID: PendingTabClose] = [:]
    @ObservationIgnored private var tabCloses = PendingTabCloseMachine()
    /// Each counting Close's countdown.
    @ObservationIgnored private var tabCloseTasks: [ConsoleAgent.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private let tabCloseUndoWindow: Countdown
    @ObservationIgnored private let rowDepartureWindow: Countdown
    /// `tab.close` failure text from a countdown that ran out; non-nil shows
    /// the Console's error alert.
    var tabCloseFailure: String?
    /// The rows sent swiped Closes just took off `agents` — each Close's
    /// own row and every other row on its tab — newest Close first, each
    /// Close's rows in their last listed order. The index keeps listing them
    /// until their `rowDepartureWindow` ends, so the Console list can lift
    /// each card out of its place and then delete the row, the rows below
    /// gliding up, instead of dropping it in one frame. Only the index reads
    /// these.
    private(set) var departingRows: [DepartingRow] = []
    /// The Review Prompt's local history (nil in the demo and previews,
    /// which never ask). Fed by successful phone-side actions only.
    @ObservationIgnored private(set) var reviewPrompt: ReviewPromptStore?
    /// Told when the user steers an Agent: a Composer message delivered to
    /// it, or Allow or Cancel sent to a Blocked card. The app model points
    /// it at analytics; nil in tests and previews that never install one.
    @ObservationIgnored var onSteer: (@MainActor () -> Void)?

    /// How long a swiped Close can be undone before `tab.close` is sent.
    static let tabCloseUndoSeconds: TimeInterval = 5
    /// How long `departingRows` stay listed by default: longer than the
    /// Console list's lift, so the list has deleted each row itself by the
    /// time the index stops listing it.
    static let rowDepartureHold: Duration = .milliseconds(500)
    /// The least time between two Chat Marker reads of one Host.
    static let chatModeMarkerRefreshInterval: TimeInterval = 30
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "ConsoleStore")

    /// A swiped Close: counting down (undoable) until `deadline`, then
    /// closing while `tab.close` is in flight.
    struct PendingTabClose: Equatable {
        enum Phase: Equatable { case counting, closing }
        let agent: ConsoleAgent
        let deadline: Date
        var phase: Phase
    }

    /// A row a sent swiped Close took, as the index last listed it.
    struct DepartingRow: Equatable {
        let agent: ConsoleAgent
        /// Its own swiped Close, if it had one, so the card lifts away as it
        /// was drawn: still slid aside over the disc.
        let pendingClose: PendingTabClose?
        /// The row listed just above it then, so it lifts away in place.
        let anchor: ConsoleAgent.ID?
    }

    private struct TabKey: Hashable {
        let hostID: Host.ID
        let tabID: String

        init(_ agent: ConsoleAgent) {
            hostID = agent.hostID
            tabID = agent.agent.tabID
        }
    }

    private struct PersistedInventory: Equatable {
        let liveSnapshotRevision: UInt64
        let sidebarLayout: ConsoleInventoryCache.SidebarLayout?
    }

    private enum ReconnectGraceState {
        case verified
        case running(token: UUID, task: Task<Void, Never>)
        case elapsed
    }

    /// One server chat launch's optional terminal failed; its session
    /// remains usable. Cleared when the user leaves that chat, never saved
    /// to disk.
    private(set) var serverLaunchNotices: [ConsoleAgent.ID: String] = [:]

    func dismissServerLaunchNotice(for id: ConsoleAgent.ID) {
        serverLaunchNotices.removeValue(forKey: id)
    }

    private struct ChatModeMarkerReads {
        /// The Host's verifications and the read in flight; its tokens name
        /// this entry, so a Task from a removed entry never ends a newer one.
        var machine: ChatMarkerReadMachine
        /// The read, or the wait for it, the machine holds.
        var task: Task<Void, Never>?
        /// The primary projection, by backend and connection, whose
        /// transport answered `pluginNotInstalled` for markers.
        var markerless: MarkerlessProjection?
    }

    /// Numbers each `ChatModeMarkerReads` entry for its machine's tokens.
    @ObservationIgnored private var chatModeMarkerReadEntries: UInt64 = 0

    private func newChatModeMarkerReads() -> ChatModeMarkerReads {
        chatModeMarkerReadEntries &+= 1
        return ChatModeMarkerReads(machine: ChatMarkerReadMachine(entry: chatModeMarkerReadEntries))
    }

    /// A projection on one connection: a reconnect gets a new generation.
    private struct MarkerlessProjection: Equatable {
        let backend: HostBackend
        let transportGeneration: UInt64
    }

    private typealias VerificationPatience = InventoryVerificationMachine.Patience

    private struct VerificationWaiter {
        let hostID: Host.ID
        /// The backend whose projection must verify; nil is the Host's
        /// primary projection.
        let backend: HostBackend?
        var machine = InventoryVerificationMachine()
        let settle: @MainActor (Result<HostConsoleProjection, any Error>) -> Void
        var timeout: Task<Void, Never>?
    }

    /// A wait the store counts down: the reconnect grace, how long an
    /// Agent-scoped RPC waits for its Host's rows to be verified, a swiped
    /// Close's undo window, or how long its departing rows stay listed. A
    /// value rather than a closure parameter so a trailing session factory
    /// still binds to `makeSession`; tests elapse it by hand.
    struct Countdown: Sendable {
        let wait: @Sendable () async throws -> Void

        static func after(_ duration: Duration) -> Countdown {
            Countdown { try await Task.sleep(for: duration) }
        }
    }

    /// - Parameters:
    ///   - inventoryCache: where last-known inventories persist between
    ///     launches; nil keeps them in memory only.
    ///   - chatTranscriptCache: where Chat Mode transcripts persist between
    ///     launches; nil keeps none, so a chat waits for its Host's read.
    ///   - chatMediaCache: where the images and videos chats show persist;
    ///     nil fetches them every time into a temporary directory.
    ///   - queuedMessages: where Queued Messages persist between launches;
    ///     nil keeps them in a scratch folder deleted with this store.
    ///   - queuedLaunches: where Queued Launches persist between launches;
    ///     nil keeps them in a scratch folder deleted with this store.
    ///   - reconnectGrace: how long an unverified Host with last-known rows
    ///     stays quiet before its connection condition is shown.
    ///   - verificationTimeout: how long an Agent-scoped RPC waits for its
    ///     Host's rows to be verified before failing with `.timedOut`.
    ///   - summaryRefreshTiming: how often each Host refreshes its Agent
    ///     Summaries, and how long it waits to re-read them.
    ///   - shellActivityTiming: how often each Host sweeps its Shell
    ///     Activity while the app is on screen.
    ///   - tabCloseUndoWindow: how long a swiped Close stays undoable.
    ///   - rowDepartureWindow: how long the rows a sent swiped Close took
    ///     stay listed in the index, lifting away.
    ///   - makeSession: one backend's events session for a Host; nil is the
    ///     production SSH factory, remembering what each Host's connections
    ///     prove (`$HOME`, protocol version) in `inventoryCache`.
    ///   - detectBackends: which backends a Host has (ADR 0026). The default
    ///     reports herdr only, as every Host had before tmux support.
    ///   - startRuntime: starts a stopped Herdr TUI or Herdr Core on a Host
    ///     (#389), only for the user's Start; the default starts nothing.
    init(
        snapshotRetryDelay: Duration = .seconds(2),
        summaryRefreshTiming: AgentSummaryRefreshTiming = AgentSummaryRefreshTiming(),
        shellActivityTiming: ShellActivityTiming = ShellActivityTiming(),
        pins: PinnedAgentsStore = PinnedAgentsStore(),
        unread: UnreadAgentsStore = UnreadAgentsStore(),
        closedSessions: ClosedSessionsStore = ClosedSessionsStore(),
        chatMode: ChatModeStore = ChatModeStore(),
        rowLayouts: AgentRowLayoutStore = AgentRowLayoutStore(),
        backendPreferences: HostBackendPreferences = HostBackendPreferences(),
        inventoryCache: ConsoleInventoryCache? = nil,
        chatTranscriptCache: ChatTranscriptCache? = nil,
        chatMediaCache: ChatMediaCache? = nil,
        queuedMessages: QueuedMessageStore? = nil,
        queuedLaunches: QueuedLaunchStore? = nil,
        reconnectGrace: Countdown = .after(.seconds(10)),
        verificationTimeout: Countdown = .after(SSHTransportSettings.defaultRequestTimeout),
        tabCloseUndoWindow: Countdown = .after(.seconds(ConsoleStore.tabCloseUndoSeconds)),
        rowDepartureWindow: Countdown = .after(ConsoleStore.rowDepartureHold),
        makeSession: (@Sendable (Host, HostBackend, [EventSubscription]) -> EventsSession)? =
            nil,
        detectBackends: @escaping @Sendable (Host) async throws -> HostBackendPresence = { _ in
            .herdrOnly
        },
        probeServerRuntime: @escaping @Sendable (Host, ServerChatBackend, HostBackendPresence) async throws
            -> Bool = { _, _, _ in false },
        startRuntime: @escaping @Sendable (Host, HostBackend) async throws -> Void = { _, _ in },
        trustHolds: HostKeyTrustHoldReporter = .shared
    ) {
        agentTerminals = AgentTerminalCache()
        self.snapshotRetryDelay = snapshotRetryDelay
        self.summaryRefreshTiming = summaryRefreshTiming
        self.shellActivityTiming = shellActivityTiming
        self.pins = pins
        self.unread = unread
        self.closedSessions = closedSessions
        self.chatMode = chatMode
        self.rowLayouts = rowLayouts
        self.backendPreferences = backendPreferences
        self.inventoryCache = inventoryCache
        self.chatTranscriptCache = chatTranscriptCache
        self.chatMediaCache = chatMediaCache
        if let queuedMessages {
            queuedMessageStore = queuedMessages
            queuedMessageScratch = nil
        } else {
            let scratch = FileManager.default.temporaryDirectory
                .appending(path: "QueuedMessages-\(UUID().uuidString)", directoryHint: .isDirectory)
            queuedMessageStore = QueuedMessageStore(directory: scratch)
            queuedMessageScratch = scratch
        }
        if let queuedLaunches {
            queuedLaunchStore = queuedLaunches
            queuedLaunchScratch = nil
        } else {
            let scratch = FileManager.default.temporaryDirectory
                .appending(path: "QueuedLaunches-\(UUID().uuidString)", directoryHint: .isDirectory)
            queuedLaunchStore = QueuedLaunchStore(directory: scratch)
            queuedLaunchScratch = scratch
        }
        self.reconnectGrace = reconnectGrace
        self.verificationTimeout = verificationTimeout
        self.tabCloseUndoWindow = tabCloseUndoWindow
        self.rowDepartureWindow = rowDepartureWindow
        // The production factory remembers what each Host's connections
        // prove in the same cache as its inventory (#105).
        self.makeSession =
            makeSession ?? ConsoleStore.sshSessionFactory(connectionMemory: inventoryCache)
        backendDetector = detectBackends
        serverRuntimeProbe = probeServerRuntime
        runtimeStarter = startRuntime
        closedSessions.chatModeLookup = { [chatMode] row in
            !row.backend.hasTerminal || chatMode.isChatMode(row)
        }
        // Another device's Show tmux sessions choice starts or ends the
        // Host's tmux projection here too.
        backendPreferences.onReload = { [weak self] in self?.reconcileAllBackends() }
        chatTranscriptCache?.prune(olderThan: .seconds(30 * 24 * 3600))
        if let chatTranscriptCache {
            transcriptPrefetcher = makeTranscriptPrefetcher(keeping: chatTranscriptCache)
        }
        chatMediaCache?.prune(olderThan: .seconds(30 * 24 * 3600))
        // Once per process, not per store: a later store must not delete
        // a live sibling's folder, but the first one clears what killed
        // processes left (their `deinit` never ran).
        if !Self.sweptChatMediaScratch {
            Self.sweptChatMediaScratch = true
            Self.removeStaleChatMediaScratch(keeping: chatMediaScratchDirectory)
        }
        resolveChatMediaHome = { [weak self] hostID in
            guard let self else { throw CancellationError() }
            return try await self.remoteHomeDirectory(on: hostID)
        }
        let holds = trustHolds.updates()
        Task { [weak self] in
            for await (hostID, hold) in holds {
                guard let self else { return }
                if self.hostKeyTrustHolds[hostID] != hold {
                    self.hostKeyTrustHolds[hostID] = hold
                }
            }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: chatMediaScratchDirectory)
        if let queuedMessageScratch { try? FileManager.default.removeItem(at: queuedMessageScratch) }
        if let queuedLaunchScratch { try? FileManager.default.removeItem(at: queuedLaunchScratch) }
    }

    private static var sweptChatMediaScratch = false

    /// Deletes every `ChatMedia-*` scratch folder in the temporary
    /// directory but `current`.
    private nonisolated static func removeStaleChatMediaScratch(keeping current: URL) {
        let manager = FileManager.default
        let root = current.deletingLastPathComponent()
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        let keep = current.standardizedFileURL.lastPathComponent
        for entry in entries
        where entry.lastPathComponent.hasPrefix("ChatMedia-") && entry.lastPathComponent != keep {
            try? manager.removeItem(at: entry)
        }
    }

    func installReviewPrompt(_ store: ReviewPromptStore) {
        reviewPrompt = store
    }

    /// How long a focus request waits for its Chat view; an abandoned one
    /// must not raise the keyboard on a later visit.
    nonisolated static let chatInputFocusLifetime: TimeInterval = 15

    /// How long a launch note waits for its terminal; an abandoned one must
    /// not echo the launch on a later visit.
    nonisolated static let agentLaunchLifetime: TimeInterval = 15

    /// Asks the Chat view of `id` to raise its keyboard on its next
    /// appearance (New Chat). One-shot; a new request replaces the previous
    /// one, and it expires after `chatInputFocusLifetime`.
    func requestChatInputFocus(_ id: ConsoleAgent.ID) {
        chatInputFocusRequest.leave((), for: id, at: now())
    }

    /// True once for the Agent last passed to `requestChatInputFocus`, while
    /// the request is fresh.
    func consumeChatInputFocus(_ id: ConsoleAgent.ID) -> Bool {
        chatInputFocusRequest.take(for: id, at: now()) != nil
    }

    /// Tells the terminal of `id` that the New Agent sheet just opened it.
    /// One-shot like `requestChatInputFocus`; expires after
    /// `agentLaunchLifetime`.
    func noteAgentLaunch(_ id: ConsoleAgent.ID, _ note: AgentLaunchNote) {
        agentLaunchNote.leave(note, for: id, at: now())
    }

    /// The note `noteAgentLaunch` left for `id`, once, while it is fresh.
    func consumeAgentLaunch(_ id: ConsoleAgent.ID) -> AgentLaunchNote? {
        agentLaunchNote.take(for: id, at: now())
    }

    /// Agent Summaries refresh only while the app is in the foreground —
    /// the scene phase, not the connections' grace period.
    func setAgentSummaryForeground(_ isForeground: Bool) {
        var gate = summaryRefreshGate
        gate.isForeground = isForeground
        applySummaryRefreshGate(gate)
    }

    /// The AI summaries setting: off hides every summary line and stops
    /// asking the Hosts for new ones.
    func setAgentSummariesEnabled(_ isEnabled: Bool) {
        var gate = summaryRefreshGate
        gate.isEnabled = isEnabled
        applySummaryRefreshGate(gate)
    }

    private func applySummaryRefreshGate(_ gate: AgentSummaryRefreshGate) {
        guard gate != summaryRefreshGate else { return }
        summaryRefreshGate = gate
        for projection in projections.values {
            projection.setSummaryRefreshGate(gate)
        }
    }

    /// Shell Activity is swept only while a window is on screen — the
    /// scene phase, not the connections' grace period, and never for
    /// CarPlay, which does not show it.
    func setShellActivityForeground(_ isForeground: Bool) {
        guard isForeground != isShellActivityForeground else { return }
        isShellActivityForeground = isForeground
        for projection in projections.values {
            projection.setForeground(isForeground)
        }
    }

    /// Pins or unpins the Agent and re-sorts the published list in the same
    /// turn — a pin must not wait on a reconnect to move.
    func togglePin(hostID: Host.ID, paneID: String) {
        pins.togglePin(hostID: hostID, paneID: paneID)
        rebuild()
    }

    /// Marks an Idle Agent unread (app-local; herdr keeps reporting Idle)
    /// and re-sorts the published list in the same turn. The mark reads the
    /// live row, not a window's held copy, so it records the current
    /// `stateChangeSeq`. Returns whether the Agent is now marked: false when
    /// it could not be (it is no longer Idle, or is already marked).
    @discardableResult
    func markUnread(_ agent: ConsoleAgent) -> Bool {
        let live = agents.first { $0.id == agent.id } ?? agent
        guard unread.markUnread(live) else { return false }
        rebuildAgentOrder()
        return true
    }

    /// Clears an unread mark: Mark as Read, or the user opening the Agent.
    /// Sends nothing to the Host.
    func markRead(_ id: ConsoleAgent.ID) {
        guard unread.markRead(id) else { return }
        rebuildAgentOrder()
    }

    /// The Console index's rows: `agents` in Console order with unread marks
    /// applied (a marked Idle Agent lists as Done), except that `held` — the
    /// row a window listed when it opened that Agent — keeps the place it
    /// had then, so the Agent's own changes (opening a Done Agent turns it
    /// Idle and bumps its recency) do not move it in that window's list.
    /// `departingRows` stay listed where they were until their hold ends,
    /// and a resumed Agent the user backed out of unused is no longer listed
    /// while its Pane closes (`ClosedSessionsStore.backedOutResumes`).
    /// Only the index reads this; `agents` keeps herdr's statuses for every
    /// other consumer.
    func indexAgents(holding held: ConsoleAgent?) -> [ConsoleAgent] {
        var listed = agents.map(unread.displayed)
        let backedOut = closedSessions.backedOutResumes
        if !backedOut.isEmpty {
            listed.removeAll { backedOut[$0.id] != nil }
        }
        if let held, listed.contains(where: { $0.id == held.id }) {
            listed = sortedAgents(listed) { $0.id == held.id ? held : $0 }
        }
        // Each departing row goes back just below its anchor once that is
        // placed; a row with no anchor was listed first. An anchor may have
        // departed too, with the same Close or a later one, so passes repeat
        // until every row is placed. A pass that places nothing means an
        // anchor left without being held: the first stranded row lists
        // first, and the rows anchored on it follow it there.
        var unplaced = departingRows.filter { departing in
            !listed.contains { $0.id == departing.agent.id }
        }
        while !unplaced.isEmpty {
            var waiting: [DepartingRow] = []
            for departing in unplaced {
                guard let anchor = departing.anchor else {
                    listed.insert(departing.agent, at: 0)
                    continue
                }
                if let above = listed.firstIndex(where: { $0.id == anchor }) {
                    listed.insert(departing.agent, at: above + 1)
                } else {
                    waiting.append(departing)
                }
            }
            if waiting.count == unplaced.count {
                listed.insert(waiting.removeFirst().agent, at: 0)
            }
            unplaced = waiting
        }
        return listed
    }

    /// The departing row listed for `id`, if its hold is still running.
    func departingRow(_ id: ConsoleAgent.ID) -> DepartingRow? {
        departingRows.first { $0.agent.id == id }
    }

    /// The row a window holds when it opens `id`: the live Agent as the
    /// index lists it (an unread-marked one is held as Done).
    func listedAgent(_ id: ConsoleAgent.ID) -> ConsoleAgent? {
        addressableAgent(id).map(unread.displayed)
    }

    /// Terminal panes hidden behind a server chat session's Show Terminal.
    private var serverLinkedPanes: Set<ConsoleAgent.ID> = []
    /// The pane each server session row id is linked to, archived sessions
    /// included: Resume reuses it rather than opening another.
    private var serverSessionTerminals: [ConsoleAgent.ID: ConsoleAgent.TerminalLink] = [:]
    /// The server sessions whose pane only the folder rule links.
    private var serverFolderLinkedSessions: Set<ConsoleAgent.ID> = []

    private func addressableAgent(_ id: ConsoleAgent.ID) -> ConsoleAgent? {
        agents.first { $0.id == id }
            ?? projection(on: id.hostID, backend: .ultimate)?.addressableAgent(id.paneID)
            ?? (serverLinkedPanes.contains(id)
                ? projections(on: id.hostID).compactMap { $0.agentsByPane[id.paneID] }.first : nil)
    }

    /// Resolve a server session's Attach on the pane's own backend, never
    /// the server's.
    func linkedTerminalAgent(for thread: ConsoleAgent) -> ConsoleAgent? {
        guard let link = agents.first(where: { $0.id == thread.id })?.linkedTerminal else { return nil }
        return projection(on: link.id.hostID, backend: link.backend)?.agentsByPane[link.id.paneID]
    }

    /// Input through Show Terminal uses the thread's pending resume too;
    /// its Closed Session belongs to the thread, not to the linked pane.
    func noteUserInput(to id: ConsoleAgent.ID) {
        closedSessions.noteUserInput(to: id)
        if let thread = agents.first(where: { $0.linkedTerminal?.id == id }) {
            closedSessions.noteUserInput(to: thread.id)
        }
    }

    /// A window's held row after a mark changed on `id`: the held Agent's
    /// own mark re-takes it from the live row, so its badge, sort place and
    /// Status counts follow the mark; a mark on any other Agent leaves the
    /// held row where it was when the window opened it.
    func held(_ held: ConsoleAgent?, afterMarkChangeOn id: ConsoleAgent.ID) -> ConsoleAgent? {
        guard held?.id == id else { return held }
        return listedAgent(id)
    }

    /// Aligns Host projections with the catalog. Editing a Host replaces its
    /// projections because its connection coordinates may have changed. An
    /// edit that keeps the connection target (a rename) hands each replaced
    /// projection's rows and layout to its successor; a removed or
    /// re-targeted Host loses its last-known inventories and detected
    /// backends, on disk too. A Disabled Host stays in the catalog, so its
    /// last-known inventories, transcripts, unread marks and Closed Sessions
    /// are kept, but it gets no projection or backend detection; disabling a
    /// projected Host ends its projections like an edit does, and since the
    /// connection target is unchanged nothing on disk is purged. Changes are
    /// read against the previous catalog rather than the projections, so a
    /// Disabled Host that is re-targeted or removed loses its saved state too.
    func setHosts(_ hosts: [Host]) {
        let incoming = Dictionary(hosts.map { ($0.id, $0) }) { _, last in last }
        for (agentID, store) in composerStores where incoming[agentID.hostID] == nil {
            store.cancelQueue()
        }
        composerStores = composerStores.filter { incoming[$0.key.hostID] != nil }
        shellComposerStores = shellComposerStores.filter { incoming[$0.key.hostID] != nil }
        var handovers: [ConsoleScope: (snapshot: SessionSnapshot, verifiedAt: Date?)] = [:]
        var changed: [Host.ID: Host] = [:]
        for (id, previous) in catalog where incoming[id] != previous {
            changed[id] = previous
        }
        for (id, previous) in changed {
            let keepsTarget = incoming[id].map {
                ConsoleInventoryCache.Target($0) == ConsoleInventoryCache.Target(previous)
            } ?? false
            for (scope, projection) in projections where scope.hostID == id {
                if keepsTarget {
                    handovers[scope] = projection.inventorySnapshot.map {
                        (snapshot: $0, verifiedAt: projection.inventoryVerifiedAt)
                    }
                }
                persistedInventories[scope] = nil
                terminalSnapshotRevisions[scope] = nil
                terminalTransportGenerations[scope] = nil
                projection.end()
                projections[scope] = nil
                sendBackendDetection(.scopeEnded(scope.backend), on: id)
            }
            if !keepsTarget {
                sidebarSnapshots.invalidate(id)
                inventoryCache?.remove(id)
                chatTranscriptCache?.remove(hostID: id)
                chatMediaHomes[id] = nil
                chatMediaTransfers[id] = nil
                moshFastPath.availability.forget(hostID: id)
                // Queued Messages were for the old target's Agents: none may
                // go out to whatever answers on the new one.
                for (agentID, store) in composerStores where agentID.hostID == id {
                    store.cancelQueue()
                }
                blockedAnswers.withdrawAll(on: id)
                composerStores = composerStores.filter { $0.key.hostID != id }
                shellComposerStores = shellComposerStores.filter { $0.key.hostID != id }
                queuedMessageStore.remove(hostID: id)
                queueRestoredHosts.remove(id)
                queueDrainGenerations = queueDrainGenerations.filter { $0.key.hostID != id }
                queuedMessageCounts = queuedMessageCounts.filter { $0.key.hostID != id }
                // Queued Launches were for the old target likewise.
                sendLaunchDrain(.cancel, on: id)
                queuedLaunchStore.remove(hostID: id)
                for launch in queuedLaunches where launch.hostID == id {
                    pendingComposerStores.removeValue(forKey: launch.id)?.cancelQueue()
                }
                queuedLaunches.removeAll { $0.hostID == id }
                startedAgentsByQueuedLaunch = startedAgentsByQueuedLaunch.filter {
                    $0.value.hostID != id
                }
                launchRestoredHosts.remove(id)
                launchDrainMachines[id] = nil
            }
            endReconnectGrace(id)
            sendMosh(.hostChanged(id, keepsTarget: keepsTarget))
            forgetMoshStandbys(on: id)
            chatModeMarkerReads.removeValue(forKey: id)?.task?.cancel()
            sendBackendDetection(.hostChanged(keepsTarget: keepsTarget), on: id)
            Task { await agentTerminals.removeHost(id) }
        }
        catalog = incoming
        inventoryCache?.retainOnly(Set(incoming.keys))
        moshFastPath.availability.retainOnly(Array(incoming.values))
        chatTranscriptCache?.retainOnly(Set(incoming.keys))
        unread.retainHosts(Set(incoming.keys))
        closedSessions.retainHosts(Set(incoming.keys))
        queuedMessageStore.retainOnly(Set(incoming.keys))
        queuedLaunchStore.retainOnly(Set(incoming.keys))
        if queuedLaunches.contains(where: { incoming[$0.hostID] == nil }) {
            queuedLaunches.removeAll { incoming[$0.hostID] == nil }
        }
        launchRestoredHosts = launchRestoredHosts.filter { incoming[$0] != nil }
        launchDrainMachines = launchDrainMachines.filter { incoming[$0.key] != nil }
        blockedAnswers.retainHosts(Set(incoming.keys))
        queueRestoredHosts = queueRestoredHosts.filter { incoming[$0] != nil }
        queueDrainGenerations = queueDrainGenerations.filter { incoming[$0.key.hostID] != nil }
        if queuedMessageCounts.keys.contains(where: { incoming[$0.hostID] == nil }) {
            queuedMessageCounts = queuedMessageCounts.filter { incoming[$0.key.hostID] != nil }
        }
        restoreQueuedLaunches(on: hosts.map(\.id))
        restoreQueuedMessages(on: hosts.map(\.id))
        for host in hosts where host.isEnabled && projections(on: host.id).isEmpty {
            startProjections(for: host, handovers: handovers)
        }
        rebuild()
    }

    func resume() async {
        await activate(revalidating: false)
    }

    /// Foreground activation: activates whatever is suspended, and re-proves
    /// whatever is not. A session the app was still holding when it went away
    /// comes back believing it is connected even when its link died in the
    /// meantime, and `resume()` has nothing to re-activate on it — so without
    /// the second half the Console shows a connection that is already gone
    /// until the keepalive gets round to noticing, up to its interval plus a
    /// request timeout later (#142). A Host already stopped on a
    /// non-retryable failure is asked once more here too: `resume()` no-ops on
    /// it as well, so on a return that no suspension preceded, nothing else
    /// would ask it again (#147).
    func reactivate() async {
        await activate(revalidating: true)
    }

    private func activate(revalidating: Bool) async {
        await enqueueLifecycleTransition { [self] in
            sendActivation(.began(active: true))
            transcriptPrefetcher?.update()
            // Coming back drains every queue again with its backoff reset,
            // on the connection it has or the one it is about to get.
            queueDrainGenerations.removeAll()
            invalidateLaunchDrains()
            // The grace an unverified Host gets is counted from the moment
            // the user can see it, not from whenever it last dropped.
            for hostID in projectedHostIDs {
                if let lead = leadProjection(on: hostID), !Self.isVerified(lead) {
                    startReconnectGrace(hostID)
                }
            }
            publishReconnectGrace()
            let projections = Array(self.projections.values)
            for projection in projections {
                let scope = ConsoleScope(hostID: projection.host.id, backend: projection.backend)
                if waitsForHerdr(scope) {
                    sendBackendDetection(.scopeDeferred(scope.backend), on: scope.hostID)
                } else {
                    await projection.resume()
                }
            }
            // A Host may have gained or lost a backend while the app was
            // away (ADR 0026): asked once its connection settles, unless
            // the Host answered recently (#105).
            for hostID in catalog.keys {
                requestBackendDetection(on: hostID)
            }
            rebuild()
            guard revalidating else { return }
            // Every Host, not only one the user has navigated to: recovery
            // that depends on navigation just trades the Retry button for
            // another hidden step, and the Console is a single list across
            // all Hosts anyway, so it has no notion of one being on screen.
            // The population this costs anything for is the Hosts currently
            // *failed*, which is normally none (#147).
            //
            // All at once: re-proving is one bounded round trip per Host, but
            // its only bound is the Transport's request timeout, and a Host
            // frozen with the app is exactly the case that runs it out.
            // Serially that is N timeouts holding the lifecycle chain, and
            // behind that chain sits any suspend() the user triggers by
            // leaving again — including the didFinishSuspending() that
            // releases the background assertion.
            await withTaskGroup(of: Void.self) { group in
                for projection in projections {
                    group.addTask { await projection.revalidate() }
                }
            }
        }
    }

    /// Suspends every Host for backgrounding: the Agent terminals end and
    /// each Host's session quiesces, keeping its SSH connection open for
    /// the return to probe (#105). `locally` is the expiration path, with
    /// no background time left: nothing waits on the network then. The
    /// teardowns run on their own and this returns at once.
    func suspend(locally: Bool = false) async {
        await enqueueLifecycleTransition { [self] in
            sendActivation(.began(active: false))
            // An in-flight background read ends with the foreground.
            transcriptPrefetcher?.cancel()
            for hostID in backendDetections.keys {
                sendBackendDetection(.suspend, on: hostID)
            }
            if locally {
                let terminals = agentTerminals
                Task { await terminals.suspend() }
            } else {
                await agentTerminals.suspend()
            }
            rebuild()
            for projection in projections.values {
                await projection.suspend(locally: locally)
            }
        }
    }

    /// Follows the device's network path from `monitor`, the app's one
    /// (#105). Every settled change re-proves each connected Host with the
    /// hedged probe (`EventsSession.revalidate()`): a connection the old
    /// path carried may be dead, and a fresh dial beside a slow probe
    /// replaces it. A path that comes back after none first cuts every
    /// reconnect short, whether it is waiting out a backoff or stuck on a
    /// dial retrying its SYN where there was no path, so each Host redials
    /// at once (`EventsSession.redialNow(trigger:)`). The monitor's debounce is the
    /// only one. Calling again replaces the earlier subscription.
    ///
    /// Each change is handled in its own task, never awaited here, so a
    /// slow revalidate never holds up the next change (a none-then-back
    /// and its redial). Passes
    /// may overlap, as the foreground pass already does with this one: the
    /// pool joins a pending dial, and `adopt` drops a replacement for a
    /// transport that is no longer current.
    func followNetworkPath(_ monitor: NetworkPathMonitor) {
        networkPathTask?.cancel()
        let changes = monitor.changes(includingBaseline: true)
        monitor.start()
        guard case .follow(let follow)? = sendActivation(.followed).first else { return }
        networkPathTask = Task { [weak self] in
            // The first element is the baseline: it seeds the flag (a launch
            // with no network queues at once) but is not a change.
            for await path in changes {
                guard let self else { return }
                sendActivation(.pathRead(follow: follow, path: path))
            }
            self?.sendActivation(.followEnded(follow))
        }
    }

    /// Feeds the activation and path machine and performs its effects;
    /// `run` and `follow` belong to the caller, which gets them back.
    @discardableResult
    private func sendActivation(
        _ event: ConsoleActivationMachine.Event
    ) -> [ConsoleActivationMachine.Effect] {
        let effects = activation.handle(event)
        for effect in effects {
            switch effect {
            case .release(let token):
                lifecycleTasks[token] = nil
            case .setOffline(let offline):
                hasLostNetworkPath = offline
            case .lostPath:
                settleVerificationWaiters()
                // A drain the lost path stopped goes again on the
                // connection that outlives it (`networkPathDidChange`).
                invalidateLaunchDrains()
            case .pathChanged(let path, let recovered):
                Task { await self.networkPathDidChange(to: path, recovered: recovered) }
            case .run, .follow:
                break
            }
        }
        return effects
    }

    private func networkPathDidChange(to path: NetworkPathKey?, recovered: Bool) async {
        NetworkLog.signposter.emitEvent("path change")
        NetworkLog.logger.notice(
            "network path: \(path?.interface.rawValue ?? "none", privacy: .public), back after none: \(recovered, privacy: .public)"
        )
        // No path: nothing can be proved. Suspended: the return probes.
        guard path != nil, isActive else { return }
        let sessions = projections.values.map(\.session)
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask {
                    if recovered { await session.redialNow(trigger: .pathChange) }
                    await session.revalidate(after: .pathChange)
                }
            }
        }
        // A connection that outlived the gap keeps its generation, so
        // nothing else drains the launches Started while there was none.
        drainQueuedLaunches()
    }

    /// Chains `transition` behind the previously enqueued one and waits for
    /// it. Enqueueing is synchronous on the main actor, so the chain order is
    /// the call order.
    private func enqueueLifecycleTransition(
        _ transition: @escaping @MainActor () async -> Void
    ) async {
        guard case .run(let token, let after)? = sendActivation(.enqueued).first else { return }
        let previous = after.flatMap { lifecycleTasks[$0] }
        let task = Task { @MainActor in
            await previous?.value
            await transition()
            self.sendActivation(.finished(token))
        }
        lifecycleTasks[token] = task
        await task.value
    }

    /// Restarts only Hosts whose connection has failed; connected and
    /// reconnecting Hosts, and the Attach terminals riding on them, are left
    /// alone.
    func retryFailedHosts() async {
        for projection in projections.values {
            if case .failed = projection.status {
                await projection.retry()
            }
        }
    }

    /// Restarts one Host without disturbing other Hosts that may be connected,
    /// reconnecting, or waiting for their own repair. On a Host running both
    /// backends only the projections not connected restart, unless both are.
    func retryHost(_ id: Host.ID) async {
        let hostProjections = projections(on: id)
        let stopped = hostProjections.filter { $0.status != .connected }
        for projection in stopped.isEmpty ? hostProjections : stopped {
            await projection.retry()
        }
    }

    /// Restarts one backend's projection: a Retry on its own failure.
    func retry(_ scope: ConsoleScope) async {
        await projections[scope]?.retry()
    }

    /// The backends on a dual Host that failed while the Host presents the
    /// other one (`hostStatuses` is the lead's): each with its failure, so
    /// the Console can name it and offer `retry(_:)` for it alone. Failed,
    /// or Connecting with a Standing Failure; herdr first.
    func failedSecondaryScopes(on hostID: Host.ID) -> [(scope: ConsoleScope, failure: TransportError)] {
        guard let lead = hostLeadBackends[hostID] else { return [] }
        return HostBackend.allCases.compactMap { backend in
            guard backend != lead else { return nil }
            let scope = ConsoleScope(hostID: hostID, backend: backend)
            return scopeFailure(scope).map { (scope, $0) }
        }
    }

    /// One projection's failure: Failed, or Connecting with a Standing
    /// Failure; nil while it connects afresh, serves, or does not exist.
    func scopeFailure(_ scope: ConsoleScope) -> TransportError? {
        switch scopeStatuses[scope] {
        case .failed(let failure): failure
        case .connecting: scopeStandingFailures[scope]
        default: nil
        }
    }

    // MARK: Starting a stopped runtime (#389)

    /// Whether the Host's `backend` (Herdr TUI or Herdr Core) is installed
    /// but stopped by the Console's own account, so its row offers the
    /// Start: that scope fails with an error naming it
    /// (`TransportError.startableRuntime`), whether it leads the Host or not.
    /// Also true while a start of it runs.
    func offersStart(of backend: HostBackend, on hostID: Host.ID) -> Bool {
        guard !backend.isServerChat else { return false }
        let scope = ConsoleScope(hostID: hostID, backend: backend)
        return runtimeStartsInFlight.contains(scope)
            || scopeFailure(scope)?.startableRuntime == backend
    }

    /// A start of the Host's `backend` runs: the start, then the reconnect
    /// it asked for.
    func isStarting(_ backend: HostBackend, on hostID: Host.ID) -> Bool {
        runtimeStartsInFlight.contains(ConsoleScope(hostID: hostID, backend: backend))
    }

    /// What the last failed start of the Host's `backend` said, until
    /// another start or that scope connecting.
    func startError(_ backend: HostBackend, on hostID: Host.ID) -> String? {
        runtimeStartErrors[ConsoleScope(hostID: hostID, backend: backend)]
    }

    /// Each runtime's start error on the Host, for its Console rows.
    func startErrors(on hostID: Host.ID) -> [HostBackend: String] {
        var errors: [HostBackend: String] = [:]
        for (scope, error) in runtimeStartErrors
        where scope.hostID == hostID && !scope.backend.isServerChat {
            errors[scope.backend] = error
        }
        return errors
    }

    /// Host detail and New Agent own a server chat runtime's stopped/start
    /// UI. It never appears as a stopped runtime or start error in the
    /// Console list.
    func serverRuntimeState(_ server: ServerChatBackend, on hostID: Host.ID) -> ServerRuntimeState {
        ServerRuntimeState(
            server: server, presence: backendPresence(on: hostID),
            starting: isStarting(server.backend, on: hostID),
            error: startError(server.backend, on: hostID))
    }

    /// The user's Start Herdr TUI, Start Herdr Core or Start Codex server (#389): the only
    /// caller of the starter, which nothing else runs. One start per Host
    /// and runtime at a time; a second tap meanwhile does nothing and
    /// returns false. A failed start keeps its words for the row and
    /// reconnects nothing; a start that worked retries that runtime's
    /// projection and stays in flight until the reconnect settles, so the
    /// row never flashes its stopped state in between. A Host removed or
    /// edited (another address, user or session) while the start ran gets
    /// neither: the outcome was about the Host as it was. Returns whether
    /// the start ran and worked.
    @discardableResult
    func startRuntime(_ backend: HostBackend, on hostID: Host.ID) async -> Bool {
        let scope = ConsoleScope(hostID: hostID, backend: backend)
        guard let host = catalog[hostID] else { return false }
        var effects = runtimeStarts[scope, default: RuntimeStartMachine()].handle(.userStart(host))
        while !effects.isEmpty {
            let effect = effects.removeFirst()
            switch effect {
            case .start(let token, let target):
                let failure: String?
                do {
                    try await runtimeStarter(target, backend)
                    failure = nil
                } catch {
                    failure = Self.startErrorText(error, starting: backend)
                }
                effects += runtimeStarts[scope, default: RuntimeStartMachine()].handle(
                    .started(token, current: catalog[hostID], error: failure, serverChat: backend.isServerChat))
            case .detect(let token, let target):
                let presence: HostBackendPresence?
                let failure: String?
                do {
                    presence = try await backendDetector(target)
                    failure = nil
                } catch {
                    presence = nil
                    failure = Self.startErrorText(error, starting: backend)
                }
                effects += runtimeStarts[scope, default: RuntimeStartMachine()].handle(
                    .detected(token, current: catalog[hostID], presence: presence, error: failure))
            case .record(let presence):
                recordDetectedPresence(presence, on: hostID)
            case .verify(let token, let reconnect):
                if reconnect { await retry(scope) }
                _ = try? await awaitVerification(on: hostID, backend: backend, patience: .failsFast)
                effects += runtimeStarts[scope, default: RuntimeStartMachine()].handle(.verified(token))
            case .finish(let succeeded):
                return succeeded
            }
        }
        return false
    }

    /// A failed start's words: the runtime's own output (`HerdrStartError`,
    /// named for the runtime started), the link's
    /// presentation, or the error's description.
    nonisolated static func startErrorText(_ error: any Error, starting runtime: HostBackend)
        -> String
    {
        let name = runtime.serverChat?.serverName ?? runtime.displayName
        return switch error {
        case let error as HerdrStartError:
            error.output.isEmpty
                ? "\(name) did not start."
                : "\(name) did not start: \(error.output)"
        case let error as TransportError:
            error.presentation.message
        default:
            error.localizedDescription
        }
    }

    /// The Host's missing backend (WAY-338) while it is what the Host's
    /// Console row reports: the Host was detected with neither herdr nor a
    /// usable tmux, and its status is a failure only that explains. The row
    /// then opens the install panel instead of Host settings. A Host that
    /// is unreachable, or fails for another reason, has none: the gap would
    /// hide the real cause. So does one waiting on a host key: the sheet
    /// cannot trust a key, and that row must stay.
    func backendGapBehindFailure(on hostID: Host.ID) -> HostBackendGap? {
        guard hostKeyTrustHolds[hostID] == nil,
            let gap = HostBackendGap(presence: backendPresence(on: hostID))
        else { return nil }
        let failure: TransportError?
        switch hostStatuses[hostID] {
        case .failed(let error): failure = error
        case .connecting: failure = hostStandingFailures[hostID]
        default: failure = nil
        }
        switch failure {
        case .socketNotFound, .herdrBinaryNotFound, .streamLocalOpenFailed, .herdrNotRunning,
            .herdrSessionNotFound, .tmuxNotInstalled, .tmuxTooOld, .zellijNotInstalled, .zellijTooOld:
            return gap
        default:
            return nil
        }
    }

    /// A tmux-only Host whose tmux runs no session (design §2 scenario 8):
    /// its tmux projection is Connected and verified, and lists no
    /// Workspace. The Console offers `startTmuxSession(on:)` instead of the
    /// plain "No Agents" claim.
    func needsTmuxSession(on hostID: Host.ID) -> Bool {
        let scope = ConsoleScope(hostID: hostID, backend: .tmux)
        return presentBackends(on: hostID) == [.tmux]
            && scopeStatuses[scope] == .connected
            && !scopesAwaitingSnapshot.contains(scope)
            && workspaces(for: hostID).isEmpty
    }

    /// Whether every backend the Host lists Workspaces from is live: each
    /// present projection that has not Failed is Connected and verified by
    /// a snapshot on its current connection, and at least one is. Quick
    /// chat plans against `workspaces(for:)` only then, so a Host running
    /// both never plans against tmux's last-known (or missing) sessions
    /// while herdr's are live. A herdr-only Host: its projection's state.
    /// Never while the device has no network path: a connection the lost
    /// path carried still reads Connected until its keepalive notices, up
    /// to about 35 s, and a New Agent Start then would fail instead of
    /// queueing.
    func hasLiveSnapshots(on hostID: Host.ID) -> Bool {
        guard hasNetwork else { return false }
        let scopes = presentBackends(on: hostID)
            .map { ConsoleScope(hostID: hostID, backend: $0) }
            .filter { scope in
                if case .some(.failed) = scopeStatuses[scope] { return false }
                return true
            }
        return !scopes.isEmpty
            && scopes.allSatisfy {
                scopeStatuses[$0] == .connected && !scopesAwaitingSnapshot.contains($0)
            }
    }

    /// Starts tmux's `main` session at the Host's home; the projection
    /// refreshes once tmux has it.
    func startTmuxSession(on hostID: Host.ID) async throws {
        try await projection(for: hostID, backend: .tmux).startMainSession()
    }

    /// The returned runner resolves the Host's live projection on every
    /// call: editing a Host replaces its projection (and session), and a
    /// runner captured by a long-lived Attach screen must follow it there
    /// instead of staying bound to the ended session. The projection is
    /// `backend`'s, or with nil the one whose rows hold the attach target
    /// (the primary one when none does).
    func terminalRunner(for hostID: Host.ID, backend: HostBackend? = nil) -> TerminalSessionRunner {
        { [weak self] request, handler in
            guard let self else {
                throw TransportError.sshUnreachable(detail: "The Host is not connected.")
            }
            try await runTerminal(request, handler, on: hostID, backend: backend)
        }
    }

    /// Attach first (#105): an attach starts as soon as its Host's
    /// connection can carry it, without waiting for the live snapshot to
    /// verify the row it was opened from. The target a last-known row names
    /// may be gone by then, so an attach that fails or ends while the Host's
    /// rows are still unverified waits for that verification — through a
    /// stopped Host too, whose detail presents the failure meanwhile — and
    /// only then decides, with no error shown in between: a target the
    /// verified rows no longer list leaves the detail for its pane-gone
    /// placeholder, and one they still list is attached once more. An
    /// attach that ends once the rows are verified ends as it always did.
    private func runTerminal(
        _ request: TerminalAttachRequest, _ handler: TerminalSessionHandler,
        on hostID: Host.ID, backend: HostBackend?
    ) async throws {
        let resolved = backend ?? attachTargetOwner(request.target, on: hostID)
        guard let projection = projection(on: hostID, backend: resolved) else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        do {
            try await projection.terminalRunner()(request, handler)
        } catch {
            guard Self.awaitsVerificationAfter(error), isUnverified(hostID, resolved) else {
                throw error
            }
            try await reattachOnceVerified(
                request, handler, on: hostID, backend: backend, failure: error)
            return
        }
        guard !Task.isCancelled, isUnverified(hostID, resolved) else { return }
        try await reattachOnceVerified(
            request, handler, on: hostID, backend: backend, failure: nil)
    }

    /// Whether the Host backend's projection is there and its rows are not
    /// verified on its current connection.
    private func isUnverified(_ hostID: Host.ID, _ backend: HostBackend?) -> Bool {
        guard let projection = projection(on: hostID, backend: backend) else { return false }
        return !Self.isVerified(projection)
    }

    /// The pane-gone guard of `runTerminal`: waits for the Host's rows to
    /// be verified, then attaches once more if they still list the target.
    /// A target they no longer list ends the attach as it ended (`failure`,
    /// or normally) while the detail leaves for its placeholder.
    private func reattachOnceVerified(
        _ request: TerminalAttachRequest, _ handler: TerminalSessionHandler,
        on hostID: Host.ID, backend: HostBackend?, failure: (any Error)?
    ) async throws {
        let resolved = backend ?? attachTargetOwner(request.target, on: hostID)
        let verified = try await awaitVerification(
            on: hostID, backend: resolved, patience: .waitsOutFailure)
        guard Self.lists(request.target, in: verified) else {
            if let failure { throw failure }
            return
        }
        try await verified.terminalRunner()(request, handler)
    }

    /// Failures a verified Host might not repeat: not a cancelled or stopped
    /// attach, a terminal another surface owns, or a mosh session the
    /// terminal's own fallback takes over — a failed one, or one whose link
    /// was lost, which reattaches through `.connecting` on its own (#105).
    private nonisolated static func awaitsVerificationAfter(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError, is MoshLinkLost: false
        case TransportError.cancelled, TransportError.terminalChannelAlreadyOpen,
            TransportError.moshSessionFailed:
            false
        default: true
        }
    }

    private static func lists(
        _ target: TerminalAttachTarget, in projection: HostConsoleProjection
    ) -> Bool {
        switch target {
        case .agentPane(let paneID):
            projection.agentsByPane[paneID] != nil
        case .terminal(let terminalID):
            projection.agentsByPane.values.contains { $0.agent.terminalID == terminalID }
        }
    }

    /// Late-bound for the same reason as `terminalRunner(for:)`: a retryable
    /// upload taken before a Host edit must stage over the new session.
    func imageStager(for hostID: Host.ID) -> ImageStager {
        { [weak self] image, reporter in
            guard let stager = await self?.liveImageStager(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: "The Host is not connected.")
            }
            return try await stager(image, reporter)
        }
    }

    func fileStager(for hostID: Host.ID) -> FileStager {
        { [weak self] file, reporter in
            guard let stager = await self?.liveFileStager(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: "The Host is not connected.")
            }
            return try await stager(file, reporter)
        }
    }

    /// Launch Prompt File services for a launch on `hostID`, nil when the
    /// Console has no connection to it. Late-bound like `fileStager(for:)`:
    /// a launch retried after a reconnect writes over the new session.
    func launchPromptHost(for hostID: Host.ID) -> LaunchPromptHost? {
        guard primaryProjection(on: hostID) != nil else { return nil }
        return LaunchPromptHost(
            capabilities: { [weak self] in
                guard let host = await self?.liveLaunchPromptHost(for: hostID) else {
                    return .none
                }
                return await host.capabilities()
            },
            stage: { [weak self] files in
                guard let host = await self?.liveLaunchPromptHost(for: hostID) else {
                    throw TransportError.sshUnreachable(
                        detail: "The Host is not connected.")
                }
                return try await host.stage(files)
            },
            homeDirectory: { [weak self] in
                guard let host = await self?.liveLaunchPromptHost(for: hostID) else {
                    throw TransportError.sshUnreachable(
                        detail: "The Host is not connected.")
                }
                return try await host.homeDirectory()
            })
    }

    private func liveLaunchPromptHost(for hostID: Host.ID) -> LaunchPromptHost? {
        primaryProjection(on: hostID)?.launchPromptHost()
    }

    /// The backend whose rows hold an attach target, if any lists it.
    private func attachTargetOwner(
        _ target: TerminalAttachTarget, on hostID: Host.ID
    ) -> HostBackend? {
        switch target {
        case .agentPane(let paneID):
            paneOwner(paneID, on: hostID)
        case .terminal(let terminalID):
            projections(on: hostID).first { projection in
                projection.agentsByPane.values.contains { $0.agent.terminalID == terminalID }
            }?.backend
        }
    }

    private func liveImageStager(for hostID: Host.ID) -> ImageStager? {
        primaryProjection(on: hostID)?.imageStager()
    }

    /// Ranged Host-file reads for the terminal usage strip (#325). Late-bound
    /// for the same reason as `imageStager(for:)`: the strip refreshes on a
    /// timer, and a reconnect between two refreshes must not leave it reading
    /// through the transport that was replaced.
    func sessionFileReader(for hostID: Host.ID) -> SessionFileReader {
        { [weak self] range in
            guard let reader = await self?.liveSessionFileReader(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: "The Host is not connected.")
            }
            return try await reader(range)
        }
    }

    private func liveSessionFileReader(for hostID: Host.ID) -> SessionFileReader? {
        primaryProjection(on: hostID)?.sessionFileReader()
    }

    /// Whole-file reads for previewing a path tapped in a terminal,
    /// late-bound like `sessionFileReader(for:)`: a preview started just
    /// before a reconnect reads through the new transport.
    func previewFileReader(for hostID: Host.ID) -> PreviewFileReader {
        { [weak self] path, maxBytes in
            guard let reader = await self?.livePreviewFileReader(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: "The Host is not connected.")
            }
            return try await reader(path, maxBytes)
        }
    }

    private func livePreviewFileReader(for hostID: Host.ID) -> PreviewFileReader? {
        primaryProjection(on: hostID)?.previewFileReader()
    }

    /// Model window lookups for the terminal usage strip (#325), late-bound
    /// like `sessionFileReader(for:)`.
    func modelContextWindowResolver(for hostID: Host.ID) -> ModelContextWindowResolver {
        { [weak self] selector in
            guard let resolver = await self?.liveModelContextWindowResolver(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: "The Host is not connected.")
            }
            return try await resolver(selector)
        }
    }

    private func liveModelContextWindowResolver(
        for hostID: Host.ID
    ) -> ModelContextWindowResolver? {
        primaryProjection(on: hostID)?.modelContextWindowResolver()
    }

    /// Branch reads for the Agent Footer (#169), late-bound like
    /// `sessionFileReader(for:)`: the footer polls, and a reconnect between
    /// two reads must not leave it reading through the replaced transport.
    func gitBranchReader(for hostID: Host.ID) -> GitBranchReader {
        { [weak self] cwd in
            guard let reader = await self?.liveGitBranchReader(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: "The Host is not connected.")
            }
            return try await reader(cwd)
        }
    }

    private func liveGitBranchReader(for hostID: Host.ID) -> GitBranchReader? {
        primaryProjection(on: hostID)?.gitBranchReader()
    }

    private func liveFileStager(for hostID: Host.ID) -> FileStager? {
        primaryProjection(on: hostID)?.fileStager()
    }

    func workspaces(for hostID: Host.ID) -> [ConsoleWorkspace] {
        workspacesByHost[hostID] ?? []
    }

    /// The Agent names live on a Host, so a Closed Session's resume keeps
    /// its recorded name only while no Agent has it. Names only: herdr's
    /// duplicate check ignores detected kind labels, but the Console reports
    /// those as names too, and skipping them merely bumps the suffix. Shells
    /// are left out: a Shell row's name is its tab label, which herdr's check
    /// ignores too — and the tab an Agent exited from keeps the Agent's name.
    func agentNames(on hostID: Host.ID) -> Set<String> {
        Set(agents.lazy.filter { $0.hostID == hostID && !$0.isShell }.compactMap(\.agent.name))
    }

    /// The projection behind every Host-level RPC: the Host's primary one
    /// (`primaryProjection(on:)`). An unconnected Host fails loudly
    /// instead of silently dropping the action.
    private func projection(for hostID: Host.ID) throws -> HostConsoleProjection {
        guard let projection = primaryProjection(on: hostID) else {
            throw TransportError.sshUnreachable(
                detail: "The Host is not connected.")
        }
        return projection
    }

    /// One backend's projection, for work only that backend can do.
    private func projection(
        for hostID: Host.ID, backend: HostBackend
    ) throws -> HostConsoleProjection {
        guard let projection = projections[ConsoleScope(hostID: hostID, backend: backend)] else {
            throw TransportError.sshUnreachable(
                detail: "The Host is not connected.")
        }
        return projection
    }

    /// The projection for `backend` on the Host, or with nil its primary one.
    func projection(on hostID: Host.ID, backend: HostBackend?) -> HostConsoleProjection? {
        guard let backend else { return primaryProjection(on: hostID) }
        return projections[ConsoleScope(hostID: hostID, backend: backend)]
    }

    /// The Host's projections, preferred lead first.
    private func projections(on hostID: Host.ID) -> [HostConsoleProjection] {
        let lead = leadBackend(on: hostID)
        let order = [lead] + HostBackend.allCases.filter { $0 != lead }
        return order.compactMap { projections[ConsoleScope(hostID: hostID, backend: $0)] }
    }

    /// Internal TUI-first lead among installed, visible runtimes; core then
    /// tmux take over when TUI is absent or hidden.
    func leadBackend(on hostID: Host.ID) -> HostBackend {
        let present = desiredBackends(for: hostID)
        return HostBackend.allCases.first(where: present.contains) ?? .herdr
    }

    /// The projection Host-level exec features ride (every one is a plain
    /// command over the Host's SSH session, whichever backend owns it): the
    /// first Connected one in lead order, so a failed lead does not take
    /// them down while another backend serves; with none Connected, the
    /// preferred lead. `hostConnectionGenerations` follows the same pick.
    func primaryProjection(on hostID: Host.ID) -> HostConsoleProjection? {
        let present = projections(on: hostID)
        return present.first { $0.status == .connected } ?? present.first
    }

    /// Core has no mosh attach; its placeholder probe must not poison the
    /// Host/network-wide availability shared by TUI and tmux attaches.
    func moshProjection(on hostID: Host.ID) -> HostConsoleProjection? {
        let candidates = [HostBackend.herdr, .tmux, .zellij].compactMap {
            projection(on: hostID, backend: $0)
        }
        return candidates.first { $0.status == .connected } ?? candidates.first
    }

    func readHerdrSidebarLayout(for hostID: Host.ID) async throws -> Data? {
        let herdr = try projection(for: hostID, backend: .herdr)
        return try await herdr.session.withTransport { try await $0.readSidebarLayout() }
    }

    /// The projection the Host's Chat Markers are read over and verified
    /// by, and Host-level marker writes go over: the primary one, unless its
    /// transport answered `pluginNotInstalled` for markers on its current
    /// connection (a Host running herdr without the Waycar herdr plugin,
    /// set up with `install.sh --tmux`); then the Host's other Connected
    /// projection, whose transport finds the Host tools' config dir itself.
    private func markerProjection(on hostID: Host.ID) -> HostConsoleProjection? {
        // Ultimate chats are marker-free. Its empty default must never
        // replace another backend's Host Tools markers on a mixed Host.
        let candidates = projections(on: hostID).filter { $0.backend.hasTerminal }
        guard let primary = candidates.first(where: { $0.status == .connected }) ?? candidates.first else { return nil }
        guard isMarkerless(primary),
            let other = candidates.first(where: {
                $0 !== primary && $0.status == .connected
            })
        else { return primary }
        return other
    }

    /// Whether `projection`'s transport answered `pluginNotInstalled` for
    /// markers on its current connection.
    private func isMarkerless(_ projection: HostConsoleProjection) -> Bool {
        chatModeMarkerReads[projection.host.id]?.markerless
            == MarkerlessProjection(
                backend: projection.backend, transportGeneration: projection.transportGeneration)
    }

    /// Records that `projection`'s transport has no Host tools for Chat
    /// Markers. Only the primary projection's answer counts: when it moves
    /// the markers to the Host's other projection, their verification moves
    /// with them, so that projection's read confirms them before any
    /// marker is followed.
    private func noteMarkerless(_ projection: HostConsoleProjection) {
        let hostID = projection.host.id
        guard primaryProjection(on: hostID) === projection, !isMarkerless(projection) else { return }
        var reads = chatModeMarkerReads[hostID] ?? newChatModeMarkerReads()
        reads.markerless = MarkerlessProjection(
            backend: projection.backend, transportGeneration: projection.transportGeneration)
        chatModeMarkerReads[hostID] = reads
        guard let current = markerProjection(on: hostID), current !== projection else { return }
        noteChatModeMarkerVerifications(on: [hostID])
        scheduleChatModeMarkerReads([current])
    }

    /// Where a Chat Marker write or delete goes: over `backend`'s projection
    /// (the Agent's own), or with nil over the Host's marker projection; a
    /// projection without Host tools for markers hands it to the marker
    /// projection.
    private func chatMarkerProjection(
        for hostID: Host.ID, backend: HostBackend?
    ) throws -> HostConsoleProjection {
        if let backend {
            let own = try projection(for: hostID, backend: backend)
            guard isMarkerless(own), let marker = markerProjection(on: hostID) else { return own }
            return marker
        }
        guard let marker = markerProjection(on: hostID) else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        return marker
    }

    /// Runs one Chat Marker write or delete (`chatMarkerProjection`). A
    /// primary projection answering `pluginNotInstalled` is recorded, and
    /// the operation runs again over the projection the markers moved to.
    private func withChatMarkers(
        on hostID: Host.ID, backend: HostBackend? = nil,
        _ operation: @escaping @Sendable (any Transport) async throws -> Void
    ) async throws {
        let projection = try chatMarkerProjection(for: hostID, backend: backend)
        do {
            try await projection.session.withTransport(operation)
        } catch NotificationRegistrationError.pluginNotInstalled {
            noteMarkerless(projection)
            let next = try chatMarkerProjection(for: hostID, backend: backend)
            guard next !== projection else { throw NotificationRegistrationError.pluginNotInstalled }
            try await next.session.withTransport(operation)
        }
    }

    /// Prefer the configured lead's status. A serving secondary with rows
    /// can take over when it fails; empty secondary inventories never mask
    /// the lead's failure.
    private func leadProjection(on hostID: Host.ID) -> HostConsoleProjection? {
        let present = projections(on: hostID)
        guard let lead = present.first else { return nil }
        let others = present.dropFirst().filter { !$0.agentsByPane.isEmpty }
        if lead.status == .connected || others.isEmpty { return lead }
        if let connected = others.first(where: { $0.status == .connected }) { return connected }
        if case .failed = lead.status {
            return others.first { projection in
                if case .failed = projection.status { return false }
                return true
            } ?? lead
        }
        return lead
    }

    var projectedHostIDs: Set<Host.ID> {
        Set(projections.keys.lazy.map(\.hostID))
    }

    /// The backend whose rows list `paneID` on the Host, if any does.
    private func paneOwner(_ paneID: String, on hostID: Host.ID) -> HostBackend? {
        projections(on: hostID).first { $0.addressableAgent(paneID) != nil }?.backend
    }

    /// The backend whose snapshot lists `workspaceID` on the Host, if any.
    private func workspaceOwner(_ workspaceID: String, on hostID: Host.ID) -> HostBackend? {
        projections(on: hostID).first { projection in
            projection.workspaces.contains { $0.id == workspaceID }
        }?.backend
    }

    /// Where a launch runs: the caller's backend, else the one whose
    /// snapshot holds its Workspace, else the Host's New Agent default.
    private func launchBackend(
        _ explicit: HostBackend?, workspaceID: String?, on hostID: Host.ID
    ) -> HostBackend {
        explicit
            ?? workspaceID.flatMap { workspaceOwner($0, on: hostID) }
            ?? defaultNewAgentBackend(on: hostID)
    }

    /// The connection generation of the projection listing `agent`.
    func connectionGeneration(for agent: ConsoleAgent) -> UInt64? {
        scopeConnectionGenerations[ConsoleScope(hostID: agent.hostID, backend: agent.backend)]
    }

    // MARK: Backends (ADR 0026)

    /// The backends the Host has a projection for, herdr first. A hidden
    /// tmux (`setShowsTmux`) has none.
    func presentBackends(on hostID: Host.ID) -> [HostBackend] {
        HostBackend.allCases.filter { projectedScopes.contains(ConsoleScope(hostID: hostID, backend: $0)) }
    }

    /// Connected runtimes other than the one supplying the Host's status,
    /// in the same order as its visible runtimes.
    func connectedSecondaryBackends(on hostID: Host.ID) -> [HostBackend] {
        guard let lead = hostLeadBackends[hostID] else { return [] }
        return presentBackends(on: hostID).filter {
            $0 != lead && scopeStatuses[ConsoleScope(hostID: hostID, backend: $0)] == .connected
        }
    }

    /// The Host's backends as last detected; nil before any detection.
    func backendPresence(on hostID: Host.ID) -> HostBackendPresence? {
        backendDetections[hostID]?.presence
    }

    /// All detected backends, including hidden ones; nil before detection.
    func resolvedBackends(on hostID: Host.ID) -> [HostBackend]? {
        backendPresence(on: hostID).map(\.backends)
    }

    /// The Host's Waycar plugin against what this build needs (#209), from
    /// its last detected presence; `.unknown` before any detection probed it.
    /// A Host that uses herdr-core is measured against the plugin that has a
    /// core mode (`WaycarPluginRequirement.coreMinimumVersion`), independently
    /// of which runtime leads.
    func waycarPluginStatus(on hostID: Host.ID) -> WaycarPluginStatus {
        WaycarPluginRequirement.status(
            of: backendPresence(on: hostID)?.waycarPlugin,
            backends: resolvedBackends(on: hostID) ?? [])
    }

    /// The Host's Waycar plugin against `nativeToolsMinimumVersion` (WAY-451),
    /// from its last detected presence. `.outdated` means a Node-era plugin
    /// that prompts an update; no feature reads it as a gate.
    func nativeToolsStatus(on hostID: Host.ID) -> WaycarPluginStatus {
        WaycarPluginRequirement.nativeToolsStatus(of: backendPresence(on: hostID)?.waycarPlugin)
    }

    /// Records a presence detected outside the Console, e.g. by Host
    /// detail's fresh checks, exactly as the Console's own detection would:
    /// stamped now, cached, and reconciled into the Host's projections. A
    /// detection still in flight is dropped: it asked no later than this.
    func recordDetectedPresence(_ presence: HostBackendPresence, on hostID: Host.ID) {
        guard catalog[hostID] != nil else { return }
        sendBackendDetection(.recorded(presence, now: now()), on: hostID)
    }

    /// After the Waycar plugin was updated on the Host (#209): records the
    /// installer's follow-up `presence`, then restarts the Host's
    /// projections. A restart (`retry()`, as Reconnect does) winds the
    /// session's Transport down and connects a new one, so what a Transport
    /// learned about the old plugin for the life of its connection —
    /// herdr's notification plugin, tmux's Host Tools, a summary action
    /// found missing — is asked afresh rather than kept. Without a
    /// presence the Host is asked again once the restarted connection
    /// settles (`runDeferredConnectWork`), so the exec never races its first
    /// snapshot (#105). Projections the new presence starts are new already;
    /// ones it ends ignore the restart. While the app is inactive nothing
    /// restarts: the next activation connects new Transports, and asks again
    /// about a plugin still recorded as outdated.
    func waycarPluginUpdated(on hostID: Host.ID, presence: HostBackendPresence?) {
        let restarting = projections(on: hostID)
        if let presence {
            recordDetectedPresence(presence, on: hostID)
        } else {
            // One started before the update would answer for the old plugin.
            sendBackendDetection(.cancelDetection, on: hostID)
        }
        guard isActive else { return }
        Task { [weak self] in
            for projection in restarting {
                await projection.retry()
            }
            // Deferred only now: until the restarts begin, the old
            // connections still count as settled and would run it at once.
            guard presence == nil, let self, isActive, catalog[hostID] != nil else { return }
            sendBackendDetection(.deferDetection, on: hostID)
            runDeferredConnectWork()
        }
    }

    /// After an install, or Check Again, found a backend on the Host
    /// (WAY-338): records the fresh `presence` and restarts the Host's
    /// projections exactly as a finished plugin update does, so the
    /// projection that failed for want of the backend connects to it now.
    func backendFound(on hostID: Host.ID, presence: HostBackendPresence) {
        waycarPluginUpdated(on: hostID, presence: presence)
    }

    /// A Backend Install ended on the Host (WAY-338). A find reconnects it.
    /// A tmux that landed under the floor is recorded as the Host's tmux, so
    /// the panel offers herdr, not the install that just ended there. Any
    /// other end changes nothing the Console knows.
    func backendInstallEnded(on hostID: Host.ID, outcome: BackendInstallCenter.Outcome) {
        switch outcome.result {
        case .found(let presence):
            forgetLoginPATH(on: hostID)
            backendFound(on: hostID, presence: presence)
        case .failed(.tmuxTooOld(let found)):
            // Install tmux is offered only on a Host with no herdr.
            recordDetectedPresence(HostBackendPresence(herdr: false, tmuxVersion: found), on: hostID)
        case .failed, .hostUnreachable:
            break
        }
    }

    /// An install changes what the Host's login PATH holds (`~/.local/bin`
    /// exists once something is installed there, design C22): the next
    /// herdr-core connection resolves it again.
    private func forgetLoginPATH(on hostID: Host.ID) {
        guard let host = catalog[hostID] else { return }
        inventoryCache?.connectionMemory(for: host).rememberLoginPATH(nil)
    }

    /// Internal fallback when a caller names neither backend nor Workspace.
    /// New Agent supplies its own remembered choice for new Workspaces.
    func defaultNewAgentBackend(on hostID: Host.ID) -> HostBackend {
        let present = presentBackends(on: hostID)
        let lead = leadBackend(on: hostID)
        let slot = present.contains(lead) && lead.fillsHerdrSlot
            ? lead : present.first(where: \.fillsHerdrSlot)
        return slot ?? present.first(where: { $0 == .tmux || $0 == .zellij }) ?? .tmux
    }

    /// Both inventories now show, so repair the old exclusive runtime's
    /// `core_enabled: false` using the core visibility preference. Once per
    /// Host and launch, retried at detection if the Host cannot be reached.
    private func writeCoreEnabledDefault(on hostID: Host.ID, presence: HostBackendPresence) {
        guard presence.bothRuntimesFound else { return }
        _ = sendNotificationVisibilityWrite(.enqueue(.coreDefault), on: hostID)
    }

    /// Writes `core_enabled` over the Host's herdr-slot projection (the new
    /// pick's, once it connects). No Host tools, or no connection, leaves
    /// the file as it is. `onlyIfUnset` leaves a file that already has the
    /// key alone. False when the write could not be tried or failed.
    @discardableResult
    private func writeCoreEnabled(
        _ enabled: Bool, on hostID: Host.ID, onlyIfUnset: Bool = false
    ) async -> Bool {
        guard let projection = primaryProjection(on: hostID) else { return false }
        do {
            try await projection.session.withTransport { transport in
                let current = try await transport.readNotificationConfig()
                if onlyIfUnset, ConsoleStore.hasCoreEnabled(in: current) { return }
                try await transport.replaceNotificationConfig(
                    ConsoleStore.settingCoreEnabled(enabled, in: current))
            }
            return true
        } catch NotificationRegistrationError.pluginNotInstalled {
            // No Host tools: nothing pushes for this Host anyway.
            return true
        } catch {
            Self.log.error("core_enabled write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Show tmux sessions on a Host running both backends. Off ends the tmux
    /// projection, recording nothing, as a Host leaving the catalog does;
    /// on starts it. Either way the Host's `notify.json` learns
    /// `tmux_enabled`, so its notifier stops (or resumes) pushing and
    /// counting tmux Agents. That write is best effort: a Host without the
    /// Host tools, or not connected, keeps its file as it is.
    func setShowsTmux(_ shows: Bool, for hostID: Host.ID) async {
        backendPreferences.setShowsTmux(shows, for: hostID)
        reconcileBackends(on: hostID)
        let write = sendNotificationVisibilityWrite(.enqueue(.tmux(shows)), on: hostID)
        await write?.value
    }

    /// Write before removing the last projection, as core visibility does.
    func setShowsZellij(_ shows: Bool, for hostID: Host.ID) async {
        backendPreferences.setShowsZellij(shows, for: hostID)
        if shows { reconcileBackends(on: hostID) }
        let write = sendNotificationVisibilityWrite(.enqueue(.zellij(shows)), on: hostID)
        await write?.value
        if !shows { reconcileBackends(on: hostID) }
    }

    func setShowsServerChat(_ shows: Bool, _ server: ServerChatBackend, for hostID: Host.ID) {
        backendPreferences.setShowsServerChat(shows, server, for: hostID)
        reconcileBackends(on: hostID)
    }

    /// Hides one runtime without changing the preferred lead. Core's Host
    /// Tools notifications follow its visibility; TUI notifications are
    /// owned by herdr and have no per-runtime switch in the Host Tools.
    func setShowsRuntime(_ shows: Bool, runtime: HerdrRuntime, for hostID: Host.ID) async {
        backendPreferences.setShowsRuntime(shows, runtime: runtime, for: hostID)
        guard runtime == .core else {
            reconcileBackends(on: hostID)
            return
        }
        // Enabling needs a live projection to write through, so reconcile
        // first; disabling must write over the still-live connection before
        // the reconcile tears it down (it may be the last projection).
        if shows { reconcileBackends(on: hostID) }
        let write = sendNotificationVisibilityWrite(.enqueue(.core(shows)), on: hostID)
        await write?.value
        if !shows { reconcileBackends(on: hostID) }
    }

    /// Every flag still resolves the current primary when its FIFO turn
    /// starts, as before; no target capture, service start or retry is added.
    private func sendNotificationVisibilityWrite(
        _ event: NotificationVisibilityWriteMachine.Event, on hostID: Host.ID
    ) -> Task<Void, Never>? {
        var enqueued: Task<Void, Never>?
        let effects = notificationVisibilityWrites[
            hostID, default: NotificationVisibilityWriteMachine()].handle(event)
        for effect in effects {
            switch effect {
            case .enqueue(let token, let predecessor, let operation):
                let earlier = predecessor.flatMap { notificationConfigWrites[hostID]?[$0] }
                let write = Task { [weak self] in
                    await earlier?.value
                    guard let self else { return }
                    let succeeded = await performNotificationVisibilityWrite(operation, on: hostID)
                    _ = sendNotificationVisibilityWrite(.finished(token, succeeded: succeeded), on: hostID)
                }
                notificationConfigWrites[hostID, default: [:]][token] = write
                enqueued = write
            case .release(let token):
                notificationConfigWrites[hostID]?[token] = nil
            }
        }
        return enqueued
    }

    private func performNotificationVisibilityWrite(
        _ operation: NotificationVisibilityWriteMachine.Write, on hostID: Host.ID
    ) async -> Bool {
        switch operation {
        case .core(let enabled):
            return await writeCoreEnabled(enabled, on: hostID)
        case .coreDefault:
            return await writeCoreEnabled(
                backendPreferences.showsRuntime(.core, for: hostID), on: hostID)
        case .tmux(let enabled):
            guard let projection = primaryProjection(on: hostID) else { return false }
            do {
                try await projection.session.withTransport { transport in
                    let current = try await transport.readNotificationConfig()
                    try await transport.replaceNotificationConfig(
                        ConsoleStore.settingTmuxEnabled(enabled, in: current))
                }
                return true
            } catch NotificationRegistrationError.pluginNotInstalled {
                // No Host tools: nothing pushes for this Host anyway.
                return true
            } catch {
                Self.log.error("tmux_enabled write failed: \(error.localizedDescription)")
                return false
            }
        case .zellij(let enabled):
            guard let projection = primaryProjection(on: hostID) else { return false }
            do {
                try await projection.session.withTransport { transport in
                    let current = try await transport.readNotificationConfig()
                    try await transport.replaceNotificationConfig(
                        ConsoleStore.settingZellijEnabled(enabled, in: current))
                }
                return true
            } catch NotificationRegistrationError.pluginNotInstalled {
                // No Host tools: nothing pushes for this Host anyway.
                return true
            } catch {
                Self.log.error("zellij_enabled write failed: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// `notify.json` with `tmux_enabled` set and every other field kept
    /// verbatim; absent or unreadable content starts empty, as
    /// `NotificationConfigFile` reads it.
    nonisolated static func settingTmuxEnabled(_ enabled: Bool, in config: Data?) throws -> Data {
        try setting("tmux_enabled", enabled, in: config)
    }

    nonisolated static func settingZellijEnabled(_ enabled: Bool, in config: Data?) throws -> Data {
        try setting("zellij_enabled", enabled, in: config)
    }

    /// `notify.json` with `core_enabled` set and every other field kept
    /// verbatim, as ``settingTmuxEnabled(_:in:)``.
    nonisolated static func settingCoreEnabled(_ enabled: Bool, in config: Data?) throws -> Data {
        try setting("core_enabled", enabled, in: config)
    }

    /// `notify.json` already has a `core_enabled` field, whatever its value.
    nonisolated static func hasCoreEnabled(in config: Data?) -> Bool {
        guard let config,
            let value = try? JSONDecoder().decode(JSONValue.self, from: config),
            case .object(let object) = value
        else { return false }
        return object["core_enabled"] != nil
    }

    private nonisolated static func setting(
        _ key: String, _ enabled: Bool, in config: Data?
    ) throws -> Data {
        var fields: [String: JSONValue] = [:]
        if let config, let value = try? JSONDecoder().decode(JSONValue.self, from: config),
            case .object(let object) = value
        {
            fields = object
        }
        fields[key] = .bool(enabled)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(fields)
    }

    /// The Host tools' report on Waycar's agent status hooks, over the
    /// Host's tmux projection (design §4.5).
    func statusHooksReport(on hostID: Host.ID) async throws -> StatusHooksReport {
        let backend: HostBackend = presentBackends(on: hostID).contains(.tmux) ? .tmux
            : (presentBackends(on: hostID).contains(.zellij) ? .zellij : .core)
        return try await projection(for: hostID, backend: backend).session.withTransport { transport in
            try await transport.statusHooksReport()
        }
    }

    /// Installs Waycar's agent status hooks on the Host, over its tmux
    /// projection, and returns the resulting report.
    func installStatusHooks(on hostID: Host.ID) async throws -> StatusHooksReport {
        let backend: HostBackend = presentBackends(on: hostID).contains(.tmux) ? .tmux
            : (presentBackends(on: hostID).contains(.zellij) ? .zellij : .core)
        return try await projection(for: hostID, backend: backend).session.withTransport { transport in
            try await transport.installStatusHooks()
        }
    }

    /// Installed backends, less explicitly hidden inventories.
    private func desiredBackends(for hostID: Host.ID) -> [HostBackend] {
        let backends = (backendPresence(on: hostID) ?? .herdrOnly).backends
        // A single terminal Backend remains usable after an uninstall.
        // A server chat runtime's explicit session visibility applies even
        // on a Host with nothing else.
        guard backends.count > 1 || backends.contains(.zellij) || backends.contains(where: \.isServerChat) else { return backends }
        return backends.filter { backend in
            if let server = backend.serverChat {
                return backendPreferences.showsServerChat(server, for: hostID)
            }
            return switch backend {
            case .herdr: backendPreferences.showsRuntime(.tui, for: hostID)
            case .core: backendPreferences.showsRuntime(.core, for: hostID)
            case .tmux: backendPreferences.showsTmux(for: hostID)
            case .zellij: backendPreferences.showsZellij(for: hostID)
            // Server chat runtimes answered above.
            case .ultimate, .codex, .opencode: true
            }
        }
    }

    private func reconcileAllBackends() {
        for hostID in catalog.keys {
            reconcileBackends(on: hostID)
        }
    }

    /// Starts the projections the Host's backends and preferences ask for
    /// and ends the rest. Only this ends a projection while its Host stays:
    /// a failed one is never ended for failing.
    private func reconcileBackends(on hostID: Host.ID) {
        guard let host = catalog[hostID], host.isEnabled else { return }
        let desired = desiredBackends(for: hostID)
        for backend in HostBackend.allCases {
            let scope = ConsoleScope(hostID: hostID, backend: backend)
            if desired.contains(backend), projections[scope] == nil {
                startProjection(for: host, backend: backend, handover: nil)
            } else if !desired.contains(backend), projections[scope] != nil {
                endProjection(scope)
            }
        }
        // Priority changes do not replace projections, but do change all
        // Host-level roles and published status.
        rebuild()
    }

    /// Ends one backend's projection because the Host no longer has that
    /// backend or the user hid it. Like a Host leaving the catalog it
    /// records nothing — no Closed Sessions, no Unread changes — its rows
    /// simply go, with their terminals and cached inventory.
    private func endProjection(_ scope: ConsoleScope) {
        guard let projection = projections.removeValue(forKey: scope) else { return }
        sendBackendDetection(.scopeEnded(scope.backend), on: scope.hostID)
        projection.end()
        let hostID = scope.hostID
        inventoryCache?.remove(hostID, backend: scope.backend)
        persistedInventories[scope] = nil
        terminalSnapshotRevisions[scope] = nil
        terminalTransportGenerations[scope] = nil
        if scope.backend.fillsHerdrSlot {
            // The herdr runtime was the primary projection: the Host-level
            // probes and Chat Marker reads move to tmux's connection.
            sidebarSnapshots.invalidate(hostID)
            sendMosh(.primaryProjectionEnded(hostID))
            chatModeMarkerReads.removeValue(forKey: hostID)?.task?.cancel()
        }
        let backend = scope.backend
        forgetMoshStandbys(on: hostID)
        Task { await agentTerminals.removeHost(hostID, backend: backend) }
    }

    /// Asks the Host which backends it has, once at a time per Host: when
    /// its connection settles after its projections start or the app
    /// activates (`requestBackendDetection`), and at once after a projection
    /// fails for want of its backend. The answer reconciles the Host's
    /// projections; a failed detection changes nothing.
    /// A detection effect may name stopped server chat runtimes whose cheap
    /// probe runs first: only one that now answers earns the exec.
    private func sendBackendDetection(_ event: BackendDetectionMachine.Event, on hostID: Host.ID) {
        var machine = backendDetections[hostID] ?? BackendDetectionMachine()
        let effects = machine.handle(event)
        if backendDetections[hostID]?.state != machine.state { backendDetections[hostID] = machine }
        for effect in effects {
            switch effect {
            case .detect(let token, let checking):
                guard let host = catalog[hostID] else { continue }
                let detect = backendDetector
                let probe = serverRuntimeProbe
                let known = machine.presence
                let stopped = known.map { known in
                    ServerChatBackend.allCases.filter {
                        checking.contains($0) && $0.presence(in: known) != nil
                    }
                } ?? []
                detectionTasks[hostID, default: [:]][token] = Task { [weak self] in
                    let presence: HostBackendPresence?
                    do {
                        if let known, !stopped.isEmpty,
                            try await Self.anyServerAnswers(stopped, host: host, presence: known, probe: probe)
                                == false
                        {
                            presence = nil
                        } else {
                            presence = try await detect(host)
                        }
                    } catch {
                        presence = nil
                        Self.log.info("Backend detection failed: \(error.localizedDescription)")
                    }
                    guard let self else { return }
                    sendBackendDetection(
                        .finished(token, presence: presence, sameHost: catalog[hostID] == host, now: now()),
                        on: hostID)
                }
            case .cancel(let token):
                detectionTasks[hostID]?.removeValue(forKey: token)?.cancel()
            case .release(let token):
                detectionTasks[hostID]?[token] = nil
            case .apply(let cache):
                guard let host = catalog[hostID] else { continue }
                inventoryCache?.savePresence(
                    .init(presence: cache.presence, verifiedAt: cache.verifiedAt), for: host)
                reconcileBackends(on: hostID)
                writeCoreEnabledDefault(on: hostID, presence: cache.presence)
            case .resume(let backend):
                guard let projection = projections[ConsoleScope(hostID: hostID, backend: backend)] else { continue }
                Task { await projection.resume() }
            }
        }
    }

    /// Probes `servers` in order until one answers.
    private nonisolated static func anyServerAnswers(
        _ servers: [ServerChatBackend], host: Host, presence: HostBackendPresence,
        probe: @Sendable (Host, ServerChatBackend, HostBackendPresence) async throws -> Bool
    ) async throws -> Bool {
        for server in servers {
            if try await probe(host, server, presence) { return true }
        }
        return false
    }

    /// How long a detected backend presence stands before the Host is asked
    /// again on start or activation (#105). A failure that says a backend
    /// is missing asks at once whatever its age.
    static let backendPresenceFreshness = BackendDetectionMachine.freshness

    /// Detection on start and activation: skipped while the Host's presence
    /// is fresh, otherwise deferred until its connection settles
    /// (`runDeferredConnectWork`), so the exec never races the first
    /// snapshot or attach (#105). A presence whose Waycar plugin was never
    /// probed (cached by an older build), is missing or outdated counts as
    /// stale, so an install or update made in a terminal clears the prompt
    /// on the next activation (#209, WAY-341). So does one that never asked
    /// about Ultimate projects or a server chat runtime (cached before those
    /// probes). A fresh installed/stopped server chat runtime (Codex) instead
    /// gets its cheap probe (a socket-only check) on connect/foreground;
    /// only an answer triggers a new detection exec.
    private func requestBackendDetection(on hostID: Host.ID) {
        guard catalog[hostID]?.isEnabled == true else { return }
        sendBackendDetection(.request(now: now()), on: hostID)
    }

    /// Starts the connect work that waits for a Host's connection to settle
    /// (#105): its backend detection, and on a Host running herdr too, the
    /// tmux projection's connection.
    private func runDeferredConnectWork() {
        guard isActive else { return }
        for hostID in backendDetections.keys {
            // Only deferred scopes can resume; asking every backend made each
            // rebuild pay for the Host's lead and preferences six times over.
            let deferred = backendDetections[hostID]?.facts.deferredScopes ?? []
            let resumable = deferred.filter {
                !waitsForHerdr(ConsoleScope(hostID: hostID, backend: $0))
            }
            sendBackendDetection(
                .settled(resumable: resumable, detectionReady: hasSettledConnection(hostID),
                         enabled: catalog[hostID]?.isEnabled == true), on: hostID)
        }
    }

    /// Secondary connections wait for the configured lead to settle:
    /// verified by a snapshot, or stopped trying. This includes the other
    /// runtime as well as tmux.
    private func waitsForHerdr(_ scope: ConsoleScope) -> Bool {
        guard scope.backend != leadBackend(on: scope.hostID),
            let slot = projections(on: scope.hostID).first
        else { return false }
        return !Self.hasSettled(slot)
    }

    /// Whether any of the Host's projections has settled.
    private func hasSettledConnection(_ hostID: Host.ID) -> Bool {
        projections(on: hostID).contains(where: Self.hasSettled)
    }

    /// Verified by a live snapshot, or stopped or backing off after a
    /// failure: either way its first connect attempt has answered.
    private static func hasSettled(_ projection: HostConsoleProjection) -> Bool {
        switch projection.status {
        case .failed, .reconnecting: true
        default: isVerified(projection)
        }
    }

    /// A projection stopped because its backend is not there — herdr: no
    /// socket, no binary; tmux: not installed or too old — asks the Host
    /// once which backends it has, fresh presence or not: the other
    /// backend may be there instead. Its failure stands until the answer
    /// says so.
    private func detectAfterMissingBackend(_ current: [HostConsoleProjection]) {
        for projection in current {
            let scope = ConsoleScope(hostID: projection.host.id, backend: projection.backend)
            let shouldDetect: Bool
            switch projection.status {
            case .failed(let failure):
                shouldDetect = scope.backend.isServerChat
                    || Self.meansBackendMissing(failure, backend: projection.backend)
            case .reconnecting where scope.backend.isServerChat:
                // An external stop removes a server chat runtime's projection, rather than
                // leaving a Console failure for an optional stopped service.
                shouldDetect = true
            default:
                shouldDetect = false
            }
            sendBackendDetection(
                .missing(scope.backend, shouldDetect, enabled: catalog[scope.hostID]?.isEnabled == true),
                on: scope.hostID)
        }
    }

    private static func meansBackendMissing(
        _ failure: TransportError, backend: HostBackend
    ) -> Bool {
        switch (backend, failure) {
        case (.herdr, .socketNotFound), (.herdr, .herdrBinaryNotFound): true
        case (.tmux, .tmuxNotInstalled), (.tmux, .tmuxTooOld): true
        case (.core, .coreNotInstalled): true
        case (.zellij, .zellijNotInstalled), (.zellij, .zellijTooOld): true
        case (.herdr, _), (.core, _), (.tmux, _), (.zellij, _), (.ultimate, _), (.codex, _), (.opencode, _): false
        }
    }

    /// Detects the Host's installed Agent kinds and keeps a successful
    /// answer on the device for the connection target it came from
    /// (`cachedAgentKinds(on:)`).
    func availableAgentKinds(on hostID: Host.ID) async throws -> [SupportedAgentKind] {
        let host = catalog[hostID]
        let kinds = try await projection(for: hostID).availableAgentKinds()
        if let host {
            inventoryCache?.saveAgentKinds(
                CachedAgentKinds(kinds: kinds, verifiedAt: now()), for: host)
        }
        return kinds
    }

    /// The Agent kinds the Host's last detection found, kept for its
    /// current connection target; nil when none were.
    func cachedAgentKinds(on hostID: Host.ID) -> CachedAgentKinds? {
        guard let host = catalog[hostID] else { return nil }
        return inventoryCache?.loadAgentKinds(for: host)
    }
    /// Resolves the Host's remote home directory for the New Workspace
    /// directory browser (#280). Throws the error's own presentation,
    /// including homeDirectoryUnresolvable when the probe fails.
    func remoteHomeDirectory(on hostID: Host.ID) async throws -> String {
        try await projection(for: hostID).session.withTransport { transport in
            try await transport.remoteHomeDirectory()
        }
    }

    /// Lists one absolute remote path's subdirectories for the New Workspace
    /// directory browser (#280).
    func listRemoteDirectories(at path: String, on hostID: Host.ID) async throws -> RemoteDirectoryListing {
        try await projection(for: hostID).session.withTransport { transport in
            try await transport.listDirectories(at: path)
        }
    }

    private struct SkillsCacheKey: Hashable {
        let hostID: Host.ID
        let generation: UInt64
        let kind: SupportedAgentKind
        let projectRoot: String?
    }

    /// The Skills pane's data source: probes the Host over its live Console
    /// connection, cached per (connection, kind, project root) until the
    /// connection is replaced. `forceRefresh` is the pane's manual refresh.
    func fetchSkills(
        kind: SupportedAgentKind,
        projectRoot: String?,
        on hostID: Host.ID,
        forceRefresh: Bool = false
    ) async throws -> [AgentSkill] {
        let generation = hostConnectionGenerations[hostID] ?? 0
        let key = SkillsCacheKey(
            hostID: hostID, generation: generation, kind: kind, projectRoot: projectRoot)
        if !forceRefresh, let cached = skillsCache[key] {
            return cached
        }
        let query = SkillListQuery(kind: kind, projectRoot: projectRoot)
        let skills = try await projection(for: hostID).session.withTransport { transport in
            try await transport.listSkills(query)
        }
        skillsCache = skillsCache.filter {
            $0.key.hostID != hostID || $0.key.generation == generation
        }
        skillsCache[key] = skills
        return skills
    }

    /// The skill content sheet's data source: reads one skill document over
    /// the Host's live Console connection. Uncached — it is user-triggered,
    /// one file at a time.
    func readSkillFile(path: String, on hostID: Host.ID) async throws -> String {
        try await projection(for: hostID).session.withTransport { transport in
            try await transport.readSkillFile(atPath: path)
        }
    }

    /// Composer's one-shot delivery source. Prompts borrow the Host's current
    /// Console connection rather than dialing a parallel connection or holding
    /// an RPC open for Agent completion. Never replayed after a link
    /// failure: herdr may already have delivered it, so the Composer shows
    /// the failure and the user resends deliberately. A prompt written
    /// against a last-known row waits for the Host's live snapshot, and goes
    /// out only if that snapshot still has the same terminal on the pane.
    /// A link failure before the Transport had the prompt (no verified rows,
    /// no installed Transport) fails `RequestNotSentError`: nothing left the
    /// device, so the Composer queues it (CONTEXT.md **Queued Message**).
    func promptAgent(_ params: AgentPromptParams, on hostID: Host.ID) async throws -> Agent {
        let projection: HostConsoleProjection
        do {
            // Unverified: with no network path, or a failed, reconnecting
            // or paused Host, the prompt queues at once; a Host still
            // connecting gets up to `verificationTimeout` to verify first.
            // The queue's drain sends it once the Host verifies (CONTEXT.md
            // **Queued Message**).
            projection = try await verifiedRow(
                paneID: params.target, on: hostID, patience: .failsFastOffline
            ).projection
        } catch {
            throw RequestNotSentError.wrapping(error)
        }
        let handedOver = RequestWriteMark()
        do {
            return try await projection.session.withTransport(retryOnLinkFailure: false) {
                transport in
                handedOver.mark()
                return try await transport.promptAgent(params)
            }
        } catch {
            guard !handedOver.isMarked else { throw error }
            throw RequestNotSentError.wrapping(error)
        }
    }

    /// Stops the chat run behind `target` without withdrawing queued
    /// follow-ups (`Transport.abortAgentRun`). The Chat composer's Stop.
    func abortAgentRun(_ target: String, on hostID: Host.ID) async throws {
        let projection = try await verifiedRow(paneID: target, on: hostID).projection
        try await projection.session.withTransport { transport in
            try await transport.abortAgentRun(target: target)
        }
    }

    func pendingAgentRequests(for agent: ConsoleAgent) async throws -> [AgentPendingRequest] {
        let owner = try await verifiedRow(for: agent, patience: .failsFastOffline).projection
        return try await owner.session.withTransport { transport in
            try await transport.pendingAgentRequests(target: agent.agent.paneID)
        }
    }

    func answerAgentRequest(
        for agent: ConsoleAgent, requestID: String, answer: AgentRequestAnswer
    ) async throws {
        let owner = try await verifiedRow(for: agent, patience: .failsFastOffline).projection
        // An approval is never queued or replayed after a lost connection.
        try await owner.session.withTransport(retryOnLinkFailure: false) { transport in
            try await transport.answerAgentRequest(
                target: agent.agent.paneID, requestID: requestID, answer: answer)
        }
    }

    /// The Transport's sign-in and folder-trust screen check for the
    /// Agent in `target` (`Transport.checkAgentInputScreen`).
    func checkAgentInputScreen(_ target: String, on hostID: Host.ID) async throws {
        let projection = try await verifiedRow(paneID: target, on: hostID).projection
        try await projection.session.withTransport { transport in
            try await transport.checkAgentInputScreen(target: target)
        }
    }

    /// One Composer per selected row for the lifetime of its Host catalog
    /// entry. The Console detail may be replaced by a reconnect placeholder;
    /// retaining the store here keeps its entirely local draft intact. A
    /// shell row gets the `pane.send_input` Composer; an Agent the
    /// `agent.prompt` one.
    func composerStore(for agent: ConsoleAgent) -> AgentComposerStore {
        let hostID = agent.hostID
        if agent.isShell {
            if let existing = shellComposerStores[agent.id] { return existing }
            // Send types the draft and Enter in one atomic `pane.send_input`.
            let store = AgentComposerStore(shellPaneID: agent.agent.paneID) {
                [weak self] params in
                guard let self else { throw TransportError.cancelled }
                await self.noteUserInput(to: agent.id)
                try await self.sendPaneInput(params, on: hostID)
            }
            shellComposerStores[agent.id] = store
            return store
        }
        return composerStores[agent.id]
            ?? makeAgentComposerStore(for: agent.id, initialStatus: agent.agent.status)
    }

    /// An Agent Composer for a row or, restoring Queued Messages, for an
    /// Agent no row lists yet: it needs only the pane and the Host.
    private func makeAgentComposerStore(
        for id: ConsoleAgent.ID, initialStatus: AgentStatus
    ) -> AgentComposerStore {
        let hostID = id.hostID
        let store = AgentComposerStore(
            target: id.paneID,
            initialStatus: initialStatus,
            statusUpdates: agentStatusUpdates(for: id),
            outbox: composerOutbox(for: id),
            checkInputScreen: { [weak self] target in
                guard let self else { throw TransportError.cancelled }
                try await self.checkAgentInputScreen(target, on: hostID)
            }
        ) { [weak self] params in
            guard let self else { throw TransportError.cancelled }
            await self.noteUserInput(to: id)
            return try await self.promptAgent(params, on: hostID)
        }
        store.onAgentMessageDelivered = { [weak self] in
            self?.reviewPrompt?.recordValueEvent()
            self?.onSteer?()
        }
        store.onAgentTurnDone = { [weak self] in self?.reviewPrompt?.noteTurnCompleted(agent: id) }
        composerStores[id] = store
        store.setHostReachable(queueProjectionIsVerified(for: id))
        return store
    }

    /// Hands a fresh launch's first message to its Agent's Composer as a
    /// Queued Message (`AgentComposerStore.queueLaunchMessage`): a preset's,
    /// for a kind that takes none on its launch line, and the one typed in
    /// New Agent, with its prepared `attachments` copied from `directory`.
    /// The Composer is made if no row lists the Agent yet; the message goes
    /// out without it ever opening. `.queued` means it is on the device.
    @discardableResult
    func queueLaunchMessage(
        _ text: String, for agent: QueuedMessage.AgentIdentity, on hostID: Host.ID,
        attachments: [QueuedMessage.Attachment] = [], from directory: URL? = nil
    ) -> AgentComposerStore.SendResult {
        let id = ConsoleAgent.ID(hostID: hostID, paneID: agent.paneID)
        let store = composerStores[id]
            ?? makeAgentComposerStore(
                for: id, initialStatus: agents.first { $0.id == id }?.agent.status ?? .idle)
        store.open()
        return store.queueLaunchMessage(
            text, for: agent, attachments: attachments, from: directory)
    }

    // MARK: Queued Messages

    /// An Agent Composer's hooks for its Queued Messages: they persist in
    /// `queuedMessageStore`, drain only in the foreground over verified rows,
    /// check the Agent those rows list, and upload through the Host's
    /// stagers.
    private func composerOutbox(for id: ConsoleAgent.ID) -> ComposerOutbox {
        let stageImage = imageStager(for: id.hostID)
        let stageFile = fileStager(for: id.hostID)
        return ComposerOutbox(
            hostID: id.hostID,
            store: queuedMessageStore,
            identity: { [weak self] in self?.queuedAgentIdentity(for: id) },
            mayDrain: { [weak self] in
                guard let self else { return false }
                return isActive && queueProjectionIsVerified(for: id)
            },
            prepare: { source, directory in
                try await QueuedMessage.Attachment.prepare(source, into: directory)
            },
            upload: { attachment, fileURL in
                try await QueuedMessage.Attachment.upload(
                    attachment, from: fileURL, stageImage: stageImage, stageFile: stageFile)
            },
            sleep: { [weak self] delay in
                let sleep = await MainActor.run { self?.queueRetrySleep }
                try await sleep?(delay)
            },
            countDidChange: { [weak self] count in
                guard let self, queuedMessageCounts[id] ?? 0 != count else { return }
                queuedMessageCounts[id] = count > 0 ? count : nil
            })
    }

    /// The projection that lists, or would list, the Agent's pane.
    private func queueProjection(for id: ConsoleAgent.ID) -> HostConsoleProjection? {
        let backend = agents.first { $0.id == id }?.backend
            ?? paneOwner(id.paneID, on: id.hostID)
        return projection(on: id.hostID, backend: backend)
    }

    private func queueProjectionIsVerified(for id: ConsoleAgent.ID) -> Bool {
        queueProjection(for: id).map(Self.isVerified) ?? false
    }

    /// The Agent on the pane by the Host's verified rows, else by the rows
    /// the Console lists; nil when neither lists it.
    private func queuedAgentIdentity(for id: ConsoleAgent.ID) -> QueuedMessage.AgentIdentity? {
        if let projection = queueProjection(for: id), Self.isVerified(projection) {
            return projection.addressableAgent(id.paneID).map { QueuedMessage.AgentIdentity($0.agent) }
        }
        return addressableAgent(id).map { QueuedMessage.AgentIdentity($0.agent) }
    }

    /// Reads each newly catalogued Host's Queued Messages from the device
    /// into its Agents' Composers, creating any this launch has not made:
    /// a message must survive its Composer never being opened.
    private func restoreQueuedMessages(on hostIDs: [Host.ID]) {
        for hostID in hostIDs where queueRestoredHosts.insert(hostID).inserted {
            let records = queuedMessageStore.messages(on: hostID)
            guard !records.isEmpty else { continue }
            for (id, messages) in Dictionary(grouping: records, by: \.agentID) {
                if QueuedLaunch.launchID(forPendingAgent: id) != nil {
                    if let launch = queuedLaunch(forPendingAgent: id),
                        let store = pendingComposer(for: launch.id)
                    {
                        store.restoreQueued(messages)
                    } else {
                        Self.log.notice("Deleting Queued Messages for a missing Queued Launch")
                        queuedMessageStore.remove(agentID: id)
                    }
                    continue
                }
                let row = addressableAgent(id)
                let store = composerStores[id]
                    ?? makeAgentComposerStore(for: id, initialStatus: row?.agent.status ?? .idle)
                store.open()
                store.restoreQueued(messages)
            }
        }
    }

    /// Tells each Agent Composer whether its Host can take a message now,
    /// and drains its queue each time the Agent's projection is verified on
    /// a new connection while the app is in the foreground: a reconnect, a
    /// network path change's redial, a return, a launch.
    private func reconcileQueuedMessages() {
        for (id, store) in composerStores {
            let projection = queueProjection(for: id)
            let verified = projection.map(Self.isVerified) ?? false
            store.setHostReachable(verified)
            guard verified, isActive, let projection else {
                queueDrainGenerations[id] = nil
                continue
            }
            guard queueDrainGenerations[id] != projection.transportGeneration else { continue }
            queueDrainGenerations[id] = projection.transportGeneration
            store.drainQueue()
        }
        drainBlockedAnswers()
        drainQueuedLaunches()
    }

    // MARK: Queued Launches

    func queuedLaunch(forPendingAgent id: ConsoleAgent.ID) -> QueuedLaunch? {
        guard let launchID = QueuedLaunch.launchID(forPendingAgent: id) else { return nil }
        return queuedLaunches.first { $0.id == launchID && $0.hostID == id.hostID }
    }

    /// A real Composer, but with no Host hooks at all. Even an explicit
    /// drain or staging bind cannot make its messages leave this device.
    func pendingComposer(for id: QueuedLaunch.ID) -> AgentComposerStore? {
        guard let launch = queuedLaunches.first(where: { $0.id == id }),
            let identity = launch.pendingIdentity
        else { return nil }
        if let store = pendingComposerStores[id] { return store }
        let store = AgentComposerStore(
            target: identity.paneID,
            outbox: ComposerOutbox(
                hostID: launch.hostID, store: queuedMessageStore,
                identity: { nil }, mayDrain: { false },
                prepare: { try await QueuedMessage.Attachment.prepare($0, into: $1) },
                upload: { _, _ in throw TransportError.cancelled },
                sleep: { try await Task.sleep(for: $0) }, countDidChange: { _ in }),
            holdingForLaunch: identity
        ) { _ in throw TransportError.cancelled }
        pendingComposerStores[id] = store
        store.restoreQueued(queuedMessageStore.messages(on: launch.hostID).filter {
            $0.agentID == launch.pendingAgentID
        })
        store.setLaunchStarting(launch.lifecycle.isStarting)
        return store
    }

    /// Save deterministic message records before clearing the launch's
    /// old fields. A repeated migration finds those ids without duplicating
    /// them. A non-flag preset precedes the typed First Message and follow-ups;
    /// flag kinds keep their preset on the launch line.
    private func migrateFirstMessage(_ launch: inout QueuedLaunch) throws {
        guard case .agent(let kind) = launch.draft.dispatch.launch else { return }
        let preset = LaunchPromptStager.firstMessageArguments(kind: kind, pointer: "") == nil
            ? launch.draft.presetFirstMessage : nil
        guard preset != nil || launch.draft.firstMessage != nil,
            let identity = launch.pendingIdentity, let composer = pendingComposer(for: launch.id)
        else { return }
        if let preset {
            guard composer.queueLaunchMessage(
                preset, for: identity, id: launch.presetMessageID,
                createdAt: launch.createdAt.addingTimeInterval(-1)) == .queued
            else { throw CocoaError(.fileWriteUnknown) }
            launch.draft.presetFirstMessage = nil
        }
        if let first = launch.draft.firstMessage {
            guard composer.queueLaunchMessage(
                first.text, for: identity, attachments: first.attachments,
                from: queuedLaunchStore.launchDirectory(hostID: launch.hostID, launchID: launch.id),
                id: launch.id, createdAt: launch.createdAt) == .queued
            else { throw CocoaError(.fileWriteUnknown) }
            launch.draft.firstMessage = nil
        }
        try queuedLaunchStore.save(launch)
    }

    /// New Agent's form logic wired to this Console. The sheet
    /// (`StartAgentView`) and a Queued Launch's replay share it, so a replay
    /// launches exactly as the sheet would have, but for one thing: its
    /// start is never sent again after a link failure (`replaying` turns
    /// off `retriesLinkFailure`), since the lost answer may have been a
    /// launch; the replay ends uncertain instead.
    func makeStartAgentStore(
        hosts: [Host], origin: StartAgentStore.LaunchOrigin? = nil,
        quickChat: NewChatPreferences? = nil, preset: AgentLaunchPreset? = nil,
        replaying: Bool = false,
        onAgentStarted: (@MainActor (ConsoleAgent.ID, Bool) -> Void)? = nil
    ) -> StartAgentStore {
        StartAgentStore(
            hosts: hosts,
            workspaces: { self.workspaces(for: $0) },
            existingAgentNames: { hostID in
                Set(self.agents.filter { $0.hostID == hostID }.compactMap { $0.agent.name })
            },
            existingTabLabels: { hostID in
                Set(self.projections(on: hostID).flatMap {
                    $0.inventorySnapshot?.tabs.map(\.label) ?? []
                })
            },
            discoverAgentKinds: { try await self.availableAgentKinds(on: $0) },
            cachedAgentKinds: { self.cachedAgentKinds(on: $0) },
            remoteHome: { try await self.remoteHomeDirectory(on: $0) },
            start: {
                try await self.startAgent(
                    $0, at: $1, on: $2, backend: $3, retriesLinkFailure: !replaying)
            },
            startShell: {
                try await self.startShell(
                    $0, at: $1, on: $2, backend: $3, retriesLinkFailure: !replaying)
            },
            backends: { self.presentBackends(on: $0) },
            defaultBackend: { self.defaultNewAgentBackend(on: $0) },
            showsServerChat: { self.backendPreferences.showsServerChat($1, for: $0) },
            serverRuntimeState: { self.serverRuntimeState($1, on: $0) },
            startServerRuntime: { _ = await self.startRuntime($1.backend, on: $0) },
            createServerSession: { try await self.startAgent($0, on: $1, backend: .opencode) },
            awaitAgentVisible: { await self.waitForAgent($0) },
            onAgentStarted: onAgentStarted,
            origin: origin,
            reviewPrompt: reviewPrompt,
            recordChatMode: { marker, hostID in
                await self.recordChatModeLaunch(marker, hostID: hostID)
            },
            launchPromptHost: { self.launchPromptHost(for: $0) },
            queueLaunchMessage: { self.queueLaunchMessage($0, for: $1, on: $2) },
            queueFirstMessage: { message, directory, agent, hostID in
                self.queueLaunchMessage(
                    message.text, for: agent, on: hostID, attachments: message.attachments,
                    from: directory) == .queued
            },
            launchQueue: StartAgentStore.LaunchQueue(
                store: queuedLaunchStore, enqueue: { try self.enqueueLaunch($0) }),
            quickChat: quickChat,
            preset: preset,
            hasLiveSnapshot: { self.hasLiveSnapshots(on: $0) },
            backendPresence: { self.backendPresence(on: $0) })
    }

    /// Keeps a Start its Host had no verified connection for: on the device
    /// first, so it outlives the app, then listed and drained.
    func enqueueLaunch(_ launch: QueuedLaunch) throws {
        try queuedLaunchStore.save(launch)
        queuedLaunches.append(launch)
        migrateFirstMessageInList(launch.id)
        // Preparation may have outlasted this connection's earlier drain.
        sendLaunchDrain(.invalidate, on: launch.hostID)
        drainQueuedLaunches()
    }

    /// Deletes a Queued Launch and its attachment copies; one whose replay
    /// is under way is past cancelling.
    func cancelQueuedLaunch(_ id: QueuedLaunch.ID) {
        guard let index = queuedLaunches.firstIndex(where: { $0.id == id }),
            !queuedLaunches[index].lifecycle.isStarting
        else { return }
        let launch = queuedLaunches.remove(at: index)
        pendingComposerStores.removeValue(forKey: id)?.cancelQueue()
        // Delete launch-owned records on both sides of a partial move before
        // releasing the real pane. Its own, unrelated Sends stay queued.
        let moved = queuedMessageStore.messages(on: launch.hostID).filter { $0.originLaunchID == id }
        for (agentID, records) in Dictionary(grouping: moved, by: \.agentID) {
            for record in records { queuedMessageStore.remove(record) }
            composerStores[agentID]?.forgetHandedOverMessages(Set(records.map(\.id)))
        }
        queuedMessageStore.remove(agentID: launch.pendingAgentID)
        queuedLaunchStore.remove(launch)
        if let agentID = launch.startedAgentID, let composer = composerStores[agentID] {
            composer.holdingForLaunch = nil
            composer.drainQueue()
        }
    }

    /// Retry on a failed Queued Launch: it waits again and goes
    /// out at once if its Host is verified.
    func retryQueuedLaunch(_ id: QueuedLaunch.ID) {
        guard let index = queuedLaunches.firstIndex(where: { $0.id == id }) else { return }
        // A failed save does not stop the drain.
        for effect in queuedLaunches[index].handle(.retry) {
            try? perform(effect, for: queuedLaunches[index])
        }
    }

    /// Reads each newly catalogued Host's Queued Launches from the device.
    /// One the app ended on while it was starting may have launched: the
    /// next verified connection checks its tag before starting it.
    private func restoreQueuedLaunches(on hostIDs: [Host.ID]) {
        var restored = false
        for hostID in hostIDs where launchRestoredHosts.insert(hostID).inserted {
            for var launch in queuedLaunchStore.launches(on: hostID) {
                for effect in launch.handle(.restored) {
                    try? perform(effect, for: launch)
                }
                queuedLaunches.append(launch)
                migrateFirstMessageInList(launch.id)
                if let agentID = launch.startedAgentID {
                    startedAgentsByQueuedLaunch[launch.id] = agentID
                    // No network is needed to finish a recorded handover.
                    do { try handOverPendingMessages(launch, to: agentID) }
                    catch { Self.log.error("Queued Launch handover failed: \(error.localizedDescription)") }
                }
                restored = true
            }
        }
        if restored { queuedLaunches.sort { $0.createdAt < $1.createdAt } }
    }

    private func migrateFirstMessageInList(_ id: QueuedLaunch.ID) {
        guard let index = queuedLaunches.firstIndex(where: { $0.id == id }) else { return }
        var launch = queuedLaunches[index]
        do { try migrateFirstMessage(&launch) }
        catch {
            let effects = launch.handle(.messagesNotKept)
            // Keep the legacy fields if clearing them did not reach disk.
            launch.draft.presetFirstMessage = queuedLaunches[index].draft.presetFirstMessage
            launch.draft.firstMessage = queuedLaunches[index].draft.firstMessage
            for effect in effects { try? perform(effect, for: launch) }
        }
        queuedLaunches[index] = launch
    }

    /// Performs one of a Queued Launch's effects on `launch` as it is now.
    private func perform(_ effect: QueuedLaunchMachine.Effect, for launch: QueuedLaunch) throws {
        switch effect {
        case .save:
            try queuedLaunchStore.save(launch)
        case .holdRecipient(let paneID):
            guard let pending = launch.pendingIdentity else { return }
            let id = ConsoleAgent.ID(hostID: launch.hostID, paneID: paneID)
            let composer = composerStores[id]
                ?? makeAgentComposerStore(
                    for: id, initialStatus: addressableAgent(id)?.agent.status ?? .idle)
            composer.holdingForLaunch = QueuedMessage.AgentIdentity(
                paneID: paneID, kind: pending.kind, session: nil)
        case .handOver(let paneID):
            try handOverPendingMessages(
                launch, to: ConsoleAgent.ID(hostID: launch.hostID, paneID: paneID))
        case .drain:
            sendLaunchDrain(.invalidate, on: launch.hostID)
            drainQueuedLaunches()
        }
    }

    private func handOverPendingMessages(_ launch: QueuedLaunch, to id: ConsoleAgent.ID) throws {
        if let pending = launch.pendingIdentity {
            // A retry of a partially moved queue must not discard a Send
            // still preparing on the pending Composer. Normal replay waits
            // before starting and then disables Send through the handover.
            guard pendingComposerStores[launch.id]?.messages.contains(where: {
                $0.state == .queued && $0.queued == nil
            }) != true else { throw CocoaError(.fileReadUnknown) }
            let identity = QueuedMessage.AgentIdentity(
                paneID: id.paneID, kind: pending.kind, session: nil)
            let recipient = launch.joinedRunningAgent == true
                ? QueuedMessage.AgentIdentity(paneID: id.paneID, kind: nil, session: nil)
                : identity
            let composer = composerStores[id]
                ?? makeAgentComposerStore(
                    for: id, initialStatus: addressableAgent(id)?.agent.status ?? .idle)
            composer.holdingForLaunch = identity
            composer.open()
            func adoptMovedMessages() {
                let moved = queuedMessageStore.messages(on: launch.hostID).filter { $0.agentID == id }
                composer.restoreQueued(moved, awaitingLaunch: true)
                pendingComposerStores[launch.id]?.forgetHandedOverMessages(Set(moved.map(\.id)))
            }
            do {
                let records = queuedMessageStore.messages(on: launch.hostID)
                    .filter { $0.agentID == launch.pendingAgentID }
                for record in records {
                    _ = try queuedMessageStore.rekey(record, to: recipient, from: launch.id)
                }
                guard !queuedMessageStore.hasMessages(for: launch.pendingAgentID) else {
                    throw CocoaError(.fileReadUnknown)
                }
            } catch {
                // The moved prefix belongs to the real pane already. Make
                // it visible/deletable there before returning the failure;
                // the pending card keeps only the unmoved suffix.
                adoptMovedMessages()
                throw error
            }
            adoptMovedMessages()
            pendingComposerStores[launch.id]?.moveDraft(to: composer)
            composer.holdingForLaunch = nil
            composer.drainQueue()
        }
        startedAgentsByQueuedLaunch[launch.id] = id
        pendingComposerStores.removeValue(forKey: launch.id)?.cancelQueue()
        queuedMessageStore.remove(agentID: launch.pendingAgentID)
        queuedLaunches.removeAll { $0.id == launch.id }
        queuedLaunchStore.remove(launch)
    }

    /// Replays each Host's waiting Queued Launches, oldest first and one at
    /// a time, once per connection its rows are verified on while the app
    /// is in the foreground.
    private func drainQueuedLaunches() {
        let hostIDs = Set(queuedLaunches.lazy.filter(\.lifecycle.awaitsReplay).map(\.hostID))
        for hostID in hostIDs {
            let generation = isActive && hasLiveSnapshots(on: hostID)
                ? primaryProjection(on: hostID)?.transportGeneration : nil
            sendLaunchDrain(.wake(generation: generation), on: hostID)
        }
    }

    private func invalidateLaunchDrains() {
        for hostID in Array(launchDrainMachines.keys) {
            sendLaunchDrain(.invalidate, on: hostID)
        }
    }

    private func sendLaunchDrain(_ event: QueuedLaunchDrainMachine.Event, on hostID: Host.ID) {
        let effects = launchDrainMachines[hostID, default: QueuedLaunchDrainMachine()].handle(event)
        for effect in effects {
            switch effect {
            case .start(let token):
                let task = Task { [weak self] in
                    await self?.replayQueuedLaunches(on: hostID)
                    // A cancelled drain's entry went when it was cancelled.
                    guard !Task.isCancelled else { return }
                    self?.sendLaunchDrain(.finished(token), on: hostID)
                }
                launchDrains[hostID] = (token, task)
            case .finish(let token):
                guard launchDrains[hostID]?.token == token else { continue }
                launchDrains[hostID] = nil
            case .cancel(let token):
                guard launchDrains[hostID]?.token == token else { continue }
                launchDrains.removeValue(forKey: hostID)?.task.cancel()
            case .redrain:
                // Reconnect may have verified while the old try was still
                // Starting. Its token ends before the replacement can drain.
                drainQueuedLaunches()
            }
        }
    }

    private func replayQueuedLaunches(on hostID: Host.ID) async {
        while !Task.isCancelled, isActive, hasLiveSnapshots(on: hostID),
            let next = queuedLaunches.filter({ $0.hostID == hostID && $0.lifecycle.awaitsReplay })
                .min(by: { $0.createdAt < $1.createdAt })
        {
            guard await replay(next) else { return }
        }
    }

    /// Replays one Queued Launch through the sheet's own store. Returns
    /// whether the next may go: not once nothing reached the Host or its
    /// link failed, so the rest wait for its next connection.
    private func replay(_ queued: QueuedLaunch) async -> Bool {
        var launch = queued
        do {
            if let id = launch.startedAgentID {
                try handOverPendingMessages(launch, to: id)
                return true
            }
            try migrateFirstMessage(&launch)
            try await pendingComposerStores[launch.id]?.waitForQueuePreparation()
            try Task.checkCancellation()
        } catch {
            guard !Task.isCancelled,
                let index = queuedLaunches.firstIndex(where: { $0.id == launch.id })
            else { return false }
            for effect in launch.handle(.messagesNotKept) { try? perform(effect, for: launch) }
            queuedLaunches[index] = launch
            return false
        }
        guard let index = queuedLaunches.firstIndex(where: { $0.id == launch.id }),
            queuedLaunches[index].lifecycle.awaitsReplay
        else { return false }
        let pendingIdentity = launch.pendingIdentity
        let launchID = launch.id
        let store = makeStartAgentStore(
            hosts: catalog[launch.hostID].map { [$0] } ?? [], replaying: true,
            onAgentStarted: { [weak self] id, joinedRunningAgent in
                guard let self, !Task.isCancelled, pendingIdentity != nil,
                    let index = queuedLaunches.firstIndex(where: { $0.id == launchID })
                else { return }
                // Before any post-start await can accept a real-pane Send:
                // restore must know to hand over the older pending records.
                let effects = queuedLaunches[index].handle(
                    .agentStarted(paneID: id.paneID, joinedRunningAgent: joinedRunningAgent))
                for effect in effects {
                    do { try perform(effect, for: queuedLaunches[index]) }
                    catch { Self.log.error("Queued Launch start record failed: \(error.localizedDescription)") }
                }
            })
        launch.draft = store.prepareLaunchDraft(launch.draft)
        // Identity and Starting reach disk before dispatch: restore checks
        // the same tag, name and branch. No await separates this save and
        // locking Send.
        do {
            for effect in launch.handle(.dispatching) { try perform(effect, for: launch) }
        } catch { return false }
        queuedLaunches[index] = launch
        pendingComposerStores[launch.id]?.setLaunchStarting(launch.lifecycle.isStarting)
        let outcome = await store.launch(
            launch.draft, mayHaveStarted: launch.mayHaveStarted == true)
        // Its Host was removed or re-targeted meanwhile (which cancels this
        // drain): nothing is left to write back.
        guard !Task.isCancelled,
            queuedLaunches.contains(where: { $0.id == launch.id })
        else { return false }
        let effects: [QueuedLaunchMachine.Effect]
        switch outcome {
        case .started(let agentID, _):
            let joined = queuedLaunches.first { $0.id == launch.id }?.joinedRunningAgent
            let started = launch.handle(.started(paneID: agentID.paneID, joinedRunningAgent: joined))
            do {
                for effect in started { try perform(effect, for: launch) }
                return true
            } catch {
                Self.log.error("Queued Launch handover failed: \(error.localizedDescription)")
                effects = launch.handle(.handoverFailed)
            }
        case .notSent:
            effects = launch.handle(.notSent)
        case .uncertain:
            effects = launch.handle(.answerLost)
        case .failed(let message):
            effects = launch.handle(.refused(message))
        }
        guard !Task.isCancelled,
            let current = queuedLaunches.firstIndex(where: { $0.id == launch.id })
        else { return false }
        for effect in effects { try? perform(effect, for: launch) }
        queuedLaunches[current] = launch
        pendingComposerStores[launch.id]?.setLaunchStarting(launch.lifecycle.isStarting)
        return launch.lifecycle.letsNextReplayGo
    }

    // MARK: Queued Answers

    /// Keeps an Allow or Deny the Host could not be reached for, to go out
    /// when the Agent's Host is back.
    func queueBlockedAnswer(_ pending: PendingBlockedAnswer, for agentID: ConsoleAgent.ID) {
        blockedAnswers.enqueue(pending, for: agentID)
        reconcileQueuedMessages()
    }

    /// The answerer a Queued Answer replays through: this Console's reads
    /// and keys for the Agent. It never queues, so a replay that cannot
    /// reach the Host stays the one queued answer.
    private func makeReplayAnswerer(for id: ConsoleAgent.ID) -> BlockedPromptAnswerer {
        BlockedPromptAnswerer(
            readScreen: { [weak self] in
                guard let self, let agent = self.agents.first(where: { $0.id == id })
                else { throw CancellationError() }
                return try await self.readVisibleScreen(for: agent)
            },
            sendKeys: { [weak self] keys in
                guard let self, let agent = self.agents.first(where: { $0.id == id })
                else { throw CancellationError() }
                try await self.sendKeys(keys, to: agent)
            })
    }

    /// Replays each Queued Answer whose Agent's Host is verified on a
    /// connection it has not tried yet, while the app is in the foreground.
    /// One that the Agent no longer needs (it left Blocked: answered on the
    /// Mac) is dropped silently.
    private func drainBlockedAnswers() {
        // An entry withdrawn, expired or replaced leaves nothing to track.
        let live = Set(blockedAnswers.entries.values.map(\.id))
        blockedAnswerGenerations = blockedAnswerGenerations.filter { live.contains($0.key) }
        for entry in blockedAnswers.entries.values {
            // One replay at a time per entry, whatever the connection did
            // meanwhile: two could both pass the guard and send twice.
            guard !blockedAnswersInFlight.contains(entry.id) else { continue }
            guard isActive, let projection = queueProjection(for: entry.agentID),
                Self.isVerified(projection)
            else {
                blockedAnswerGenerations[entry.id] = nil
                continue
            }
            guard blockedAnswerGenerations[entry.id] != projection.transportGeneration
            else { continue }
            blockedAnswerGenerations[entry.id] = projection.transportGeneration
            guard projection.agentsByPane[entry.agentID.paneID]?.agent.status == .blocked else {
                blockedAnswers.withdraw(agentID: entry.agentID)
                blockedAnswerGenerations[entry.id] = nil
                continue
            }
            let answerer = makeReplayAnswerer(for: entry.agentID)
            blockedAnswersInFlight.insert(entry.id)
            Task { [weak self] in
                let outcome = await answerer.replay(
                    entry.pending,
                    stillWanted: { [weak self] in
                        // Withdrawn, replaced or expired while the screen was read.
                        self?.blockedAnswers.entry(for: entry.agentID)?.id == entry.id
                    },
                    willSend: { [weak self] in self?.blockedAnswers.beginSending(entry) ?? false })
                self?.blockedAnswersInFlight.remove(entry.id)
                self?.finishBlockedAnswer(entry, outcome)
            }
        }
    }

    private func finishBlockedAnswer(
        _ entry: BlockedAnswerQueue.Entry, _ outcome: BlockedPromptAnswerer.Outcome
    ) {
        let finish: BlockedAnswerQueue.Finish
        switch outcome {
        case .sent: finish = .sent
        case .promptChanged: finish = .promptChanged
        case .sendFailed, .abandoned, .busy, .refused, .queued: finish = .notConfirmed
        // Still unreachable or cancelled: it stays queued for the next
        // connection, until it expires.
        case .unreachable, .cancelled: return
        }
        blockedAnswerGenerations[entry.id] = nil
        blockedAnswers.finish(entry, finish)
    }

    /// Shell row Composer delivery. `pane.send_input` works on any Pane,
    /// where `agent.prompt` refuses a plain shell; like prompts it borrows
    /// the Host's current Console connection. Input that submits is never
    /// replayed after a link failure — the shell may already have run it.
    func sendPaneInput(_ params: PaneSendInputParams, on hostID: Host.ID) async throws {
        let (projection, _) = try await verifiedRow(paneID: params.paneID, on: hostID)
        try await projection.session.withTransport(
            retryOnLinkFailure: !params.submitsInput
        ) { transport in
            try await transport.sendPaneInput(params)
        }
    }

    // MARK: Chat Mode

    /// Ultimate conversations and server chat sessions (Codex threads)
    /// always open Chat Mode.
    /// Terminal agents need a Chat Marker on their pane that still
    /// describes the Agent running there.
    func isChatMode(_ agent: ConsoleAgent) -> Bool {
        !agent.backend.hasTerminal || chatMode.isChatMode(agent)
    }

    /// Records a Chat Mode launch that just started: locally at once, so
    /// the Chat view shows before the Host lists the marker, then as the
    /// Host's Chat Marker for every other device and the plugin. A failed
    /// write only logs (the launch itself already succeeded); the next
    /// marker refresh writes it again.
    func recordChatModeLaunch(
        _ marker: ChatModeMarker, hostID: Host.ID, backend: HostBackend? = nil
    ) async {
        chatMode.record(marker, hostID: hostID)
        rebuildAgentOrder()
        await writeChatModeMarker(marker, hostID: hostID, backend: backend)
    }

    private func writeChatModeMarker(
        _ marker: ChatModeMarker, hostID: Host.ID, backend: HostBackend?
    ) async {
        do {
            try await withChatMarkers(on: hostID, backend: backend) { transport in
                try await transport.writeChatModeMarker(marker)
            }
        } catch {
            Self.log.error("Chat Marker write failed: \(error.localizedDescription)")
        }
    }

    /// Archive leaves a desk TUI running, but the folder rule matches only
    /// listed sessions: a pane linked to the session by folder alone would
    /// come back as its own card (card 1611 2a). So Archive first pins that
    /// pane to its session with the plain marker New Agent's own pane gets.
    /// It hides with the archived session, and Resume shows both as one
    /// card again. A pane linked to anything else, or whose folder match is
    /// ambiguous, is never linked by folder, so never pinned. Nothing closes
    /// the pane.
    private func pinFolderLinkedTerminal(of session: ConsoleAgent) {
        guard let server = session.backend.serverChat, server.archivesSessions,
            serverFolderLinkedSessions.contains(session.id),
            let link = serverSessionTerminals[session.id],
            let pane = projection(on: link.id.hostID, backend: link.backend)?
                .agentsByPane[link.id.paneID]
        else { return }
        let marker = ChatModeMarker(
            paneID: pane.agent.paneID, terminalID: pane.agent.terminalID,
            kind: server.agentKind.rawValue,
            cwd: pane.agent.cwd.isEmpty ? session.agent.cwd : pane.agent.cwd,
            session: .init(kind: "id", value: server.sessionID(paneID: session.agent.paneID)),
            chatMode: false, launchedAt: Date())
        // Locally at once, before the archive takes the session's row.
        chatMode.record(marker, hostID: session.hostID)
        rebuildAgentOrder()
        Task { [weak self] in
            await self?.writeChatModeMarker(marker, hostID: session.hostID, backend: link.backend)
        }
    }

    /// Where an Agent's transcript is kept on this device: its pane, its
    /// terminal, and the launch of the Chat Marker that still describes it
    /// (in the marker's wire form; one whose kind or terminal no longer
    /// matches is another Agent's), so a later Agent in the same pane never
    /// opens with it.
    func chatTranscriptKey(for agent: ConsoleAgent) -> ChatTranscriptCache.Key {
        let launchedAt = chatMode.marker(for: agent.id)
            .flatMap { $0.applies(to: agent.agent) ? $0 : nil }
            .map { ChatModeTimestamp.string(from: $0.launchedAt) } ?? ""
        return ChatTranscriptCache.Key(
            hostID: agent.id.hostID,
            paneID: agent.id.paneID,
            terminalID: agent.agent.terminalID,
            launchedAt: launchedAt)
    }

    /// A Chat view's transcript store for `agent`. Reads follow the
    /// Console's current row, whose session and status move on (`/clear`,
    /// turns) after the store was built. The chat opens with the transcript
    /// kept on this device and keeps it current.
    func makeChatTranscriptStore(for agent: ConsoleAgent) -> ChatTranscriptStore {
        let id = agent.id
        let current: @MainActor (ConsoleStore) -> ConsoleAgent = { console in
            console.addressableAgent(id) ?? agent
        }
        let key = chatTranscriptKey(for: current(self))
        let pendingRequests: (@MainActor () async throws -> [AgentPendingRequest])?
        if agent.backend.isServerChat {
            pendingRequests = { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.pendingAgentRequests(for: current(self))
            }
        } else {
            pendingRequests = nil
        }
        return ChatTranscriptStore(
            read: { [weak self] after in
                guard let self else { throw CancellationError() }
                return try await self.readChatTranscript(for: current(self), after: after)
            },
            readScreen: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.readVisibleScreen(for: current(self))
            },
            sendKeys: { [weak self] keys in
                guard let self else { throw CancellationError() }
                try await self.sendKeys(keys, to: current(self))
            },
            queueAnswer: { [weak self] pending in self?.queueBlockedAnswer(pending, for: id) },
            queuedAnswer: { [weak self] in self?.blockedAnswers.entry(for: id) },
            withdrawQueuedAnswer: { [weak self] in self?.blockedAnswers.withdraw(agentID: id) },
            initialStatus: current(self).agent.status,
            pendingRequests: pendingRequests,
            answerRequest: { [weak self] requestID, answer in
                guard let self else { throw CancellationError() }
                try await self.answerAgentRequest(
                    for: current(self), requestID: requestID, answer: answer)
            },
            statusUpdateSource: { [weak self] in
                self?.agentStatusUpdates(for: id)
            },
            cachedMessages: chatTranscriptCache?.messages(for: key) ?? [],
            // Saved under the listed row's key at the time: an Agent that
            // closed (its copy already removed) or whose pane now runs
            // another launch never writes into a copy that isn't its own.
            // Through the same merge as the terminal screen's reads, so
            // neither shrinks what the other kept.
            persist: { [weak self] messages in
                guard let self, let row = self.addressableAgent(id),
                    self.isChatMode(row)
                else { return }
                self.keepTranscript(messages, isWholeList: true, truncated: false, for: row)
            })
    }

    /// Reads a Chat Mode Agent's transcript from its Host. The live
    /// session wins over the one the marker holds (it follows `/clear`);
    /// the marker's cwd and launch time locate a transcript the Agent
    /// reports no session for yet, and the match then sticks to the marker
    /// (`bindChatTranscript`).
    func readChatTranscript(
        for agent: ConsoleAgent, after: String?
    ) async throws -> ChatTranscriptSnapshot {
        // The listed row carries the newest session and the status shown;
        // one on another terminal is a different Agent in the same pane.
        let listed = listedAgent(agent.id)
            .flatMap { $0.agent.terminalID == agent.agent.terminalID ? $0 : nil } ?? agent
        let marker = chatMode.marker(for: agent.id).flatMap {
            $0.applies(to: listed.agent) ? $0 : nil
        }
        let session: ChatModeMarker.Session? =
            if let live = listed.agent.agentSession, !live.value.isEmpty {
                ChatModeMarker.Session(kind: live.kind.rawValue, value: live.value)
            } else {
                marker?.session
            }
        let request = ChatTranscriptRequest(
            paneID: listed.agent.paneID,
            kind: listed.agent.kind,
            sessionKind: session?.kind,
            sessionValue: session?.value,
            cwd: listed.agent.cwd.isEmpty ? marker?.cwd : listed.agent.cwd,
            launchedAt: marker?.launchedAt,
            status: listed.agent.status,
            after: after)
        // The transcript is the Agent's own: read over the backend running it.
        let owner = try projection(for: agent.hostID, backend: agent.backend)
        let snapshot = try await owner.session.withTransport { transport in
            try await transport.readChatTranscript(request)
        }
        if session == nil, let marker, snapshot.header.status == .ok,
            let path = snapshot.header.transcript, !path.isEmpty
        {
            bindChatTranscript(path, of: agent.id, launchedWith: marker)
        }
        return snapshot
    }

    /// Makes the transcript the reader matched by cwd and launch time stick
    /// to its Agent: the marker names it from now on, so later reads and
    /// the plugin's reply push stop matching, and a newer transcript in the
    /// same cwd can never take over. A live session herdr reports still
    /// wins (it follows `/clear`). Writing the Host's copy is best effort;
    /// a failed write is retried by the next marker refresh.
    private func bindChatTranscript(
        _ path: String, of id: ConsoleAgent.ID, launchedWith marker: ChatModeMarker
    ) {
        // The read may have outlived its marker; a newer launch's is another Agent's.
        guard chatMode.marker(for: id) == marker,
            let bound = chatMode.updateSession(.init(kind: "path", value: path), for: id)
        else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await withChatMarkers(on: id.hostID) { transport in
                    try await transport.writeChatModeMarker(bound)
                }
            } catch {
                Self.log.error("Chat Marker write failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Offline reading

    /// Which Agent in a terminal a saved copy belongs to, beyond its cache key
    /// (pane, terminal, a chat's launch). herdr keeps pane and terminal ids
    /// when it replaces an Agent typed into the same pane, and when a server
    /// restart resumes one under a new session, so for the same terminal:
    /// - A Chat Mode Agent's launch (its Chat Marker, part of the key) is its
    ///   identity whatever its session does (`/clear` moves it within the
    ///   launch): "".
    /// - Any other Agent's identity is the session herdr reports for it,
    ///   `Agent.kind` and `agent_session.value` (`QueuedMessage.AgentIdentity`
    ///   trusts the same value). A copy saved under another session is not
    ///   shown and not merged for this one; the next read replaces it.
    /// - An Agent that reports no session has no identity, so nothing is
    ///   kept for it and nothing shown: a read cannot say whose it is, and a
    ///   launch just started (nil, then a session) simply has no copy until
    ///   its first read after the session appears. Nothing is orphaned,
    ///   because nothing was saved under "no session".
    func transcriptIdentity(for agent: ConsoleAgent) -> String? {
        // Only a real Chat Mode Agent rides on its launch; a plain launch's
        // pin names a launch too (in the key) but says nothing of which
        // session now runs.
        if chatMode.isChatMode(agent) { return "" }
        guard let session = agent.agent.agentSession, !session.value.isEmpty else { return nil }
        return "s:\(agent.agent.kind)/\(session.value)"
    }

    /// The identity (`transcriptIdentity(for:)`) of the Agent now on `agent`'s
    /// pane, from the live row: a screen holds the row it opened with, whose
    /// session may be older. The row it opened with when the pane is gone.
    func currentTranscriptIdentity(for agent: ConsoleAgent) -> String? {
        transcriptIdentity(for: transcriptOwner(of: agent) ?? agent)
    }

    /// The copy of `agent`'s conversation this device kept, for reading with
    /// no connection; nil when it holds no message, or none under this
    /// Agent's identity (`transcriptIdentity(for:)`, of its live row).
    func savedTranscript(for agent: ConsoleAgent) -> SavedTranscript? {
        let row = transcriptOwner(of: agent) ?? agent
        guard let cache = chatTranscriptCache, let identity = transcriptIdentity(for: row)
        else { return nil }
        let key = chatTranscriptKey(for: row)
        let messages = cache.messages(for: key, identity: identity)
        guard !messages.isEmpty, let savedAt = cache.savedAt(for: key, identity: identity)
        else { return nil }
        return SavedTranscript(messages: messages, savedAt: savedAt)
    }

    /// `readChatTranscript(for:after:)` of the whole conversation, which
    /// also keeps what it reads for offline reading. A read that did not
    /// find the transcript keeps nothing, and neither does one for an Agent
    /// with no identity, or whose Agent left, started another launch or
    /// reported another session while it ran (`transcriptIdentity(for:)`).
    func readChatTranscriptSaving(for agent: ConsoleAgent) async throws -> ChatTranscriptSnapshot {
        let before = transcriptOwner(of: agent)
        let beforeKey = before.map(chatTranscriptKey(for:))
        let beforeIdentity = before.flatMap(transcriptIdentity(for:))
        let snapshot = try await readChatTranscript(for: agent, after: nil)
        if snapshot.header.status == .ok, let beforeKey, let beforeIdentity,
            let row = transcriptOwner(of: agent),
            chatTranscriptKey(for: row) == beforeKey,
            transcriptIdentity(for: row) == beforeIdentity
        {
            keepTranscript(
                snapshot.messages, isWholeList: true, truncated: snapshot.header.truncated,
                for: row)
        }
        return snapshot
    }

    /// The row the Console lists for `agent`'s pane while it still runs the
    /// same terminal; nil once it closed or another Agent took the pane.
    private func transcriptOwner(of agent: ConsoleAgent) -> ConsoleAgent? {
        addressableAgent(agent.id).flatMap {
            $0.agent.terminalID == agent.agent.terminalID ? $0 : nil
        }
    }

    /// Merges what a read of `row`'s transcript answered into the copy kept
    /// on this device (`ChatTranscriptMerge`), or marks the copy current
    /// when nothing changed. A list that starts inside the copy, or that the
    /// reader cut older messages from, never makes the copy smaller; one
    /// sharing no message with it (`/clear`, a new session in the same
    /// terminal) replaces it unless the reader truncated. The copy merged
    /// into is the one under `row`'s identity: another Agent's is replaced.
    private func keepTranscript(
        _ incoming: [ChatTranscriptMessage], isWholeList: Bool, truncated: Bool,
        for row: ConsoleAgent
    ) {
        guard let cache = chatTranscriptCache, let identity = transcriptIdentity(for: row)
        else { return }
        let key = chatTranscriptKey(for: row)
        let cached = cache.messages(for: key, identity: identity)
        let merged = ChatTranscriptMerge.merged(
            cached: cached, incoming: incoming, isWholeList: isWholeList, truncated: truncated)
        guard !merged.isEmpty else { return }
        if merged == cached {
            // The saved time moved: the reader's "Saved X ago" looks again.
            if cache.confirm(key, identity: identity) {
                savedTranscriptRevisions[row.id, default: 0] += 1
            }
        } else {
            cache.save(merged, for: key, identity: identity)
            savedTranscriptRevisions[row.id, default: 0] += 1
        }
    }

    private func makeTranscriptPrefetcher(keeping cache: ChatTranscriptCache) -> ChatTranscriptPrefetcher {
        ChatTranscriptPrefetcher(
            source: .init(
                isActive: { [weak self] in self?.isActive ?? false },
                agents: { [weak self] in self?.agents ?? [] },
                canRead: { [weak self] agent in
                    guard let self, let projection = queueProjection(for: agent.id),
                        Self.isVerified(projection),
                        let reads = chatModeMarkerReads[agent.hostID],
                        reads.machine.isConfirmed
                    else { return false }
                    return WatchStateBuilder.readsTranscript(agent, isChatMode: isChatMode(agent))
                },
                savedAt: { [weak self] agent in
                    guard let self, let identity = transcriptIdentity(for: agent) else { return nil }
                    return cache.savedAt(for: chatTranscriptKey(for: agent), identity: identity)
                },
                fetch: { [weak self] agent in
                    guard let self else { throw CancellationError() }
                    _ = try await readChatTranscriptSaving(for: agent)
                },
                now: { [weak self] in self?.now() ?? Date() },
                sleep: { try await Task.sleep(for: $0) }))
    }

    // MARK: Chat media

    /// A local file holding one chat media item, with the extension Quick
    /// Look and the decoders need. Content-addressed items (omp/pi blobs,
    /// inline transcript images, opencode session-inline images, `https`
    /// URLs) come from the device cache
    /// when there; any other Host file is fetched fresh on every load, since
    /// the file at a path can change. A Host file comes over SFTP (`~/` and
    /// relative paths resolved against the Host's home and the Agent's cwd),
    /// an inline transcript image through the plugin's media reader, both
    /// over the backend running the Agent, and an `https` URL on the phone
    /// through one global transfer limit.
    /// Concurrent requests for one item share a fetch.
    func chatMediaFile(for media: ChatMedia, agent: ConsoleAgent) async throws -> URL {
        let key: String
        let path: String?
        let cacheable: Bool
        let fetch: @Sendable (Int) async throws -> Data
        let hostID = agent.hostID
        switch media.source {
        case .hostFile(let printed):
            let resolved = try await resolveChatMediaPath(printed, agent: agent)
            let session = try projection(for: hostID, backend: agent.backend).session
            let transfers = chatMediaTransfers(for: hostID)
            cacheable = media.id.hasPrefix(ChatMedia.blobIDPrefix)
            key = cacheable ? "blob|\(media.id)" : "\(hostID.uuidString)|file|\(resolved)"
            path = resolved
            fetch = { maxBytes in
                do {
                    return try await transfers.run {
                        try await session.withTransport { transport in
                            try await transport.readPreviewFile(atPath: resolved, maxBytes: maxBytes)
                        }
                    }
                } catch RemoteFilePreviewError.tooLarge {
                    throw ChatMediaError.tooLarge
                } catch is RemoteFilePreviewError {
                    throw ChatMediaError.unavailable
                }
            }
        case .inline(let transcript, let offset, let pointer):
            let session = try projection(for: hostID, backend: agent.backend).session
            let transfers = chatMediaTransfers(for: hostID)
            key = "\(hostID.uuidString)|inline|\(transcript)|\(offset)|\(pointer)"
            path = nil
            cacheable = true
            fetch = { maxBytes in
                try await transfers.run {
                    try await session.withTransport { transport in
                        try await transport.readChatMedia(
                            ChatMediaRequest.line(
                                transcript: transcript, offset: offset, pointer: pointer,
                                maxBytes: maxBytes))
                    }
                }
            }
        case .sessionInline(let exportSession, let pointer, let agentKind):
            let session = try projection(for: hostID, backend: agent.backend).session
            let transfers = chatMediaTransfers(for: hostID)
            key = "\(hostID.uuidString)|inline|session|\(agentKind ?? "")|\(exportSession)|\(pointer)"
            path = nil
            cacheable = true
            fetch = { maxBytes in
                try await transfers.run {
                    try await session.withTransport { transport in
                        try await transport.readChatMedia(
                            ChatMediaRequest.sessionInline(
                                session: exportSession, id: media.id, pointer: pointer,
                                agentKind: agentKind, maxBytes: maxBytes))
                    }
                }
            }
        case .web(let url):
            guard url.scheme?.lowercased() == "https" else { throw ChatMediaError.unsupported }
            key = "web|\(url.absoluteString)"
            path = url.path(percentEncoded: false)
            cacheable = true
            fetch = { maxBytes in
                try await ChatMediaTransfers.web.run {
                    try await ChatMediaWebDownload.data(from: url, maxBytes: maxBytes)
                }
            }
        }
        if let pending = chatMediaLoads[key] { return try await pending.value }
        let load = Task.detached { [cache = cacheable ? chatMediaCache : nil, scratch = chatMediaScratchDirectory] in
            try await Self.loadChatMedia(
                key: key, path: path, mime: media.mime, kind: media.kind,
                maxBytes: media.maximumBytes, fetch: fetch,
                cache: cache, scratch: scratch)
        }
        chatMediaLoads[key] = load
        defer { if chatMediaLoads[key] == load { chatMediaLoads[key] = nil } }
        return try await load.value
    }

    private func chatMediaTransfers(for hostID: Host.ID) -> ChatMediaTransfers {
        if let transfers = chatMediaTransfers[hostID] { return transfers }
        let transfers = ChatMediaTransfers()
        chatMediaTransfers[hostID] = transfers
        return transfers
    }

    /// The folder a relative path the Agent printed resolves against: its
    /// listed row's cwd (the pane's, while that pane is still the Agent's),
    /// or, while tmux reports none, the cwd its Chat Mode marker recorded.
    /// Nil with neither. Thumbnails and previews of the same printed path
    /// read the same folder through this.
    func mediaWorkingDirectory(for agent: ConsoleAgent) -> String? {
        let listed = listedAgent(agent.id)
            .flatMap { $0.agent.terminalID == agent.agent.terminalID ? $0 : nil } ?? agent
        if !listed.agent.cwd.isEmpty { return listed.agent.cwd }
        guard let cwd = chatMode.marker(for: agent.id)?.cwd, !cwd.isEmpty else { return nil }
        return cwd
    }

    /// The absolute Host path a chat names: `~/` against the Host's home
    /// (asked once per Host), a relative path against the Agent's cwd
    /// (`mediaWorkingDirectory(for:)`).
    private func resolveChatMediaPath(_ printed: String, agent: ConsoleAgent) async throws -> String {
        let cwd = mediaWorkingDirectory(for: agent)
        var home: String?
        if TerminalPathResolver.needsHomeDirectory(printed) {
            if let known = chatMediaHomes[agent.hostID] {
                home = known
            } else {
                let resolved = try await resolveChatMediaHome(agent.hostID)
                chatMediaHomes[agent.hostID] = resolved
                home = resolved
            }
        }
        guard
            let path = TerminalPathResolver.resolve(
                printed, workingDirectory: cwd, homeDirectory: home)
        else { throw ChatMediaError.unavailable }
        return path
    }

    /// The cached file for `key`, else the fetched bytes stored there; with
    /// no cache, in `scratch` under a folder from `key`, named after the
    /// Host file (`displayName`), so Quick Look titles it with the name the
    /// user knows; each fetch overwrites it. Off the main actor: files may
    /// be 100 MiB.
    private nonisolated static func loadChatMedia(
        key: String, path: String?, mime: String?, kind: ChatMedia.Kind, maxBytes: Int,
        fetch: @Sendable (Int) async throws -> Data,
        cache: ChatMediaCache?, scratch: URL
    ) async throws -> URL {
        // A file cached before `.file` copies went through the preview rule
        // keeps its own extension; fetch it again so it is stored as text.
        if let cached = cache?.file(for: key),
            kind != .file || ChatMedia.isPreviewableFile(extension: cached.pathExtension)
        {
            return cached
        }
        let data = try await fetch(maxBytes)
        guard data.count <= maxBytes else { throw ChatMediaError.tooLarge }
        guard let ext = ChatMedia.fileExtension(path: path, mime: mime, data: data, kind: kind) else {
            throw ChatMediaError.unsupported
        }
        if let cache {
            return try cache.store(data, for: key, pathExtension: ext)
        }
        let folder = scratch.appending(
            path: (ChatMediaCache.fileName(for: key, pathExtension: ext) as NSString)
                .deletingPathExtension,
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(
            path: displayName(forRemotePath: path, pathExtension: ext), directoryHint: .notDirectory)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// The Host file's own name with the extension the bytes are shown as:
    /// a last path component never contains `/`, and `.`/`..`/empty fall
    /// back to `file`, so the name cannot leave its folder. A name past the
    /// file system's 255-byte limit falls back to `file` too, rather than
    /// failing the write.
    nonisolated static func displayName(forRemotePath path: String?, pathExtension ext: String) -> String {
        var name = ((path ?? "") as NSString).lastPathComponent
        if name.isEmpty || name == "/" || name == "." || name == ".." {
            name = "file"
        }
        if (name as NSString).pathExtension.lowercased() != ext.lowercased() {
            name += "." + ext
        }
        return name.utf8.count <= 255 ? name : "file." + ext
    }

    /// Records the Agents a live snapshot no longer runs as Closed Sessions,
    /// then retires their panes' markers and drops the chat ones' on-device
    /// transcripts: their records have already kept Chat Mode and the
    /// session, and an Agent typed into the same pane later (same pane and
    /// terminal ids) was never given the Chat Prompt or the pin.
    /// A closed Agent's session is the one the Backend reported (herdr's
    /// `agent_session`, a tmux Status Hook's), else the one its launch
    /// pinned or bound in its marker: herdr reports none for most kinds
    /// without its own integration.
    /// Across a gap a session switched in place (`/clear`, `/resume`) is
    /// captured as well; while the pane still runs an Agent its marker
    /// describes, the marker stays. It also stays while the pane may still
    /// be restoring the Agent (`mayBeRestoring`); once the restored Agent
    /// reports its session the marker either matches it by session or
    /// simply never applies. Deleting the Host's copy is best effort: the
    /// marker refresh deletes it again while the Host still lists it.
    private func agentsDidClose(_ captures: [ClosedAgentCapture], on scope: ConsoleScope) {
        let hostID = scope.hostID
        let running = projections[scope]?.agentsByPane ?? [:]
        let markedRows = captures.map(\.row).filter { row in
            guard chatMode.hasMarker(row) else { return false }
            guard let successor = running[row.agent.paneID] else { return true }
            return !chatMode.hasMarker(successor) && !Self.mayBeRestoring(successor, of: row)
        }
        // Capture callbacks precede the merge publishing the new inventory:
        // the old thread row still knows the pane whose identity it owned.
        closedSessions.record(
            captures.filter { !serverLinkedPanes.contains($0.row.id) }
                .map { $0.withLaunchSession(from: chatMode.marker(for: $0.row.id)) })
        // A plain Agent's saved conversation goes with it; a chat's goes with
        // its marker, below.
        for row in captures.map(\.row) where !chatMode.hasMarker(row) {
            chatTranscriptCache?.remove(chatTranscriptKey(for: row))
        }
        guard !markedRows.isEmpty else { return }
        for row in markedRows {
            chatMode.retire(row.id)
            chatTranscriptCache?.remove(hostID: row.id.hostID, paneID: row.agent.paneID)
        }
        Task { [weak self] in
            guard let self else { return }
            for row in markedRows {
                do {
                    try await withChatMarkers(on: hostID, backend: scope.backend) { transport in
                        try await transport.deleteChatModeMarker(paneID: row.agent.paneID)
                    }
                } catch {
                    Self.log.error("Chat Marker delete failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Whether `successor`, now in a closed chat row's pane, may be that
    /// chat still being restored by herdr: a new terminal that herdr has not
    /// identified an Agent in yet (a shell row, or `Agent.unidentifiedKind`),
    /// or the same kind there with no session reported yet. A chat Agent
    /// exiting to its shell keeps its terminal, so it is still retired.
    private static func mayBeRestoring(_ successor: ConsoleAgent, of row: ConsoleAgent) -> Bool {
        guard successor.agent.terminalID != row.agent.terminalID else { return false }
        if successor.isShell || successor.agent.kind == Agent.unidentifiedKind { return true }
        return successor.agent.kind == row.agent.kind
            && (successor.agent.agentSession?.value ?? "").isEmpty
    }

    /// The Agent's visible screen as plain text: what a Blocked Agent is
    /// asking, shown in the Chat view's Blocked card.
    func readVisibleScreen(for agent: ConsoleAgent) async throws -> String {
        let params = PaneReadParams(
            paneID: agent.agent.paneID, source: .visible, format: .text, stripANSI: true)
        let owner = try projection(for: agent.hostID, backend: agent.backend)
        return try await owner.session.withTransport { transport in
            try await transport.readPane(params).text
        }
    }

    /// Scrolls a tmux pane's view through its history in copy mode
    /// (``Transport/scrollPaneHistory(paneID:towardOlderContent:rows:)``).
    /// Never replayed after a link failure: a scroll that went out would
    /// move twice.
    func scrollPaneHistory(
        for agent: ConsoleAgent, towardOlderContent: Bool, rows: Int
    ) async throws -> PaneHistoryScroll {
        let paneID = agent.agent.paneID
        let owner = try projection(for: agent.hostID, backend: agent.backend)
        return try await owner.session.withTransport(retryOnLinkFailure: false) { transport in
            try await transport.scrollPaneHistory(
                paneID: paneID, towardOlderContent: towardOlderContent, rows: rows)
        }
    }

    /// Takes a tmux pane's view out of copy mode, back to live output.
    func leavePaneHistory(for agent: ConsoleAgent) async throws {
        let paneID = agent.agent.paneID
        let owner = try projection(for: agent.hostID, backend: agent.backend)
        try await owner.session.withTransport { transport in
            try await transport.leavePaneHistory(paneID: paneID)
        }
    }

    /// A tmux Attach's copy-mode scroll path over the two calls above; nil
    /// on herdr. A tmux attach shows only tmux's redraw, so an inline
    /// agent's or a shell's history is reachable only through the pane's
    /// copy mode. One per Attach (``AgentAttachStore/paneHistory``).
    func makePaneHistory(for agent: ConsoleAgent) -> TmuxPaneHistory? {
        guard agent.backend == .tmux else { return nil }
        return TmuxPaneHistory { [weak self] towardOlderContent, rows in
            guard let self else { throw CancellationError() }
            return try await self.scrollPaneHistory(
                for: agent, towardOlderContent: towardOlderContent, rows: rows)
        } leave: { [weak self] in
            try await self?.leavePaneHistory(for: agent)
        }
    }

    /// Named keys to the Agent (`agent.send_keys`): the Blocked card's
    /// Allow and Cancel. Never replayed after a link failure — herdr may
    /// already have answered the prompt with them.
    func sendKeys(_ keys: [String], to agent: ConsoleAgent) async throws {
        let (projection, row) = try await verifiedRow(for: agent)
        noteUserInput(to: agent.id)
        let params = AgentSendKeysParams(keys: keys, target: row.agent.paneID)
        try await projection.session.withTransport(retryOnLinkFailure: false) { transport in
            try await transport.sendAgentKeys(params)
        }
        onSteer?()
    }

    /// Types `text` into the Agent's pane without Enter (`pane.send_input`
    /// with no keys): a Chat view send while the Agent is Blocked, left for
    /// the user to submit in the terminal.
    func insertText(_ text: String, into agent: ConsoleAgent) async throws {
        noteUserInput(to: agent.id)
        try await sendPaneInput(
            PaneSendInputParams(paneID: agent.agent.paneID, text: text), on: agent.hostID)
    }

    /// A latest-value view of the existing `pane.agent_status_changed`
    /// subscription for one Agent. Composer consumes it for delivery
    /// transitions without opening another event channel.
    func agentStatusUpdates(for id: ConsoleAgent.ID) -> AsyncStream<AgentStatusUpdate> {
        let observerID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentStatusUpdate.self, bufferingPolicy: .bufferingNewest(1))
        agentStatusObservers[id, default: [:]][observerID] = continuation
        continuation.yield(agentStatusUpdate(for: id))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.removeAgentStatusObserver(observerID, for: id)
            }
        }
        return stream
    }

    // Every launch takes a trailing `backend` (ADR 0026): nil runs it on the
    // backend whose snapshot holds the request's Workspace, or with no
    // Workspace on the Host's New Agent default (`defaultNewAgentBackend`).

    @discardableResult
    func startAgent(
        _ request: AgentLaunchRequest,
        on hostID: Host.ID,
        backend: HostBackend? = nil
    ) async throws -> Agent {
        try await verifiedProjection(
            for: hostID,
            backend: launchBackend(backend, workspaceID: request.workspaceID, on: hostID)
        ).startAgent(request)
    }

    func refreshTerminalInventory(on hostID: Host.ID) async {
        for projection in projections(on: hostID) {
            await projection.refreshTerminalInventory()
        }
    }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest,
        on hostID: Host.ID,
        backend: HostBackend? = nil
    ) async throws -> ShellTerminalIdentity {
        try await verifiedProjection(
            for: hostID,
            backend: launchBackend(backend, workspaceID: request.workspaceID, on: hostID)
        ).createShellTerminal(request)
    }

    @discardableResult
    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest,
        worktree: WorktreeSpec,
        on hostID: Host.ID,
        backend: HostBackend? = nil
    ) async throws -> Agent {
        try await verifiedProjection(
            for: hostID,
            backend: launchBackend(backend, workspaceID: request.workspaceID, on: hostID)
        ).startAgentInNewWorktree(request, worktree: worktree)
    }

    @discardableResult
    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest,
        workspace: NewWorkspaceSpec,
        on hostID: Host.ID,
        backend: HostBackend? = nil
    ) async throws -> Agent {
        try await verifiedProjection(
            for: hostID,
            backend: launchBackend(backend, workspaceID: request.workspaceID, on: hostID)
        ).startAgentInNewWorkspace(request, workspace: workspace)
    }

    /// The launch variant a New Agent destination names: a fresh tab in an
    /// existing Workspace, a new Worktree of one, or a new Workspace. A Host
    /// whose rows never verified fails `RequestNotSentError`: nothing was
    /// sent, so a Queued Launch waits for its next connection.
    /// `retriesLinkFailure` false never sends the start again after a link
    /// failure (a Queued Launch's replay).
    @discardableResult
    func startAgent(
        _ request: AgentLaunchRequest,
        at destination: StartAgentStore.LaunchDestination,
        on hostID: Host.ID,
        backend: HostBackend? = nil,
        retriesLinkFailure: Bool = true
    ) async throws -> Agent {
        let resolvedBackend = launchBackend(backend, workspaceID: request.workspaceID, on: hostID)
        let projection = try await launchProjection(on: hostID, backend: resolvedBackend)
        if let server = resolvedBackend.serverChat {
            return try await startServerChatAgent(
                server, request: request, destination: destination, projection: projection,
                on: hostID, retriesLinkFailure: retriesLinkFailure)
        }
        switch destination {
        case .existingWorkspace:
            return try await projection.startAgent(request, retriesLinkFailure: retriesLinkFailure)
        case .newWorktree(let worktree):
            return try await projection.startAgentInNewWorktree(
                request, worktree: worktree, retriesLinkFailure: retriesLinkFailure)
        case .newWorkspace(let workspace):
            return try await projection.startAgentInNewWorkspace(
                request, workspace: workspace, retriesLinkFailure: retriesLinkFailure)
        }
    }

    /// A server chat session owns the launch. Its optional desk TUI, a pane
    /// on the lead visible terminal runtime running the server's resume
    /// command, gets the same Launch Tag, so a replay reconciles both halves
    /// independently. Its Chat Marker links it to the session, which hides
    /// it behind Show Terminal (`ServerSessionLinks`).
    private func startServerChatAgent(
        _ server: ServerChatBackend, request: AgentLaunchRequest,
        destination: StartAgentStore.LaunchDestination, projection: HostConsoleProjection,
        on hostID: Host.ID, retriesLinkFailure: Bool
    ) async throws -> Agent {
        var launch = ServerChatLaunchMachine()
        var effects = launch.handle(.begin)
        while !effects.isEmpty {
            let effect = effects.removeFirst()
            do {
                switch effect {
                case .startSession(let token):
                    let session: Agent
                    if case .newWorkspace(let workspace) = destination {
                        session = try await projection.startAgentInNewWorkspace(
                            request, workspace: workspace, retriesLinkFailure: retriesLinkFailure)
                    } else {
                        session = try await projection.startAgent(request, retriesLinkFailure: retriesLinkFailure)
                    }
                    try Task.checkCancellation()
                    effects += launch.handle(.sessionStarted(token, session))
                case .chooseTerminal(let token, let session):
                    let id = ConsoleAgent.ID(hostID: hostID, paneID: session.paneID)
                    serverLaunchNotices[id] = nil
                    // An archived session's TUI may still run, hidden:
                    // Resume shows the session in that pane again.
                    let choice: ServerChatLaunchMachine.Choice
                    if serverSessionTerminals[id] != nil {
                        choice = .existing
                    } else if let backend = HostBackend.allCases.first(where: {
                        $0.hostsLinkedServerTerminal && desiredBackends(for: hostID).contains($0)
                    }) {
                        choice = .open(backend)
                    } else {
                        choice = .unavailable
                    }
                    effects += launch.handle(.terminalChosen(token, choice))
                case .openTerminal(let token, let session, let backend):
                    let pane = try await startAgent(
                        server.linkedPaneRequest(
                            sessionID: server.sessionID(paneID: session.paneID), name: request.name,
                            launchID: request.launchID, mayHaveStarted: request.mayHaveStarted),
                        at: .newWorkspace(NewWorkspaceSpec(directory: session.cwd, label: nil)),
                        on: hostID, backend: backend, retriesLinkFailure: retriesLinkFailure)
                    try Task.checkCancellation()
                    effects += launch.handle(.terminalOpened(token, pane))
                case .recordMarker(let token, let session, let pane, let backend):
                    await recordChatModeLaunch(
                        ChatModeMarker(
                            paneID: pane.paneID, terminalID: pane.terminalID,
                            kind: server.agentKind.rawValue,
                            cwd: pane.cwd.isEmpty ? session.cwd : pane.cwd,
                            session: .init(kind: "id", value: server.sessionID(paneID: session.paneID)),
                            chatMode: false, launchedAt: Date()),
                        hostID: hostID, backend: backend)
                    try Task.checkCancellation()
                    effects += launch.handle(.markerRecorded(token))
                case .showTerminalFailure(let session):
                    let id = ConsoleAgent.ID(hostID: hostID, paneID: session.paneID)
                    serverLaunchNotices[id] =
                        "Couldn't open a terminal for this \(server.sessionNoun). Chat still works."
                }
            } catch {
                guard let token = effect.token else { throw error }
                let failure: ServerChatLaunchMachine.Failure = error is CancellationError ? .cancelled
                    : EventsSession.isTransportLinkFailure(error) ? .uncertain : .definitive
                let recovery = launch.handle(.failed(token, failure))
                // Only a definitive terminal failure becomes Chat-only.
                // Uncertain dispatches retain both Launch Tags for replay.
                guard !recovery.isEmpty else { throw error }
                effects += recovery
            }
        }
        guard case .ready(let session, _) = launch.state else { throw TransportError.cancelled }
        return session
    }

    /// The plain-shell variant a New Agent destination names, as
    /// `startAgent(_:at:on:backend:)`.
    @discardableResult
    func startShell(
        _ request: ShellLaunchRequest,
        at destination: StartAgentStore.LaunchDestination,
        on hostID: Host.ID,
        backend: HostBackend? = nil,
        retriesLinkFailure: Bool = true
    ) async throws -> ShellLaunchResult {
        let projection = try await launchProjection(
            on: hostID, backend: launchBackend(backend, workspaceID: request.workspaceID, on: hostID))
        switch destination {
        case .existingWorkspace:
            return try await projection.startShellTerminal(
                request, retriesLinkFailure: retriesLinkFailure)
        case .newWorktree(let worktree):
            return try await projection.startShellTerminalInNewWorktree(
                request, worktree: worktree, retriesLinkFailure: retriesLinkFailure)
        case .newWorkspace(let workspace):
            return try await projection.startShellTerminalInNewWorkspace(
                request, workspace: workspace, retriesLinkFailure: retriesLinkFailure)
        }
    }

    /// The verified projection a New Agent launch runs on. Until its rows
    /// verify nothing is sent, so a failure there is `RequestNotSentError`.
    private func launchProjection(
        on hostID: Host.ID, backend: HostBackend
    ) async throws -> HostConsoleProjection {
        do {
            return try await verifiedProjection(for: hostID, backend: backend)
        } catch {
            throw RequestNotSentError.wrapping(error)
        }
    }

    @discardableResult
    func startShellTerminal(
        _ request: ShellLaunchRequest,
        on hostID: Host.ID,
        backend: HostBackend? = nil
    ) async throws -> ShellLaunchResult {
        try await verifiedProjection(
            for: hostID,
            backend: launchBackend(backend, workspaceID: request.workspaceID, on: hostID)
        ).startShellTerminal(request)
    }

    @discardableResult
    func startShellTerminalInNewWorktree(
        _ request: ShellLaunchRequest,
        worktree: WorktreeSpec,
        on hostID: Host.ID,
        backend: HostBackend? = nil
    ) async throws -> ShellLaunchResult {
        try await verifiedProjection(
            for: hostID,
            backend: launchBackend(backend, workspaceID: request.workspaceID, on: hostID)
        ).startShellTerminalInNewWorktree(request, worktree: worktree)
    }

    @discardableResult
    func startShellTerminalInNewWorkspace(
        _ request: ShellLaunchRequest,
        workspace: NewWorkspaceSpec,
        on hostID: Host.ID,
        backend: HostBackend? = nil
    ) async throws -> ShellLaunchResult {
        try await verifiedProjection(
            for: hostID,
            backend: launchBackend(backend, workspaceID: request.workspaceID, on: hostID)
        ).startShellTerminalInNewWorkspace(request, workspace: workspace)
    }

    /// Suspends until `id` is reported by its Host's sync machinery, or the
    /// timeout elapses. The new-agent flow (#12) opens the started Agent's
    /// terminal, and the row it navigates to exists only once the post-start
    /// resync lands — waiting keeps the detail column from flashing its
    /// missing-Agent placeholder over a launch that just succeeded.
    func waitForAgent(_ id: ConsoleAgent.ID, timeout: Duration = .seconds(5)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !agents.contains(where: { $0.id == id }) {
            guard clock.now < deadline,
                (try? await Task.sleep(for: .milliseconds(50))) != nil
            else { return }
        }
    }

    /// The row `id`'s pane has in its Host's verified snapshot, whatever
    /// terminal it runs.
    func verifiedAgent(_ id: ConsoleAgent.ID) async throws -> ConsoleAgent {
        try await verifiedRow(
            paneID: id.paneID, on: id.hostID,
            backend: paneOwner(id.paneID, on: id.hostID), seenTerminalID: nil
        ).row
    }

    /// Closes `row`'s pane while it still runs `row`'s terminal: the
    /// automatic close of a resumed pane the user backed out of, so it never
    /// takes a worktree group with it.
    func closePane(of row: ConsoleAgent) async throws {
        let (projection, verified) = try await verifiedRow(for: row)
        try await projection.closePane(
            row.agent.paneID,
            closesWorktreeGroup: false,
            removesRowAtOnce: !swipedCloseHolds(tabID: verified.agent.tabID, on: row.hostID))
    }

    /// The user's Close Agent: closing a main checkout's last pane closes
    /// its worktree group, as on herdr's desktop.
    func closePane(_ paneID: String, on hostID: Host.ID) async throws {
        let (projection, verified) = try await verifiedRow(paneID: paneID, on: hostID)
        pinFolderLinkedTerminal(of: verified)
        try await projection.closePane(
            paneID,
            closesWorktreeGroup: true,
            removesRowAtOnce: !swipedCloseHolds(tabID: verified.agent.tabID, on: hostID))
    }

    /// Whether a swiped Close is pending on the Host's `tabID`. Its rows
    /// leave through that Close's bookkeeping — `.closing` until the resync
    /// drops them, then held as `departingRows` — so a confirmed close must
    /// not take them off the list ahead of it (#105).
    private func swipedCloseHolds(tabID: String, on hostID: Host.ID) -> Bool {
        pendingTabCloses.values.contains {
            $0.agent.hostID == hostID && liveTabID(of: $0.agent) == tabID
        }
    }

    /// Whether closing this agent's tab also closes the Workspace: the tab
    /// is the workspace's last one (shell tabs count), which herdr turns
    /// into a workspace close. VoiceOver's close announcement and undo label
    /// say so.
    func closesWorkspaceWithTab(of agent: ConsoleAgent) -> Bool {
        agent.workspaceTabCount <= 1
    }

    /// Starts a swiped Close's undo window; when it runs out the tab closes
    /// with no further question, Workspace or not. A row already counting
    /// down is left alone. One tab gets one `tab.close`: a countdown that
    /// runs out while a sibling on its tab is already closing rides along.
    func scheduleTabClose(_ agent: ConsoleAgent) {
        sendTabClose(.schedule(
            agent, deadline: Date().addingTimeInterval(Self.tabCloseUndoSeconds)))
    }

    /// Feeds the swiped Closes and performs their effects; a `close` is left
    /// to the countdown that asked for it, which returns it.
    @discardableResult
    private func sendTabClose(_ event: PendingTabCloseMachine.Event) -> [PendingTabCloseMachine.Effect] {
        let effects = tabCloses.handle(event)
        if pendingTabCloses != tabCloses.state.closes { pendingTabCloses = tabCloses.state.closes }
        for effect in effects {
            switch effect {
            case .startCountdown(let agent, let token):
                // A row swiped again after its Close was released replaces
                // the Task held for it; the older countdown runs on.
                startTabCloseCountdown(agent, token: token)
            case .cancelCountdown(let id):
                tabCloseTasks.removeValue(forKey: id)?.cancel()
            case .dropCountdown(let id):
                tabCloseTasks[id] = nil
            case .close:
                break
            }
        }
        return effects
    }

    /// One countdown, with the Agent it was swiped with: when it runs out
    /// it sends that Agent's `tab.close` unless a sibling's covers the tab,
    /// whether or not its row still shows a Close.
    private func startTabCloseCountdown(_ agent: ConsoleAgent, token: UInt64) {
        let countdown = tabCloseUndoWindow
        tabCloseTasks[agent.id] = Task { [weak self] in
            // Cancellation is the undo.
            guard (try? await countdown.wait()) != nil, !Task.isCancelled,
                let self
            else { return }
            let effects = self.sendTabClose(
                .countdownEnded(token: token, liveTabs: self.liveTabIDs()))
            guard let tabID = effects.lazy.compactMap({ effect -> String? in
                if case .close(let tabID) = effect { tabID } else { nil }
            }).first
            else { return }
            do {
                // Stays `.closing` until the resync drops the row.
                try await self.closeAgentTab(agent)
                self.sendTabClose(.closed(agent, tabID: tabID, liveTabs: self.liveTabIDs()))
            } catch TransportError.apiRejected(let code, _) where code == "agent_not_found" {
                // Already gone: the close the user wanted happened.
                self.sendTabClose(.closeFailed(agent, tabID: tabID, liveTabs: self.liveTabIDs()))
            } catch {
                self.tabCloseFailure = Self.failureMessage(for: error)
                self.sendTabClose(.closeFailed(agent, tabID: tabID, liveTabs: self.liveTabIDs()))
            }
        }
    }

    /// The tab a row is on now: its live row's when still listed (herdr can
    /// move a pane mid-countdown), else the one captured at the swipe.
    private func liveTabID(of agent: ConsoleAgent) -> String {
        agents.first(where: { $0.id == agent.id })?.agent.tabID ?? agent.agent.tabID
    }

    /// The tab each listed row is on now: herdr can move a pane
    /// mid-countdown. A row no longer listed keeps the tab captured at the
    /// swipe. Every row, since a running countdown's row may show no Close.
    private func liveTabIDs() -> [ConsoleAgent.ID: String] {
        var tabs: [ConsoleAgent.ID: String] = [:]
        for row in agents where tabs[row.id] == nil {
            tabs[row.id] = row.agent.tabID
        }
        return tabs
    }

    /// Cancels a swiped Close still in its undo window. Once `tab.close` is
    /// in flight there is nothing left to undo.
    func undoTabClose(_ id: ConsoleAgent.ID) {
        sendTabClose(.undo(id))
    }

    /// What a failed Console row action (a Close, a Move) tells the user: a
    /// `TransportError`'s whole Transport Error Presentation, and a Host's
    /// rejection as the same presentation of `apiRejected`.
    nonisolated static func failureMessage(for error: any Error) -> String {
        switch error {
        case let error as TransportError:
            error.presentation.message
        case let error as HerdrAPIError:
            TransportError.apiRejected(code: error.code, message: error.message)
                .presentation.message
        default:
            error.localizedDescription
        }
    }

    /// Closes the Agent's tab (Console row swipe action). Every agent on the
    /// Host sharing that tab disappears with it, so their pins are dropped
    /// too — a deliberately closed tab must not leave a pin that would
    /// re-pin a herdr-reused id. The tab's rows leave once herdr confirms,
    /// or with a swiped Close pending on it, when the projection's resync
    /// drops them (`swipedCloseHolds`).
    /// The tab is the verified row's, not the last-known one's.
    ///
    /// The Close is committed by now (its undo window ran out), and a bulk
    /// Close runs every countdown out at once: a Host reconnecting or
    /// retrying its snapshot at that moment is waited for, within
    /// `verificationTimeout`, rather than failing every Close with the
    /// failure that started the recovery and sending none of them.
    func closeAgentTab(_ agent: ConsoleAgent) async throws {
        let hostID = agent.hostID
        let (projection, verified) = try await verifiedRow(
            for: agent, patience: .ridesOutRecovery)
        let tabID = verified.agent.tabID
        let pinnedPaneIDs = agents
            .filter {
                $0.hostID == hostID && $0.backend == verified.backend && $0.agent.tabID == tabID
            }
            .map(\.agent.paneID)
            .filter { pins.isPinned(hostID: hostID, paneID: $0) }
        pinFolderLinkedTerminal(of: verified)
        try await projection.closeTab(
            tabID, removesRowsAtOnce: !swipedCloseHolds(tabID: tabID, on: hostID))
        for paneID in pinnedPaneIDs {
            pins.removePin(hostID: hostID, paneID: paneID)
        }
        rebuild()
    }

    /// Moves the Agent into another Workspace on its Host (Console row
    /// drag-to-workspace). A drop on the Agent's own workspace is a
    /// silent no-op (nil, no RPC). herdr auto-closes the emptied source tab
    /// (and workspace when it was its last tab) and re-keys the moved
    /// Pane's id — the reply's `pane` carries the new id, so the moved
    /// Agent's pin and unread mark land on the new id, while sibling panes
    /// in the source tab keep their ids (and pins and marks).
    /// The projection's resync refreshes the list. Returns the reply so
    /// callers can re-target the open detail to the new pane id.
    @discardableResult
    func moveAgent(
        _ agent: ConsoleAgent,
        toWorkspaceID: String,
        on hostID: Host.ID
    ) async throws -> PaneMoveResponse? {
        guard agent.agent.workspaceID != toWorkspaceID else { return nil }
        let (projection, current) = try await verifiedRow(for: agent)
        guard current.agent.workspaceID != toWorkspaceID else { return nil }
        let movedPaneID = current.agent.paneID
        let movedID = ConsoleAgent.ID(hostID: hostID, paneID: movedPaneID)
        // herdr moves the pane before the reply names its new id; a snapshot
        // landing in between must not settle the mark as gone.
        unread.beginMove(movedID)
        let response: PaneMoveResponse
        do {
            response = try await projection.movePane(movedPaneID, toWorkspaceID: toWorkspaceID)
        } catch {
            unread.cancelMove(movedID)
            throw error
        }
        let newPaneID = response.moveResult.pane.paneID
        if pins.isPinned(hostID: hostID, paneID: movedPaneID) {
            pins.removePin(hostID: hostID, paneID: movedPaneID)
            pins.addPin(hostID: hostID, paneID: newPaneID)
        }
        unread.rekey(movedID, toPaneID: newPaneID)
        rebuild()
        return response
    }

    func listWorktrees(
        forWorkspaceID workspaceID: String, on hostID: Host.ID
    ) async throws -> WorktreeListResponse {
        try await workspaceProjection(workspaceID, on: hostID)
            .listWorktrees(forWorkspaceID: workspaceID)
    }

    func removeWorktree(
        _ request: WorktreeRemovalRequest, on hostID: Host.ID
    ) async throws -> WorktreeRemovalReceipt {
        try await verifiedProjection(
            for: hostID, backend: workspaceOwner(request.identity.workspaceID, on: hostID)
        ).removeWorktree(request)
    }

    func focusAgent(_ paneID: String, on hostID: Host.ID) async throws {
        guard let owner = projection(on: hostID, backend: paneOwner(paneID, on: hostID)) else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        try await owner.focusAgent(paneID)
    }

    func renameAgent(
        _ paneID: String, name: String?, on hostID: Host.ID
    ) async throws {
        try await verifiedRow(paneID: paneID, on: hostID).projection
            .renameAgent(paneID, name: name)
    }

    func renameWorkspace(
        _ workspaceID: String, label: String, on hostID: Host.ID
    ) async throws {
        try await verifiedProjection(
            for: hostID, backend: workspaceOwner(workspaceID, on: hostID)
        ).renameWorkspace(workspaceID, label: label)
    }

    /// The projection whose snapshot lists `workspaceID`, else the Host's
    /// primary one.
    private func workspaceProjection(
        _ workspaceID: String, on hostID: Host.ID
    ) throws -> HostConsoleProjection {
        guard
            let owner = projection(
                on: hostID, backend: workspaceOwner(workspaceID, on: hostID))
        else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        return owner
    }

    /// A shell row's rename: its name is its tab label (`tab.rename`), taken
    /// from the verified row rather than the last-known one.
    func renameTab(of agent: ConsoleAgent, label: String) async throws {
        let (projection, verified) = try await verifiedRow(for: agent)
        try await projection.renameTab(verified.agent.tabID, label: label)
    }

    /// Starts the projections a Host's backends ask for: the last detected
    /// ones (this run's, else the cache's), herdr only when none is known.
    /// A detection follows once the Host's connection settles, unless the
    /// known presence is fresh (#105); it reconciles the set.
    private func startProjections(
        for host: Host,
        handovers: [ConsoleScope: (snapshot: SessionSnapshot, verifiedAt: Date?)]
    ) {
        if backendPresence(on: host.id) == nil, let cached = inventoryCache?.loadPresence(for: host) {
            sendBackendDetection(.seed(.init(presence: cached.presence, verifiedAt: cached.verifiedAt)), on: host.id)
        }
        for backend in desiredBackends(for: host.id) {
            startProjection(
                for: host, backend: backend,
                handover: handovers[ConsoleScope(hostID: host.id, backend: backend)])
        }
        requestBackendDetection(on: host.id)
    }

    /// Starts one backend's projection on its last-known inventory: the
    /// replaced projection's (`handover`), else the on-device cache's. Either
    /// stays unverified until the Host answers.
    private func startProjection(
        for host: Host, backend: HostBackend,
        handover: (snapshot: SessionSnapshot, verifiedAt: Date?)?
    ) {
        let scope = ConsoleScope(hostID: host.id, backend: backend)
        let session = makeSession(
            host, backend,
            HostConsoleProjection.subscriptions(paneIDs: []))
        let projection = HostConsoleProjection(
            host: host,
            session: session,
            backend: backend,
            snapshotRetryDelay: snapshotRetryDelay,
            summaryRefreshTiming: summaryRefreshTiming,
            shellActivityTiming: shellActivityTiming,
            // Its snapshot times become Closed Sessions' last-seen times.
            now: closedSessions.now
        ) { [weak self] in
            self?.rebuild()
        }
        projection.setSummaryRefreshGate(summaryRefreshGate)
        projection.setForeground(isShellActivityForeground)
        let cached = handover == nil ? inventoryCache?.load(for: host, backend: backend) : nil
        if let handover {
            projection.seed(handover.snapshot, verifiedAt: handover.verifiedAt)
        } else if let cached {
            projection.seed(cached.snapshot, verifiedAt: cached.verifiedAt)
        }
        if backend.capabilities.pluginRowLayout, let layout = cached?.sidebarLayout {
            sidebarSnapshots.seed(host.id, layout: layout)
        }
        projections[scope] = projection
        projection.moshAttach = makeMoshAttach(for: projection)
        projection.onAgentsClosed = { [weak self] captures in
            self?.agentsDidClose(captures, on: scope)
        }
        // On a Host running herdr too, tmux connects once herdr's
        // connection settles (#105).
        let defers = isActive && waitsForHerdr(scope)
        if defers { sendBackendDetection(.scopeDeferred(backend), on: host.id) }
        projection.start(isActive: isActive && !defers)
    }

    func rebuild() {
        let current = Array(projections.values)
        let hostIDs = projectedHostIDs
        var leads: [Host.ID: HostConsoleProjection] = [:]
        var primaries: [Host.ID: HostConsoleProjection] = [:]
        for id in hostIDs {
            leads[id] = leadProjection(on: id)
            primaries[id] = primaryProjection(on: id)
        }
        reconcileTerminalConnections()
        hostStatuses = leads.compactMapValues { $0.status }
        hostStandingFailures = leads.compactMapValues { $0.standingFailure }
        let leadBackends = leads.mapValues(\.backend)
        if hostLeadBackends != leadBackends { hostLeadBackends = leadBackends }
        hostLatencies = leads.compactMapValues { $0.latency }
        hostSyncErrors = leads.compactMapValues { $0.syncError }
        hostConnectionGenerations = primaries.mapValues { $0.transportGeneration }
        hostsAwaitingSnapshot = Set(leads.lazy.filter { $0.value.isAwaitingSnapshot }.map(\.key))
        publishScopeStates()
        let nextWorkspacesByHost = Dictionary(
            uniqueKeysWithValues: hostIDs.map { id in
                (id, projections(on: id).flatMap(\.workspaces))
            })
        if workspacesByHost != nextWorkspacesByHost {
            workspacesByHost = nextWorkspacesByHost
        }
        let nextRemovedWorktreesByAgent = current.reduce(into: [:]) { result, projection in
            result.merge(projection.removedWorktreesByAgent) { _, latest in latest }
        }
        if removedWorktreesByAgent != nextRemovedWorktreesByAgent {
            removedWorktreesByAgent = nextRemovedWorktreesByAgent
        }
        // The Agent Row Layout is the herdr plugin's (`pluginRowLayout`).
        let sidebarConnections = Dictionary(uniqueKeysWithValues: current.compactMap { projection
            -> (Host.ID, HerdrSidebarSnapshotStore.Connection)? in
            guard isActive, projection.backend.capabilities.pluginRowLayout,
                projection.status == .connected,
                !projection.isAwaitingSnapshot
            else { return nil }
            return (projection.host.id, HerdrSidebarSnapshotStore.Connection(
                generation: projection.transportGeneration, revision: projection.sidebarRevision))
        })
        sidebarSnapshots.reconcile(sidebarConnections, transports: self) { [weak self] in
            self?.sidebarLayoutDidChange()
        }
        // Taken before unread marks settle: a closed pane's mark goes with
        // it, and its departing row keeps the badge and place it was listed
        // with. Only a sent swiped Close can make a departing row.
        let listedBefore = pendingTabCloses.values.contains { $0.phase == .closing }
            ? agents.map(unread.displayed) : []
        // Unread marks settle only against verified rows: a last-known
        // inventory neither proves a pane gone nor reports new activity.
        // Each projection settles its own backend's marks and resumes only.
        for projection in current where Self.isVerified(projection) {
            unread.reconcile(
                hostID: projection.host.id, backend: projection.backend,
                agents: projection.agentsByPane)
            closedSessions.noteVerifiedAgents(
                on: projection.host.id, backend: projection.backend,
                rows: projection.agentsByPane)
        }
        // A Closed Session is not listed while its session runs. Hiding one
        // forgets nothing, so last-known rows count as well as verified ones.
        closedSessions.noteLiveAgents(current.lazy.flatMap { $0.agentsByPane.values })
        // A server that archives its sessions keeps their records itself.
        closedSessions.setServerSessions(current.flatMap { projection -> [ClosedSession] in
            guard let server = projection.backend.serverChat, server.archivesSessions else { return [] }
            return projection.archivedSessions.map {
                ClosedSession(
                    archived: $0, on: server, hostID: projection.host.id,
                    hostName: projection.host.displayName)
            }
        }.sorted { $0.id < $1.id })
        closedSessions.pruneExpired()
        rebuildAgentOrder()
        holdRowsTakenByTabCloses(listedBefore: listedBefore)
        pruneTabClosesWithoutRows()
        publishAgentStatuses()
        updateReconnectGrace(leads)
        persistInventories()
        settleVerificationWaiters()
        reconcileQueuedMessages()
        // Chat Markers are one file set per Host: read over, and verified
        // by, its marker projection; every projection's chat Agents follow.
        noteChatModeMarkerVerifications(on: hostIDs)
        scheduleChatModeMarkerReads(hostIDs.compactMap { markerProjection(on: $0) })
        followChatModeMarkers(current)
        // An SSH reconnect can happen without a foreground transition.
        // Check each stopped server chat runtime once when the Host's
        // primary verifies anew.
        for (hostID, primary) in primaries where Self.isVerified(primary) {
            sendBackendDetection(.primaryVerified(primary.transportGeneration, now: now()), on: hostID)
        }
        detectAfterMissingBackend(current)
        transcriptPrefetcher?.update()
        runDeferredConnectWork()
    }

    /// Starts a new verification for each Host whose marker projection's
    /// rows just became verified, whose markers just moved to or from its
    /// other projection (`markerProjection(on:)`), or any of whose
    /// projections' rows just became verified again: its cached markers wait
    /// for that verification's read before `followChatModeMarkers` treats
    /// them as the Host's. A gap on either backend of a Host running both
    /// may have let another device retire a marker meanwhile.
    private func noteChatModeMarkerVerifications(on hostIDs: some Sequence<Host.ID>) {
        for hostID in hostIDs {
            guard let projection = markerProjection(on: hostID) else { continue }
            let verified = Self.isVerified(projection)
            let fallback = projection !== primaryProjection(on: hostID)
            let verifiedBackends = Set(
                projections(on: hostID).filter { Self.isVerified($0) }.map(\.backend))
            var reads = chatModeMarkerReads[hostID] ?? newChatModeMarkerReads()
            for effect in reads.machine.handle(
                .observed(verified: verified, fallback: fallback, verifiedBackends: verifiedBackends))
            {
                switch effect {
                case .keep:
                    chatModeMarkerReads[hostID] = reads
                case .cancel, .start, .read, .confirmed, .release, .reschedule:
                    break
                }
            }
        }
    }

    /// Keeps each verified chat Agent's marker holding its terminal and
    /// live session (`ChatModeStore.follow`), so a chat herdr restored in a
    /// new terminal stays one, and writes the change to the Host over the
    /// Agent's own backend. Waits for the Host's markers to be read in its
    /// current verification: a cached copy another device retired since
    /// must not be written back. Writing is best effort: a failed write is
    /// retried by the marker refresh through its `rewrites`. `follow`
    /// returns nil once the store holds the marker, so the same marker is
    /// never written twice in a row.
    private func followChatModeMarkers(_ current: [HostConsoleProjection]) {
        for host in current where Self.isVerified(host) {
            let hostID = host.host.id
            let backend = host.backend
            guard let reads = chatModeMarkerReads[hostID], reads.machine.isVerified,
                reads.machine.isConfirmed
            else { continue }
            let followed = host.agentsByPane.values
                .filter { !$0.isShell }
                .compactMap { chatMode.follow($0) }
            guard !followed.isEmpty else { continue }
            Task { [weak self] in
                guard let self else { return }
                for marker in followed {
                    do {
                        try await withChatMarkers(on: hostID, backend: backend) { transport in
                            try await transport.writeChatModeMarker(marker)
                        }
                    } catch {
                        Self.log.error("Chat Marker write failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Publishes each projection's own state, only where it changed.
    private func publishScopeStates() {
        let statuses = projections.compactMapValues { $0.status }
        if scopeStatuses != statuses { scopeStatuses = statuses }
        let failures = projections.compactMapValues { $0.standingFailure }
        if scopeStandingFailures != failures { scopeStandingFailures = failures }
        let generations = projections.mapValues { $0.transportGeneration }
        if scopeConnectionGenerations != generations { scopeConnectionGenerations = generations }
        let awaiting = Set(projections.lazy.filter { $0.value.isAwaitingSnapshot }.map(\.key))
        if scopesAwaitingSnapshot != awaiting { scopesAwaitingSnapshot = awaiting }
        // A failed start's words go once its runtime connects, or with the
        // Host.
        let settled = runtimeStartErrors.keys.filter {
            statuses[$0] == .connected || catalog[$0.hostID] == nil
        }
        for scope in settled { _ = runtimeStarts[scope]?.handle(.clearError) }
    }

    /// Lists the rows a sent swiped Close just took off `agents` in
    /// `departingRows` until `rowDepartureWindow` ends: every row
    /// `listedBefore` (the index before this rebuild) had on a `.closing`
    /// Close's tab that is no longer listed. Runs before
    /// `pruneTabClosesWithoutRows`, while the Closes that took them are
    /// still pending.
    private func holdRowsTakenByTabCloses(listedBefore: [ConsoleAgent]) {
        let listed = Set(agents.lazy.map(\.id))
        // A departing row listed again (herdr reused its pane id) is a new row.
        if departingRows.contains(where: { listed.contains($0.agent.id) }) {
            departingRows.removeAll { listed.contains($0.agent.id) }
        }
        guard !listedBefore.isEmpty else { return }
        let rowsBefore = Dictionary(
            listedBefore.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let closedTabs = Set(
            pendingTabCloses.values.lazy
                .filter { $0.phase == .closing }
                .map { TabKey(rowsBefore[$0.agent.id] ?? $0.agent) })
        var taken: [DepartingRow] = []
        var anchor: ConsoleAgent.ID?
        for row in listedBefore {
            if listed.contains(row.id) {
                anchor = row.id
            } else if closedTabs.contains(TabKey(row)) {
                taken.append(
                    DepartingRow(agent: row, pendingClose: pendingTabCloses[row.id], anchor: anchor))
                anchor = row.id
            }
        }
        guard !taken.isEmpty else { return }
        // Newest first: an earlier Close's row can be anchored on one of
        // these, which were still listed then, never the other way round.
        departingRows = taken + departingRows
        let window = rowDepartureWindow
        Task { [weak self, taken] in
            try? await window.wait()
            self?.departingRows.removeAll { taken.contains($0) }
        }
    }

    /// Drops swiped Closes whose row has left `agents`: the closed tab's
    /// resync took it, with any sibling counting down on the same tab, or it
    /// vanished elsewhere mid-countdown and a late `tab.close` would only
    /// fail. Leaves `pendingTabCloses` untouched when nothing has gone.
    private func pruneTabClosesWithoutRows() {
        guard !pendingTabCloses.isEmpty else { return }
        let present = Set(agents.lazy.map(\.id))
        let gone = pendingTabCloses.keys.filter { !present.contains($0) }
        guard !gone.isEmpty else { return }
        sendTabClose(.rowsGone(Array(gone)))
    }

    /// The rows banners and Live Activities may treat as fact: every Host's,
    /// except those still awaiting verification. A Host's first live
    /// snapshot therefore reaches them as first sight — a silent baseline —
    /// never as a transition out of its last-known statuses.
    var verifiedAgents: [ConsoleAgent] {
        agents.filter {
            !scopesAwaitingSnapshot.contains(ConsoleScope(hostID: $0.hostID, backend: $0.backend))
        }
    }

    private static func isVerified(_ projection: HostConsoleProjection) -> Bool {
        projection.status == .connected && !projection.isAwaitingSnapshot
    }

    /// Reads each verified Host's Chat Markers, over its marker projection
    /// (`current` holds those), once its rows are verified, after
    /// connecting or after a gap, then again as its rows keep
    /// changing — the same status changes, snapshots and summary updates
    /// that drive its Agent Summaries — never sooner than
    /// `chatModeMarkerRefreshInterval` after the last read in the same
    /// verification. A change inside the interval arms one read for when it
    /// ends, so a marker another device writes just after its launch still
    /// lands. A failed read keeps the markers already cached; a marker this
    /// device recorded within `ChatModeStore.localRecordGrace` that the Host
    /// does not list yet is written again, so one failed write does not
    /// cost the Agent its chat, and a marker this device retired that the
    /// Host still lists is deleted again, so one failed delete does not
    /// bring the chat back. A read that lands in the verification it started
    /// in confirms the markers, and the Host's chat Agents are followed.
    private func scheduleChatModeMarkerReads(_ current: [HostConsoleProjection]) {
        guard isActive else { return }
        for projection in current where Self.isVerified(projection) {
            let hostID = projection.host.id
            var reads = chatModeMarkerReads[hostID] ?? newChatModeMarkerReads()
            let effects = reads.machine.handle(
                .schedule(now: Date(), interval: Self.chatModeMarkerRefreshInterval))
            guard !effects.isEmpty else { continue }
            for effect in effects {
                switch effect {
                case .cancel:
                    reads.task?.cancel()
                case .start(let token, let wait):
                    reads.task = chatModeMarkerRead(
                        on: hostID, over: projection, token: token, after: wait)
                case .keep, .read, .confirmed, .release, .reschedule:
                    break
                }
            }
            chatModeMarkerReads[hostID] = reads
        }
    }

    /// Feeds `hostID`'s marker reads, while it still has an entry, and
    /// performs the effects that need no Task. A read that spanned a
    /// reconnect kept the new verification from scheduling its own, so its
    /// end reads for it now; the next read records its verification, and an
    /// inactive or unverified Host schedules nothing.
    private func sendChatModeMarkerRead(
        _ event: ChatMarkerReadMachine.Event, on hostID: Host.ID
    ) -> [ChatMarkerReadMachine.Effect] {
        guard let effects = chatModeMarkerReads[hostID]?.machine.handle(event) else { return [] }
        for effect in effects {
            switch effect {
            case .release:
                chatModeMarkerReads[hostID]?.task = nil
            case .reschedule:
                if let current = markerProjection(on: hostID) {
                    scheduleChatModeMarkerReads([current])
                }
            case .keep, .cancel, .start, .read, .confirmed:
                break
            }
        }
        return effects
    }

    /// One Chat Marker read: waits out `wait`, then reads over `projection`
    /// if it is still the verified marker projection, repairs what the Host
    /// lacks or still lists, and confirms the markers when it lands in the
    /// verification it began in.
    private func chatModeMarkerRead(
        on hostID: Host.ID, over projection: HostConsoleProjection,
        token: ChatMarkerReadMachine.Token, after wait: TimeInterval
    ) -> Task<Void, Never> {
        Task { [weak self, weak projection] in
            if wait > 0 {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
            guard let self else { return }
            defer { _ = sendChatModeMarkerRead(.ended(token), on: hostID) }
            let eligible = projection.map {
                markerProjection(on: hostID) === $0 && isActive && Self.isVerified($0)
            } ?? false
            guard let projection,
                case .read(let verification)? = sendChatModeMarkerRead(
                    .began(eligible: eligible, now: Date()), on: hostID).first
            else { return }
            let markers: [ChatModeMarker]
            do {
                markers = try await projection.session.withTransport { transport in
                    try await transport.readChatModeMarkers()
                }
            } catch NotificationRegistrationError.pluginNotInstalled {
                // No Host tools on this backend: a Host running both
                // reads them over its other one (`markerProjection`).
                Self.log.info("Chat Marker read failed: the plugin is not installed")
                noteMarkerless(projection)
                return
            } catch {
                Self.log.info("Chat Marker read failed: \(error.localizedDescription)")
                return
            }
            guard markerProjection(on: hostID) === projection else { return }
            // Recorded here inside the grace yet missing on the Host:
            // the write failed or is still in flight, and writing the
            // same marker again is harmless either way. Retired here yet
            // still listed: the delete failed, or raced this read.
            let repairs = chatMode.replaceMarkers(markers, for: hostID)
            for marker in repairs.rewrites {
                do {
                    try await projection.session.withTransport { transport in
                        try await transport.writeChatModeMarker(marker)
                    }
                } catch {
                    Self.log.error("Chat Marker write failed: \(error.localizedDescription)")
                }
            }
            for paneID in repairs.deletes {
                do {
                    try await projection.session.withTransport { transport in
                        try await transport.deleteChatModeMarker(paneID: paneID)
                    }
                } catch {
                    Self.log.error("Chat Marker delete failed: \(error.localizedDescription)")
                }
            }
            // A read from before a gap the rows came back from confirms
            // nothing: the new verification reads again.
            guard markerProjection(on: hostID) === projection,
                sendChatModeMarkerRead(.landed(verification: verification), on: hostID)
                    == [.confirmed]
            else { return }
            rebuildAgentOrder()
            transcriptPrefetcher?.update()
            followChatModeMarkers(projections(on: hostID))
        }
    }

    private func sidebarLayoutDidChange() {
        persistInventories()
    }

    // MARK: Last-known inventory

    /// Writes each Host's latest live snapshot and layout to the on-device
    /// cache when either changed. The cache coalesces and does the I/O.
    private func persistInventories() {
        guard let inventoryCache else { return }
        for (scope, projection) in projections where projection.liveSnapshotRevision > 0 {
            guard let snapshot = projection.inventorySnapshot else { continue }
            let next = PersistedInventory(
                liveSnapshotRevision: projection.liveSnapshotRevision,
                sidebarLayout: scope.backend.capabilities.pluginRowLayout
                    ? sidebarSnapshots.layoutFiles[scope.hostID] : nil)
            guard persistedInventories[scope] != next else { continue }
            persistedInventories[scope] = next
            inventoryCache.save(
                ConsoleInventoryCache.Entry(
                    liveSnapshot: snapshot, sidebarLayout: next.sidebarLayout,
                    verifiedAt: projection.inventoryVerifiedAt),
                for: projection.host, backend: scope.backend)
        }
    }

    // MARK: Reconnect grace

    /// Per Host, judged by the projection the Host presents.
    private func updateReconnectGrace(_ leads: [Host.ID: HostConsoleProjection]) {
        for (id, projection) in leads {
            if Self.isVerified(projection) {
                endReconnectGrace(id)
                reconnectGraceStates[id] = .verified
            } else {
                switch reconnectGraceStates[id] {
                case nil, .verified: startReconnectGrace(id)
                case .running, .elapsed: break
                }
            }
        }
        publishReconnectGrace()
    }

    private func startReconnectGrace(_ id: Host.ID) {
        endReconnectGrace(id)
        let token = UUID()
        let wait = reconnectGrace.wait
        let task = Task { [weak self] in
            do { try await wait() } catch { return }
            guard let self, case .running(let current, _) = reconnectGraceStates[id],
                current == token
            else { return }
            reconnectGraceStates[id] = .elapsed
            publishReconnectGrace()
        }
        reconnectGraceStates[id] = .running(token: token, task: task)
    }

    private func endReconnectGrace(_ id: Host.ID) {
        if case .running(_, let task) = reconnectGraceStates[id] { task.cancel() }
        reconnectGraceStates[id] = nil
    }

    /// Only a Host with rows to show gets the grace: without them, its
    /// condition row is all the Console can say about it.
    private func publishReconnectGrace() {
        let next = Set(projectedHostIDs.filter { id in
            guard let lead = leadProjection(on: id), lead.hasInventory,
                case .running = self.reconnectGraceStates[id]
            else { return false }
            return true
        })
        if hostsWithinReconnectGrace != next { hostsWithinReconnectGrace = next }
    }

    // MARK: Verification

    /// A Host backend's projection (nil: the primary one) once its rows are
    /// verified by a live snapshot. With `.failsFast` it fails instead of
    /// waiting when the Host cannot get there on its own — stopped, paused,
    /// recovering from a failure, or unable to snapshot; `.failsFastOffline`
    /// also fails while the device has no network path; `.ridesOutRecovery`
    /// waits out the recovery. Each fails after `verificationTimeout`.
    private func verifiedProjection(
        for hostID: Host.ID, backend: HostBackend? = nil,
        patience: VerificationPatience = .failsFast
    ) async throws -> HostConsoleProjection {
        try await awaitVerification(on: hostID, backend: backend, patience: patience)
    }

    /// The row an Agent-scoped action may act on: the verified row for the
    /// pane the caller acted on, on the backend that listed it, still
    /// holding the terminal the caller saw. herdr reuses short ids, so a
    /// last-known row whose pane is gone or now holds another terminal fails
    /// with `agent_not_found` and nothing is sent. Tab and Workspace ids must
    /// come from the returned row.
    private func verifiedRow(
        for agent: ConsoleAgent, patience: VerificationPatience = .failsFast
    ) async throws -> (projection: HostConsoleProjection, row: ConsoleAgent) {
        try await verifiedRow(
            paneID: agent.agent.paneID, on: agent.hostID, backend: agent.backend,
            seenTerminalID: agent.agent.terminalID, patience: patience)
    }

    /// For actions addressed by pane id, the caller's row is the one the
    /// Console lists when the action starts. With none listed, the verified
    /// snapshot must still have the pane.
    private func verifiedRow(
        paneID: String, on hostID: Host.ID, patience: VerificationPatience = .failsFast
    ) async throws -> (projection: HostConsoleProjection, row: ConsoleAgent) {
        let seen = agents.first { $0.id == ConsoleAgent.ID(hostID: hostID, paneID: paneID) }
        return try await verifiedRow(
            paneID: paneID, on: hostID, backend: seen?.backend ?? paneOwner(paneID, on: hostID),
            seenTerminalID: seen?.agent.terminalID, patience: patience)
    }

    private func verifiedRow(
        paneID: String, on hostID: Host.ID, backend: HostBackend?, seenTerminalID: String?,
        patience: VerificationPatience = .failsFast
    ) async throws -> (projection: HostConsoleProjection, row: ConsoleAgent) {
        let projection = try await verifiedProjection(
            for: hostID, backend: backend, patience: patience)
        guard let row = projection.addressableAgent(paneID),
            seenTerminalID.map({ $0 == row.agent.terminalID }) ?? true
        else {
            throw TransportError.apiRejected(
                code: "agent_not_found", message: "The Agent is no longer listed.")
        }
        return (projection, row)
    }

    private func awaitVerification(
        on hostID: Host.ID, backend: HostBackend?, patience: VerificationPatience
    ) async throws -> HostConsoleProjection {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<HostConsoleProjection, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let outcome = verificationOutcome(
                    hostID: hostID, backend: backend, patience: patience)
                {
                    continuation.resume(with: outcome)
                    return
                }
                var waiter = VerificationWaiter(
                    hostID: hostID, backend: backend,
                    settle: { continuation.resume(with: $0) })
                for effect in waiter.machine.handle(.begin(patience)) {
                    switch effect {
                    case .armTimeout(let token):
                        let wait = verificationTimeout.wait
                        waiter.timeout = Task { [weak self] in
                            do { try await wait() } catch { return }
                            guard let self else { return }
                            // A recovery that never finished reports the failure
                            // it was riding out, not a bare timeout.
                            var outcome: Result<HostConsoleProjection, any Error> =
                                .failure(TransportError.timedOut)
                            if patience == .ridesOutRecovery,
                                case .failure(let cause) = verificationOutcome(
                                    hostID: hostID, backend: backend, patience: .failsFast)
                            {
                                outcome = .failure(cause)
                            }
                            finishVerificationWaiter(
                                waiterID, event: .timedOut(token), with: outcome)
                        }
                    case .settle:
                        break // begin only admits a timeout, never a settlement.
                    }
                }
                verificationWaiters[waiterID] = waiter
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishVerificationWaiter(
                    waiterID, event: .cancel, with: .failure(CancellationError()))
            }
        }
    }

    private func finishVerificationWaiter(
        _ id: UUID, event: InventoryVerificationMachine.Event,
        with outcome: Result<HostConsoleProjection, any Error>
    ) {
        guard var waiter = verificationWaiters[id] else { return }
        for effect in waiter.machine.handle(event) {
            switch effect {
            case .settle:
                // Remove before resuming: a rebuild or cancellation can re-enter.
                verificationWaiters[id] = nil
                waiter.timeout?.cancel()
                waiter.settle(outcome)
            case .armTimeout:
                break // Only begin admits a timeout.
            }
        }
    }

    private func verificationOutcome(
        hostID: Host.ID, backend: HostBackend?, patience: VerificationPatience
    ) -> Result<HostConsoleProjection, any Error>? {
        guard let scoped = projection(on: hostID, backend: backend) else {
            return .failure(TransportError.sshUnreachable(detail: "The Host is not connected."))
        }
        if Self.isVerified(scoped) { return .success(scoped) }
        guard patience != .waitsOutFailure else { return nil }
        if patience == .failsFastOffline, hasLostNetworkPath {
            return .failure(TransportError.sshUnreachable(detail: "The device has no network."))
        }
        // Reconnecting and a failed snapshot both retry on their own.
        let ridesOutRecovery = patience == .ridesOutRecovery
        switch scoped.status {
        case .failed(let failure):
            return .failure(failure)
        case .reconnecting(_, _, let failure):
            return ridesOutRecovery ? nil : .failure(failure)
        case .suspended:
            return .failure(
                TransportError.sshUnreachable(detail: "The connection is paused."))
        case .connected:
            return ridesOutRecovery ? nil : scoped.syncFailure.map { .failure($0) }
        case .connecting, .ended, nil:
            return nil
        }
    }

    private func settleVerificationWaiters() {
        for (id, waiter) in verificationWaiters {
            guard let patience = waiter.machine.patience, let token = waiter.machine.token,
                let outcome = verificationOutcome(
                    hostID: waiter.hostID, backend: waiter.backend, patience: patience)
            else { continue }
            finishVerificationWaiter(id, event: .resolved(token), with: outcome)
        }
    }

    /// Per projection: its terminals follow its own connection generation
    /// and verified rows; the Host's mosh availability rides its primary
    /// one, and its speculative standby the Console's state (#105).
    private func reconcileTerminalConnections() {
        defer { reconcileSpeculativeStandbys() }
        for (scope, projection) in projections {
            let hostID = scope.hostID
            let backend = scope.backend
            let generation = projection.transportGeneration
            if terminalTransportGenerations[scope] != generation {
                terminalTransportGenerations[scope] = generation
                Task { [weak self, weak projection] in
                    guard let self, let projection, projections[scope] === projection,
                        projection.transportGeneration == generation
                    else { return }
                    let isCurrent: @MainActor () -> Bool = { [weak self, weak projection] in
                        guard let self, let projection else { return false }
                        return projections[scope] === projection
                            && projection.transportGeneration == generation
                    }
                    await agentTerminals.transportGenerationDidChange(
                        generation, for: hostID, backend: backend, isCurrent: isCurrent)
                }
            }
            reconcileMoshAvailability(projection)
            guard !projection.isAwaitingSnapshot,
                projection.status == .connected,
                terminalSnapshotRevisions[scope] != projection.sidebarRevision
            else { continue }
            terminalSnapshotRevisions[scope] = projection.sidebarRevision
            let revision = projection.sidebarRevision
            let agents = Array(projection.agentsByPane.values)
            let isCurrent: @MainActor () -> Bool = { [weak self, weak projection] in
                guard let self, let projection else { return false }
                return projections[scope] === projection && !projection.isAwaitingSnapshot
                    && projection.status == .connected && projection.sidebarRevision == revision
            }
            Task {
                await agentTerminals.reconcile(
                    hostID: hostID, backend: backend, agents: agents, isCurrent: isCurrent)
            }
        }
    }

    func rowLayout(for hostID: Host.ID) -> AgentRowLayout {
        rowLayouts.resolvedLayout(
            for: hostID, pluginSnapshot: sidebarSnapshots.snapshot(for: hostID))
    }

    func refreshSidebarLayouts() async {
        let current = Array(projections.values)
        await withTaskGroup(of: Void.self) { group in
            for projection in current {
                group.addTask { await projection.refreshSidebarMetadata() }
            }
        }
        await sidebarSnapshots.refresh(transports: self) { [weak self] in
            self?.sidebarLayoutDidChange()
        }
    }

    /// Settings' Sync from plugin: one Host's layout file, on its current
    /// connection. nil means the Host has no connection to read from.
    func refreshSidebarLayout(for hostID: Host.ID) async -> HerdrSidebarSnapshotStore.HostState? {
        await sidebarSnapshots.refresh(hostID, transports: self) { [weak self] in
            self?.sidebarLayoutDidChange()
        }
    }

    /// `agents` keeps herdr's statuses but takes the index's order, where an
    /// unread-marked Idle Agent sorts as Done.
    private func rebuildAgentOrder() {
        let rows = projections.values.flatMap { $0.agentsByPane.values }
        var archived: [ConsoleScope: Set<String>] = [:]
        for projection in projections.values where !projection.archivedSessions.isEmpty {
            archived[ConsoleScope(hostID: projection.host.id, backend: projection.backend)] =
                Set(projection.archivedSessions.map(\.sessionID))
        }
        let links = ServerSessionLinks.resolve(rows, archived: archived, marker: chatMode.marker)
        serverLinkedPanes = Set(rows.map(\.id)).subtracting(links.rows.map(\.id))
        serverSessionTerminals = links.terminals
        serverFolderLinkedSessions = links.linkedByFolder
        agents = sortedAgents(links.rows, sortAs: unread.displayed)
    }

    private func sortedAgents(
        _ unsorted: [ConsoleAgent], sortAs: (ConsoleAgent) -> ConsoleAgent = { $0 }
    ) -> [ConsoleAgent] {
        let pinRanks = Dictionary(uniqueKeysWithValues: unsorted.compactMap { agent in
            pins.pinRank(hostID: agent.hostID, paneID: agent.agent.paneID)
                .map { (agent.id, $0) }
        })
        return unsorted.consoleSorted(pinRank: { pinRanks[$0.id] }, sortAs: sortAs)
    }

    private func publishAgentStatuses() {
        for (id, observers) in agentStatusObservers {
            let update = agentStatusUpdate(for: id)
            for continuation in observers.values {
                continuation.yield(update)
            }
        }
    }

    /// Live updates follow the connection of the projection listing the
    /// Agent, not the Host's other backend.
    private func agentStatusUpdate(for id: ConsoleAgent.ID) -> AgentStatusUpdate {
        let row = addressableAgent(id)
        let status = row?.agent.status
        let scope = row.map { ConsoleScope(hostID: id.hostID, backend: $0.backend) }
        return AgentStatusUpdate(
            status: status,
            liveUpdatesAvailable: status != nil
                && scope.map {
                    scopeStatuses[$0] == .connected && !scopesAwaitingSnapshot.contains($0)
                } ?? false)
    }

    private func removeAgentStatusObserver(_ observerID: UUID, for id: ConsoleAgent.ID) {
        agentStatusObservers[id]?[observerID] = nil
        if agentStatusObservers[id]?.isEmpty == true {
            agentStatusObservers[id] = nil
        }
    }
}

extension ConsoleStore: NotificationTransportProvider {
    /// Notification Registration work borrows the Host's live Console
    /// connection (#75) instead of dialing a second one — its primary
    /// projection's, herdr's when present; an unconnected Host fails loudly
    /// like every other Host-scoped RPC here.
    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        try await projection(for: hostID).session.withTransport(operation)
    }
}

extension ConsoleStore: HostLiveTelemetrySource {
    /// The Hosts the open Hosts sheet samples (#134): enabled, connected and
    /// past their first snapshot, so a sample is non-critical connect work
    /// like backend detection and never races the first snapshot or attach
    /// on a fresh connection (#105). A Disabled Host has no projection and
    /// so no status; the catalog check keeps that true by construction.
    var connectedHostIDs: Set<Host.ID> {
        Set(hostStatuses.compactMap { id, status in
            guard status == .connected, catalog[id]?.isEnabled == true,
                !hostsAwaitingSnapshot.contains(id)
            else { return nil }
            return id
        })
    }

    /// Re-measures the latency `hostLatencies` shows: the lead projection's
    /// session, without `HostConsoleProjection.revalidate()`'s retry of a
    /// `.failed` session. True only when the ping proved the live channel;
    /// false with no projection for the Host.
    func sampleLatency(on hostID: Host.ID) async -> Bool {
        guard let session = leadProjection(on: hostID)?.session else { return false }
        return await session.sampleLatency()
    }

    /// One resource sample over the Host's primary connection at `.normal`
    /// SSH priority: it queues behind any terminal work rather than ahead
    /// of it (#105).
    func hostResourceUsage(on hostID: Host.ID) async throws -> HostResourceUsage {
        try await projection(for: hostID).session.withTransport(priority: .normal) {
            try await $0.hostResourceUsage()
        }
    }
}

extension ConsoleStore {
    /// The production session factory: one backend's SSH transport built
    /// from the Host catalog's credentials (`connect(settings:backend:)`).
    /// TOFU is restricted to already-trusted fingerprints; the Console never
    /// prompts. A Host or Jump Host that answers with a key never trusted
    /// holds the session, Connecting or Reconnecting, with the hold reported
    /// to `trustHolds`, until a key is trusted (by the Host page, Scan to
    /// Pair or iCloud Keychain), then it dials again on its own
    /// (`dialHoldingForTrust`). Suspend, Reconnect and a Host edit cancel
    /// the wait with the session.
    ///
    /// With `connectionMemory`, each Host's connections remember what they
    /// proved there (#105): `$HOME`, so a new connection runs no home exec,
    /// and herdr's protocol version, so its first events subscribe goes out
    /// alongside its `ping`.
    ///
    /// Each session knows which of the connector's pooled connections its
    /// Transport rides (#105). That lets suspension keep the connection open
    /// for the return to probe, a hedged dial replace one that does not
    /// answer, and a connection found dead be retired.
    static func sshSessionFactory(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        trustPollInterval: Duration = .seconds(1),
        trustHolds: HostKeyTrustHoldReporter = .shared,
        reconnectPolicy: ReconnectPolicy = .default,
        connectionMemory: ConsoleInventoryCache? = nil
    ) -> @Sendable (Host, HostBackend, [EventSubscription]) -> EventsSession {
        { host, backend, subscriptions in
            if SampleHost.isSample(host.id) {
                return EventsSession(
                    subscriptions: subscriptions,
                    connect: { SampleTransport() },
                    keepalive: nil,
                    recordsNetworkTelemetry: false)
            }
            let memory = connectionMemory?.connectionMemory(for: host)
            let poolKey = SSHTransportSettings.catalogPoolKey(for: host)
            return EventsSession(
                subscriptions: subscriptions,
                connection: SharedConnection(
                    connect: { replacing in
                        try await ConsoleStore.dialHoldingForTrust(
                            host, knownHosts: knownHosts, credentials: credentials,
                            trustPollInterval: trustPollInterval,
                            report: { trustHolds.report($0, for: host.id) }
                        ) { trusted in
                            var settings = trusted
                            settings.connectionMemory = memory
                            return try await connector.connect(
                                settings: settings, backend: backend, replacing: replacing)
                        }
                    },
                    keep: { await connector.keepConnection($0) },
                    release: { await connector.releaseKeptConnection($0) },
                    retire: { await connector.retireConnection($0) },
                    abandonDial: { await connector.abandonDial(poolKey: poolKey) }),
                reconnectPolicy: reconnectPolicy,
                // herdr's protocol only: tmux reports none, and core's
                // generation is not a herdr protocol number.
                connectionMemory: backend == .herdr ? memory : nil)
        }
    }

    /// The production backend detector (ADR 0026): one detection exec over
    /// `connector.detectBackends(settings:)`, with the same credentials and
    /// the same wait for a trusted key as `sshSessionFactory`, so a Host
    /// detects right after trust. It waits silently: nothing cancels a
    /// detection on suspend or Reconnect, so a hold it reported could
    /// outlive the session's and mask a fresh failure. The session's own
    /// hold is what the Console shows.
    static func sshBackendDetector(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        trustPollInterval: Duration = .seconds(1)
    ) -> @Sendable (Host) async throws -> HostBackendPresence {
        { host in
            if SampleHost.isSample(host.id) { return .herdrOnly }
            return try await ConsoleStore.dialHoldingForTrust(
                host, knownHosts: knownHosts, credentials: credentials,
                trustPollInterval: trustPollInterval, report: { _ in }
            ) { settings in
                try await connector.detectBackends(settings: settings)
            }
        }
    }

    /// A cheap external-start check of a stopped server chat runtime, over
    /// the same pooled SSH session and credentials as detection. No exec:
    /// Codex's is a plain socket open (`connector.probeCodexServer`),
    /// OpenCode's a plain direct-tcpip open (`connector.probeOpenCodeServer`).
    static func sshServerRuntimeProbe(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        trustPollInterval: Duration = .seconds(1)
    ) -> @Sendable (Host, ServerChatBackend, HostBackendPresence) async throws -> Bool {
        { host, server, presence in
            guard !SampleHost.isSample(host.id) else { return false }
            switch server {
            case .codex:
                guard let codex = presence.codex else { return false }
                return try await ConsoleStore.dialHoldingForTrust(
                    host, knownHosts: knownHosts, credentials: credentials,
                    trustPollInterval: trustPollInterval, report: { _ in }
                ) { settings in
                    try await connector.probeCodexServer(settings: settings, presence: codex)
                }
            case .opencode:
                guard let opencode = presence.opencode else { return false }
                return try await ConsoleStore.dialHoldingForTrust(
                    host, knownHosts: knownHosts, credentials: credentials,
                    trustPollInterval: trustPollInterval, report: { _ in }
                ) { settings in
                    try await connector.probeOpenCodeServer(settings: settings, presence: opencode)
                }
            }
        }
    }

    /// The production runtime starter (#389): the user's Start Herdr TUI
    /// runs `connector.wakeHerdr(settings:)` once, Start Herdr Core
    /// `connector.startCore(settings:)`, Start Codex server
    /// `connector.startCodex(settings:)`, Start OpenCode server
    /// `connector.startOpenCode(settings:)`, with `sshBackendDetector`'s
    /// credentials and wait for a trusted key. The sample Host starts
    /// nothing, and neither does any other backend.
    static func sshRuntimeStarter(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        trustPollInterval: Duration = .seconds(1)
    ) -> @Sendable (Host, HostBackend) async throws -> Void {
        { host, backend in
            guard !SampleHost.isSample(host.id),
                backend == .herdr || backend == .core || backend.isServerChat
            else {
                return
            }
            try await ConsoleStore.dialHoldingForTrust(
                host, knownHosts: knownHosts, credentials: credentials,
                trustPollInterval: trustPollInterval, report: { _ in }
            ) { settings in
                if backend == .herdr {
                    try await connector.wakeHerdr(settings: settings)
                } else if backend == .core {
                    try await connector.startCore(settings: settings)
                } else if let server = backend.serverChat {
                    switch server {
                    case .codex: try await connector.startCodex(settings: settings)
                    case .opencode: try await connector.startOpenCode(settings: settings)
                    }
                }
            }
        }
    }

    /// Runs `dial` with the Host's settings, which trust only stored keys.
    /// When the Host or its Jump Host answered with a key never trusted
    /// (`.hostKeyRejected`, before authenticating to the hop that presented
    /// it), it reports that hop to `report` on every `trustPollInterval`
    /// check until the hop has a stored key, reports nil when the wait ends
    /// either way, and dials again. Every other failure, an unreachable Host
    /// or a changed key included, throws unchanged with no hold: a Host that
    /// never answered has no key to trust. A cancelled wait throws
    /// `.cancelled`; a Host whose password is not set fails as an
    /// authentication failure.
    nonisolated private static func dialHoldingForTrust<Value: Sendable>(
        _ host: Host,
        knownHosts: any KnownHostsStore,
        credentials: HostCredentialsProvider,
        trustPollInterval: Duration,
        report: @Sendable (HostKeyTrustHold?) -> Void,
        dial: @Sendable (SSHTransportSettings) async throws -> Value
    ) async throws -> Value {
        let resolved: SSHCredentials
        do {
            resolved = try credentials.credentials(for: host)
        } catch HostCredentialsError.passwordNotSet {
            throw TransportError.authenticationFailed
        }
        let settings = SSHTransportSettings(
            host: host,
            credentials: resolved,
            hostKeyPolicy: HostKeyPolicy(knownHosts: knownHosts) { _ in false })
        var held = false
        defer { if held { report(nil) } }
        while true {
            let hop: (host: String, port: Int, hold: HostKeyTrustHold)
            do {
                return try await dial(settings)
            } catch let error as TransportError {
                switch error {
                case .hostKeyRejected:
                    hop = (settings.host, settings.port, .host)
                case .jumpHostFailed(.hostKeyRejected):
                    guard let jump = settings.jump else { throw error }
                    hop = (jump.host, jump.port, .jumpHost)
                default:
                    throw error
                }
            }
            while await knownHosts.fingerprints(host: hop.host, port: hop.port).isEmpty {
                // Re-reported every poll so a stale clear from a replaced
                // session (a Host edit) cannot leave the hold unshown.
                held = true
                report(hop.hold)
                do {
                    try await Task.sleep(for: trustPollInterval)
                } catch {
                    throw TransportError.cancelled
                }
            }
            if held {
                held = false
                report(nil)
            }
        }
    }
}

/// Which hop holds a Console connection for want of a trusted host key.
enum HostKeyTrustHold: Sendable, Equatable {
    case host
    case jumpHost
}

/// Carries trust holds from the session factory, which runs off the main
/// actor, to the Console that shows them. Each `updates()` stream gets every
/// report in order; a stream stops receiving once its consumer ends it.
final class HostKeyTrustHoldReporter: Sendable {
    static let shared = HostKeyTrustHoldReporter()

    typealias Update = (hostID: Host.ID, hold: HostKeyTrustHold?)

    private let observers = Mutex<[UUID: AsyncStream<Update>.Continuation]>([:])

    func report(_ hold: HostKeyTrustHold?, for hostID: Host.ID) {
        let continuations = observers.withLock { Array($0.values) }
        for continuation in continuations {
            continuation.yield((hostID: hostID, hold: hold))
        }
    }

    func updates() -> AsyncStream<Update> {
        let (stream, continuation) = AsyncStream.makeStream(of: Update.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.observers.withLock { $0[id] = nil }
        }
        observers.withLock { $0[id] = continuation }
        return stream
    }
}
