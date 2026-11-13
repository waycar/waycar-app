import Foundation

/// One row of the Console (#8): an Agent joined with its Host identity and
/// workspace context. The list is flat across Hosts; the workspace is a
/// context tag only, never a grouping level.
struct ConsoleAgent: Identifiable, Sendable, Equatable {
    /// Pane addresses are unique per herdr session, not across Hosts; the
    /// row identity pairs them.
    struct ID: Hashable, Sendable {
        let hostID: Host.ID
        let paneID: String
    }

    let hostID: Host.ID
    let hostName: String
    /// SSH account name, used only for conservative presentation of standard
    /// macOS/Linux home paths as `~`. The actual remote path stays unchanged.
    let hostUsername: String?
    var agent: Agent
    /// Workspace label from the session snapshot; nil when the snapshot did
    /// not carry the workspace.
    let workspaceLabel: String?
    let tabLabel: String?
    let paneLabel: String?
    /// One-based position within the snapshot's workspace tabs. herdr's
    /// automatic label uses position, not TabInfo.number's stable identity.
    let tabPosition: Int?
    let workspaceTabCount: Int
    /// Collection order from herdr's session.snapshot.agents; the Console's
    /// tie-break after recency.
    let snapshotOrder: Int?
    /// Snapshot git metadata when the workspace reported any. Presence does
    /// not mean this is removable: the main checkout is reported with
    /// `isLinkedWorktree == false` too.
    let repositoryCheckout: RepositoryCheckout?
    /// The backend whose projection listed the row (ADR 0026): it drives the
    /// tmux mark and per-row capabilities, and routes the row's actions.
    /// Pane ids are unique across a Host's backends (tmux's carry `tmux:`),
    /// so the row identity stays Host plus pane.
    let backend: HostBackend
    /// The Host's latest Agent Summary for this pane, whatever status it was
    /// written for; `summaryLine(at:)` decides how it reads. Nil whenever
    /// AI summaries are off.
    var summary: AgentSummary?
    /// Whether this row still waits for its first Agent Summary: summaries
    /// are on, the Host has the plugin but no summary for the pane yet, and
    /// a refresh can still run that has not covered the pane.
    var isSummaryPending: Bool
    /// Whether this row's Host reports Agent Progress (#189): AI summaries
    /// are on and a store record read on this connection declared the
    /// `progress` key (`AgentSummary.declaresProgress`). Holds across a
    /// tombstone, unlike `summary`; an older plugin never sets it, so its
    /// Working rows never wait on an estimate that cannot come.
    var hostReportsProgress: Bool
    /// What a Shell row's foreground is doing (Shell Activity); nil when
    /// unknown, and always nil on an Agent row. Live only: never persisted,
    /// and never feeds Agent Status, sort order, pills, unread marks or any
    /// notification surface. A running command line may hold secrets, so
    /// only the row's own card shows it.
    var shellActivity: ShellActivity?
    struct TerminalLink: Sendable, Equatable {
        let id: ID
        let backend: HostBackend
    }

    /// Live inventory facts used only by the server session merge
    /// (`ServerSessionLinks`), never persisted.
    var paneCommandLine: String?
    var serverSessionOrigin: String?
    /// The terminal pane hidden behind this server session's Show Terminal.
    var linkedTerminal: TerminalLink?
    var canShowTerminal: Bool { backend.hasTerminal || linkedTerminal != nil }

    /// Ultimate's folded branches are addressable chats, not inventory rows.
    var isUltimateLeader = false
    var ultimateChildren: [UltimateChildInfo] = []
    var ultimateOpenQuestions: Int = 0

    var ultimateBranchSummary: String {
        let counts = "\(ultimateChildren.count) branches · \(ultimateChildren.filter(\.busy).count) working"
        return ultimateOpenQuestions > 0 ? counts + " · \(ultimateOpenQuestions) needs you" : counts
    }

