import Foundation

/// Comparable desired Live Activity content for one Host, before sealing.
/// Working/blocked/done counts cover the full eligible inventory, `idle` the
/// full idle inventory; `agents` is already sorted and capped
/// (docs/agents/live-activity-contract.md).
struct AgentActivityDesire: Equatable, Sendable {
    var counts: AgentActivityAttributes.ContentState.Counts
    var hostName: String
    var agents: [AgentActivityDetails.AgentDetail]
}

/// Builds a Host's Live Activity `ContentState` from the Console's Agent
/// list: plaintext counts plus a sealed details envelope.
enum AgentActivityContentBuilder {
    static let maxTitleGraphemes = 80
    static let maxHostGraphemes = 80
    static let maxAgents = 5
    /// Base64url `ct` budget from the shared vector-file description, so the
    /// full APNs payload stays under 4096.
    static let maxCiphertextBytes = 2800

    /// Nil when no Agent is working, blocked, or done — the end signal.
    /// Idle Agents are counted but never make a desire on their own.
    /// `pinnedPaneIDs` is most-recently-pinned first; pins reorder the
    /// eligible list and never change eligibility or counts.
    static func desire(
        from agents: [ConsoleAgent],
        hostName: String,
        pinnedPaneIDs: [String] = [],
        layout: AgentRowLayout? = nil,
        now: Date = Date()
    ) -> AgentActivityDesire? {
        let eligible = agents.filter {
            isEligible($0.agent.status) || ($0.isUltimateLeader
                && ($0.ultimateChildren.contains(where: \.busy) || $0.ultimateOpenQuestions > 0))
        }
        guard !eligible.isEmpty else { return nil }
        var working = 0
        var blocked = 0
        var done = 0
        var idle = 0
        for agent in agents {
            switch agent.agent.status {
            case .working: working += 1
            case .blocked: blocked += 1
            case .done: done += 1
            case .idle: idle += 1
            default: break
            }
        }
        let details = Array(sorted(eligible, pinnedPaneIDs: pinnedPaneIDs).prefix(maxAgents))
            .map { detail(from: $0, layout: layout, now: now) }
        return AgentActivityDesire(
            counts: .init(working: working, blocked: blocked, done: done, idle: idle),
            hostName: prefixGraphemes(hostName, max: maxHostGraphemes),
            agents: details)
    }

    /// Seals `desire` under the Host's Notification Key, sending the first
    /// `degradeCandidates` entry whose `ct` fits the budget. Tests can pin
    /// the nonce.
    static func content(
        for desire: AgentActivityDesire,
        key: Data,
        nonce: Data? = nil
    ) -> AgentActivityAttributes.ContentState? {
        for candidate in degradeCandidates(for: desire) {
            guard let sealed = try? AgentActivityEnvelope.seal(
                AgentActivityDetails(hostName: candidate.hostName, agents: candidate.agents),
                using: key,
                nonce: nonce),
                let envelope = try? JSONDecoder().decode(
                    AgentActivityAttributes.ContentState.Envelope.self, from: sealed)
            else { continue }
            if envelope.ct.count <= maxCiphertextBytes || candidate.agents.isEmpty {
                return AgentActivityAttributes.ContentState(
                    counts: desire.counts, envelope: envelope)
            }
        }
        return nil
    }

    /// The contract's degrade order under the ciphertext cap
    /// (`degrade` in the shared vectors): as desired, then without titles
    /// and names, then also without configured rows, then also without
    /// progress, then `agents: []`. A step that changes nothing is skipped.
    static func degradeCandidates(for desire: AgentActivityDesire) -> [AgentActivityDesire] {
        var candidates = [desire]
        var withoutTitles = desire
        withoutTitles.agents = desire.agents.map { agent in
            var stripped = agent
            stripped.title = nil
            stripped.name = nil
            return stripped
        }
        if withoutTitles != desire { candidates.append(withoutTitles) }
        var withoutRows = withoutTitles
        withoutRows.agents = withoutTitles.agents.map { agent in
            var stripped = agent
            stripped.rows = nil
            return stripped
        }
        if withoutRows != withoutTitles { candidates.append(withoutRows) }
        var withoutProgress = withoutRows
        withoutProgress.agents = withoutRows.agents.map { agent in
            var stripped = agent
            stripped.progress = nil
            return stripped
        }
        if withoutProgress != withoutRows { candidates.append(withoutProgress) }
        var emptyAgents = desire
        emptyAgents.agents = []
        if emptyAgents != withoutProgress { candidates.append(emptyAgents) }
        return candidates
    }

