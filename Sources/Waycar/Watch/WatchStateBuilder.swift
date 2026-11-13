import Foundation

// MARK: Source

/// The Console facts a Watch State is built from, read at one moment
/// (`WatchBridge` observes this value to know when to republish).
struct WatchStateSource: Equatable, Sendable {
    /// `ConsoleStore.verifiedAgents`: rows of Hosts still awaiting their
    /// live snapshot are not facts yet. Shells are dropped by the builder.
    var agents: [ConsoleAgent]
    /// The Console's Host catalog; Disabled Hosts are dropped by the builder.
    var hosts: [Host]
    /// `ConsoleStore.hostStatuses`.
    var statuses: [Host.ID: EventsSessionStatus]
    /// `ConsoleStore.hostsAwaitingSnapshot`.
    var awaitingSnapshot: Set<Host.ID>
    /// The listed Agents the Console's Chat Mode markers say run in Chat
    /// Mode (`ConsoleStore.isChatMode`).
    var chatModeAgents: Set<ConsoleAgent.ID>
    /// `DictationEngines.fileTranscriber != nil`.
    var voiceTranscription: Bool
    /// Whether the Console's connections are suspended in the background
    /// (`AppActivityPhase.suspended`): no Host is confirmed then.
    var isSuspended = false

    /// Nothing known: no Hosts, no Agents.
    static let empty = WatchStateSource(
        agents: [], hosts: [], statuses: [:], awaitingSnapshot: [], chatModeAgents: [],
        voiceTranscription: false)
}

// MARK: Status stamps

/// When the phone first saw each listed Agent in its current status, kept
/// in memory only. An Agent seen for the first time has no stamp: how long
/// it has been in that status is unknown, never guessed. Only a change the
/// phone watched happen is stamped.
struct WatchStatusStamps: Equatable, Sendable {
    /// One Agent's last seen status and when it began, nil when unknown.
    struct Entry: Equatable {
        /// The raw `AgentStatus` the stamp belongs to.
        let status: String
        /// When the phone saw `status` begin; nil on first sight.
        let since: Date?
    }

    /// The stamp per listed Agent.
    private(set) var entries: [ConsoleAgent.ID: Entry] = [:]

    /// Folds in the listed Agents at `now`: a new Agent is unknown, a
    /// changed status is stamped `now`, an unchanged one keeps its stamp.
    /// Agents no longer listed are forgotten, so one that returns (a Host
    /// reconnecting) is unknown again rather than carrying an old stamp.
    mutating func observe(_ agents: [ConsoleAgent], at now: Date) {
        var next: [ConsoleAgent.ID: Entry] = [:]
        next.reserveCapacity(agents.count)
        for agent in agents {
            let status = agent.agent.status.rawValue
            if let entry = entries[agent.id] {
                next[agent.id] = entry.status == status ? entry : Entry(status: status, since: now)
            } else {
                next[agent.id] = Entry(status: status, since: nil)
            }
        }
        entries = next
    }

    /// The stamp for `agent`'s current status, if the phone saw it begin.
    func since(of agent: ConsoleAgent) -> Date? {
        guard let entry = entries[agent.id], entry.status == agent.agent.status.rawValue else {
            return nil
        }
        return entry.since
    }
}

// MARK: Builder

/// Builds the Watch State and the watch's Latest text from Console facts.
/// Pure: no Console, no clock of its own.
enum WatchStateBuilder {
    /// The most JSON-encoded bytes of Latest text one reply carries, with
    /// each character `JSONEncoder` escapes counted as its escape.
    /// `sendMessageData` replies have an undocumented size limit
    /// (`payloadTooLarge`); this stays well under it with room for the
    /// summary and the JSON around it.
    static let latestByteBudget = 48 * 1024

    /// How far past a cut the kept text may skip to start at a whole word;
    /// a longer run is cut at a character instead.
    static let wordSkipLimit = 64

    /// The plain leading line of a reply cut to `latestByteBudget`.
    static let earlierTextNotice = "Earlier text is on your iPhone."

    /// The smallest `stateChangeSeq` read as tmux's wall-clock nanoseconds
    /// (September 2001); anything below is not a time.
    static let minimumWallClockNanoseconds = 1_000_000_000_000_000_000

    /// The same floor for herdr-core's `status_ms` (September 2001).
    static let minimumWallClockMilliseconds = 1_000_000_000_000

