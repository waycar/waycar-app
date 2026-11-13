#if DEBUG
import Foundation

// MARK: - Demo store

extension WatchStore {
    /// The launch argument that turns demo mode on: `-WaycarWatchDemo YES`.
    static let demoLaunchKey = "WaycarWatchDemo"
    /// The launch argument that picks a `WatchDemoScenario`, e.g.
    /// `-WaycarWatchDemoScenario hold`; `standard` when absent.
    static let demoScenarioKey = "WaycarWatchDemoScenario"

    /// Whether the app was launched with `-WaycarWatchDemo YES`.
    static var isDemoLaunch: Bool {
        UserDefaults.standard.bool(forKey: demoLaunchKey)
    }

    /// The design's sample data (§4) answered locally, so every screen can
    /// be checked without a phone. DEBUG only.
    static func demo() -> WatchStore {
        let defaults = UserDefaults.standard
        let name = defaults.string(forKey: demoScenarioKey) ?? ""
        let store = demo(scenario: WatchDemoScenario(rawValue: name) ?? .standard)
        store.route = demoRoute(defaults.string(forKey: demoRouteKey))
        if defaults.bool(forKey: demoSentKey) {
            store.seedDemoVoice(
                to: WatchDemoData.siteCodex, text: WatchDemoData.dictated,
                sentAt: WatchDemoData.sentAt)
        } else if defaults.bool(forKey: demoSendingKey) {
            store.seedDemoVoice(to: WatchDemoData.siteCodex, text: WatchDemoData.dictated, sentAt: nil)
        }
        return store
    }

    /// `-WaycarWatchDemoRoute list|agent:<id>|blocked:<id>|recorder:<id>`,
    /// where `<id>` names a `WatchDemoData` Agent, e.g. `agent:siteCodex`.
    static let demoRouteKey = "WaycarWatchDemoRoute"
    /// `-WaycarWatchDemoSent YES`: `site · codex` shows a delivered voice
    /// message (W5).
    static let demoSentKey = "WaycarWatchDemoSent"
    /// `-WaycarWatchDemoSending YES`: the same message still transcribing
    /// (W5a).
    static let demoSendingKey = "WaycarWatchDemoSending"
    /// `-WaycarWatchDemoLongReply YES`: `site · codex` answers with a reply
    /// near the phone's byte budget, cut after "Earlier text is on your
    /// iPhone.", to check W2 scrolling a long reply.
    nonisolated static let demoLongReplyKey = "WaycarWatchDemoLongReply"

    /// The launch route for `value`; the list for anything unrecognised.
    static func demoRoute(_ value: String?) -> [Route] {
        guard let value else { return [] }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = WatchDemoData.agents[parts[1]] else { return [] }
        switch parts[0] {
        case "agent": return [.agent(id)]
        case "blocked": return [.blocked(id)]
        case "recorder": return [.agent(id), .recorder(id)]
        default: return []
        }
    }

    /// The sample data under one scenario.
    static func demo(scenario: WatchDemoScenario) -> WatchStore {
        WatchStore(link: WatchDemoLink(scenario: scenario))
    }
}

// MARK: - Scenarios

/// Which screen states demo mode reaches. `standard` covers W1, W2 (full
/// replies, a Working summary over its last reply, stale with Checking…), W3 Allow, W4, W5a,
/// and W5; the others each force one remaining state.
enum WatchDemoScenario: String, CaseIterable, Sendable {
    /// Every happy path.
    case standard
    /// W6: no Watch State has arrived yet.
    case firstRun
    /// W6: the iPhone reports no Hosts.
    case empty
    /// W1 banner "iPhone not reachable · 3m ago"; every action disabled.
    case stale
    /// W1 banners "studio is still connecting" and "Can't reach linuxhost".
    case connecting
    /// W3 with a risky command: Deny only.
    case hold
    /// W3 "Answer this one on iPhone."
    case readOnly
    /// W3 "Prompt changed. Reload." on the first answer; the reload works.
    case promptChanged
    /// W5 "Not sent — iPhone didn't answer" on the first send; Try again
    /// works.
    case notSent
    /// W5 "Couldn't confirm it was delivered".
    case unknown
    /// W5 "Kept as draft on iPhone — answer the prompt first".
    case keptAsDraft
    /// W5a then "Couldn't make out any words. Nothing sent." for voice.
    case noWords
    /// The iPhone cannot transcribe (below iOS 26): the mic opens system
    /// text input.
    case noVoice
}

