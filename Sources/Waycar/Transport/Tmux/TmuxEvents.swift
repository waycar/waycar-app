import Foundation

/// Pure: tmux's control-mode notifications and the two format subscriptions
/// turned into the `HerdrEvent`s HostConsoleProjection already consumes
/// (design §4.3).
///
/// tmux has no per-pane add or close notification and its `%*` feed covers
/// only the attached session (T6), so two session-scope subscriptions watch
/// every pane (T7): `wc-topo` for topology and the foreground command,
/// `wc-status` for the hook-written options. Each pane is its fields in the
/// inventory's convention (``TmuxInventory/fields(_:)``: ␟ between fields,
/// each stripped of ␞ and ␟) followed by ␞, so loop commas need no `#,`
/// escaping and an option or command cannot split or forge a row.
enum TmuxEvents {
    static let topologyName = "wc-topo"
    static let statusName = "wc-status"

    static let topologyFields = [
        "session_id", "window_id", "pane_id", "pane_current_command", "pane_dead",
    ]
    static let statusFields = [
        "pane_id", "@waycar_status", "@waycar_agent", "@waycar_session", "@waycar_seq",
    ]

    /// `name::#{S:#{W:#{P:…}}}`, the argument of `refresh-client -B`.
    static func subscriptionSpec(name: String, fields: [String]) -> String {
        let pane = TmuxInventory.fields(fields) + String(TmuxInventory.recordSeparator)
        return "\(name)::#{S:#{W:#{P:\(pane)}}}"
    }

    static var topologySubscribeCommand: String {
        "refresh-client -B "
            + TmuxCommand.singleQuoted(subscriptionSpec(name: topologyName, fields: topologyFields))
    }

    static var statusSubscribeCommand: String {
        "refresh-client -B "
            + TmuxCommand.singleQuoted(subscriptionSpec(name: statusName, fields: statusFields))
    }

    /// The kind every topology-level change maps to: one the projection
    /// answers with a re-snapshot.
    static let resyncKind = GlobalEventKind.paneCreated.kind

    static let resync = HerdrEvent(kind: resyncKind, data: .object([:]))

    // MARK: Subscriptions

    /// One subscription value split into per-pane field lists. A pane listed
    /// once per grouped session repeats; the first row wins. A row whose
    /// first field is not a tmux id (`$N`, `@N`, `%N`), or whose last field
    /// holds a stray field separator, is dropped.
    static func rows(_ value: String, fieldCount: Int) -> [[String]] {
        let separator = TmuxInventory.fieldSeparator
        return TmuxInventory.split(value, at: TmuxInventory.recordSeparator).compactMap { chunk in
            let fields = TmuxInventory.split(chunk, at: separator, maxSplits: fieldCount - 1)
            guard fields.count == fieldCount,
                fields.last?.unicodeScalars.contains(separator) == false,
                let id = fields.first, let prefix = id.first, "$@%".contains(prefix),
                TmuxInventory.isID(id, prefix: prefix)
            else { return nil }
            return fields
        }
    }

    /// The raw hook values the last snapshot listed, as a status subscription
    /// value. The first push can arrive after that snapshot and must diff it.
    static func statusValue(_ panes: [TmuxPaneRecord]) -> String {
        panes.map { pane in
            [pane.id, pane.waycarStatus, pane.waycarAgent, pane.waycarSession, pane.waycarSeq]
                .joined(separator: String(TmuxInventory.fieldSeparator))
                + String(TmuxInventory.recordSeparator)
        }.joined()
    }

    /// Events for one `%subscription-changed` push, given the subscription's
    /// previous value, or the last snapshot's hook values for a first status
    /// push. Without a snapshot yet, that push requests one instead.
    static func events(name: String, previous: String?, value: String) -> [HerdrEvent] {
        guard let previous else { return name == statusName ? [resync] : [] }
        guard previous != value else { return [] }
        switch name {
        case topologyName:
            return topologyKey(previous) == topologyKey(value) ? [] : [resync]
        case statusName:
            return statusEvents(previous: previous, value: value)
        default:
            return []
        }
    }

    /// Topology compared as a set of distinct pane rows, so a grouped
    /// session's repeated listing order cannot fake a change.
    private static func topologyKey(_ value: String) -> Set<[String]> {
        Set(rows(value, fieldCount: topologyFields.count))
    }

    private struct StatusRow: Equatable {
        let status: String
        let agent: String
        let session: String
        let seq: String
    }

    private static func statusRows(_ value: String) -> [String: StatusRow] {
        var rows: [String: StatusRow] = [:]
        for fields in self.rows(value, fieldCount: statusFields.count)
        where rows[fields[0]] == nil {
            rows[fields[0]] = StatusRow(
                status: fields[1], agent: fields[2], session: fields[3], seq: fields[4])
        }
        return rows
    }

    /// A status change is one `pane.agent_status_changed` per pane, applied
    /// in place. A kind, session or pane-set change, or a new sequence under
    /// an unchanged status (a whole turn between two pushes), resyncs.
    private static func statusEvents(previous: String, value: String) -> [HerdrEvent] {
        let old = statusRows(previous)
        let new = statusRows(value)
        guard Set(old.keys) == Set(new.keys) else { return [resync] }
        var changes: [HerdrEvent] = []
        var needsResync = false
        for paneID in new.keys.sorted() {
            guard let before = old[paneID], let after = new[paneID], before != after else {
                continue
            }
            if before.agent != after.agent || before.session != after.session {
                needsResync = true
            } else if before.status != after.status {
                changes.append(statusChanged(paneID: paneID, status: after.status))
            } else {
                needsResync = true
            }
        }
        return needsResync ? changes + [resync] : changes
    }

    /// The payload `HostConsoleProjection.applyStatusChange` reads.
    static func statusChanged(paneID rawPaneID: String, status rawStatus: String) -> HerdrEvent {
        let status = TmuxAgentDetection.waycarStatus(rawStatus) ?? .unknown
        return HerdrEvent(
            kind: PaneEventKind.agentStatusChanged.kind,
            data: .object([
                "pane_id": .string(TmuxID.app(rawPaneID)),
                "agent_status": .string(status.rawValue),
            ]))
    }

    // MARK: Notifications

    /// Events for one control-mode notification line (`%window-add @3`).
    /// Notifications that reach every session (T8, T23) map to resync kinds;
    /// `%layout-change` maps to nothing, since `wc-topo` sees pane changes.
    static func events(notification line: String) -> [HerdrEvent] {
        let name = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
        let kind: GlobalEventKind? =
            switch name {
            case "%sessions-changed": .workspaceCreated
            case "%session-renamed": .workspaceRenamed
            case "%window-add", "%unlinked-window-add": .tabCreated
            case "%window-close", "%unlinked-window-close": .tabClosed
            case "%window-renamed", "%unlinked-window-renamed": .tabRenamed
            default: nil
            }
        return kind.map { [HerdrEvent(kind: $0.kind, data: .object([:]))] } ?? []
    }
}