    /// The Watch State for `source` at `now`: every enabled Host with its
    /// condition, and the listed Agents of enabled Hosts in glance order.
    ///
    /// Only a confirmed Host's live snapshot can remove a row. An enabled
    /// Host that is not confirmed (connecting, awaiting its snapshot,
    /// unreachable, or the Console suspended) keeps its rows from
    /// `previous`, the last state built, with their last-known statuses;
    /// any row the Console still lists for it replaces its kept copy. A
    /// disabled or removed Host's rows are dropped.
    static func state(
        from source: WatchStateSource, stamps: WatchStatusStamps, previous: WatchState? = nil,
        now: Date
    ) -> WatchState {
        let enabledHosts = source.hosts.filter(\.isEnabled)
        let enabledIDs = Set(enabledHosts.map(\.id))
        let current = AgentGlanceList.listed(source.agents.filter { enabledIDs.contains($0.hostID) })
            .map { agent in
                WatchAgentRow(
                    id: WatchAgentID(agent.id),
                    title: AgentGlanceList.title(for: agent),
                    status: agent.agent.status.rawValue,
                    statusSince: statusSince(of: agent, stamps: stamps, now: now),
                    hostName: agent.hostName,
                    isChatMode: source.chatModeAgents.contains(agent.id),
                    progress: progress(of: agent, now: now))
            }
        let unconfirmed = Set(
            enabledHosts.filter { condition(of: $0, in: source) != .confirmed }.map(\.id))
        let listedIDs = Set(current.map(\.id))
        let kept = (previous?.rows ?? []).filter {
            unconfirmed.contains($0.id.hostID) && !listedIDs.contains($0.id)
        }
        return WatchState(
            generatedAt: now,
            hosts: hosts(from: source),
            rows: kept.isEmpty ? current : glanceOrdered(current + kept),
            voiceTranscription: source.voiceTranscription)
    }