    func ultimateChild(_ paneID: String) -> ConsoleAgent? {
        guard backend == .ultimate, let child = ultimateChildren.first(where: { $0.paneID == paneID }) else { return nil }
        let info = AgentInfo(
            agentStatus: child.status, focused: false, paneID: child.paneID,
            revision: 0, tabID: child.paneID, terminalID: child.paneID,
            workspaceID: agent.workspaceID, agent: "ultimate", cwd: agent.cwd,
            interactiveReady: true, launchPending: false, name: child.name)
        return ConsoleAgent(hostID: hostID, hostName: hostName, agent: Agent(info),
                            workspaceLabel: workspaceLabel, repositoryCheckout: nil,
                            hostUsername: hostUsername, backend: .ultimate)
    }
    /// herdr's own status on a row the index lists as another
    /// (`display(as:)`); nil when `agent.status` is herdr's.
    private var statusBehindDisplay: AgentStatus?

    /// The Agent Status herdr reports, whatever the index shows for it.
    var herdrStatus: AgentStatus { statusBehindDisplay ?? agent.status }

    /// Lists the row under `status` — its badge, colour, pills and sort
    /// bucket — while `herdrStatus` keeps herdr's.
    mutating func display(as status: AgentStatus) {
        statusBehindDisplay = herdrStatus
        agent.replaceStatus(status)
    }

    var id: ID { ID(hostID: hostID, paneID: agent.paneID) }

    /// What the row shows under its headline at `now`: the Agent Summary,
    /// fresh while the Agent is still in the status it was written for and
    /// for `AgentSummary.freshness` after, otherwise stale; the loading
    /// placeholder while the first one is on its way; else nothing.
    func summaryLine(at now: Date) -> AgentSummaryLine? {
        guard !isShell else { return nil }
        guard let summary else { return isSummaryPending ? .loading : nil }
        let age = Self.age(ofHostMilliseconds: summary.timestamp, at: now)
        return .summary(text: summary.text, age: age, isStale: !isFresh(summary, age: age))
    }

    /// What the row's progress bar shows at `now` (#189): only a Working or
    /// Blocked Agent has one. Its estimate is stale on the summary's terms,
    /// aged from when the plugin last refreshed it (`progressWrittenAt`). A
    /// Working Agent without an estimate is pending while its Host reports
    /// progress; a Blocked one only ever shows the estimate it froze with.
    func progressDisplay(at now: Date) -> AgentProgressDisplay? {
        if let estimate = progressEstimate(at: now) {
            return .estimate(estimate.progress, isStale: estimate.isStale)
        }
        return isProgressPending ? .pending : nil
    }

    /// What VoiceOver hears after the Agent's status at `now`: the estimate,
    /// never a percent, with when the plugin last refreshed it once stale
    /// ("3 of 7 steps done, as of 5 minutes ago"); nil without an estimate.
    func spokenProgress(at now: Date) -> String? {
        guard let estimate = progressEstimate(at: now) else { return nil }
        let spoken = estimate.progress.spokenLabel
        guard estimate.isStale else { return spoken }
        return "\(spoken), as of \(AgentSummaryLine.spokenAge(estimate.age))"
    }

    /// The estimate behind `progressDisplay(at:)` and how long ago the
    /// plugin last refreshed it; nil when the bar shows no estimate.
    func progressEstimate(
        at now: Date
    ) -> (progress: AgentProgress, age: TimeInterval, isStale: Bool)? {
        guard showsProgress, let summary, let progress = summary.progress else { return nil }
        let age = Self.age(ofHostMilliseconds: summary.progressWrittenAt, at: now)
        return (progress, age, !isFresh(summary, age: age))
    }

    private var showsProgress: Bool {
        !isShell && (herdrStatus == .working || herdrStatus == .blocked)
    }

    private var isProgressPending: Bool {
        showsProgress && herdrStatus == .working && summary?.progress == nil && hostReportsProgress
    }

    /// Whether the card offers "Update plugin for progress" (#209): AI
    /// summaries are on, the Agent is Working or Blocked (where a bar would
    /// show) without an estimate, its Host does not report progress, and
    /// the Host's plugin is below this build's minimum. Anything else keeps
    /// the card as it is.
    func showsPluginProgressHint(
        summariesEnabled: Bool, pluginStatus: WaycarPluginStatus
    ) -> Bool {
        guard backend.hasTerminal, summariesEnabled, showsProgress, summary?.progress == nil, !hostReportsProgress,
            case .outdated = pluginStatus
        else { return false }
        return true
    }

