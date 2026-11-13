import Foundation

/// The surface-neutral Agent list a glance surface shows: CarPlay's root
/// list and the Apple Watch's Agents list (docs/design/carplay.md §4,
/// docs/design/apple-watch-v0.md §3.5). Shells excluded, attention order,
/// and a headline that never carries message content. Each surface caps and
/// lays out the rows itself.
enum AgentGlanceList {
    /// A Workspace label longer than this falls back to the kind alone.
    static let maximumWorkspaceLength = 24

    // MARK: Rows

    /// The Agents a glance lists, in order: shells dropped, then `sorted`.
    static func listed(_ agents: [ConsoleAgent]) -> [ConsoleAgent] {
        sorted(agents.excludingShells)
    }

    /// The Agent with this id among `agents` when a glance lists it: nil
    /// for a Shell or an id `agents` doesn't have. `listed`'s rule, without
    /// sorting.
    static func listedAgent(_ id: ConsoleAgent.ID, in agents: [ConsoleAgent]) -> ConsoleAgent? {
        agents.first { $0.id == id && !$0.isShell }
    }

    /// Blocked > Done > Working > Idle > the rest. Inside a bucket the
    /// Console's order: Host, then backend, then newest status change
    /// first. `stateChangeSeq` is a per-Host counter on herdr and
    /// wall-clock nanoseconds on tmux, so it is compared only between
    /// rows of the same Host and backend.
    static func sorted(_ agents: [ConsoleAgent]) -> [ConsoleAgent] {
        agents.sorted { lhs, rhs in
            let lhsBucket = lhs.agent.status.consoleSortBucket
            let rhsBucket = rhs.agent.status.consoleSortBucket
            if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
            if lhs.hostName != rhs.hostName { return lhs.hostName < rhs.hostName }
            if lhs.hostID != rhs.hostID {
                return lhs.hostID.uuidString < rhs.hostID.uuidString
            }
            // `allCases` puts the herdr slot (herdr or core) before tmux.
            if lhs.backend != rhs.backend {
                let order = HostBackend.allCases
                return (order.firstIndex(of: lhs.backend) ?? order.count)
                    < (order.firstIndex(of: rhs.backend) ?? order.count)
            }
            let lhsSeq = lhs.agent.stateChangeSeq ?? Int.min
            let rhsSeq = rhs.agent.stateChangeSeq ?? Int.min
            if lhsSeq != rhsSeq { return lhsSeq > rhsSeq }
            return title(for: lhs) < title(for: rhs)
        }
    }

    // MARK: Title

    /// The phone card's headline, `workspace · tab` (`AgentRowRenderer`'s
    /// workspace and tab tokens): the tab label when the phone shows one,
    /// else the Agent name, else the push identity `workspace · Kind`. A
    /// name equal to the Workspace is said once.
    static func title(for agent: ConsoleAgent) -> String {
        let workspace = sanitizedWorkspace(agent.workspaceLabel)
        guard let name = sanitizedName(nameSource(of: agent)) ?? sanitizedName(agent.agent.name)
        else {
            return AgentNotificationIdentity.title(workspace: workspace, kind: agent.agent.kind)
        }
        guard let workspace else { return name }
        if workspace.caseInsensitiveCompare(name) == .orderedSame { return workspace }
        return "\(workspace) · \(name)"
    }

    /// The tab label the phone shows. On tmux the tab label is the window
    /// name; when that is the automatic-rename artifact the inventory gives
    /// the Agent no name (`TmuxInventory.agentName`), so a glance skips it.
    private static func nameSource(of agent: ConsoleAgent) -> String? {
        guard agent.showsTabLabel else { return nil }
        if agent.backend == .tmux, agent.agent.name == nil { return nil }
        return agent.tabLabel
    }

    /// herdr accepts any Workspace label, so a glance shows one only when
    /// it reads as a name: control and box-drawing characters stripped,
    /// whitespace collapsed, nothing path- or code-like, at most
    /// `maximumWorkspaceLength` characters. Otherwise nil (kind alone).
    static func sanitizedWorkspace(_ label: String?) -> String? {
        guard let collapsed = sanitizedName(label), !collapsed.contains("/"),
            !collapsed.contains("`")
        else { return nil }
        return collapsed
    }

    /// A tab label or Agent name, cleaned like a Workspace label but
    /// keeping `/` (`Partners DO/TO`). Nil when empty or too long.
    static func sanitizedName(_ label: String?) -> String? {
        guard let label else { return nil }
        // A stripped character becomes a space, so a tab still
        // separates words before whitespace collapses.
        let kept = label.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar)
                || (0x2500...0x259F).contains(scalar.value)
                ? " " : Character(scalar)
        }
        let collapsed = String(kept)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= maximumWorkspaceLength else { return nil }
        return collapsed
    }

    // MARK: Age

    /// Time in the current status. The Console has no status timestamp
    /// yet; an Agent Summary written in the same status is the closest
    /// fact, so the age shows only when one exists.
    static func statusAge(of agent: ConsoleAgent, now: Date) -> String? {
        guard let summary = agent.summary, summary.status == agent.agent.status else {
            return nil
        }
        let since = Date(timeIntervalSince1970: TimeInterval(summary.timestamp) / 1000)
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        switch minutes {
        case 0: return "now"
        case ..<60: return "\(minutes)m"
        case ..<(24 * 60): return "\(minutes / 60)h"
        default: return "\(minutes / (24 * 60))d"
        }
    }
}
