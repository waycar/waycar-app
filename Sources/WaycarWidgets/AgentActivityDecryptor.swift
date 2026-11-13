import Foundation

/// Render-time view of one Live Activity update: decrypted Host details, or
/// the plaintext counts when the envelope cannot be opened.
enum AgentActivityPresentation: Equatable, Sendable {
    case detailed(details: AgentActivityDetails, counts: AgentActivityAttributes.ContentState.Counts)
    case countsOnly(counts: AgentActivityAttributes.ContentState.Counts)

    var counts: AgentActivityAttributes.ContentState.Counts {
        switch self {
        case .detailed(_, let counts), .countsOnly(let counts):
            return counts
        }
    }

    var agents: [AgentActivityDetails.AgentDetail] {
        switch self {
        case .detailed(let details, _):
            return details.agents
        case .countsOnly:
            return []
        }
    }

    /// The Host's short name; nil in counts-only.
    var hostName: String? {
        switch self {
        case .detailed(let details, _):
            return details.hostName
        case .countsOnly:
            return nil
        }
    }

    /// Agents in the compact island's bar stack (top 3, envelope order),
    /// or nil when the stack does not replace the count: the lead must be
    /// Working and at least one of them must have a drawn bar.
    var compactProgressAgents: [AgentActivityDetails.AgentDetail]? {
        guard counts.attentionStatusItem?.status == "working" else { return nil }
        let top = Array(agents.prefix(AgentActivityCopy.compactBarLimit))
        guard top.contains(where: { AgentActivityProgressCopy.drawnProgress(for: $0) != nil })
        else { return nil }
        return top
    }

    /// Rows in the expanded Dynamic Island, in envelope order (pinned
    /// eligible first, then status rank): every Agent when the eligible
    /// inventory fits `rowLimit`, otherwise one fewer so the "+N more"
    /// footer fits the expanded height.
    var islandAgents: [AgentActivityDetails.AgentDetail] {
        let limit = counts.total <= AgentActivityCopy.rowLimit
            ? AgentActivityCopy.rowLimit : AgentActivityCopy.rowLimit - 1
        return Array(agents.prefix(limit))
    }

    /// Eligible Agents beyond the expanded island rows, from the full
    /// inventory in `counts` (the envelope list is capped at 5). Zero in
    /// counts-only: there is nothing to overflow from.
    var islandOverflowCount: Int {
        let shown = islandAgents.count
        guard shown > 0 else { return 0 }
        return max(0, counts.total - shown)
    }

    /// The most one-line rows that fit the 160 pt Lock Screen budget beside
    /// the status header and, when needed, the overflow/stale footer. Fresh
    /// hosts with four or fewer Agents show them all; five or more, or a
    /// stale banner, show three plus the footer.
    func lockScreenAgents(isStale: Bool) -> [AgentActivityDetails.AgentDetail] {
        let total = counts.total
        let candidates = Array(agents.prefix(min(total, AgentActivityLockScreenMetrics.maximumRows)))
        let fitting = (0...candidates.count).last { shown in
            AgentActivityLockScreenMetrics.height(
                rows: shown, hasFooter: isStale || total > shown)
                <= AgentActivityLockScreenMetrics.heightBudget
        } ?? 0
        return Array(candidates.prefix(fitting))
    }

    /// Inventory beyond the drawn lock-screen rows. Zero in counts-only.
    func lockScreenOverflowCount(isStale: Bool) -> Int {
        let shown = lockScreenAgents(isStale: isStale)
        guard !shown.isEmpty else { return 0 }
        return max(0, counts.total - shown.count)
    }

    /// Lock Screen footer: overflow, stale notice, or both.
    func lockScreenTrailingCaption(isStale: Bool) -> String? {
        let overflow = lockScreenOverflowCount(isStale: isStale)
        let staleCaption = "May be out of date"
        if isStale {
            if overflow > 0 {
                return "+\(overflow) more · \(staleCaption)"
            }
            return staleCaption
        }
        if overflow > 0 {
            return "+\(overflow) more"
        }
        return nil
    }
}

/// Layout constants of the Lock Screen banner, shared by the view and the
/// row budget so the estimate matches what is drawn.
enum AgentActivityLockScreenMetrics {
    static let verticalPadding: CGFloat = 10
    static let horizontalPadding: CGFloat = 14
    /// Rendered height of the `.headline` status header.
    static let headerHeight: CGFloat = 22
    /// Gap between header, rows, and footer.
    static let sectionSpacing: CGFloat = 6
    /// Apple's documented minimum iOS control size for dense layouts; also
    /// each one-line row's tap target.
    static let rowHeight: CGFloat = 28
    /// Rendered height of the `.footnote` overflow/stale footer.
    static let footerHeight: CGFloat = 16
    static let maximumRows = 4
    /// Kind monogram diameter and the gap after it. The footer starts at
    /// the text column they leave, clear of the island's rounded corners.
    static let monogramSize: CGFloat = 24
    static let monogramSpacing: CGFloat = 8
    /// ActivityKit's lock-screen presentation height limit.
    static let heightBudget: CGFloat = 160

    static func height(rows: Int, hasFooter: Bool) -> CGFloat {
        var height = verticalPadding * 2 + headerHeight
        if rows > 0 { height += sectionSpacing + rowHeight * CGFloat(rows) }
        if hasFooter { height += sectionSpacing + footerHeight }
        return height
    }
}