    /// Host clock against this device's: a Host running ahead must not read
    /// as written in the future.
    private static func age(ofHostMilliseconds stamp: Int64, at now: Date) -> TimeInterval {
        let written = Date(timeIntervalSince1970: TimeInterval(stamp) / 1000)
        return max(0, now.timeIntervalSince(written))
    }

    private func isFresh(_ summary: AgentSummary, age: TimeInterval) -> Bool {
        summary.status == herdrStatus && age < AgentSummary.freshness
    }

    /// A plain shell tab projected as a row (`Agent.isShell`). Everything
    /// keyed on a ConsoleAgent — rows, pins, moves, close, switcher — applies
    /// to it unchanged; only Agent-only API calls are gated on this.
    var isShell: Bool { agent.isShell }

    /// What an Attach resolves for this row. `agent attach` refuses a pane
    /// with no Agent, so a shell attaches by terminal id (ADR 0015).
    var attachTarget: TerminalAttachTarget {
        isShell ? .terminal(agent.terminalID) : .agentPane(agent.paneID)
    }

    /// The one Agent whose session file `AgentSessionUsage` knows how to
    /// fold. Another Agent that came to report a path would only have its
    /// file downloaded and parsed for nothing.
    static let sessionFileAgent = "omp"

    /// The Agent's own session transcript on the Host, when herdr reports one
    /// by path for `sessionFileAgent` (#325). A reference herdr resolves
    /// itself carries no path to read, so those stay nil rather than being
    /// guessed at.
    var sessionFilePath: String? {
        guard
            let session = agent.agentSession, session.kind == .path,
            session.agent == Self.sessionFileAgent
        else { return nil }
        return session.value.isEmpty ? nil : session.value
    }

    init(
        hostID: Host.ID,
        hostName: String,
        agent: Agent,
        workspaceLabel: String?,
        repositoryCheckout: RepositoryCheckout?,
        summary: AgentSummary? = nil,
        isSummaryPending: Bool = false,
        hostReportsProgress: Bool = false,
        hostUsername: String? = nil,
        tabLabel: String? = nil,
        tabPosition: Int? = nil,
        workspaceTabCount: Int = 0,
        snapshotOrder: Int? = nil,
        paneLabel: String? = nil,
        backend: HostBackend = .herdr,
        shellActivity: ShellActivity? = nil
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.hostUsername = hostUsername
        self.agent = agent
        self.workspaceLabel = workspaceLabel
        self.tabLabel = tabLabel
        self.paneLabel = paneLabel
        self.tabPosition = tabPosition
        self.workspaceTabCount = workspaceTabCount
        self.snapshotOrder = snapshotOrder
        self.repositoryCheckout = repositoryCheckout
        self.summary = summary
        self.isSummaryPending = isSummaryPending
        self.hostReportsProgress = hostReportsProgress
        self.backend = backend
        self.shellActivity = shellActivity
    }

    var repoName: String? { repositoryCheckout?.repoName }

    /// Protocol 20 has no custom-name bit. A manual name equal to the
    /// automatic position cannot be distinguished from an automatic name.
    var showsTabLabel: Bool {
        guard let tabLabel, !tabLabel.isEmpty else { return false }
        if workspaceTabCount > 1 { return true }
        guard let tabPosition else { return true }
        return tabLabel != String(tabPosition)
    }

    var checkoutPath: String? { repositoryCheckout?.checkoutPath }

    /// Console badge and destructive-action eligibility come only from the
    /// latest session snapshot's explicit linkage bit.
    var isLinkedWorktree: Bool { repositoryCheckout?.isLinkedWorktree == true }

    var workspaceContext: String? {
        switch (workspaceLabel, repoName) {
        case (nil, nil): nil
        case (let label?, nil): label
        case (nil, let repo?): repo
        case (let label?, let repo?): label == repo ? label : "\(label) · \(repo)"
        }
    }