    /// Convenience: desire + seal, or nil when there is nothing to show.
    static func make(
        agents: [ConsoleAgent],
        hostName: String,
        key: Data,
        nonce: Data? = nil,
        pinnedPaneIDs: [String] = [],
        layout: AgentRowLayout? = nil
    ) -> AgentActivityAttributes.ContentState? {
        guard let desire = desire(
            from: agents, hostName: hostName, pinnedPaneIDs: pinnedPaneIDs, layout: layout)
        else { return nil }
        return content(for: desire, key: key, nonce: nonce)
    }

    private static func isEligible(_ status: AgentStatus) -> Bool {
        status == .working || status == .blocked || status == .done
    }

    /// Pinned eligible agents first, by pin-list index (most recent = 0);
    /// the rest keep status rank then pane-id byte order. Unknown or
    /// ineligible pin ids are simply not in `agents`.
    ///
    /// The Live Activity's attention rank is Blocked > Done > Working, the
    /// same order as the Console's `consoleSortBucket`, because a finished
    /// result is actionable while a working agent is not. The shared plugin
    /// vectors pin this order for both implementations; keep it local rather
    /// than reading the Console buckets, which also rank Idle and Unknown.
    private static func sorted(
        _ agents: [ConsoleAgent], pinnedPaneIDs: [String]
    ) -> [ConsoleAgent] {
        agents.sorted { lhs, rhs in
            let leftPin = pinnedPaneIDs.firstIndex(of: lhs.agent.paneID)
            let rightPin = pinnedPaneIDs.firstIndex(of: rhs.agent.paneID)
            switch (leftPin, rightPin) {
            case let (left?, right?):
                if left != right { return left < right }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            let left = activityRank(lhs.agent.status)
            let right = activityRank(rhs.agent.status)
            if left != right { return left < right }
            return lhs.agent.paneID.utf8.lexicographicallyPrecedes(rhs.agent.paneID.utf8)
        }
    }

    /// Blocked first (waiting on the user's reply), then Done (a result
    /// waiting to be read), then Working (merely busy). Unknown statuses
    /// share the bottom bucket — a status this build cannot interpret is not
    /// actionable, so it must not outrank one it can.
    private static func activityRank(_ status: AgentStatus) -> Int {
        switch status {
        case .blocked: 0
        case .done: 1
        case .working: 2
        default: 3
        }
    }

    /// Only an estimate that applies to the current status travels (C3),
    /// matching the plugin producer: one written in the Agent's current
    /// status, or, for a Blocked Agent, its still-Working record's estimate
    /// (the frozen bar; the Blocked record lands seconds later). Pending has
    /// nothing to draw, and `progressDisplay` is nil outside Working/Blocked,
    /// so Done never carries progress. An age-stale estimate still ships;
    /// the activity's own stale date dims it.
    private static func progress(of agent: ConsoleAgent, now: Date) -> AgentProgress? {
        guard case .estimate(let progress, _) = agent.progressDisplay(at: now),
            let written = agent.summary?.status
        else { return nil }
        let status = agent.herdrStatus
        guard written == status || (status == .blocked && written == .working) else { return nil }
        return progress
    }

    private static func detail(
        from agent: ConsoleAgent, layout: AgentRowLayout?, now: Date
    ) -> AgentActivityDetails.AgentDetail {
        let kind = agent.agent.kind.isEmpty ? "unknown" : agent.agent.kind
        let trimmed = prefixGraphemes(agent.agent.title, max: maxTitleGraphemes)
        let name = agent.agent.name.map { prefixGraphemes($0, max: maxTitleGraphemes) }
        let workspace = agent.workspaceLabel.map {
            prefixGraphemes($0, max: maxTitleGraphemes)
        }
        return AgentActivityDetails.AgentDetail(
            paneID: agent.agent.paneID,
            kind: kind,
            name: name?.isEmpty == false ? name : nil,
            workspace: workspace?.isEmpty == false ? workspace : nil,
            status: agent.agent.status.rawValue,
            title: trimmed.isEmpty ? nil : trimmed,
            rows: agent.isUltimateLeader ? [
                [.init(text: workspace ?? name ?? "Ultimate")],
                [.init(text: agent.ultimateBranchSummary)]
            ] : layout.map { layout in
                AgentRowRenderer.render(layout: layout.normalizedForConsole(), agent: agent).map { row in
                    row.map { field in
                        AgentActivityDetails.Field(
                            text: prefixGraphemes(field.text, max: maxTitleGraphemes),
                            fg: field.fg?.rawValue, bold: field.bold, dim: field.dim)
                    }
                }
            },
            progress: progress(of: agent, now: now))
    }

    static func prefixGraphemes(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max))
    }
}