// MARK: - Sample data

/// The design's sample Hosts, Agents, and texts (§4, make_mockups.py).
enum WatchDemoData {
    /// The `studio` Host.
    static let studio = WatchHost(id: id(1), name: "studio", condition: .confirmed)
    /// The `linuxhost` Host.
    static let linuxhost = WatchHost(id: id(2), name: "linuxhost", condition: .confirmed)

    /// `waycar · claude`, Blocked at 3/6 (frozen).
    static let waycarClaude = WatchAgentID(hostID: studio.id, paneID: "w1:t1:p1")
    /// `site · codex`, Done.
    static let siteCodex = WatchAgentID(hostID: studio.id, paneID: "w2:t1:p1")
    /// `waycar · omp`, Working at 6/7, Chat Mode.
    static let waycarOmp = WatchAgentID(hostID: studio.id, paneID: "w1:t2:p1")
    /// `documentation-site-redux · gemini-deep-research-cli`, Working with
    /// no estimate yet (dotted bar): the longest title (24-character
    /// workspace and name), so wrapping shows in W1, W2 and W4.
    static let docsGemini = WatchAgentID(hostID: studio.id, paneID: "w3:t1:p1")
    /// `relay · pi`, Working, Exploring.
    static let relayPi = WatchAgentID(hostID: linuxhost.id, paneID: "w1:t1:p1")
    /// `plugin · claude`, Idle.
    static let pluginClaude = WatchAgentID(hostID: linuxhost.id, paneID: "w2:t1:p1")
    /// The sample Agents by name, for `-WaycarWatchDemoRoute`.
    static let agents: [String: WatchAgentID] = [
        "waycarClaude": waycarClaude, "siteCodex": siteCodex, "waycarOmp": waycarOmp,
        "docsGemini": docsGemini, "relayPi": relayPi, "pluginClaude": pluginClaude,
    ]
    /// How long a fresh estimate stays fresh: the iPhone's
    /// `AgentSummary.freshness`.
    static let estimateFreshness: TimeInterval = 3 * 60
    /// When the seeded W5 message was sent: 10:10 today, local time.
    static var sentAt: Date {
        Calendar.current.date(bySettingHour: 10, minute: 10, second: 0, of: Date()) ?? Date()
    }

    /// The Blocked command (lossless, W3).
    static let command = "make test-app TEST_FLAGS='-only-testing:WaycarTests/WatchListModelTests'"
    /// A command the CarPlay rules hold (Deny only).
    static let riskyCommand = "git push --force origin main"
    /// The hold reason for `riskyCommand`.
    static let riskyReason = "it force-pushes"
    /// What the iPhone "transcribes" from any recording (W5).
    static let dictated = "Now run the tests and commit if they pass."

    /// The Watch State at `now`, with the scenario's Host conditions. In
    /// `stale` every estimate is out of date too.
    static func state(at now: Date, scenario: WatchDemoScenario) -> WatchState? {
        switch scenario {
        case .firstRun:
            return nil
        case .empty:
            return WatchState(generatedAt: now, hosts: [], rows: [], voiceTranscription: true)
        case .stale:
            return WatchState(
                generatedAt: now.addingTimeInterval(-180), hosts: [studio, linuxhost],
                rows: rows(at: now, estimatesStaleAfter: now), voiceTranscription: true)
        case .connecting:
            let hosts = [
                WatchHost(id: studio.id, name: studio.name, condition: .connecting),
                WatchHost(id: linuxhost.id, name: linuxhost.name, condition: .unreachable),
            ]
            return WatchState(generatedAt: now, hosts: hosts, rows: rows(at: now), voiceTranscription: true)
        case .noVoice:
            return WatchState(
                generatedAt: now, hosts: [studio, linuxhost], rows: rows(at: now),
                voiceTranscription: false)
        case .standard, .hold, .readOnly, .promptChanged, .notSent, .unknown, .keptAsDraft, .noWords:
            return WatchState(
                generatedAt: now, hosts: [studio, linuxhost], rows: rows(at: now),
                voiceTranscription: true)
        }
    }