    /// The directory the skills probe treats as the agent's project root:
    /// the worktree checkout when the workspace has one, else the agent's
    /// launch cwd. Deliberately not the live foreground cwd — agents load
    /// project skills from where they started.
    var skillsProjectRoot: String? {
        if let checkoutPath, !checkoutPath.isEmpty { return checkoutPath }
        return agent.cwd.isEmpty ? nil : agent.cwd
    }

    /// Client-side Agents search (#292, `ConsoleSearch`) over the working
    /// directory and the title/visible text.
    func matchesAgentSearch(_ query: String) -> Bool {
        ConsoleSearch.matches(
            query,
            in: [
                agent.cwd,
                workspaceLabel,
                tabLabel,
                paneLabel,
                agent.title,
                agent.paneTitle,
                agent.displayName,
                agent.terminalTitle,
                agent.terminalTitleStripped,
            ])
    }

    /// The launch directory as a Console row should print it. The snapshot
    /// carries the expanded remote path but not `$HOME`, so only the
    /// account's conventional macOS/Linux homes are shortened to `~`; every
    /// other path stays exactly as the Agent reported it.
    var displayCwd: String { Self.displayPath(agent.cwd, hostUsername: hostUsername) }

    /// `path` with `hostUsername`'s conventional home shortened to `~`.
    static func displayPath(_ path: String, hostUsername: String?) -> String {
        guard let hostUsername, !hostUsername.isEmpty else { return path }
        let homes =
            hostUsername == "root"
            ? ["/root"]
            : ["/Users/\(hostUsername)", "/home/\(hostUsername)"]
        guard let home = homes.first(where: { path == $0 || path.hasPrefix("\($0)/") })
        else { return path }
        return path == home ? "~" : "~\(path.dropFirst(home.count))"
    }
}

/// The Console's search rule (#292), shared by Agent and Closed Session
/// rows: a trimmed, case-insensitive substring match against any non-empty
/// field. An empty query matches everything.
enum ConsoleSearch {
    static func matches(_ query: String, in fields: [String?]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return fields.contains { field in
            guard let field, !field.isEmpty else { return false }
            return field.range(of: needle, options: .caseInsensitive) != nil
        }
    }
}

extension AgentStatus {
    /// Presentation only, never on the wire: the status a projected shell row
    /// (`Agent.shellKind`) carries where an Agent carries its Agent Status —
    /// its Console badge and the status line above its input chrome. It
    /// falls into the palette's muted default and the bottom sort bucket,
    /// like Unknown, counts toward no Host status total, and reads "Shell".
    static let shellTerminal = AgentStatus(rawValue: "shell")
}

extension Agent {
    /// A plain shell pane as a Console row's Agent (`Agent.shellKind`). It
    /// carries the pane's own identity — terminal, pane, tab, Workspace —
    /// and its terminal title. The cwd follows the shell's `cd`, falling
    /// back to its launch directory. Status is `.shellTerminal`: neutral,
    /// presentation only, in the bottom sort bucket.
    init(shellPane pane: PaneInfo, name: String?) {
        let foregroundCwd = pane.foregroundCwd.flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            terminalID: pane.terminalID,
            kind: Agent.shellKind,
            title: TerminalTitleGlyphs.strip(
                pane.terminalTitleStripped ?? pane.terminalTitle ?? ""),
            status: .shellTerminal,
            workspaceID: pane.workspaceID,
            tabID: pane.tabID,
            paneID: pane.paneID,
            cwd: foregroundCwd ?? pane.cwd ?? "",
            revision: pane.revision,
            name: name,
            terminalTitle: pane.terminalTitle,
            terminalTitleStripped: pane.terminalTitleStripped,
            paneTitle: pane.title)
    }
}

extension ConsoleAgent {
    /// Whether attaching to this Agent reports `terminal_attach` and the
    /// network phases. A Sample Agent opens no network connection, so it
    /// reports nothing. Every `AgentAttachStore` built for an Agent takes
    /// this value, and the parameter has no default.
    var recordsNetworkTelemetry: Bool { !SampleHost.isSample(hostID) }

