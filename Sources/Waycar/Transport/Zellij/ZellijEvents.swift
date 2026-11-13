import Foundation

/// Inventory deltas as the same synthesized events tmux feeds the Console projection.
enum ZellijEvents {
    static let resync = HerdrEvent(kind: GlobalEventKind.paneCreated.kind, data: .object([:]))

    static func events(
        previous: ZellijFrame?, frame: ZellijFrame, firstSeenMs: [String: Int64] = [:]
    ) -> [HerdrEvent] {
        guard let previous else { return [resync] }
        let old = ZellijSnapshotBuilder.snapshot(frame: previous, firstSeenMs: firstSeenMs)
        let new = ZellijSnapshotBuilder.snapshot(frame: frame, firstSeenMs: firstSeenMs)
        var needsResync =
            previous.sessions != frame.sessions
            || old.panes.map(\.paneID) != new.panes.map(\.paneID)
            || foreground(previous) != foreground(frame)
        let before = Dictionary(old.panes.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [HerdrEvent] = []
        for pane in new.panes {
            guard let prior = before[pane.paneID] else {
                needsResync = true
                continue
            }
            if pane.agentStatus != prior.agentStatus {
                events.append(
                    HerdrEvent(
                        kind: PaneEventKind.agentStatusChanged.kind,
                        data: .object([
                            "pane_id": .string(pane.paneID),
                            "agent_status": .string(pane.agentStatus.rawValue),
                        ])))
            }
            if pane.tabID != prior.tabID || pane.agent != prior.agent
                || pane.agentSession != prior.agentSession || pane.cwd != prior.cwd
                || pane.terminalTitle != prior.terminalTitle || pane.focused != prior.focused
            {
                needsResync = true
            }
        }
        // Labels/order and a whole turn between ticks must also refresh metadata/recency.
        if old.tabs.map({ [$0.tabID, $0.label, String($0.number)] })
            != new.tabs.map({ [$0.tabID, $0.label, String($0.number)] })
        {
            needsResync = true
        }
        let oldAgents = Dictionary(
            old.agents.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        for agent in new.agents {
            if let prior = oldAgents[agent.paneID], prior.agentStatus == agent.agentStatus,
                prior.stateChangeSeq != agent.stateChangeSeq
            {
                needsResync = true
            }
        }
        return needsResync ? events + [resync] : events
    }

    private struct Foreground: Equatable {
        let command: String?
        let exited: Bool?
    }

    private static func foreground(_ frame: ZellijFrame) -> [String: Foreground] {
        var result: [String: Foreground] = [:]
        for session in frame.sessions where !session.closed {
            for pane in ZellijSnapshotBuilder.visiblePanes(frame, session: session.name) {
                guard let id = ZellijPaneID(session: session.name, pane: pane.id) else { continue }
                result[id.description] = Foreground(command: pane.paneCommand, exited: pane.exited)
            }
        }
        return result
    }
}