    /// The six sample rows in CarPlay order, ages relative to `now`, with
    /// every Agent Progress state: Blocked 3/6, Working 6/7, Working with
    /// no estimate yet, Working Exploring. Estimates go stale at
    /// `estimatesStaleAfter`, by default one freshness window after `now`.
    static func rows(at now: Date, estimatesStaleAfter: Date? = nil) -> [WatchAgentRow] {
        let staleAfter = estimatesStaleAfter ?? now.addingTimeInterval(estimateFreshness)
        let pending = WatchProgress(done: nil, total: nil, phase: nil, staleAfter: nil)
        return [
            row(
                waycarClaude, "waycar · claude", "blocked", 60, studio, now: now,
                progress: WatchProgress(done: 3, total: 6, phase: nil, staleAfter: staleAfter)),
            row(siteCodex, "site · codex", "done", 4 * 60, studio, now: now),
            row(
                waycarOmp, "waycar · omp", "working", 12 * 60, studio, now: now, chat: true,
                progress: WatchProgress(done: 6, total: 7, phase: "verifying", staleAfter: staleAfter)),
            row(
                docsGemini, "documentation-site-redux · gemini-deep-research-cli", "working", 20, studio, now: now, progress: pending),
            row(
                relayPi, "relay · pi", "working", 3 * 60, linuxhost, now: now,
                progress: WatchProgress(done: nil, total: nil, phase: "exploring", staleAfter: staleAfter)),
            row(pluginClaude, "plugin · claude", "idle", 60 * 60, linuxhost, now: now),
        ]
    }

    /// An Agent's progress once it enters `status` at `now`, the way the
    /// iPhone builds it: Working keeps the estimate (fresh again) or waits
    /// for one, Blocked freezes it, anything else drops it.
    static func progress(_ progress: WatchProgress?, entering status: String, at now: Date) -> WatchProgress? {
        switch status {
        case "working":
            guard let progress, !progress.isPending else {
                return WatchProgress(done: nil, total: nil, phase: nil, staleAfter: nil)
            }
            return WatchProgress(
                done: progress.done, total: progress.total, phase: progress.phase,
                staleAfter: now.addingTimeInterval(estimateFreshness))
        case "blocked":
            return progress
        default:
            return nil
        }
    }

    /// The Latest for an Agent; `relay · pi` is stale until `fresh`. Long,
    /// multi-paragraph replies, so W2's Crown scrolling shows.
    static func latest(for id: WatchAgentID, fresh: Bool) -> WatchLatest? {
        switch id {
        case siteCodex:
            let text = UserDefaults.standard.bool(forKey: WatchStore.demoLongReplyKey) ? longReply : siteReply
            return WatchLatest(source: .reply, text: text, lastReply: nil, isStale: false)
        case waycarOmp:
            return WatchLatest(
                source: .summary, text: "Verifying the watch store split on the simulator.",
                lastReply: ompReply, isStale: false)
        case relayPi:
            return fresh
                ? WatchLatest(
                    source: .summary, text: "Rebuilt the relay index; all five shards verified.",
                    lastReply: nil, isStale: false)
                : WatchLatest(
                    source: .summary, text: "Rebuilding the relay index after the schema change.",
                    lastReply: nil, isStale: true)
        case pluginClaude:
            return WatchLatest(source: .reply, text: pluginReply, lastReply: nil, isStale: false)
        case waycarClaude:
            return WatchLatest(
                source: .summary, text: "Wants to run the watch list tests.", lastReply: nil,
                isStale: false)
        case docsGemini:
            return WatchLatest(
                source: .summary, text: "Reading the docs site layout before writing the page.",
                lastReply: nil, isStale: false)
        default:
            return nil
        }
    }

    /// `site · codex`'s last reply.
    static let siteReply = """
        I added the Apple Watch page to the help docs and linked it from the Getting Started \
        list and the Agents page.

        Two links were broken: the Hosts page pointed at the old pairing anchor, and the \
        Chat Mode page linked a heading that was renamed last week. Both now resolve, and \
        the link checker passes on every page.

        I also tightened the intro so it fits the screenshot above it. Nothing else changed. \
        Want me to open a pull request, or keep going with the CarPlay page next?
        """