    /// `rows` in the glance list's bucket and Host order; stable, so rows
    /// of one Host keep their order.
    private static func glanceOrdered(_ rows: [WatchAgentRow]) -> [WatchAgentRow] {
        rows.enumerated().sorted { lhs, rhs in
            let lhsBucket = AgentStatus(rawValue: lhs.element.status).consoleSortBucket
            let rhsBucket = AgentStatus(rawValue: rhs.element.status).consoleSortBucket
            if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
            if lhs.element.hostName != rhs.element.hostName {
                return lhs.element.hostName < rhs.element.hostName
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The enabled Hosts by name, each confirmed unless
    /// `CarVoiceScript.unverifiedHosts` calls it connecting or unreachable.
    static func hosts(from source: WatchStateSource) -> [WatchHost] {
        source.hosts.filter(\.isEnabled)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { host in
                WatchHost(
                    id: host.id, name: host.displayName,
                    condition: condition(of: host, in: source))
            }
    }

    /// One Host's condition, the same verdict CarPlay's briefing speaks,
    /// except that a Host whose events session the background suspended, or
    /// any Host while the Console is suspended, is connecting: the app
    /// resumes it on its own.
    static func condition(of host: Host, in source: WatchStateSource) -> WatchHostCondition {
        if source.isSuspended || source.statuses[host.id] == .suspended { return .connecting }
        let unverified = CarVoiceScript.unverifiedHosts(
            [host], statuses: source.statuses, awaitingSnapshot: source.awaitingSnapshot)
        switch unverified.first?.condition {
        case .connecting: return .connecting
        case .unreachable: return .unreachable
        case nil: return .confirmed
        }
    }

    /// When `agent` entered its status: the phone's own stamp when it saw
    /// the change, else on tmux the Host's wall-clock `@waycar_seq` and on
    /// herdr-core its `status_ms` (milliseconds since the epoch, pinned by
    /// the contract check) for the status the snapshot reported (never in
    /// the future), else unknown. herdr's counter is no clock.
    static func statusSince(of agent: ConsoleAgent, stamps: WatchStatusStamps, now: Date) -> Date? {
        if let stamped = stamps.since(of: agent) { return stamped }
        switch agent.backend {
        case .herdr, .ultimate, .codex, .opencode:
            return nil
        case .core, .zellij:
            // Zellij's program reports use updated_ms; hook seq is only a counter.
            // The epoch floor rejects hook counters rather than inventing a date.
            guard let milliseconds = agent.agent.statusStateChangeSeq,
                milliseconds >= minimumWallClockMilliseconds
            else { return nil }
            return min(Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000), now)
        case .tmux:
            break
        }
        guard let seq = agent.agent.statusStateChangeSeq,
            seq >= minimumWallClockNanoseconds
        else { return nil }
        let since = Date(timeIntervalSince1970: TimeInterval(seq / 1_000_000) / 1000)
        return min(since, now)
    }

    /// The watch's progress bar for `agent` at `now`, from
    /// `ConsoleAgent.progressDisplay(at:)`. `staleAfter` never depends on
    /// `now`, so an unchanged estimate builds an equal row and the Watch
    /// State is not resent: a fresh estimate goes stale
    /// `AgentSummary.freshness` after the plugin wrote it (the phone's
    /// clamped-age rule, `max(0, now − written) < freshness`, holds exactly
    /// while `now < written + freshness`), a stale one has been stale since
    /// `Date.distantPast`; pending has no steps or phase; nil means no bar.
    static func progress(of agent: ConsoleAgent, now: Date) -> WatchProgress? {
        switch agent.progressDisplay(at: now) {
        case .pending:
            return WatchProgress(done: nil, total: nil, phase: nil, staleAfter: nil)
        case .estimate(let progress, let isStale):
            let staleAfter: Date
            if !isStale, let summary = agent.summary {
                let written = Date(timeIntervalSince1970: TimeInterval(summary.progressWrittenAt) / 1000)
                staleAfter = written.addingTimeInterval(AgentSummary.freshness)
            } else {
                staleAfter = .distantPast
            }
            return WatchProgress(
                done: progress.steps?.done, total: progress.steps?.total,
                phase: progress.steps == nil ? progress.phase?.rawValue : nil,
                staleAfter: staleAfter)
        case nil:
            return nil
        }
    }

    // MARK: Latest

    /// Whether the phone reads `agent`'s last reply from its transcript: a
    /// Chat Mode Agent, or any Agent whose kind the plugin's transcript
    /// reader understands while the Host reports its live agent session.
    /// `ConsoleStore.readChatTranscript` locates the transcript by that
    /// session first; without one only a Chat Marker's cwd and launch
    /// time do, which a plain Agent lacks.
    static func readsTranscript(_ agent: ConsoleAgent, isChatMode: Bool) -> Bool {
        if isChatMode { return true }
        guard let session = agent.agent.agentSession, !session.value.isEmpty,
            let kind = SupportedAgentKind(rawValue: agent.agent.kind)
        else { return false }
        return kind.supportsChatMode
    }

    /// The watch's Latest for `agent` at `now`, given its last reply when
    /// the transcript had one: the reply in full, or for a Working Agent
    /// with a fresh summary that summary first and the reply under
    /// `lastReply`. With no reply, the summary alone. Nothing is capped
    /// but the reply's byte budget.
    static func latest(for agent: ConsoleAgent, reply: String?, now: Date) -> WatchLatest? {
        let summary = summaryLatest(for: agent, now: now)
        guard let reply else { return summary }
        let fitted = fittingBudget(reply)
        if agent.agent.status == .working, let summary, !summary.isStale {
            return WatchLatest(source: .summary, text: summary.text, lastReply: fitted, isStale: false)
        }
        return WatchLatest(source: .reply, text: fitted, lastReply: nil, isStale: false)
    }

    /// The Agent Summary as the watch's Latest text, in full (the plugin
    /// already keeps it short); stale when `summaryLine` says so. Nil while
    /// there is none or the first one is still loading.
    static func summaryLatest(for agent: ConsoleAgent, now: Date) -> WatchLatest? {
        guard case .summary(let text, _, let isStale) = agent.summaryLine(at: now) else {
            return nil
        }
        let clean = cleaned(text)
        guard !clean.isEmpty else { return nil }
        return WatchLatest(source: .summary, text: clean, lastReply: nil, isStale: isStale)
    }

    /// The transcript's last reply with text, cleaned and in full; nil when
    /// it holds none.
    static func lastReply(from transcript: ChatTranscriptSnapshot) -> String? {
        transcript.messages.reversed().lazy
            .filter { $0.role == .assistant }
            .map { cleaned($0.text) }
            .first { !$0.isEmpty }
    }

    /// `text` safe to show, line by line as `HostText.normalizedLine`
    /// cleans Host text: newlines normalized as `TerminalTextSafety` does,
    /// whole terminal escape sequences and control and format characters
    /// (bidi, zero-width) dropped, whitespace runs within a line collapsed.
    /// Line breaks stay, with blank-line runs kept as one paragraph break;
    /// outer whitespace is trimmed.
    static func cleaned(_ text: String) -> String {
        let normalized = TerminalTextSafety.normalizingNewlines(strippingEscapes(text))
        var lines: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = HostText.normalizedLine(String(raw), limit: raw.unicodeScalars.count + 1) ?? ""
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` without whole terminal escape sequences: CSI (`ESC [` or
    /// C1 `0x9B` through its final byte), string sequences (OSC, DCS, SOS,
    /// PM, APC through BEL or `ESC \`), and two-character escapes.
    private static func strippingEscapes(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var kept = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            guard value == 0x1B || value == 0x9B else {
                kept.append(scalars[index])
                index += 1
                continue
            }
            var next = index + 1
            let introducer = value == 0x9B ? 0x5B : (next < scalars.count ? scalars[next].value : 0)
            if value == 0x1B { next += 1 }
            switch introducer {
            case 0x5B:  // CSI: parameters and intermediates, then a final byte.
                while next < scalars.count, !(0x40...0x7E).contains(scalars[next].value) { next += 1 }
                next += 1
            case 0x5D, 0x50, 0x58, 0x5E, 0x5F:  // A string, through BEL or ST.
                while next < scalars.count {
                    let current = scalars[next].value
                    next += 1
                    if current == 0x07 { break }
                    if current == 0x1B, next < scalars.count, scalars[next].value == 0x5C {
                        next += 1
                        break
                    }
                }
            default:  // Intermediates, then one final character.
                next -= 1
                while next < scalars.count, (0x20...0x2F).contains(scalars[next].value) { next += 1 }
                next += 1
            }
            index = min(next, scalars.count)
        }
        return String(kept)
    }

    /// The bytes `character` takes in `WatchWireCodec`'s JSON: its UTF-8,
    /// plus one for each scalar `JSONEncoder` writes as a two-byte escape.
    static func encodedSize(_ character: Character) -> Int {
        character.utf8.count
            + character.unicodeScalars.reduce(0) { count, scalar in
                switch scalar.value {
                case 0x22, 0x5C, 0x2F, 0x0A, 0x0D, 0x09, 0x08, 0x0C: count + 1
                default: count
                }
            }
    }

    /// `text` within `latestByteBudget` once JSON-encoded: unchanged when it
    /// fits, else its end after the plain line `earlierTextNotice`. The end
    /// starts at a whole word when the cut word ends within
    /// `wordSkipLimit` characters, else at a character. No ellipsis.
    static func fittingBudget(_ text: String) -> String {
        guard text.reduce(0, { $0 + encodedSize($1) }) > latestByteBudget else { return text }
        let header = earlierTextNotice + "\n\n"
        let room = latestByteBudget - header.reduce(0) { $0 + encodedSize($1) }
        // Walk back whole characters until the tail fills the room.
        var start = text.endIndex
        var bytes = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            let size = encodedSize(text[previous])
            guard bytes + size <= room else { break }
            bytes += size
            start = previous
        }
        // Start at a word: skip the partial one the cut landed in, when short.
        if start > text.startIndex, !text[text.index(before: start)].isWhitespace,
            let space = text[start...].prefix(wordSkipLimit).firstIndex(where: \.isWhitespace)
        {
            start = space
        }
        let tail = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        return header + tail
    }

    // MARK: Blocked prompt

    /// What the watch may show and do for a Blocked prompt read on the
    /// phone, by `BlockedPromptClassifier.carApproval(for:)` (CarPlay
    /// parity): the command only for allow and hold.
    static func blockedPrompt(
        _ snapshot: BlockedPromptSnapshot, promptID: UUID
    ) -> WatchBlockedPrompt {
        let command: String?
        if case .permission(let text, _) = snapshot.prompt { command = text } else { command = nil }
        switch snapshot.approval {
        case .allow:
            return WatchBlockedPrompt(
                promptID: promptID, approval: .allow, command: command, holdReason: nil)
        case .hold(let reason):
            return WatchBlockedPrompt(
                promptID: promptID, approval: .hold, command: command,
                holdReason: holdReason(reason))
        case .readOnly:
            return WatchBlockedPrompt(
                promptID: promptID, approval: .readOnly, command: nil, holdReason: nil)
        }
    }

    /// Why Allow is not offered on the watch.
    static func holdReason(_ reason: HoldReason) -> String {
        switch reason {
        case .risky(let why): "This one looks risky: \(why). Allow it on iPhone."
        case .notLossless: "This one can't be shown in full. Allow it on iPhone."
        }
    }
}

// MARK: Identity

extension WatchAgentID {
    /// The watch's address for a Console Agent.
    init(_ id: ConsoleAgent.ID) {
        self.init(hostID: id.hostID, paneID: id.paneID)
    }

    /// The Console's id for this Agent.
    var consoleID: ConsoleAgent.ID {
        ConsoleAgent.ID(hostID: hostID, paneID: paneID)
    }
}
