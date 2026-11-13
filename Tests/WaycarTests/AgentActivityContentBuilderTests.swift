import Foundation
import Testing

@testable import Waycar

/// Sort, cap, and trim tests use deliberately fake pane ids (`w:p-work`,
/// `w:p%02d` → `w:p00`) as opaque sort keys. Those values are not live herdr
/// addresses; fixtures that stand in for a real pane use the observed
/// `w…:p…` family instead (see the shared Live Activity vectors).
@Suite("Agent activity content builder")
struct AgentActivityContentBuilderTests {
    private let hostID = UUID()
    private let key = Data(0..<32)

    @Test func configuredRowsKeepDirectoryPluginTextAndStylesInsideEncryption() throws {
        let row = ConsoleAgent(
            hostID: hostID, hostName: "Studio Mac",
            agent: Agent(terminalID: "terminal", kind: "claude", title: "task", status: .working,
                         workspaceID: "workspace", tabID: "tab", paneID: "w1:p1", cwd: "/work/waycar",
                         revision: 1, tokens: ["branch": "**literal**"]),
            workspaceLabel: "Waycar", repositoryCheckout: nil)
        let layout = AgentRowLayout(rows: [
            [.init(.workspace, bold: true), .init(.custom("branch"), fg: HexColor("#abc"))],
            [.init(.host, dim: true)], [.init(.directory)],
        ])
        let content = try #require(AgentActivityContentBuilder.make(
            agents: [row], hostName: "Studio Mac", key: key, layout: layout))
        let details = try opened(content)
        #expect(details.agents.first?.rows == [
            [.init(text: "Waycar", bold: true), .init(text: " · "), .init(text: "**literal**", fg: "#abc")],
            [.init(text: "Studio Mac", dim: true)], [.init(text: "/work/waycar")],
        ])
        let wire = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
        #expect(!wire.contains("/work/waycar") && !wire.contains("**literal**"))
    }

    @Test func oversizedConfiguredRowsFallBackToIdentityBeforeDroppingAgents() throws {
        var desired = try #require(AgentActivityContentBuilder.desire(
            from: [agent("w1:p1", .working, workspace: "Waycar")], hostName: "mbp"))
        desired.agents[0].rows = [[.init(text: String(repeating: "界", count: 3000))]]
        let state = try #require(AgentActivityContentBuilder.content(for: desired, key: key))
        let details = try opened(state)
        #expect(details.agents.count == 1)
        #expect(details.agents[0].rows == nil)
        #expect(details.agents[0].workspace == "Waycar")
        #expect(try #require(state.envelope).ct.count <= AgentActivityContentBuilder.maxCiphertextBytes)
    }

    @Test func countsCoverTheFullEligibleInventoryNotTheCap() throws {
        var agents: [ConsoleAgent] = [
            agent("w:p-block", .blocked),
            agent("w:p-done", .done),
        ]
        for index in 0..<6 {
            agents.append(agent("w:p-work-\(index)", .working))
        }

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "mbp"))

        #expect(desire.counts == .init(working: 6, blocked: 1, done: 1))
        #expect(desire.agents.count == 5)
    }

    @Test func sortsBlockedThenDoneThenWorkingWithPaneByteTiebreak() throws {
        let agents = [
            agent("w:p9", .working, kind: "grok", title: "later"),
            agent("w:p2", .blocked, kind: "claude", title: "first blocked"),
            agent("w:p1", .done, kind: "droid", title: "done"),
            agent("w:p8", .blocked, kind: "codex", title: "second blocked"),
            agent("w:p3", .working, kind: "claude", title: "earlier working"),
        ]

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "mbp"))

        #expect(desire.agents.map(\.paneID) == ["w:p2", "w:p8", "w:p1", "w:p3", "w:p9"])
        #expect(desire.agents.map(\.status) == [
            "blocked", "blocked", "done", "working", "working",
        ])
    }

    @Test func capsListedAgentsAtFiveAndKeepsCounts() throws {
        let agents = (0..<8).map { index in
            agent(String(format: "w:p%02d", index), .working)
        }

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "studio"))

        #expect(desire.counts.working == 8)
        #expect(desire.agents.count == 5)
        #expect(desire.agents.map(\.paneID) == ["w:p00", "w:p01", "w:p02", "w:p03", "w:p04"])
    }

    @Test func trimsCJKTitlesAndHostNamesAtEightyGraphemes() throws {
        let cjk = String(repeating: "锁", count: 81)
        let agents = [agent("w:p1", .working, title: cjk)]

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: cjk))

        #expect(desire.hostName.count == 80)
        #expect(desire.hostName == String(repeating: "锁", count: 80))
        #expect(desire.agents.first?.title?.count == 80)
        #expect(desire.agents.first?.title == String(repeating: "锁", count: 80))
    }

    @Test func trimsEmojiGraphemesNotUTF8Bytes() throws {
        let family = "👨‍👩‍👧"
        #expect(family.count == 1)
        let over = String(repeating: family, count: 81)

        let desire = try #require(
            AgentActivityContentBuilder.desire(
                from: [agent("w:p1", .blocked, title: over)], hostName: "mbp"))

        #expect(desire.agents.first?.title?.count == 80)
        #expect(desire.agents.first?.title == String(repeating: family, count: 80))
    }

    @Test func countsIdleButListsOnlyEligibleAndDropsUnknown() throws {
        let agents = [
            agent("w:p1", .idle, title: "idle"),
            agent("w:p5", .idle, title: "also idle"),
            agent("w:p2", .unknown, title: "unknown"),
            agent("w:p3", AgentStatus(rawValue: "mystery"), title: "future"),
            agent("w:p4", .working, title: "keep"),
        ]

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "mbp"))

        #expect(desire.counts == .init(working: 1, blocked: 0, done: 0, idle: 2))
        #expect(desire.agents.map(\.paneID) == ["w:p4"])
    }

    @Test func idleCountChangeChangesTheDesire() throws {
        let base = [agent("w:p1", .working), agent("w:p2", .idle)]
        let before = try #require(
            AgentActivityContentBuilder.desire(from: base, hostName: "mbp"))
        let after = try #require(
            AgentActivityContentBuilder.desire(
                from: base + [agent("w:p3", .idle)], hostName: "mbp"))

        #expect(before.counts.idle == 1)
        #expect(after.counts.idle == 2)
        #expect(before != after)
    }

    @Test func returnsNilWhenNothingIsEligible() {
        let agents = [
            agent("w:p1", .idle),
            agent("w:p2", .unknown),
        ]

        #expect(AgentActivityContentBuilder.desire(from: agents, hostName: "mbp") == nil)
        #expect(
            AgentActivityContentBuilder.make(agents: agents, hostName: "mbp", key: key) == nil)
        #expect(AgentActivityContentBuilder.make(agents: [], hostName: "mbp", key: key) == nil)
    }

    @Test func carriesTheHerdrAgentNameAndOmitsItWhenUnnamed() throws {
        let agents = [
            agent("w:p1", .working, name: "la-demo"),
            agent("w:p2", .blocked),
        ]

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "mbp"))

        let byPane = Dictionary(uniqueKeysWithValues: desire.agents.map { ($0.paneID, $0) })
        #expect(byPane["w:p1"]?.name == "la-demo")
        #expect(byPane["w:p2"]?.name == nil)
    }

    @Test func carriesTheWorkspaceLabelAndTrimsItToTheDisplayLimit() throws {
        let workspace = String(repeating: "锁", count: 81)
        let desire = try #require(
            AgentActivityContentBuilder.desire(
                from: [agent("w:p1", .working, workspace: workspace)], hostName: "mbp"))

        #expect(desire.agents.first?.workspace == String(repeating: "锁", count: 80))
        #expect(desire.agents.first?.kind == "claude")
    }

    @Test func omitsEmptyTitlesAndFallsBackToUnknownKind() throws {
        let blankKind = Agent(
            terminalID: "t", kind: "", title: "", status: .done,
            workspaceID: "w", tabID: "t", paneID: "w:p1", cwd: "/", revision: 1)
        let agents = [
            ConsoleAgent(
                hostID: hostID, hostName: "mbp", agent: blankKind,
                workspaceLabel: nil, repositoryCheckout: nil)
        ]

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "mbp"))

        #expect(desire.agents == [
            AgentActivityDetails.AgentDetail(
                paneID: "w:p1", kind: "unknown", status: "done", title: nil)
        ])
    }

    @Test func degradesAnOversizeSealedTitleThenKeepsTheAgent() throws {
        // One grapheme, many UTF-8 bytes: 80 of these blow the ct budget
        // even after the 80-grapheme trim.
        let cluster = "e" + String(repeating: "\u{0301}", count: 50)
        let huge = String(repeating: cluster, count: 80)
        #expect(huge.count == 80)

        let state = try #require(
            AgentActivityContentBuilder.make(
                agents: [agent("w:p1", .working, title: huge, name: "reviewer")],
                hostName: "mbp",
                key: key))

        #expect(state.counts == .init(working: 1, blocked: 0, done: 0))
        let envelope = try #require(state.envelope)
        #expect(envelope.ct.count <= AgentActivityContentBuilder.maxCiphertextBytes)
        let details = try opened(state)
        #expect(details.agents.count == 1)
        #expect(details.agents.first?.title == nil)
        #expect(details.agents.first?.name == nil)
        #expect(details.agents.first?.paneID == "w:p1")
        #expect(details.hostName == "mbp")
    }

    @Test func pinnedEligibleAgentsLeadByPinRecencyThenStatusRank() throws {
        let agents = [
            agent("w:p-work", .working),
            agent("w:p-block", .blocked),
            agent("w:p-done", .done),
        ]

        let desire = try #require(
            AgentActivityContentBuilder.desire(
                from: agents, hostName: "mbp",
                pinnedPaneIDs: ["w:p-work", "w:p-done"]))

        #expect(desire.agents.map(\.paneID) == ["w:p-work", "w:p-done", "w:p-block"])
        #expect(desire.agents.map(\.status) == ["working", "done", "blocked"])
        #expect(desire.counts == .init(working: 1, blocked: 1, done: 1))
    }

    @Test func pinnedIneligibleAndUnknownPaneIDsAreIgnored() throws {
        let agents = [
            agent("w:p-idle", .idle),
            agent("w:p-work", .working),
            agent("w:p-block", .blocked),
        ]

        let desire = try #require(
            AgentActivityContentBuilder.desire(
                from: agents, hostName: "mbp",
                pinnedPaneIDs: ["w:p-idle", "gone:pane", "w:p-work"]))

        #expect(desire.counts == .init(working: 1, blocked: 1, done: 0, idle: 1))
        #expect(desire.agents.map(\.paneID) == ["w:p-work", "w:p-block"])
    }

    @Test func pinOrderCapIsAppliedAfterSortAndCountsStayFull() throws {
        var agents = [
            agent("w:p-pin", .working),
        ]
        for index in 0..<6 {
            agents.append(agent(String(format: "w:p%02d", index), .blocked))
        }

        let desire = try #require(
            AgentActivityContentBuilder.desire(
                from: agents, hostName: "mbp",
                pinnedPaneIDs: ["w:p-pin"]))

        #expect(desire.counts == .init(working: 1, blocked: 6, done: 0))
        #expect(desire.agents.count == 5)
        #expect(desire.agents.map(\.paneID) == ["w:p-pin", "w:p00", "w:p01", "w:p02", "w:p03"])
        #expect(desire.agents.first?.status == "working")
    }

    @Test func sharedPinOrderVectorsMatchDesire() throws {
        for vector in LiveActivityVectorFile.shared.valid where !vector.inventory.isEmpty {
            let agents = vector.inventory.map { item -> ConsoleAgent in
                let workspaceID = item.workspaceID ?? "w"
                let tabID = item.tabID ?? "t"
                let tab = vector.tabs.first { $0.tabID == tabID && $0.workspaceID == workspaceID }
                var row = ConsoleAgent(
                    hostID: hostID, hostName: vector.payload.host,
                    agent: Agent(
                        terminalID: "t",
                        kind: item.agent ?? "",
                        title: item.terminalTitleStripped ?? item.terminalTitle ?? "",
                        status: AgentStatus(rawValue: item.agentStatus),
                        workspaceID: workspaceID, tabID: tabID, paneID: item.paneID,
                        cwd: item.cwd ?? "/", revision: 1,
                        name: nonEmpty(item.displayAgent) ?? nonEmpty(item.name)),
                    workspaceLabel: vector.workspaceLabels[workspaceID], repositoryCheckout: nil,
                    tabLabel: tab?.label, tabPosition: tab?.position, workspaceTabCount: tab?.count ?? 0)
                row.summary = vector.summaries[item.paneID]?.agentSummary(paneID: item.paneID)
                return row
            }
            // Progress has no freshness gate on the wire; use the newest
            // record as the clock so nothing reads as from the future.
            let now = vector.summaries.values.map {
                Date(timeIntervalSince1970: TimeInterval($0.ts) / 1000)
            }.max() ?? Date()

            let desire = try #require(
                AgentActivityContentBuilder.desire(
                    from: agents, hostName: vector.payload.host,
                    pinnedPaneIDs: vector.pinnedPaneIDs, layout: vector.rowLayout, now: now),
                "\(vector.name)")

            #expect(desire.hostName == vector.payload.host, "\(vector.name)")
            #expect(
                desire.agents.map(\.paneID) == vector.payload.agents.map(\.pane),
                "\(vector.name)")
            #expect(
                desire.agents.map(\.status) == vector.payload.agents.map(\.status),
                "\(vector.name)")
            #expect(
                desire.agents.map(\.title) == vector.payload.agents.map(\.title),
                "\(vector.name)")
            #expect(
                desire.agents.map(\.name) == vector.payload.agents.map(\.name),
                "\(vector.name)")
            #expect(
                desire.agents.map(\.rows) == vector.payload.agents.map(\.rows),
                "\(vector.name)")
            #expect(
                desire.agents.map(\.progress) == vector.payload.agents.map(\.agentProgress),
                "\(vector.name)")
            if let counts = vector.counts {
                #expect(
                    desire.counts
                        == .init(
                            working: counts.working, blocked: counts.blocked, done: counts.done,
                            idle: counts.idle),
                    "\(vector.name)")
            }
        }
    }

    @Test func sealedContentOpensToTheDesiredDetails() throws {
        let agents = [agent("wV:p1", .working, title: "task")]
        let state = try #require(
            AgentActivityContentBuilder.make(agents: agents, hostName: "mbp", key: key))

        let details = try opened(state)
        #expect(details.hostName == "mbp")
        #expect(details.agents.first?.title == "task")
        #expect(details.agents.first?.status == "working")
    }

    @Test func envelopeCarriesOnlyEstimatesForTheCurrentStatus() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let steps = AgentProgress(steps: .init(done: 3, total: 7), phase: nil)
        let phase = AgentProgress(steps: nil, phase: .verifying)
        let agents = [
            agent("w1:p1", .working, summary: (.working, steps), at: now),
            agent("w1:p2", .blocked, summary: (.blocked, phase), at: now),
            // Written while Working; the Agent has since blocked: frozen bar.
            agent("w1:p3", .blocked, summary: (.working, steps), at: now),
            agent("w1:p4", .done, summary: (.done, steps), at: now),
            agent("w1:p5", .working),
        ]

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "mbp", now: now))
        let state = try #require(AgentActivityContentBuilder.content(for: desire, key: key))
        let byPane = Dictionary(
            uniqueKeysWithValues: try opened(state).agents.map { ($0.paneID, $0.progress) })

        #expect(byPane["w1:p1"] == .some(steps))
        #expect(byPane["w1:p2"] == .some(phase))
        #expect(byPane["w1:p3"] == .some(steps))
        #expect(byPane["w1:p4"] == .some(nil))
        #expect(byPane["w1:p5"] == .some(nil))
        // Written while Blocked; the Agent is working again: moved on.
        let resumed = try #require(AgentActivityContentBuilder.desire(
            from: [agent("w1:p6", .working, summary: (.blocked, phase), at: now)],
            hostName: "mbp", now: now))
        #expect(resumed.agents.map(\.progress) == [nil])
    }

    /// Lockstep with the plugin: the shared `degrade` section pins the
    /// fallback plaintexts both producers send under the ciphertext cap.
    @Test func degradeOrderMatchesSharedVector() {
        let degrade = LiveActivityVectorFile.shared.degrade
        let desire = AgentActivityDesire(
            counts: .init(working: 1, blocked: 1, done: 0),
            hostName: degrade.payload.host, agents: degrade.payload.agents.map(\.detail))

        let candidates = AgentActivityContentBuilder.degradeCandidates(for: desire)

        #expect(candidates.allSatisfy { $0.hostName == degrade.payload.host })
        #expect(
            candidates.map(\.agents)
                == ([degrade.payload] + degrade.steps).map { $0.agents.map(\.detail) })
    }

    @Test func oversizedProgressDropsBeforeAgents() throws {
        // Five 340-byte panes fit the ciphertext budget alone (~2.6 KB of
        // base64) but not with five progress objects (~2.9 KB).
        let progress = AgentProgress(steps: .init(done: 3, total: 7), phase: .verifying)
        let agents = (1...5).map { index in
            AgentActivityDetails.AgentDetail(
                paneID: "w\(index):" + String(repeating: "p", count: 340), kind: "codex",
                status: "working", title: nil, progress: progress)
        }
        let desire = AgentActivityDesire(
            counts: .init(working: 5, blocked: 0, done: 0), hostName: "mbp", agents: agents)

        let state = try #require(AgentActivityContentBuilder.content(for: desire, key: key))
        let details = try opened(state)

        #expect(state.envelope.map { $0.ct.count <= AgentActivityContentBuilder.maxCiphertextBytes } == true)
        #expect(details.agents.map(\.paneID) == agents.map(\.paneID))
        #expect(details.agents.allSatisfy { $0.progress == nil })
    }

    private func opened(
        _ state: AgentActivityAttributes.ContentState
    ) throws -> AgentActivityDetails {
        let envelope = try #require(state.envelope)
        return try AgentActivityEnvelope.open(try JSONEncoder().encode(envelope), using: key)
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private func agent(
        _ paneID: String, _ status: AgentStatus,
        kind: String = "claude", title: String = "Task", name: String? = nil,
        workspace: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: "mbp",
            agent: Agent(
                .fixture(paneID: paneID, status: status, kind: kind, title: title, name: name)),
            workspaceLabel: workspace, repositoryCheckout: nil)
    }

    private func agent(
        _ paneID: String, _ status: AgentStatus,
        summary: (status: AgentStatus, progress: AgentProgress?), at now: Date
    ) -> ConsoleAgent {
        var row = agent(paneID, status)
        row.summary = AgentSummary(
            paneID: paneID, status: summary.status, text: "Doing the thing",
            timestamp: Int64(now.timeIntervalSince1970 * 1000), progress: summary.progress)
        return row
    }
}
