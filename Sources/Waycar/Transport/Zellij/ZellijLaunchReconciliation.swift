import Foundation

/// Lost launch answers reconcile only by the exact Launch Tag, never by name, folder or a new pane.
enum ZellijLaunchReconciliation {
    struct Match: Sendable, Equatable {
        let pane: ZellijPaneID
        let record: ZellijPaneRecord
    }

    enum Confirmation: Sendable, Equatable {
        case found(Match)
        case notYet
        case notFound
    }

    /// Creation is asynchronous: even exit-0 list-panes may initially print nothing (Z14).
    /// Poll notYet after a just-sent new-tab/attach -b, up to five seconds. Lost-launch replay
    /// instead uses find on a settled inventory: no tag there permits a new start.
    static func confirmation(
        tag: String, frame: ZellijFrame, elapsed: Duration, firstSeenMs: [String: Int64] = [:]
    ) -> Confirmation {
        if let found = find(tag: tag, frame: frame, firstSeenMs: firstSeenMs) { return .found(found) }
        return elapsed < .seconds(5) ? .notYet : .notFound
    }

    static func find(tag: String, frame: ZellijFrame, firstSeenMs: [String: Int64] = [:]) -> Match? {
        guard !tag.isEmpty else { return nil }
        for session in frame.sessions where !session.closed {
            for row in ZellijSnapshotBuilder.visiblePanes(frame, session: session.name)
            where row.exited != true {
                guard let id = ZellijPaneID(session: session.name, pane: row.id) else { continue }
                let document = ZellijSnapshotBuilder.document(for: id, frame: frame, firstSeenMs: firstSeenMs)
                if ZellijSnapshotBuilder.launchTag(row, document: document) == tag {
                    return Match(pane: id, record: row)
                }
            }
        }
        return nil
    }

    /// Launch Tags are generated plain tokens; quote/whitespace boundaries also match a /bin/sh -c wrapper.
    static func carries(tag: String, command: String) -> Bool {
        self.tag(in: command) == tag
    }

    static func tag(in command: String) -> String? {
        let pattern = #"(?:^|[\s'"])WAYCAR_LAUNCH=([A-Za-z0-9_-]+)(?=$|[\s'"])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
            let range = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[range])
    }
}