    /// A reply near the phone's 48 KB budget, cut as the phone cuts it:
    /// "Earlier text is on your iPhone." first, then many paragraphs.
    static let longReply: String = {
        let notice = "Earlier text is on your iPhone."
        var paragraphs: [String] = []
        var bytes = notice.utf8.count
        var step = 1
        while bytes < 46 * 1024 {
            let paragraph = """
                Step \(step): checked the next batch of help pages for broken links, fixed the \
                anchors that moved, and reran the link checker on that section. Everything in \
                this batch now resolves, and the screenshots still match their captions.
                """
            paragraphs.append(paragraph)
            bytes += paragraph.utf8.count + 2
            step += 1
        }
        return ([notice] + paragraphs).joined(separator: "\n\n")
    }()

    /// `waycar · omp`'s last reply, under its Working summary.
    static let ompReply = """
        I split the watch store from the session client. The store now owns only what the \
        screens show; the client owns the phone link and its retries.

        The simulator build passes. Next I will wire the recorder to the outbox, then add \
        demo data so every screen can be checked without a phone.
        """

    /// `plugin · claude`'s last reply.
    static let pluginReply = """
        The plugin manifest is ready for your review. I bumped the version, listed the new \
        transcript reader under its commands, and dropped the permission it no longer needs.

        The install test passes on both herdr and tmux. One thing to check: the summary \
        interval is still 30 seconds. Say the word if you want it longer.
        """

    /// The Blocked prompt the scenario shows.
    static func prompt(id promptID: UUID, scenario: WatchDemoScenario) -> WatchBlockedPrompt {
        switch scenario {
        case .hold:
            return WatchBlockedPrompt(
                promptID: promptID, approval: .hold, command: riskyCommand, holdReason: riskyReason)
        case .readOnly:
            return WatchBlockedPrompt(promptID: promptID, approval: .readOnly, command: nil, holdReason: nil)
        case .standard, .firstRun, .empty, .stale, .connecting, .promptChanged, .notSent, .unknown,
            .keptAsDraft, .noWords, .noVoice:
            return WatchBlockedPrompt(promptID: promptID, approval: .allow, command: command, holdReason: nil)
        }
    }

    /// One row whose status began `age` seconds before `now`.
    private static func row(
        _ id: WatchAgentID, _ title: String, _ status: String, _ age: TimeInterval,
        _ host: WatchHost, now: Date, chat: Bool = false, progress: WatchProgress? = nil
    ) -> WatchAgentRow {
        WatchAgentRow(
            id: id, title: title, status: status, statusSince: now.addingTimeInterval(-age),
            hostName: host.name, isChatMode: chat, progress: progress)
    }

    /// A fixed sample id ending in `n`.
    private static func id(_ n: UInt8) -> UUID {
        UUID(uuid: (0x57, 0x41, 0x59, 0x43, 0x41, 0x52, 0x40, 0x00, 0x80, 0, 0, 0, 0, 0, 0, n))
    }
}

// MARK: - Demo link

/// Answers the store's requests locally, like a phone would: short delays
/// so loading states show, an acknowledgement at once and the delivery
/// outcome a second later, and status changes after Allow and Sent.
@MainActor
final class WatchDemoLink: WatchPhoneLink {
    /// The forced states.
    let scenario: WatchDemoScenario
    /// Unreachable only in `stale`.
    let isReachable: Bool
    /// The store's inbound handler.
    private var receive: (@MainActor (WatchInbound) -> Void)?
    /// The current sample state.
    private var state: WatchState?
    /// The prompt id the Blocked prompt is kept under.
    private var promptID = UUID()
    /// Agents whose stale Latest was already served once.
    private var servedStale: Set<WatchAgentID> = []
    /// Messages that already failed once (`notSent`).
    private var failedOnce: Set<UUID> = []
    /// Whether the first answer already reported a changed prompt.
    private var changedOnce = false

    /// A link answering under `scenario`.
    init(scenario: WatchDemoScenario) {
        self.scenario = scenario
        isReachable = scenario != .stale
        state = WatchDemoData.state(at: Date(), scenario: scenario)
    }

    /// Publishes the sample state and reachability at once.
    func activate(receiving receive: @escaping @MainActor (WatchInbound) -> Void) {
        self.receive = receive
        if let state { receive(.state(state)) }
        receive(.reachability(isReachable))
    }