/// Synchronous render-time helper. Failures degrade to counts-only so a
/// view body never has to throw (nil envelope, locked Keychain before
/// first unlock, unknown kid, decrypt or payload error).
enum AgentActivityDecryptor {
    static func presentation(
        for state: AgentActivityAttributes.ContentState,
        store: NotificationKeyStore = NotificationKeyStore(),
        mirror: NotificationKeyMirror = NotificationKeyMirror()
    ) -> AgentActivityPresentation {
        #if DEBUG
            lastFailureReason = nil
        #endif
        guard let envelope = state.envelope,
            let data = try? JSONEncoder().encode(envelope),
            let kid = SealedEnvelopeCodec.peekKeyID(in: data)
        else {
            breadcrumb("no envelope or unreadable kid")
            return .countsOnly(counts: state.counts)
        }

        // The Keychain is unreachable in the locked lock-screen rendering
        // context (errSecNotAvailable); the app-group mirror is maintained
        // for exactly that gap, so a kid missing from whichever Keychain
        // records did load falls through to it as well.
        let records = (try? store.allRecords()) ?? []
        guard
            let record = records.first(where: { $0.keyID == kid })
                ?? mirror.read().first(where: { $0.keyID == kid })
        else {
            breadcrumb("kid \(kid) not among \(records.map(\.keyID)) nor mirrored")
            return .countsOnly(counts: state.counts)
        }
        let opened: AgentActivityDetails
        do {
            opened = try AgentActivityEnvelope.open(data, using: record.key)
        } catch {
            breadcrumb("open failed: \(error)")
            return .countsOnly(counts: state.counts)
        }

        return .detailed(details: opened, counts: state.counts)
    }

    /// Debug-only: why the last `presentation(for:)` in this process fell
    /// back to counts-only, for on-lock-screen diagnosis of device-only
    /// failures. Rendered by the lock-screen view in Debug builds.
    #if DEBUG
        nonisolated(unsafe) static var lastFailureReason: String?
    #endif

    /// Debug-only render-time trace into the shared app-group container, so
    /// a countsOnly fallback on a physical device can name its cause
    /// (`devicectl device copy from --domain-type appGroupDataContainer`).
    private static func breadcrumb(_ reason: String) {
        #if DEBUG
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: NotificationKeyStore.sharedAccessGroup)
            lastFailureReason = "\(reason) | group: \(container == nil ? "nil" : "ok")"
            guard let url = container else { return }
            let line = "\(Date()) \(reason)\n"
            let file = url.appendingPathComponent("activity-decrypt-debug.txt")
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        #endif
    }
}

enum AgentActivityCopy {
    /// Most Agent rows in the expanded Dynamic Island (one fewer when a
    /// "+N more" footer is needed); the Lock Screen sizes itself via
    /// `lockScreenAgents` instead.
    static let rowLimit = 3
    /// Hairline bars stacked in the compact island's trailing region.
    static let compactBarLimit = 3
    /// Agent rows in the `.small` family (Watch Smart Stack, CarPlay
    /// Dashboard).
    static let smallRowLimit = 3
}

/// What progress (#189) an Agent row draws and says. Only Working and
/// Blocked draw a bar (Blocked's is frozen); only Working trades its status
/// word for the estimate, because attention beats progress.
enum AgentActivityProgressCopy {
    /// Fill opacity of a bar whose activity is past its stale date.
    static let staleFillOpacity = 0.4

    static func drawnProgress(for agent: AgentActivityDetails.AgentDetail) -> AgentProgress? {
        guard agent.status == "working" || agent.status == "blocked" else { return nil }
        return agent.progress
    }

    /// The row's trailing word: the progress label when Working with an
    /// estimate, else the status word.
    static func trailingLabel(for agent: AgentActivityDetails.AgentDetail) -> String {
        if agent.status == "working", let progress = agent.progress {
            return progress.label
        }
        return AgentActivityStatusVocabulary.word(for: agent.status)
    }
}

extension AgentActivityAttributes.ContentState.Counts {
    /// Actionable Agents only: the full eligible inventory. Idle is shown in
    /// the status header but never counted here, so the Dynamic Island
    /// totals keep meaning "Agents that need or will need you".
    var total: Int { working + blocked + done }

    /// Non-zero counts in attention order (blocked, done, working), then
    /// idle last.
    var chipItems: [(status: String, count: Int)] {
        var items: [(String, Int)] = []
        if blocked > 0 { items.append(("blocked", blocked)) }
        if done > 0 { items.append(("done", done)) }
        if working > 0 { items.append(("working", working)) }
        if idle > 0 { items.append(("idle", idle)) }
        return items
    }

    /// First non-zero count in attention order: blocked, done, working.
    var attentionStatusItem: (status: String, count: Int)? {
        if blocked > 0 { return ("blocked", blocked) }
        if done > 0 { return ("done", done) }
        if working > 0 { return ("working", working) }
        return nil
    }

    /// The status header's trailing counts: every non-zero status except
    /// the lead, in `chipItems` order.
    var otherStatusItems: [(status: String, count: Int)] {
        let lead = attentionStatusItem?.status
        return chipItems.filter { $0.status != lead }
    }

    /// The expanded island's trailing counts: `otherStatusItems` without
    /// idle, matching the compact and minimal totals (at most two items).
    var islandOtherStatusItems: [(status: String, count: Int)] {
        otherStatusItems.filter { $0.status != "idle" }
    }
}