    /// A shell must open in a directory tied to the selected row. A missing
    /// directory disables Open Terminal and New Terminal instead of letting
    /// herdr inherit some other focused Pane's cwd.
    var shellTerminalCreationRequest: ShellTerminalCreationRequest? {
        if Self.isAbsoluteNonEmptyPath(agent.cwd) {
            return ShellTerminalCreationRequest(
                workspaceID: agent.workspaceID,
                cwd: agent.cwd)
        }
        if isLinkedWorktree,
            let checkoutPath,
            Self.isAbsoluteNonEmptyPath(checkoutPath)
        {
            return ShellTerminalCreationRequest(
                workspaceID: agent.workspaceID,
                cwd: checkoutPath)
        }
        return nil
    }

    private static func isAbsoluteNonEmptyPath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The snapshot's exact git checkout identity for one workspace. Workspace
/// ids are reusable slots, so destructive actions match this tuple too.
struct RepositoryCheckout: Sendable, Equatable, Hashable {
    let repoKey: String
    let repoName: String
    let repoRoot: String
    let checkoutPath: String
    let isLinkedWorktree: Bool

    init(
        repoKey: String,
        repoName: String,
        repoRoot: String,
        checkoutPath: String,
        isLinkedWorktree: Bool
    ) {
        self.repoKey = repoKey
        self.repoName = repoName
        self.repoRoot = repoRoot
        self.checkoutPath = checkoutPath
        self.isLinkedWorktree = isLinkedWorktree
    }

    init(_ info: WorkspaceWorktreeInfo) {
        self.init(
            repoKey: info.repoKey,
            repoName: info.repoName,
            repoRoot: info.repoRoot,
            checkoutPath: info.checkoutPath,
            isLinkedWorktree: info.isLinkedWorktree)
    }
}

/// A workspace known for a Host from its latest session snapshot, offered as
/// a target in the new-agent flow (#12). Identity is herdr's opaque
/// `workspace_id`; the label is what the picker shows.
struct ConsoleWorkspace: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    /// The workspace's git checkout identity from the snapshot, when reported.
    /// Linked worktrees share their repo's `repoKey` with the main checkout's
    /// workspace, which is how the index nests them under it (herdr's sidebar
    /// grouping).
    let checkout: RepositoryCheckout?
    /// The backend whose snapshot lists the workspace (for tmux, a session):
    /// picking it picks where a launch runs.
    let backend: HostBackend

    init(
        id: String, label: String, checkout: RepositoryCheckout? = nil,
        backend: HostBackend = .herdr
    ) {
        self.id = id
        self.label = label
        self.checkout = checkout
        self.backend = backend
    }
}

/// The line an Agent card shows under its headline (`ConsoleAgent.summaryLine`).
enum AgentSummaryLine: Equatable, Sendable {
    /// The Agent Summary and how long ago the Host wrote it. Stale when the
    /// Agent has left the status it was written in, or it is too old.
    case summary(text: String, age: TimeInterval, isStale: Bool)
    /// The first summary is on its way.
    case loading

    /// The age under the card's status: "now", "1m", "3h", "2d".
    static func shortAge(_ age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// What VoiceOver reads for the line, units spelled out.
    var accessibilityLabel: String {
        switch self {
        case .loading:
            return "Summary loading"
        case .summary(let text, let age, let isStale):
            let spoken = Self.spokenAge(age)
            return isStale ? "\(text). Updated \(spoken)" : "\(text). \(spoken)"
        }
    }

    /// An age as VoiceOver reads it: "just now", "5 minutes ago".
    static func spokenAge(_ age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        let hours = minutes / 60
        let (value, unit): (Int, String) =
            if minutes < 1 { (0, "") }
            else if minutes < 60 { (minutes, "minute") }
            else if hours < 24 { (hours, "hour") }
            else { (hours / 24, "day") }
        guard value > 0 else { return "just now" }
        let plural = value == 1 ? unit : unit + "s"
        return "\(value) \(plural) ago"
    }
}

extension AgentStatus {
    /// Console sort bucket: Blocked > Done > Working > Idle. Blocked has
    /// stopped and is waiting on the user's reply, Done has a result waiting
    /// to be read, Working needs nothing until it finishes, and Idle asks for
    /// nothing. The two that wait on the user lead, so a pass down the list
    /// clears them before anything merely busy. Unknown and any status this
    /// build does not recognize (herdr's API has no stability guarantee)
    /// share the bottom bucket — a status we cannot interpret is not
    /// actionable, so it must not outrank one we can.
    var consoleSortBucket: Int {
        switch self {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .idle: 3
        default: 4
        }
    }
}

extension [ConsoleAgent] {
    /// The rows with an Agent Status: everything but projected shells.
    /// Status-driven surfaces — notifications, Live Activities, Host status
    /// counts — read this; row surfaces read every row.
    var excludingShells: [ConsoleAgent] { filter { !$0.isShell } }