    /// Answers one request after a short delay.
    func send(_ request: WatchRequest) async throws -> WatchReply {
        guard isReachable else { throw WatchLinkError.unreachable }
        switch request {
        case .refresh:
            try await pause(.milliseconds(300))
            guard let state else { return .failure("Open Waycar on your iPhone to add a Host.") }
            let fresh = WatchState(
                generatedAt: Date(), hosts: state.hosts, rows: state.rows,
                voiceTranscription: state.voiceTranscription)
            self.state = fresh
            return .state(fresh)
        case .latest(let id):
            try await pause(.milliseconds(500))
            let fresh = servedStale.contains(id)
            servedStale.insert(id)
            return .latest(WatchDemoData.latest(for: id, fresh: fresh))
        case .blockedPrompt(let id):
            try await pause(.milliseconds(1200))
            guard row(id)?.status == "blocked" else { return .blockedPrompt(nil) }
            promptID = UUID()
            return .blockedPrompt(WatchDemoData.prompt(id: promptID, scenario: scenario))
        case .answer(let id, let shownID, let answer):
            try await pause(.milliseconds(600))
            return .answerResult(outcome(of: answer, for: id, promptID: shownID))
        case .send(let messageID, let id, let text):
            try await pause(.milliseconds(300))
            if scenario == .notSent, failedOnce.insert(messageID).inserted {
                throw WatchLinkError.noAnswer
            }
            deliverLater(messageID, to: id, delivery: delivery(text: text, isVoice: false))
            return .received
        case .voice(let messageID, let id):
            try await pause(.milliseconds(300))
            if scenario == .notSent, failedOnce.insert(messageID).inserted {
                throw WatchLinkError.noAnswer
            }
            deliverLater(messageID, to: id, delivery: delivery(text: WatchDemoData.dictated, isVoice: true))
            return .received
        }
    }

    /// The demo has no phone to send to; the messenger deletes the file
    /// once the message settles.
    func transferVoice(fileAt url: URL, file: WatchVoiceFile, attempt: UUID) throws {}

    /// Nothing is ever queued.
    func cancelVoiceTransfer(_ messageID: UUID) {}

    // MARK: Helpers

    /// The sample row for an Agent.
    private func row(_ id: WatchAgentID) -> WatchAgentRow? {
        state?.rows.first { $0.id == id }
    }

    /// What an answer does here, by the same rules the phone applies.
    private func outcome(
        of answer: WatchAnswer, for id: WatchAgentID, promptID shownID: UUID
    ) -> WatchAnswerOutcome {
        if scenario == .promptChanged, !changedOnce {
            changedOnce = true
            return .promptChanged
        }
        guard shownID == promptID, row(id)?.status == "blocked" else { return .promptChanged }
        let prompt = WatchDemoData.prompt(id: promptID, scenario: scenario)
        switch (answer, prompt.approval) {
        case (.allow, .allow), (.deny, .allow), (.deny, .hold):
            setStatus(answer == .allow ? "working" : "idle", for: id, after: .seconds(2))
            return .sent
        case (.allow, .hold), (_, .readOnly):
            return .refused
        }
    }

    /// The outcome the scenario reports for a message.
    private func delivery(text: String, isVoice: Bool) -> WatchDelivery {
        switch scenario {
        case .unknown: .unknown
        case .keptAsDraft: .keptAsDraft(reason: .blocked)
        case .noWords where isVoice: .noWords
        default: .sent(text: text)
        }
    }

    /// Reports the outcome a second after the acknowledgement; a sent
    /// message turns the Agent Working.
    private func deliverLater(_ messageID: UUID, to id: WatchAgentID, delivery: WatchDelivery) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.receive?(.event(.delivery(messageID: messageID, id, delivery)))
            if case .sent = delivery { self.setStatus("working", for: id, after: .seconds(1)) }
        }
    }

    /// Publishes a new state with the Agent in `status` since now, its
    /// progress carried over as the iPhone would.
    private func setStatus(_ status: String, for id: WatchAgentID, after delay: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, let current = self.state else { return }
            let now = Date()
            let rows = current.rows.map { row in
                row.id == id
                    ? WatchAgentRow(
                        id: row.id, title: row.title, status: status, statusSince: now,
                        hostName: row.hostName, isChatMode: row.isChatMode,
                        progress: WatchDemoData.progress(row.progress, entering: status, at: now))
                    : row
            }
            let next = WatchState(
                generatedAt: now, hosts: current.hosts, rows: rows,
                voiceTranscription: current.voiceTranscription)
            self.state = next
            self.receive?(.state(next))
        }
    }

    /// A phone-like delay.
    private func pause(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
#endif
