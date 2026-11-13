import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Watch State builder")
struct WatchStateBuilderTests {
    private let studio = Host.fixture(name: "studio")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func consoleAgent(
        _ paneID: String, _ status: AgentStatus, on host: Host? = nil, kind: String = "claude",
        workspace: String? = "site", name: String? = nil, seq: Int? = nil,
        summary: (text: String, minutesAgo: Int, status: AgentStatus)? = nil,
        backend: HostBackend = .herdr
    ) -> ConsoleAgent {
        let host = host ?? studio
        let written = summary.map { summary in
            AgentSummary(
                paneID: paneID, status: summary.status, text: summary.text,
                timestamp: Int64((now.timeIntervalSince1970 - Double(summary.minutesAgo * 60)) * 1000))
        }
        return ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(
                .fixture(paneID: paneID, status: status, kind: kind, name: name, stateChangeSeq: seq)),
            workspaceLabel: workspace, repositoryCheckout: nil, summary: written, backend: backend)
    }

    private func source(
        _ agents: [ConsoleAgent], hosts: [Host]? = nil,
        statuses: [Host.ID: EventsSessionStatus]? = nil, awaiting: Set<Host.ID> = [],
        chatMode: Set<ConsoleAgent.ID> = [], voice: Bool = true
    ) -> WatchStateSource {
        let hosts = hosts ?? [studio]
        return WatchStateSource(
            agents: agents, hosts: hosts,
            statuses: statuses ?? Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, .connected) }),
            awaitingSnapshot: awaiting, chatModeAgents: chatMode, voiceTranscription: voice)
    }

    /// An Agent whose summary carries `progress`, written in `written`
    /// status `minutesAgo` minutes before `now`.
    private func progressAgent(
        _ paneID: String, _ status: AgentStatus, progress: AgentProgress?,
        minutesAgo: Int = 1, written: AgentStatus? = nil, reportsProgress: Bool = true
    ) -> ConsoleAgent {
        let stamp = Int64((now.timeIntervalSince1970 - Double(minutesAgo * 60)) * 1000)
        let summary = AgentSummary(
            paneID: paneID, status: written ?? status, text: "Working on it.", timestamp: stamp - 60_000,
            progress: progress, progressTimestamp: progress == nil ? nil : stamp,
            declaresProgress: reportsProgress)
        return ConsoleAgent(
            hostID: studio.id, hostName: studio.displayName,
            agent: Agent(.fixture(paneID: paneID, status: status, kind: "claude")),
            workspaceLabel: "site", repositoryCheckout: nil, summary: summary,
            hostReportsProgress: reportsProgress, backend: .herdr)
    }

    // MARK: Progress

    @Test func freshEstimateGoesStaleFreshnessAfterItWasWritten() throws {
        let steps = try #require(AgentProgress(steps: .init(done: 3, total: 7), phase: .implementing))
        let agent = progressAgent("a", .working, progress: steps, minutesAgo: 1)
        let expected = WatchProgress(
            done: 3, total: 7, phase: nil,
            staleAfter: now.addingTimeInterval(AgentSummary.freshness - 60))
        #expect(WatchStateBuilder.progress(of: agent, now: now) == expected)
        #expect(WatchStateBuilder.progress(of: agent, now: now.addingTimeInterval(90)) == expected)

        let phase = try #require(AgentProgress(steps: nil, phase: .verifying))
        let phased = progressAgent("b", .working, progress: phase, minutesAgo: 2)
        #expect(
            WatchStateBuilder.progress(of: phased, now: now)
                == WatchProgress(
                    done: nil, total: nil, phase: "verifying",
                    staleAfter: now.addingTimeInterval(AgentSummary.freshness - 120)))
    }

    @Test func staleEstimateIsStaleSinceDistantPast() throws {
        let steps = try #require(AgentProgress(steps: .init(done: 2, total: 5), phase: nil))
        let otherStatus = progressAgent("a", .working, progress: steps, written: .blocked)
        #expect(
            WatchStateBuilder.progress(of: otherStatus, now: now)
                == WatchProgress(done: 2, total: 5, phase: nil, staleAfter: .distantPast))
        let old = progressAgent("b", .working, progress: steps, minutesAgo: 10)
        #expect(WatchStateBuilder.progress(of: old, now: now)?.staleAfter == .distantPast)

        let agents = [otherStatus, old]
        let first = WatchStateBuilder.state(from: source(agents), stamps: WatchStatusStamps(), now: now)
        let later = WatchStateBuilder.state(
            from: source(agents), stamps: WatchStatusStamps(), now: now.addingTimeInterval(60))
        #expect(first.rows == later.rows)
    }

    @Test func workingWithoutEstimateIsPending() {
        let agent = progressAgent("a", .working, progress: nil)
        let progress = WatchStateBuilder.progress(of: agent, now: now)
        #expect(progress == WatchProgress(done: nil, total: nil, phase: nil, staleAfter: nil))
        #expect(progress?.isPending == true)
    }

    @Test func blockedKeepsItsEstimate() throws {
        let steps = try #require(AgentProgress(steps: .init(done: 3, total: 6), phase: nil))
        let agent = progressAgent("a", .blocked, progress: steps)
        #expect(WatchStateBuilder.progress(of: agent, now: now)?.done == 3)
        #expect(WatchStateBuilder.progress(of: agent, now: now)?.total == 6)
        #expect(WatchStateBuilder.progress(of: progressAgent("b", .blocked, progress: nil), now: now) == nil)
    }

    @Test func doneIdleAndOldPluginsShowNoBar() throws {
        let steps = try #require(AgentProgress(steps: .init(done: 7, total: 7), phase: nil))
        #expect(WatchStateBuilder.progress(of: progressAgent("a", .done, progress: steps), now: now) == nil)
        #expect(WatchStateBuilder.progress(of: progressAgent("b", .idle, progress: steps), now: now) == nil)
        let oldPlugin = progressAgent("c", .working, progress: nil, reportsProgress: false)
        #expect(WatchStateBuilder.progress(of: oldPlugin, now: now) == nil)
    }

    @Test func rowsCarryProgress() throws {
        let steps = try #require(AgentProgress(steps: .init(done: 1, total: 4), phase: nil))
        let state = WatchStateBuilder.state(
            from: source([progressAgent("a", .working, progress: steps), consoleAgent("b", .idle)]),
            stamps: WatchStatusStamps(), now: now)
        #expect(state.rows.first { $0.id.paneID == "a" }?.progress?.done == 1)
        #expect(state.rows.first { $0.id.paneID == "b" }?.progress == nil)
    }

    // MARK: Rows

    @Test func rowsFollowTheGlanceListWithoutShellsOrDisabledHosts() {
        var disabled = Host.fixture(name: "off")
        disabled.isEnabled = false
        let state = WatchStateBuilder.state(
            from: source(
                [
                    consoleAgent("idle", .idle),
                    consoleAgent("shell", .blocked, kind: Agent.shellKind),
                    consoleAgent("done", .done),
                    consoleAgent("gone", .blocked, on: disabled),
                    consoleAgent("blocked", .blocked),
                ], hosts: [studio, disabled]),
            stamps: WatchStatusStamps(), now: now)
        #expect(state.rows.map(\.id.paneID) == ["blocked", "done", "idle"])
        #expect(state.hosts.map(\.name) == ["studio"])
        #expect(state.counts == WatchCounts(blocked: 1, done: 1, working: 0, idle: 1))
        #expect(state.generatedAt == now)
    }

    @Test func rowsCarryTitleRawStatusHostAndChatMode() throws {
        let chat = consoleAgent("chat", .working, kind: "codex", workspace: "site", name: "codex")
        let state = WatchStateBuilder.state(
            from: source([chat], chatMode: [chat.id], voice: false), stamps: WatchStatusStamps(),
            now: now)
        let row = try #require(state.rows.first)
        #expect(row.id == WatchAgentID(hostID: studio.id, paneID: "chat"))
        #expect(row.title == "site · codex")
        #expect(row.status == "working")
        #expect(row.hostName == "studio")
        #expect(row.isChatMode)
        #expect(!state.voiceTranscription)
    }

    // MARK: Hosts

    @Test func hostConditionsFollowTheCarPlayVerdict() {
        let ready = Host.fixture(name: "ready")
        let loading = Host.fixture(name: "loading")
        let dialing = Host.fixture(name: "dialing")
        let down = Host.fixture(name: "down")
        let paused = Host.fixture(name: "paused")
        let state = WatchStateBuilder.state(
            from: source(
                [], hosts: [ready, loading, dialing, down, paused],
                statuses: [
                    ready.id: .connected, loading.id: .connected, dialing.id: .connecting, down.id: .ended,
                    paused.id: .suspended,
                ],
                awaiting: [loading.id]),
            stamps: WatchStatusStamps(), now: now)
        #expect(state.hosts.map(\.name) == ["dialing", "down", "loading", "paused", "ready"])
        #expect(state.hosts.map(\.condition) == [.connecting, .unreachable, .connecting, .connecting, .confirmed])
        #expect(state.showsHostNames)
    }

    // MARK: Rows across reconnects

    /// The state the watch last got: studio with a Blocked and a Working
    /// Agent.
    private func lastState() -> WatchState {
        WatchStateBuilder.state(
            from: source([consoleAgent("ask", .blocked), consoleAgent("build", .working)]),
            stamps: WatchStatusStamps(), now: now)
    }

    @Test func aHostResumingAwaitingItsSnapshotKeepsItsRowsAndConnects() {
        let previous = lastState()
        let state = WatchStateBuilder.state(
            from: source([], awaiting: [studio.id]), stamps: WatchStatusStamps(), previous: previous,
            now: now.addingTimeInterval(60))
        #expect(state.rows == previous.rows)
        #expect(state.rows.map(\.status) == ["blocked", "working"])
        #expect(state.hosts.map(\.condition) == [.connecting])
    }

    @Test func aSuspendedConsoleKeepsEveryRowAndConnects() {
        let previous = lastState()
        var suspended = source([])
        suspended.isSuspended = true
        let state = WatchStateBuilder.state(
            from: suspended, stamps: WatchStatusStamps(), previous: previous, now: now)
        #expect(state.rows == previous.rows)
        #expect(state.hosts.map(\.condition) == [.connecting])
    }

    @Test func aConfirmedSnapshotWithoutAnAgentDropsItsRow() {
        let state = WatchStateBuilder.state(
            from: source([consoleAgent("build", .working)]), stamps: WatchStatusStamps(),
            previous: lastState(), now: now)
        #expect(state.rows.map(\.id.paneID) == ["build"])
        #expect(state.hosts.map(\.condition) == [.confirmed])
    }

    @Test func aDisabledOrRemovedHostDropsItsRows() {
        var disabled = studio
        disabled.isEnabled = false
        let off = WatchStateBuilder.state(
            from: source([], hosts: [disabled], awaiting: [studio.id]), stamps: WatchStatusStamps(),
            previous: lastState(), now: now)
        #expect(off.rows.isEmpty)
        #expect(off.hosts.isEmpty)
        let removed = WatchStateBuilder.state(
            from: source([], hosts: []), stamps: WatchStatusStamps(), previous: lastState(), now: now)
        #expect(removed.rows.isEmpty)
    }

    // MARK: Status since

    @Test func statusSinceIsUnknownOnFirstSightThenStampedOnChange() {
        var stamps = WatchStatusStamps()
        let working = consoleAgent("a", .working)
        stamps.observe([working], at: now)
        #expect(WatchStateBuilder.statusSince(of: working, stamps: stamps, now: now) == nil)

        let later = now.addingTimeInterval(60)
        stamps.observe([working], at: later)
        #expect(WatchStateBuilder.statusSince(of: working, stamps: stamps, now: later) == nil)

        let done = consoleAgent("a", .done)
        let changedAt = now.addingTimeInterval(120)
        stamps.observe([done], at: changedAt)
        let stillLater = now.addingTimeInterval(300)
        stamps.observe([done], at: stillLater)
        #expect(WatchStateBuilder.statusSince(of: done, stamps: stamps, now: stillLater) == changedAt)
        let state = WatchStateBuilder.state(from: source([done]), stamps: stamps, now: stillLater)
        #expect(state.rows.first?.statusSince == changedAt)
    }

    @Test func anAgentThatLeavesAndReturnsIsUnknownAgain() {
        var stamps = WatchStatusStamps()
        stamps.observe([consoleAgent("a", .working)], at: now)
        stamps.observe([consoleAgent("a", .done)], at: now.addingTimeInterval(10))
        stamps.observe([], at: now.addingTimeInterval(20))
        let back = consoleAgent("a", .idle)
        stamps.observe([back], at: now.addingTimeInterval(30))
        #expect(WatchStateBuilder.statusSince(of: back, stamps: stamps, now: now) == nil)
    }

    @Test func tmuxUsesItsWallClockSequenceOnFirstSight() {
        let changed = now.addingTimeInterval(-240)
        let seq = Int(changed.timeIntervalSince1970) * 1_000_000_000
        let tmux = consoleAgent("tmux:%1", .done, seq: seq, backend: .tmux)
        #expect(WatchStateBuilder.statusSince(of: tmux, stamps: WatchStatusStamps(), now: now) == changed)
        // herdr's counter is not a time.
        let herdr = consoleAgent("p", .done, seq: seq)
        #expect(WatchStateBuilder.statusSince(of: herdr, stamps: WatchStatusStamps(), now: now) == nil)
        // A Host clock ahead of the phone is clamped to now.
        let ahead = consoleAgent(
            "tmux:%2", .done, seq: Int(now.timeIntervalSince1970 + 600) * 1_000_000_000, backend: .tmux)
        #expect(WatchStateBuilder.statusSince(of: ahead, stamps: WatchStatusStamps(), now: now) == now)
    }

    @Test func herdrCoreUsesItsMillisecondClockOnFirstSight() {
        let changed = now.addingTimeInterval(-90)
        let milliseconds = Int(changed.timeIntervalSince1970) * 1_000
        let core = consoleAgent("hc:t1", .done, seq: milliseconds, backend: .core)
        #expect(WatchStateBuilder.statusSince(of: core, stamps: WatchStatusStamps(), now: now) == changed)
        // A counter that is no clock stays unknown, and a Host clock ahead is clamped.
        let counter = consoleAgent("hc:t2", .done, seq: 42, backend: .core)
        #expect(WatchStateBuilder.statusSince(of: counter, stamps: WatchStatusStamps(), now: now) == nil)
        let ahead = consoleAgent(
            "hc:t3", .done, seq: Int(now.timeIntervalSince1970 + 600) * 1_000, backend: .core)
        #expect(WatchStateBuilder.statusSince(of: ahead, stamps: WatchStatusStamps(), now: now) == now)
    }

    // MARK: Latest

    @Test func summaryLatestIsFreshOnlyInItsStatusAndNeverCapped() throws {
        let fresh = consoleAgent("a", .done, summary: ("Shipped the fix.", 1, .done))
        let latest = try #require(WatchStateBuilder.summaryLatest(for: fresh, now: now))
        #expect(latest == WatchLatest(source: .summary, text: "Shipped the fix.", lastReply: nil, isStale: false))

        let stale = consoleAgent("b", .done, summary: ("Running tests.", 1, .working))
        #expect(WatchStateBuilder.summaryLatest(for: stale, now: now)?.isStale == true)

        let longText = String(repeating: "word ", count: 40) + "end"
        let long = consoleAgent("c", .done, summary: (longText, 1, .done))
        let full = try #require(WatchStateBuilder.summaryLatest(for: long, now: now))
        #expect(full.text == longText)
        #expect(!full.text.contains("…"))

        #expect(WatchStateBuilder.summaryLatest(for: consoleAgent("d", .done), now: now) == nil)
    }

    @Test func lastReplyIsTheWholeCleanedReply() throws {
        let header = ChatTranscriptHeader(
            kind: "claude", status: .ok, transcript: nil, activity: nil, turnOpen: false,
            truncated: false, error: nil)
        let transcript = ChatTranscriptSnapshot(
            header: header,
            messages: [
                ChatTranscriptMessage(id: "1", role: .user, text: "ship it?", timestamp: nil),
                ChatTranscriptMessage(
                    id: "2", role: .assistant,
                    text: "Done. \u{1B}[1mTests\u{1B}[0m pass.\r\nDeployed\u{200B} to \u{202E}staging.\u{1B}]0;title\u{07}\n\n\n\nThird sentence here.",
                    timestamp: nil),
                ChatTranscriptMessage(id: "3", role: .assistant, text: "  ", timestamp: nil),
            ])
        #expect(
            WatchStateBuilder.lastReply(from: transcript)
                == "Done. Tests pass.\nDeployed to staging.\n\nThird sentence here.")
        #expect(WatchStateBuilder.lastReply(from: ChatTranscriptSnapshot(header: header, messages: [])) == nil)
    }

    @Test func aReplyOverTheByteBudgetKeepsItsEndAfterANotice() throws {
        #expect(WatchStateBuilder.fittingBudget("All set.") == "All set.")

        let ending = "The last words stay."
        let reply = String(repeating: "naïve sentence ", count: 5_000) + ending
        let fitted = WatchStateBuilder.fittingBudget(reply)
        #expect(fitted.hasPrefix(WatchStateBuilder.earlierTextNotice + "\n\n"))
        #expect(fitted.hasSuffix(ending))
        #expect(!fitted.contains("…"))
        // The kept text starts at a whole word.
        let kept = fitted.dropFirst(WatchStateBuilder.earlierTextNotice.count + 2)
        #expect(kept.hasPrefix("naïve sentence ") || kept.hasPrefix("sentence "))
    }

    /// Characters JSON escapes count twice, so a reply of paths and quotes
    /// still encodes within the budget.
    @Test func theBudgetCountsEncodedBytes() throws {
        let line = "\"/Users/me/src/app/\\file.swift\"\t\n"
        let reply = String(repeating: line, count: 3_000)
        #expect(reply.utf8.count > WatchStateBuilder.latestByteBudget)
        let fitted = WatchStateBuilder.fittingBudget(reply)
        let latest = WatchLatest(source: .reply, text: fitted, lastReply: nil, isStale: false)
        let encoded = try WatchWireCodec.encode(WatchReply.latest(latest))
        let empty = try WatchWireCodec.encode(
            WatchReply.latest(WatchLatest(source: .reply, text: "", lastReply: nil, isStale: false)))
        #expect(encoded.count - empty.count <= WatchStateBuilder.latestByteBudget)
        #expect(encoded.count - empty.count > WatchStateBuilder.latestByteBudget - 256)
    }

    /// A cut inside a long run without whitespace keeps it from a character
    /// rather than skipping it all; a short partial word is skipped.
    @Test func theCutSkipsOnlyAShortPartialWord() {
        let token = String(repeating: "x", count: WatchStateBuilder.latestByteBudget)
        let fitted = WatchStateBuilder.fittingBudget(token + " end")
        let kept = fitted.dropFirst(WatchStateBuilder.earlierTextNotice.count + 2)
        #expect(kept.hasPrefix("xxxx"))
        #expect(kept.hasSuffix(" end"))

        let words = String(repeating: "abcdefghi ", count: 6_000)
        let cut = WatchStateBuilder.fittingBudget(words)
        #expect(cut.dropFirst(WatchStateBuilder.earlierTextNotice.count + 2).hasPrefix("abcdefghi "))
    }

    @Test func transcriptsAreReadForChatModeOrALiveSession() {
        let plain = consoleAgent("a", .done, kind: "codex")
        #expect(!WatchStateBuilder.readsTranscript(plain, isChatMode: false))
        #expect(WatchStateBuilder.readsTranscript(plain, isChatMode: true))
        #expect(WatchStateBuilder.readsTranscript(sessionAgent("codex"), isChatMode: false))
        // Cursor has no transcript reader.
        #expect(!WatchStateBuilder.readsTranscript(sessionAgent("cursor"), isChatMode: false))
    }

    @Test func latestShowsTheReplyOrAWorkingSummaryOverIt() throws {
        let done = consoleAgent("a", .done, summary: ("Shipped.", 1, .done))
        #expect(
            WatchStateBuilder.latest(for: done, reply: "Long reply.", now: now)
                == WatchLatest(source: .reply, text: "Long reply.", lastReply: nil, isStale: false))
        #expect(WatchStateBuilder.latest(for: done, reply: nil, now: now)?.text == "Shipped.")

        let working = consoleAgent("b", .working, summary: ("Running the tests.", 1, .working))
        #expect(
            WatchStateBuilder.latest(for: working, reply: "Earlier reply.", now: now)
                == WatchLatest(
                    source: .summary, text: "Running the tests.", lastReply: "Earlier reply.",
                    isStale: false))

        // A stale Working summary yields to the reply.
        let staleWorking = consoleAgent("c", .working, summary: ("Old news.", 1, .done))
        #expect(WatchStateBuilder.latest(for: staleWorking, reply: "Reply.", now: now)?.source == .reply)
    }

    /// A Done Agent whose Host reports its live agent session.
    private func sessionAgent(_ kind: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: studio.id, hostName: studio.displayName,
            agent: Agent(
                terminalID: "term-s", kind: kind, title: "Task", status: .done, workspaceID: "w1",
                tabID: "w1:t1", paneID: "s", cwd: "/work/w1", revision: 1,
                agentSession: AgentSessionInfo(
                    agent: kind, kind: .id, source: "herdr:\(kind)", value: "session-1")),
            workspaceLabel: "site", repositoryCheckout: nil)
    }

    // MARK: Blocked prompts

    @Test func blockedPromptsFollowCarPlayApproval() throws {
        let promptID = UUID()
        let allow = try #require(
            BlockedPromptSnapshot(kind: "claude", fullScreen: TmuxScreenDetectorTests.claudePermission))
        #expect(
            WatchStateBuilder.blockedPrompt(allow, promptID: promptID)
                == WatchBlockedPrompt(
                    promptID: promptID, approval: .allow, command: "touch x.txt", holdReason: nil))

        let risky = try #require(
            BlockedPromptSnapshot(
                kind: "claude",
                fullScreen: TmuxScreenDetectorTests.claudePermission.replacingOccurrences(
                    of: " touch x.txt\n", with: " sudo touch x.txt\n")))
        let held = WatchStateBuilder.blockedPrompt(risky, promptID: promptID)
        #expect(held.approval == .hold)
        #expect(held.command == "sudo touch x.txt")
        #expect(held.holdReason == "This one looks risky: it runs as root. Allow it on iPhone.")

        let question = try #require(
            BlockedPromptSnapshot(kind: "claude", fullScreen: TmuxScreenDetectorTests.claudeQuestion))
        #expect(
            WatchStateBuilder.blockedPrompt(question, promptID: promptID)
                == WatchBlockedPrompt(promptID: promptID, approval: .readOnly, command: nil, holdReason: nil))
    }
}