    /// Pins lead by rank. Everything else follows one attention order across
    /// every Host and Workspace: Blocked > Done > Working > Idle > the rest.
    /// Inside a bucket rows group by Host (name, then id), newest activity
    /// first within each Host (the `stateChangeSeq` comment at the comparator).
    /// `sortAs` maps an Agent to the copy its position is computed from; the
    /// Console passes the snapshot taken when a window opened an Agent, so
    /// that Agent's own status and recency changes do not move it.
    func consoleSorted(
        pinRank: (ConsoleAgent) -> Int? = { _ in nil },
        sortAs: (ConsoleAgent) -> ConsoleAgent = { $0 }
    ) -> [ConsoleAgent] {
        var result = sorted { liveLHS, liveRHS in
            let lhs = sortAs(liveLHS)
            let rhs = sortAs(liveRHS)
            let lhsRank = pinRank(lhs)
            let rhsRank = pinRank(rhs)
            switch (lhsRank, rhsRank) {
            case (let lhsRank?, let rhsRank?):
                if lhsRank != rhsRank { return lhsRank < rhsRank }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            let lhsBucket = lhs.agent.status.consoleSortBucket
            let rhsBucket = rhs.agent.status.consoleSortBucket
            if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
            if lhs.hostName != rhs.hostName { return lhs.hostName < rhs.hostName }
            if lhs.hostID != rhs.hostID {
                return lhs.hostID.uuidString < rhs.hostID.uuidString
            }
            // Recency inside a bucket is `stateChangeSeq`, newest first. Each
            // backend counts in its own unit (herdr a per-Host counter, tmux
            // wall-clock nanoseconds), so it is compared only between rows of
            // the same Host and backend; a Host's herdr-slot rows (herdr or
            // core, never both at once) otherwise lead its tmux rows.
            if lhs.backend != rhs.backend {
                let order = HostBackend.allCases
                return (order.firstIndex(of: lhs.backend) ?? order.count)
                    < (order.firstIndex(of: rhs.backend) ?? order.count)
            }
            let lhsSequence = lhs.agent.stateChangeSeq ?? 0
            let rhsSequence = rhs.agent.stateChangeSeq ?? 0
            if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
            let lhsOrder = lhs.snapshotOrder ?? Int.max
            let rhsOrder = rhs.snapshotOrder ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            let lhsWorkspace = lhs.workspaceLabel ?? ""
            let rhsWorkspace = rhs.workspaceLabel ?? ""
            if lhsWorkspace != rhsWorkspace { return lhsWorkspace < rhsWorkspace }
            return lhs.agent.paneID < rhs.agent.paneID
        }
        // Move only the lead within its project's existing positions. Other
        // Hosts/backends retain their relative order; no pairwise comparator
        // exception can create a cycle across workspace/status buckets.
        for lead in result.filter(\.isUltimateLeader) {
            guard let index = result.firstIndex(where: { $0.id == lead.id }),
                  let first = result.firstIndex(where: {
                      $0.hostID == lead.hostID && $0.backend == .ultimate
                          && $0.agent.workspaceID == lead.agent.workspaceID
                  }), first < index else { continue }
            let row = result.remove(at: index)
            result.insert(row, at: first)
        }
        return result
    }
}
