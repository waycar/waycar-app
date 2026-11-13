import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Waycar

@Suite("Ultimate chat-only backend")
struct UltimateTransportTests {
    private static let instance = UltimateInstance(
        id: "project-hash", home: "/home/test/.ultimate/projects/project-hash",
        project: "/work/project", name: "Project", pid: 123, port: 4747)
    private static let summaries = #"[{"id":1,"title":"Build the app","cwd":"/work/project","busy":true},{"id":2,"label":"Branch","cwd":"/home/test/.ultimate/projects/project-hash/worktrees/2","branchOf":{"conversationId":1,"at":7},"busy":false},{"id":3,"busy":false,"concluded":true},{"id":4,"cwd":"/work/project","parentConversationId":1,"busy":false},{"id":5,"label":"internal-service","cwd":"/home/test/.ultimate/projects/project-hash/lander/checkout","busy":false}]"#

    @Test("Project instances synthesize stable chat Agents and busy/idle status")
    func snapshot() throws {
        let conversations = try UltimateConversationSummary.decodeList(Data(Self.summaries.utf8))
        let snapshot = UltimateSnapshotBuilder.snapshot(
            instances: [Self.instance], conversations: [Self.instance.id: conversations])
        #expect(snapshot.agents.count == 1)
        #expect(snapshot.agents.map(\.agentStatus) == [.working])
        #expect(snapshot.agents.map(\.name) == ["@ultimate"])
        #expect(snapshot.agents.map(\.paneID) == ["ultimate:project-hash:1"])
        #expect(snapshot.agents.first?.paneID == "ultimate:project-hash:1")
        #expect(snapshot.agents.first?.cwd == "/work/project")
        #expect(snapshot.workspaces.first?.label == "Project")
        #expect(snapshot.tabs.count == 1)
        #expect(snapshot.panes.count == 1)
        #expect(!HostBackend.ultimate.hasTerminal)
        #expect(!HostBackend.ultimate.capabilities.startsAgents)
        #expect(HostBackendPresence(herdr: false, tmuxVersion: nil, ultimate: [Self.instance]).backends == [.ultimate])
    }

    @Test("Only ownerless non-branch conversations are leaders; active branches have typed children")
    func leaderAndChildren() throws {
        let summaries = try UltimateConversationSummary.decodeList(Data(#"[{"id":8,"busy":true,"branchOf":{"conversationId":1,"at":2}},{"id":9,"busy":false,"parentConversationId":1},{"id":1,"busy":false,"label":"Leader"},{"id":2,"busy":true,"label":"Working branch","branchOf":{"conversationId":1,"at":3}},{"id":3,"busy":false,"title":"Finished","branchOf":{"conversationId":2,"at":4}}]"#.utf8))
        #expect(summaries.map(\.isLeader) == [false, false, true, false, false])
        let snapshot = UltimateSnapshotBuilder.snapshot(
            instances: [Self.instance], conversations: [Self.instance.id: summaries])
        #expect(snapshot.agents.map(\.paneID) == ["ultimate:project-hash:1"])
        let children = UltimateSnapshotBuilder.children(
            instances: [Self.instance], conversations: [Self.instance.id: summaries],
            concluded: [Self.instance.id: [8, 3]])
        #expect(children == ["ultimate:project-hash:1": [UltimateChildInfo(
            conversationId: 2, paneID: "ultimate:project-hash:2", name: "Working branch", busy: true)]])
        let resumed = UltimateSnapshotBuilder.children(
            instances: [Self.instance], conversations: [Self.instance.id: summaries])
        #expect(resumed["ultimate:project-hash:1"]?.count == 3)
        #expect(resumed["ultimate:project-hash:1"]?.filter(\.busy).count == 2)
        let concludedTree = UltimateSnapshotBuilder.children(
            instances: [Self.instance], conversations: [Self.instance.id: summaries],
            concluded: [Self.instance.id: [2]])
        #expect(concludedTree["ultimate:project-hash:1"]?.map(\.conversationId) == [8])
    }

    @Test("Standing agents keep cards beside the named lead, with structural fallback for older projects")
    func standingAgents() throws {
        let fixtures: [(String, Int, [Int], [String])] = [
            (#"[{"id":1,"label":"agent","title":"@reviewer","busy":true},{"id":3,"label":"agent","title":"@ultimate","busy":false},{"id":4,"title":"Branch","busy":true,"branchOf":{"conversationId":3,"at":7}}]"#,
             3, [3, 1], ["@ultimate", "@reviewer"]),
            (#"[{"id":5,"label":"agent","title":"@reviewer","busy":true},{"id":2,"label":"agent","title":"@planner","busy":false}]"#,
             2, [2, 5], ["@ultimate", "@reviewer"]),
            (#"[{"id":8,"title":"Another root","busy":false},{"id":2,"title":"Old root","busy":false},{"id":1,"busy":true,"branchOf":{"conversationId":2,"at":7}}]"#,
             2, [2], ["@ultimate"])
        ]
        for (json, leadID, ids, names) in fixtures {
            let summaries = try UltimateConversationSummary.decodeList(Data(json.utf8))
            #expect(UltimateSnapshotBuilder.leader(in: Self.instance, conversations: summaries)?.id == leadID)
            let snapshot = UltimateSnapshotBuilder.snapshot(instances: [Self.instance], conversations: [Self.instance.id: summaries])
            #expect(snapshot.agents.map(\.paneID) == ids.map { "ultimate:project-hash:\($0)" })
            #expect(snapshot.agents.map(\.name) == names.map(Optional.some))
            let children = UltimateSnapshotBuilder.children(instances: [Self.instance], conversations: [Self.instance.id: summaries])
            #expect(children.keys.sorted() == ["ultimate:project-hash:\(leadID)"])
            #expect(children.values.flatMap { $0 }.allSatisfy { !ids.contains($0.conversationId) })
        }
    }

    @Test("Ultimate lead stays before its workspace's working standing agents")
    func leadSortsFirst() throws {
        let info = AgentInfo(agentStatus: .idle, focused: false, paneID: "ultimate:p:1", revision: 0,
                             tabID: "ultimate:p:1", terminalID: "ultimate:p:1", workspaceID: "ultimate:p",
                             agent: "ultimate", name: "@ultimate")
        var lead = ConsoleAgent(hostID: UUID(), hostName: "Mac", agent: Agent(info),
                                workspaceLabel: "Project", repositoryCheckout: nil, backend: .ultimate)
        lead.isUltimateLeader = true
        lead.ultimateChildren = [.init(conversationId: 2, paneID: "ultimate:p:2", name: "@reviewer", busy: true)]
        let standing = try #require(lead.ultimateChild("ultimate:p:2"))
        #expect([standing, lead].consoleSorted().map(\.id) == [lead.id, standing.id])
        #expect([lead, standing].consoleSorted(pinRank: { $0.id == standing.id ? 0 : nil }).map(\.id)
                == [lead.id, standing.id])
        #expect(!standing.isUltimateLeader)
    }

    @Test("Standing-agent display names prefer titles, never the internal agent label")
    func standingDisplayNames() throws {
        let summaries = try UltimateConversationSummary.decodeList(Data(#"[{"id":7,"label":"agent","title":"@reviewer","busy":false},{"id":9,"label":"agent","busy":false}]"#.utf8))
        #expect(summaries.map(\.displayName) == ["@reviewer", "Conversation #9"])
    }

    @Test("Shared UI snapshot and deltas conclude and resume branches without summary changes")
    func concludedUI() throws {
        var ui = UltimateUIState()
        try ui.receive(UltimateServerEvent(name: "ui", data: #"{"value":{"ext.conversations.concluded":[2],"future":true}}"#, id: nil))
        #expect(ui.concluded == [2])
        try ui.receive(UltimateServerEvent(name: "uiOps", data: #"{"ops":[["p",["ext.conversations.concluded"],1,0,[3]],["s",["unrelated"],true]]}"#, id: nil))
        #expect(ui.concluded == [2, 3])
        try ui.receive(UltimateServerEvent(name: "uiOps", data: #"{"ops":[["s",["ext.conversations.concluded"],[3]]]}"#, id: nil))
        #expect(ui.concluded == [3])
        try ui.receive(UltimateServerEvent(name: "uiOps", data: #"{"ops":[["r",{}]]}"#, id: nil))
        #expect(ui.concluded.isEmpty)
    }

    @Test("Root board counts only open user questions and follows answer deltas")
    func boardQuestions() throws {
        var board = UltimateBoardState()
        #expect(try board.receive(.init(name: "doc", data: "0\n" + #"{"kind":"board","value":{"messages":[{"to":"user","reply":true,"state":"delivered"},{"to":"user","reply":true,"state":"answered"},{"to":"user","questions":[{"text":"Pick?"}],"state":"delivered"},{"to":7,"reply":true,"state":"delivered"},{"to":"user","reply":true,"state":"dismissed"}],"next":6}}"#, id: nil)))
        #expect(board.openQuestions == 2)
        #expect(try board.receive(.init(name: "docOps", data: "0\n" + #"{"kind":"board","ops":[["s",["messages",0,"state"],"answered"]]}"#, id: nil)))
        #expect(board.openQuestions == 1)
        #expect(try board.receive(.init(name: "docOps", data: "0\n" + #"{"kind":"board","ops":[["p",["messages"],2,1,[]]]}"#, id: nil)))
        #expect(board.openQuestions == 0)
    }

    @Test("Board string trims and appends settle real answered and dismissed question updates")
    func boardStringUpdates() throws {
        var board = UltimateBoardState()
        _ = try board.receive(.init(name: "doc", data: "0\n" + #"{"kind":"board","value":{"messages":[{"from":2,"to":"user","reply":true,"state":"delivered"}]}}"#, id: nil))
        #expect(board.openQuestions == 1)
        _ = try board.receive(.init(name: "docOps", data: "0\n" + #"{"kind":"board","ops":[["t",["messages",0,"state"],9],["a",["messages",0,"state"],"answered"]]}"#, id: nil))
        #expect(board.openQuestions == 0)
        #expect(board.openQuestionsByConversation.isEmpty)
        _ = try board.receive(.init(name: "docOps", data: "0\n" + #"{"kind":"board","ops":[["s",["messages",0,"state"],"delivered"],["t",["messages",0,"state"],8],["a",["messages",0,"state"],"ismissed"]]}"#, id: nil))
        #expect(board.openQuestions == 0)
        // A non-BMP scalar occupies two JS UTF-16 units, not one Swift
        // Character. Trimming beyond the end also matches JS slice.
        _ = try board.receive(.init(name: "docOps", data: "0\n" + #"{"kind":"board","ops":[["s",["messages",0,"state"],"😀delivered"],["t",["messages",0,"state"],2]]}"#, id: nil))
        #expect(board.openQuestions == 1)
        _ = try board.receive(.init(name: "docOps", data: "0\n" + #"{"kind":"board","ops":[["t",["messages",0,"state"],100],["a",["messages",0,"state"],"answered"]]}"#, id: nil))
        #expect(board.openQuestions == 0)
    }

    @Test("Folded branches retain their own chat identity and Live Activity counts")
    @MainActor
    func foldedBranchRouting() throws {
        let conversations = try UltimateConversationSummary.decodeList(Data(Self.summaries.utf8))
        let info = try #require(UltimateSnapshotBuilder.snapshot(
            instances: [Self.instance], conversations: [Self.instance.id: conversations]).agents.first)
        var leader = ConsoleAgent(hostID: UUID(), hostName: "Mac", agent: Agent(info),
                                  workspaceLabel: "Project", repositoryCheckout: nil, backend: .ultimate)
        leader.isUltimateLeader = true
        leader.ultimateChildren = [
            .init(conversationId: 2, paneID: "ultimate:project-hash:2", name: "Branch", busy: true),
            .init(conversationId: 3, paneID: "ultimate:project-hash:3", name: "Idle branch", busy: false)
        ]
        leader.ultimateOpenQuestions = 1
        #expect(leader.ultimateBranchSummary == "2 branches · 1 working · 1 needs you")
        let branch = try #require(leader.ultimateChild("ultimate:project-hash:2"))
        #expect(branch.id != leader.id)
        #expect(branch.agent.paneID == "ultimate:project-hash:2")
        #expect(branch.agent.terminalID == branch.agent.paneID)
        #expect(branch.agent.displayName == "Branch")
        #expect(branch.backend == .ultimate)
        #expect(branch.ultimateChildren.isEmpty)
        leader.agent.replaceStatus(.idle)
        let desire = try #require(AgentActivityContentBuilder.desire(from: [leader], hostName: "Mac"))
        #expect(desire.agents.count == 1)
        #expect(desire.agents.first?.rows?.last?.first?.text == leader.ultimateBranchSummary)
        let key = Data(repeating: 7, count: 32)
        let content = try #require(AgentActivityContentBuilder.content(for: desire, key: key))
        let envelope = try JSONEncoder().encode(try #require(content.envelope))
        let opened = try AgentActivityEnvelope.open(envelope, using: key)
        #expect(opened.agents.first?.rows?.last?.first?.text == leader.ultimateBranchSummary)
        leader.ultimateOpenQuestions = 0
        #expect(leader.ultimateBranchSummary == "2 branches · 1 working")
    }

    @Test("Selecting a folded branch mounts its Console chat detail without listing another card")
    @MainActor
    func addressableBranch() async throws {
        let composition = DemoScreenshotComposition.make()
        let host = try #require(composition.hosts.hosts.first)
        let services = FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result() })
        // Open preflight, ping, initial SSE, then the pane-subscription
        // replacement requested after the first authoritative snapshot.
        let inventories = (0..<4).map { _ in UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n") }
        for inventory in inventories { await services.serveUltimate(inventory) }
        let history = #"{"entries":[{"id":12,"kind":"pi.assistant","model":[{"role":"assistant","stopReason":"stop","content":"Branch detail is ready."}]}]}"#
        let historyRead = UltimateTestHTTPChannel(json: history)
        await services.serveUltimate(historyRead)
        for _ in 0..<7 { await services.serveUltimate(UltimateTestHTTPChannel(json: history)) }
        // The production connector proves inventory before publishing the
        // transport to the Console's concurrent readers.
        let transport = try await UltimateTransport.open(session: services, instances: [Self.instance])
        let session = EventsSession(subscriptions: [], connect: { transport }, keepalive: nil)
        let console = ConsoleStore()
        let projection = HostConsoleProjection(host: host, session: session, backend: .ultimate,
                                              snapshotRetryDelay: .milliseconds(10), onChange: { console.rebuild() })
        console.projections[ConsoleScope(hostID: host.id, backend: .ultimate)] = projection
        projection.start(isActive: true)
        defer { projection.end(); console.projections.removeAll() }
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "ultimate:project-hash:2")
        try await waitUntil("the branch should be listed") { console.listedAgent(id) != nil }
        #expect(projection.agentsByPane.keys.sorted() == ["ultimate:project-hash:1"])
        #expect(projection.agentsByPane["ultimate:project-hash:1"]?.isUltimateLeader == true)
        #expect(console.listedAgent(id)?.agent.displayName == "Branch")
        #expect(try await console.verifiedAgent(id).id == id)
        #expect(console.isChatMode(try #require(console.listedAgent(id))))
        #expect(console.agents.map(\.id.paneID) == ["ultimate:project-hash:1"])
        composition.notificationRouter.path = [id]
        let view = ConsoleView(
            hosts: composition.hosts, console: console,
            terminal: TerminalSettings(
                themes: composition.terminalThemes, zoom: composition.terminalZoom,
                fonts: composition.terminalFonts, snippets: composition.snippets, toolbars: composition.toolbars),
            appearance: composition.appearance, pushRegistration: composition.pushRegistration,
            notificationPreferences: composition.notificationPreferences, relaySettings: composition.relaySettings,
            agentSummaries: composition.agentSummaries, notificationRouter: composition.notificationRouter,
            bannerStore: composition.bannerStore, liveActivities: composition.liveActivities,
            activity: composition.activity, aiUsage: composition.aiUsage)
        let controller = UIHostingController(rootView: view)
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 440, height: 880), rootViewController: controller)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await DisplayTickMonitor.shared.waitForTicks(20)
        let root = try #require(controller.view)
        try await waitUntil("the branch detail should render") {
            root.layoutIfNeeded()
            return Self.accessibilityLabels(in: root).contains { $0.contains("Branch detail is ready.") }
        }
        let labels = Self.accessibilityLabels(in: root)
        #expect(labels.contains(where: { $0.contains("Branch detail is ready.") }),
                "Selected branch must render Chat Mode, not the missing-Agent screen: \(labels)")
        #expect(composition.notificationRouter.path.last == id)
        #expect(String(decoding: await historyRead.written, as: UTF8.self)
            .contains("GET /api/conversations/2/history?before="))
        #expect(!console.agents.contains(where: { $0.id == id }))
        #expect(console.indexAgents(holding: console.listedAgent(id)).map(\.id.paneID) == ["ultimate:project-hash:1"])
    }

    @MainActor
    private static func accessibilityLabels(in root: UIView) -> [String] {
        var visited = Set<ObjectIdentifier>()
        var labels: [String] = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if let label = node.accessibilityLabel { labels.append(label) }
            for case let child as NSObject in node.accessibilityElements ?? [] { visit(child) }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let child = node.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
            if let view = node as? UIView { view.subviews.forEach { visit($0) } }
        }
        visit(root)
        return labels
    }

    @Test("Ultimate opens Chat Mode without a Host Tools marker")
    @MainActor
    func chatOnlyGate() throws {
        let conversations = try UltimateConversationSummary.decodeList(Data(Self.summaries.utf8))
        let snapshot = UltimateSnapshotBuilder.snapshot(
            instances: [Self.instance], conversations: [Self.instance.id: conversations])
        let info = try #require(snapshot.agents.first)
        let row = ConsoleAgent(
            hostID: UUID(), hostName: "Mac", agent: Agent(info), workspaceLabel: "Project",
            repositoryCheckout: nil, backend: .ultimate)
        let console = ConsoleStore()
        #expect(console.chatMode.marker(for: row.id) == nil)
        #expect(console.isChatMode(row))
        let card = AgentCardPresentation(agent: row)
        #expect(card.headline == "@ultimate")
        #expect(card.caption == "Project · Mac")
        #expect(card.additionalRows == ["/work/project"])
    }

    @Test("New Agent excludes the chat-only runtime and its Workspaces")
    @MainActor
    func launchDestinations() {
        let host = Host(address: "example.test", username: "test")
        let store = StartAgentStore(
            hosts: [host], workspaces: { _ in [
                ConsoleWorkspace(id: "herdr", label: "Terminal"),
                ConsoleWorkspace(id: "ultimate", label: "Chat", backend: .ultimate),
            ] }, existingAgentNames: { _ in [] }, discoverAgentKinds: { _ in [] },
            remoteHome: { _ in "/home/test" }, start: { _, _, _, _ in throw TransportError.cancelled },
            backends: { _ in [.herdr, .ultimate] }, awaitAgentVisible: { _ in })
        store.selectedHostID = host.id
        store.selectNewWorkspace()
        #expect(store.launchableBackends == [.herdr])
        #expect(!store.offersBackendChoice)
        #expect(store.workspaces.map(\.backend) == [.herdr])
    }

    @Test("Backend detection carries discovered project instances beside existing backends")
    func detection() throws {
        let output = "__WAYCAR_BACKENDS__\nherdr=path\ntmux=tmux 3.4\n__WAYCAR_BACKENDS_END__\n\0"
            + "/home/test/.ultimate/projects/project-hash\0"
            + #"{"pid":123,"port":4747,"project":"/work/project"}"# + "\0"
            + #"{"name":"Project"}"# + "\0"
        let presence = try #require(HostBackendDetection.presence(fromOutput: Data(output.utf8)))
        #expect(presence.backends == [.herdr, .tmux, .ultimate])
        #expect(presence.ultimate == [Self.instance])
        let legacy = try JSONDecoder().decode(
            HostBackendPresence.self, from: Data(#"{"herdr":true}"#.utf8))
        #expect(legacy.ultimate == nil)
        #expect(legacy.backends == [.herdr])
    }

    @Test("History maps text and collapsed tool steps oldest first with incremental ids")
    func transcript() throws {
        let history = try JSONDecoder().decode(UltimateHistoryResponse.self, from: Data(#"""
        {"entries":[
          {"id":5,"kind":"pi.assistant","model":[{"role":"assistant","stopReason":"stop","content":[{"type":"thinking","thinking":"secret"},{"type":"text","text":"Built it"}]}]},
          {"id":4,"kind":"pi.tool-result","model":[{"role":"toolResult","toolName":"bash","content":"raw output"}]},
          {"id":3,"kind":"pi.assistant","model":[{"role":"assistant","stopReason":"toolUse","content":[{"type":"text","text":"Checking files"},{"type":"toolCall","name":"bash"}]}]},
          {"id":2,"kind":"pi.user","model":[{"role":"user","content":"Build it","timestamp":1793548423900}]},
          {"id":1,"kind":"custom.card","data":{"text":"not a message"}}
        ]}
        """#.utf8))
        let snapshot = UltimateSnapshotBuilder.transcript(history, busy: false, after: nil)
        #expect(snapshot.messages.map(\.id) == ["2", "3:tools", "5"])
        #expect(snapshot.messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(snapshot.messages.map(\.text) == ["Build it", "", "Built it"])
        #expect(snapshot.messages[1].card == .toolSteps(ChatToolStepsSummary(count: 1, summary: "bash")))
        #expect(snapshot.messages.first?.timestamp == Date(timeIntervalSince1970: 1793548423.9))
        #expect(!snapshot.header.turnOpen)
        let incremental = UltimateSnapshotBuilder.transcript(history, busy: true, after: "2")
        #expect(incremental.messages.map(\.id) == ["3:tools", "5"])
        #expect(incremental.header.afterFound)
        #expect(incremental.header.turnOpen)
    }

    @Test("A growing tool round keeps its summary id, so an after cursor still matches")
    func stableToolSummaryID() throws {
        func read(_ entries: String, after: String? = nil) throws -> ChatTranscriptSnapshot {
            let history = try JSONDecoder().decode(
                UltimateHistoryResponse.self, from: Data(#"{"entries":[\#(entries)]}"#.utf8))
            return UltimateSnapshotBuilder.transcript(history, busy: true, after: after)
        }
        let first = #"""
        {"id":3,"kind":"pi.assistant","model":[{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","name":"rg"}]}]},
        {"id":1,"kind":"pi.user","model":[{"role":"user","content":"Go"}]}
        """#
        let grown = #"""
        {"id":5,"kind":"pi.assistant","model":[{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","name":"edit"}]}]},
        """# + first
        #expect(try read(first).messages.map(\.id) == ["1", "3:tools"])
        let next = try read(grown, after: "3:tools")
        // The round grew but its summary id did not move: the cursor matches
        // and the updated summary goes out again for an in-place merge.
        #expect(next.header.afterFound)
        #expect(next.messages.map(\.id) == ["3:tools"])
        #expect(next.messages.first?.card == .toolSteps(ChatToolStepsSummary(count: 2, summary: "rg, edit")))
        let full = try read(grown)
        #expect(full.messages.map(\.id) == ["1", "3:tools"])
        #expect(full.messages[1].card == .toolSteps(ChatToolStepsSummary(count: 2, summary: "rg, edit")))
    }

    @Test("Only single-pick question kinds answer by tap")
    func tapAnswerKinds() {
        func question(_ kind: String) -> ChatQuestion {
            ChatQuestion(ref: "1", text: "Q", kind: kind, options: [])
        }
        #expect(ChatQuestionCardView.tapAnswers(question("choice")))
        #expect(ChatQuestionCardView.tapAnswers(question("confirm")))
        #expect(ChatQuestionCardView.tapAnswers(question("future-kind")))
        #expect(!ChatQuestionCardView.tapAnswers(question("multi")))
        #expect(!ChatQuestionCardView.tapAnswers(question("scale")))
        #expect(!ChatQuestionCardView.tapAnswers(question("text")))
    }

    @Test("Captured history keeps final replies and rich errors without tool narration")
    func capturedTranscript() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/research/ultimate/history-sample.json"))
        let history = try JSONDecoder().decode(UltimateHistoryResponse.self, from: data)
        let snapshot = UltimateSnapshotBuilder.transcript(history, busy: false, after: nil)
        let replies = snapshot.messages.filter { $0.role == .assistant && $0.card == nil }
        #expect(replies.map(\.id) == ["84"])
        #expect(replies.map(\.text) == ["pong"])
        let failures = snapshot.messages.compactMap { message -> ChatFailureCard? in
            guard case .failure(let failure) = message.card else { return nil }
            return failure
        }
        #expect(failures.count == 2)
        #expect(failures.first?.error == "Provider is not configured: google")
        #expect(failures.last?.error.hasPrefix("OAuth refresh failed for openai-codex:") == true)
    }

    @Test("Rich history preserves questions, pointers, failures, dividers and ordered tool counts")
    func richTranscript() throws {
        let history = try JSONDecoder().decode(UltimateHistoryResponse.self, from: Data(#"""
        {"entries":[
          {"id":9,"kind":"future.kind","data":{}},
          {"id":8,"kind":"pi.reset"},
          {"id":7,"kind":"pi.compaction"},
          {"id":6,"kind":"watchdog.failure","data":{"conversation":42,"title":"Build","error":"failed\nfull detail","step":"test"}},
          {"id":5,"kind":"lineage.branched","data":{"branch":42,"intent":"Fix bug"}},
          {"id":4,"kind":"board.asked","data":{"from":42,"summary":"Needs input"}},
          {"id":3,"kind":"pi.assistant","model":[{"role":"assistant","stopReason":"toolUse","content":[{"type":"text","text":"Please choose"},{"type":"toolCall","name":"message","arguments":{"to":"user","text":"Body","questions":[{"ref":"1","text":"Which?","kind":"future-kind","options":[{"key":"a","label":"First","recommended":true}]}]}}]}]},
          {"id":2,"kind":"pi.assistant","model":[{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","name":"read"},{"type":"toolCall","name":"edit"},{"type":"toolCall","name":"read"}]}]},
          {"id":1,"kind":"pi.user","model":[{"role":"user","content":"Start"}]}
        ]}
        """#.utf8))
        let snapshot = UltimateSnapshotBuilder.transcript(history, busy: false, after: nil)
        #expect(snapshot.messages.map(\.id) == ["1", "2:tools", "3:question:0", "3", "4", "5", "6", "7", "8"])
        #expect(snapshot.messages[1].card == .toolSteps(ChatToolStepsSummary(count: 3, summary: "read ×2, edit")))
        guard case .questions(let card) = snapshot.messages[2].card else {
            Issue.record("Missing question card")
            return
        }
        #expect(snapshot.messages[2].text.isEmpty)
        #expect(card.body == "Body")
        #expect(card.questions.first?.kind == "future-kind")
        #expect(card.questions.first?.options.first?.recommended == true)
        #expect(snapshot.messages[3].text == "Please choose")
        #expect(snapshot.messages[5].card == .branch(ChatBranchPointer(conversationId: 42, title: "Fix bug", at: nil)))
        #expect(snapshot.messages[6].card == .failure(ChatFailureCard(conversationId: 42, title: "Build", error: "failed\nfull detail", step: "test")))
        #expect(snapshot.messages[7].card == .divider(kind: "compaction", label: "Conversation compacted"))
        #expect(snapshot.messages[8].card == .divider(kind: "reset", label: "Conversation reset"))
        let incremental = UltimateSnapshotBuilder.transcript(history, busy: false, after: "3:question:0")
        #expect(incremental.header.afterFound)
        #expect(incremental.messages.first?.id == "3")
    }

    @Test("Leader and child chats submit once and history uses a valid before cursor", arguments: [1, 2])
    func submitAndRead(conversation: Int) async throws {
        let session = FakeHostSSHServices(exec: { _, _ in .init(stdout: Data(), stderr: Data(), exitStatus: 0, reachedEOF: true) })
        let inventory = UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n")
        let submitted = UltimateTestHTTPChannel(json: #"{"submissionId":7}"#)
        let history = UltimateTestHTTPChannel(json: #"{"entries":[{"id":9,"kind":"pi.assistant","model":[{"role":"assistant","stopReason":"stop","content":"Hello"}]}]}"#)
        let aborted = UltimateTestHTTPChannel(json: #"{"ok":true}"#)
        for channel in [inventory, submitted, history, aborted] { await session.serveUltimate(channel) }
        let transport = UltimateTransport(session: session, instances: [Self.instance])
        _ = try await transport.sessionSnapshot()
        try await waitUntil("the inventory stream should close") { await inventory.closed }
        let target = "ultimate:project-hash:\(conversation)"
        let agent = try await transport.promptAgent(AgentPromptParams(target: target, text: "Hi\nthere"))
        #expect(agent.paneID == target)
        let wire = String(decoding: await submitted.written, as: UTF8.self)
        #expect(wire.hasPrefix("POST /api/conversations/\(conversation)/submit HTTP/1.1\r\n"))
        let body = try #require(wire.components(separatedBy: "\r\n\r\n").last)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
        #expect(json["text"]?.stringValue == "Hi\nthere")
        #expect(json["whenBusy"]?.stringValue == "steer")
        let transcript = try await transport.readChatTranscript(ChatTranscriptRequest(
            paneID: target, kind: "ultimate", sessionKind: nil, sessionValue: nil,
            cwd: nil, launchedAt: nil, status: .idle, after: nil))
        #expect(transcript.messages.first?.text == "Hello")
        #expect(String(decoding: await history.written, as: UTF8.self).contains("history?before=9007199254740991"))
        try await transport.abortConversation(target)
        #expect(String(decoding: await aborted.written, as: UTF8.self)
            .hasPrefix("POST /api/conversations/\(conversation)/abort HTTP/1.1\r\n"))
        try await transport.close()
        #expect(await session.releaseCount == 1)
        #expect(await session.attachCommands.isEmpty)
    }

    @Test("A reused port serving another project is rejected")
    func decoyIdentity() async throws {
        for (project, home) in [("/work/decoy", Self.instance.home), (Self.instance.project, "/other/home")] {
            let session = FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result() })
            await session.serveUltimate(UltimateTestHTTPChannel(
                sse: "event: conversations\ndata: \(Self.summaries)\n\n", project: project, home: home))
            await #expect(throws: TransportError.self) {
                try await UltimateTransport.open(session: session, instances: [Self.instance])
            }
            #expect(await session.releaseCount == 0)
        }
    }

    @Test("Open and snapshots keep a healthy project when another candidate is stopped")
    func initialPartialOutage() async throws {
        let session = FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result() })
        let stopped = UltimateInstance(id: "stopped", home: "/home/test/.ultimate/projects/stopped",
            project: "/work/stopped", name: "Stopped", pid: 124, port: 4748)
        for _ in 0..<2 {
            await session.serveUltimate(UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n"), port: Self.instance.port)
        }
        let transport = try await UltimateTransport.open(session: session, instances: [stopped, Self.instance])
        let snapshot = try await transport.sessionSnapshot()
        #expect(snapshot.agents.count == 1)
        #expect(snapshot.workspaces.map(\.workspaceID) == ["ultimate:project-hash"])
        #expect(await transport.isConnected)
        try await transport.close()
    }

    @Test("a one-shot inventory cannot replace a stream installed while it waited", arguments: [false, true])
    func oneShotCannotOverwriteNewStream(fails: Bool) async throws {
        let session = FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result() })
        let gate = ScriptedTransportCallGate()
        let stale = UltimateTestHTTPChannel(
            sse: "event: conversations\ndata: \(fails ? "[" : Self.summaries)\n\n", gate: gate)
        let live = UltimateTestHTTPChannel(
            sse: "event: conversations\ndata: [{\"id\":1,\"busy\":false}]\n\n")
        await session.serveUltimate(stale)
        await session.serveUltimate(live)
        let transport = UltimateTransport(session: session, instances: [Self.instance])
        let snapshot = Task { try await transport.sessionSnapshot() }
        await gate.waitForEntry()
        let stream = try await transport.subscribeToEvents([])
        #expect(try await transport.sessionSnapshot().agents.map(\.agentStatus) == [.idle])
        await gate.open()
        let result = await snapshot.result
        #expect(try result.get().agents.map(\.agentStatus) == [.idle])
        #expect(try await transport.sessionSnapshot().agents.map(\.agentStatus) == [.idle])
        #expect(await transport.isConnected)
        await stream.end()
        try await transport.close()
    }

    @Test("One project retries independently, rejects a decoy, and returns without ending healthy chats")
    func independentProjects() async throws {
        let session = FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result() })
        let other = UltimateInstance(id: "other", home: "/home/test/.ultimate/projects/other",
            project: "/work/other", name: "Other", pid: 124, port: 4748)
        let summaries = "event: conversations\ndata: \(Self.summaries)\n\n"
        let otherSummaries = "event: conversations\ndata: [{\"id\":10,\"busy\":false,\"cwd\":\"/work/other\"}]\n\n"
        let first = UltimateTestHTTPChannel(sse: summaries)
        let second = UltimateTestHTTPChannel(sse: otherSummaries, project: other.project, home: other.home)
        await session.serveUltimate(first, port: Self.instance.port)
        await session.serveUltimate(second, port: other.port)
        let transport = UltimateTransport(session: session, instances: [other, Self.instance], retryDelays: [.milliseconds(50)])
        let stream = try await transport.subscribeToEvents([])
        let probe = UltimateStreamProbe()
        let consumer = Task {
            do { for try await _ in stream.events { await probe.changed() } } catch {}
            await probe.finished()
        }
        #expect(try await transport.sessionSnapshot().agents.count == 2)
        await second.endStream()
        try await waitUntil("the ended instance's agents should leave") {
            try await transport.sessionSnapshot().agents.count == 1
        }
        #expect(try await transport.sessionSnapshot().agents.map(\.workspaceID) == ["ultimate:project-hash"])
        #expect(await transport.isConnected)
        #expect(!(await probe.ended))
        // ping skips the down project and proves the remaining one.
        await session.serveUltimate(UltimateTestHTTPChannel(sse: summaries), port: Self.instance.port)
        #expect(try await transport.ping().backend == .ultimate)
        let decoy = UltimateTestHTTPChannel(sse: otherSummaries, project: "/decoy", home: other.home)
        await session.serveUltimate(decoy, port: other.port)
        try await waitUntil("the decoy instance should be closed") { await decoy.closed }
        #expect(try await transport.sessionSnapshot().agents.count == 1)
        await session.serveUltimate(UltimateTestHTTPChannel(sse: otherSummaries, project: other.project, home: other.home), port: other.port)
        try await waitUntil("the returning instance's agents should come back") {
            try await transport.sessionSnapshot().agents.count == 2
        }
        #expect(try await transport.sessionSnapshot().agents.count == 2)
        #expect(!(await probe.ended))
        // Initial inventories, removal, return.
        try await waitUntil("every inventory change should be published") { await probe.changes >= 4 }
        await stream.end()
        await consumer.value
        try await transport.close()
    }

    @Test("Every project failing its first retry ends the transport for lock re-discovery")
    func allProjectsDown() async throws {
        let session = FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result() })
        let channel = UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n")
        await session.serveUltimate(channel)
        let transport = UltimateTransport(session: session, instances: [Self.instance], retryDelays: [.milliseconds(10)])
        let stream = try await transport.subscribeToEvents([])
        await channel.endStream()
        let probe = UltimateStreamProbe()
        let consumer = Task {
            do { for try await _ in stream.events {} }
            catch { await probe.finished(failed: true); return }
            await probe.finished()
        }
        try await waitUntil("the event stream should end") { await probe.ended }
        #expect(await probe.failed)
        #expect(!(await transport.isConnected))
        await stream.end()
        await consumer.value
        try await transport.close()
    }

    @Test("The board always subscribes to conversation 1, with a different lead or no lead", arguments: [true, false])
    func boardSubscription(hasLead: Bool) async throws {
        let session = FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result() })
        let board = #"{"kind":"board","value":{"messages":[{"from":2,"to":"user","reply":true,"state":"delivered"},{"from":3,"to":"user","reply":true,"state":"answered"}],"next":3}}"#
        let summaries = hasLead
            ? #"[{"id":7,"label":"agent","title":"@ultimate","busy":false},{"id":2,"branchOf":{"conversationId":7,"at":1},"busy":false}]"#
            : #"[{"id":2,"parentConversationId":1,"busy":false}]"#
        let channel = UltimateTestHTTPChannel(sse: "event: stream\ndata: {\"id\":\"abcd\"}\n\nevent: conversations\ndata: \(summaries)\n\nevent: doc\ndata: 0\ndata: \(board)\n\n")
        let subscription = UltimateTestHTTPChannel(json: "{}")
        await session.serveUltimate(channel)
        await session.serveUltimate(subscription)
        let transport = UltimateTransport(session: session, instances: [Self.instance])
        let stream = try await transport.subscribeToEvents([])
        try await waitUntil("the subscription should be written and any question counted") {
            if hasLead { return await transport.ultimateOpenQuestions()["ultimate:project-hash:7"] == 1 }
            return !(await subscription.written.isEmpty)
        }
        if hasLead {
            #expect(await transport.ultimateOpenQuestions() == ["ultimate:project-hash:7": 1])
            let child = try #require(await transport.ultimateConversationChildren()["ultimate:project-hash:7"]?.first)
            #expect(child.openQuestions == 1)
            #expect(child.needsUser)
            #expect(child.status == .idle)
        } else {
            #expect(await transport.ultimateOpenQuestions().isEmpty)
        }
        let request = String(decoding: await subscription.written, as: UTF8.self)
        #expect(request.contains("POST /api/events/abcd/0 HTTP/1.1"))
        let body = try #require(request.components(separatedBy: "\r\n\r\n").last)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
        #expect(json["conversation"] == .number(1))
        #expect(json["docs"] == .array([.string("board")]))
        #expect(json["view"] == .bool(false))
        await stream.end()
        try await transport.close()
    }

    @Test("A branch awaiting the user still sends a reply through the native composer submit")
    @MainActor
    func waitingBranchNativeSubmit() async throws {
        let services = FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result() })
        let board = #"{"kind":"board","value":{"messages":[{"from":2,"to":"user","reply":true,"state":"delivered"}],"next":2}}"#
        let events = UltimateTestHTTPChannel(sse: "event: stream\ndata: {\"id\":\"abcd\"}\n\nevent: conversations\ndata: \(Self.summaries)\n\nevent: doc\ndata: 0\ndata: \(board)\n\n")
        let submitted = UltimateTestHTTPChannel(json: #"{"submissionId":42}"#)
        for channel in [events, UltimateTestHTTPChannel(json: "{}"), submitted] {
            await services.serveUltimate(channel)
        }
        let transport = UltimateTransport(session: services, instances: [Self.instance])
        let stream = try await transport.subscribeToEvents([])
        try await waitUntil("the child should need the user") {
            await transport.ultimateConversationChildren()["ultimate:project-hash:1"]?.first?.needsUser == true
        }
        let info = try #require(try await transport.sessionSnapshot().agents.first)
        var leader = ConsoleAgent(hostID: UUID(), hostName: "Mac", agent: Agent(info),
                                  workspaceLabel: "Project", repositoryCheckout: nil, backend: .ultimate)
        leader.ultimateChildren = await transport.ultimateConversationChildren()[info.paneID] ?? []
        #expect(leader.ultimateChildren.first?.needsUser == true)
        let branch = try #require(leader.ultimateChild("ultimate:project-hash:2"))
        #expect(branch.agent.status == .idle)
        let composer = AgentComposerStore(target: branch.agent.paneID, initialStatus: branch.agent.status) {
            try await transport.promptAgent($0)
        }
        // Detail binds this terminal-only path even for native chats. It
        // must never be selected just because the board asks a question.
        composer.bindBlockedInsert { text in
            try await transport.sendPaneInput(.init(paneID: branch.agent.paneID, text: text))
        }
        #expect(await composer.send("Yes, continue") == .deliveredViaPrompt)
        let request = String(decoding: await submitted.written, as: UTF8.self)
        #expect(request.contains("POST /api/conversations/2/submit HTTP/1.1"))
        #expect(request.contains("Yes, continue"))
        #expect(request.components(separatedBy: "POST ").count == 2)
        composer.cancelQueue()
        await stream.end()
        try await transport.close()
    }

    @Test("SSE subscription seeds the inventory before returning and closes its channel")
    func events() async throws {
        let session = FakeHostSSHServices(exec: { _, _ in .init(stdout: Data(), stderr: Data(), exitStatus: 0, reachedEOF: true) })
        let channel = UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n")
        await session.serveUltimate(channel)
        let transport = UltimateTransport(session: session, instances: [Self.instance])
        let events = try await transport.subscribeToEvents([])
        let snapshot = try await transport.sessionSnapshot()
        #expect(snapshot.agents.map(\.agentStatus) == [.working])
        await events.end()
        try await transport.close()
        // The HTTP stream closes asynchronously when its reader is cancelled.
        try await waitUntil("the HTTP stream should close") { await channel.closed }
    }

    // MARK: Transport lifetime (CORE-10)

    private static func session() -> FakeHostSSHServices {
        FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result() })
    }

    private static func error<T>(_ operation: () async throws -> T) async -> (any Error)? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    @Test("Distrust ends the events cleanly and refuses calls, but the hold stays until close")
    func distrustKeepsTheHold() async throws {
        let session = Self.session()
        await session.serveUltimate(UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n"))
        let transport = UltimateTransport(session: session, instances: [Self.instance])
        let stream = try await transport.subscribeToEvents([])
        await transport.transportDistrusted()
        // The seeding inventory change is buffered ahead of the clean end.
        var endedCleanly = false
        do {
            for try await _ in stream.events {}
            endedCleanly = true
        } catch {
            Issue.record("distrust failed the stream with \(error)")
        }
        #expect(endedCleanly)
        #expect(await Self.error { try await transport.sessionSnapshot() } as? TransportError == .cancelled)
        #expect(await Self.error { try await transport.subscribeToEvents([]) } as? TransportError == .cancelled)
        #expect(!(await transport.isConnected))
        #expect(await session.releaseCount == 0)
        try await transport.close()
        try await transport.close()
        #expect(await session.releaseCount == 1)
    }

    @Test("A live stream refuses a second; an ended one is replaced, and ending it again leaves the replacement")
    func streamReplacement() async throws {
        let session = Self.session()
        let sse = "event: conversations\ndata: \(Self.summaries)\n\n"
        await session.serveUltimate(UltimateTestHTTPChannel(sse: sse))
        await session.serveUltimate(UltimateTestHTTPChannel(sse: sse))
        let transport = UltimateTransport(session: session, instances: [Self.instance])
        let first = try await transport.subscribeToEvents([])
        #expect(await Self.error { try await transport.subscribeToEvents([]) } as? TransportError
            == .eventsChannelAlreadyOpen)
        await first.end()
        let second = try await transport.subscribeToEvents([])
        await first.end()
        #expect(await Self.error { try await transport.subscribeToEvents([]) } as? TransportError
            == .eventsChannelAlreadyOpen)
        #expect(try await transport.sessionSnapshot().agents.map(\.agentStatus) == [.working])
        #expect(await transport.isConnected)
        await second.end()
        try await transport.close()
    }

    @Test("Once every project is offline the transport refuses snapshots and new streams")
    func lostTransportRefuses() async throws {
        let session = Self.session()
        let channel = UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n")
        await session.serveUltimate(channel)
        let transport = UltimateTransport(session: session, instances: [Self.instance], retryDelays: [.milliseconds(10)])
        let stream = try await transport.subscribeToEvents([])
        await channel.endStream()
        var iterator = stream.events.makeAsyncIterator()
        let failure = await Self.error { while try await iterator.next() != nil {} }
        #expect(failure as? TransportError == .channelFailed(detail: "Every Ultimate project is offline."))
        let offline = TransportError.channelFailed(detail: "Every Ultimate project is offline.")
        #expect(await Self.error { try await transport.sessionSnapshot() } as? TransportError == offline)
        #expect(await Self.error { try await transport.subscribeToEvents([]) } as? TransportError == offline)
        #expect(await Self.error { try await transport.ping() } as? TransportError == offline)
        try await transport.close()
        #expect(await session.releaseCount == 1)
        #expect(await Self.error { try await transport.sessionSnapshot() } as? TransportError == .cancelled)
    }

    @Test("Close while a subscribe waits for its first inventory fails the subscribe")
    func closeDuringSubscribe() async throws {
        let session = Self.session()
        let gate = ScriptedTransportCallGate()
        await session.serveUltimate(UltimateTestHTTPChannel(
            sse: "event: conversations\ndata: \(Self.summaries)\n\n", gate: gate))
        let transport = UltimateTransport(session: session, instances: [Self.instance])
        let subscribing = Task { try await transport.subscribeToEvents([]) }
        await gate.waitForEntry()
        try await transport.close()
        await gate.open()
        #expect(await Self.error { try await subscribing.value } as? TransportError == .cancelled)
        #expect(await session.releaseCount == 1)
    }

    @Test("A failed ping with no stream forgets every project")
    func failedPingForgetsProjects() async throws {
        let session = Self.session()
        await session.serveUltimate(UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n"))
        let transport = try await UltimateTransport.open(session: session, instances: [Self.instance])
        #expect(await transport.isConnected)
        #expect(await Self.error { try await transport.ping() } != nil)
        #expect(!(await transport.isConnected))
        try await transport.close()
    }

    // MARK: Per-project stream (CORE-11)

    @Test("A project that publishes again starts its retries over, so a later outage is not its last")
    func publishingResetsFailures() async throws {
        let session = Self.session()
        let first = UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n")
        let second = UltimateTestHTTPChannel(sse: "event: conversations\ndata: [{\"id\":1,\"busy\":false}]\n\n")
        let third = UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n")
        for channel in [first, second, third] { await session.serveUltimate(channel) }
        let transport = UltimateTransport(session: session, instances: [Self.instance], retryDelays: [.milliseconds(10)])
        let stream = try await transport.subscribeToEvents([])
        let probe = UltimateStreamProbe()
        let consumer = Task {
            do { for try await _ in stream.events {} } catch { await probe.finished(failed: true); return }
            await probe.finished()
        }
        await first.endStream()
        try await waitUntil("the retry publishes the second inventory") {
            try await transport.sessionSnapshot().agents.map(\.agentStatus) == [.idle]
        }
        await second.endStream()
        try await waitUntil("a later outage retries again instead of ending the transport") {
            try await transport.sessionSnapshot().agents.map(\.agentStatus) == [.working]
        }
        #expect(await transport.isConnected)
        #expect(!(await probe.ended))
        await stream.end()
        await consumer.value
        try await transport.close()
    }

    @Test("Conversations before the identity check are refused; the retry seeds the project")
    func conversationsBeforeIdentityRetry() async throws {
        let session = Self.session()
        let early = UltimateTestHTTPChannel(rawSSE: "event: conversations\ndata: \(Self.summaries)\n\n")
        let proper = UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n")
        await session.serveUltimate(early)
        await session.serveUltimate(proper)
        let transport = UltimateTransport(session: session, instances: [Self.instance], retryDelays: [.milliseconds(10)])
        let stream = try await transport.subscribeToEvents([])
        try await waitUntil("the retry seeds the project") {
            try await transport.sessionSnapshot().agents.count == 1
        }
        try await waitUntil("the refused stream's channel closes") { await early.closed }
        await stream.end()
        try await transport.close()
    }

    @Test("Subscribe returns once every project published or failed once, with the published inventory")
    func subscribeWaitsForEveryProjectOnce() async throws {
        let session = Self.session()
        let stopped = UltimateInstance(id: "stopped", home: "/home/test/.ultimate/projects/stopped",
            project: "/work/stopped", name: "Stopped", pid: 124, port: 4748)
        await session.serveUltimate(
            UltimateTestHTTPChannel(sse: "event: conversations\ndata: \(Self.summaries)\n\n"), port: Self.instance.port)
        let transport = UltimateTransport(session: session, instances: [stopped, Self.instance], retryDelays: [.seconds(30)])
        let stream = try await transport.subscribeToEvents([])
        #expect(try await transport.sessionSnapshot().agents.count == 1)
        #expect(await transport.isConnected)
        await stream.end()
        try await transport.close()
    }
}

private actor UltimateTestHTTPChannel: UltimateByteChannel {
    private var response: Data?
    private let streaming: Bool
    private var gate: ScriptedTransportCallGate?
    private var ended = false
    private(set) var written = Data()
    private(set) var closed = false

    init(json: String) {
        response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)".utf8)
        streaming = false
    }

    init(sse: String, project: String = "/work/project", home: String = "/home/test/.ultimate/projects/project-hash",
         gate: ScriptedTransportCallGate? = nil) {
        self.gate = gate
        let system = "event: system\ndata: {\"project\":{\"root\":\"\(project)\"},\"persistence\":{\"path\":\"\(home)/state.sqlite\"}}\n\n"
        let ui = "event: ui\ndata: {\"value\":{\"ext.conversations.concluded\":[]}}\n\n"
        response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n\(system)\(ui)\(sse)".utf8)
        streaming = true
    }

    /// `sse` exactly as given: no identity or shared UI ahead of it.
    init(rawSSE: String) {
        response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n\(rawSSE)".utf8)
        streaming = true
    }

    func endStream() { ended = true }

    func write(_ data: Data, timeout: Duration) { written.append(data) }
    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        if let response {
            self.response = nil
            if let gate {
                self.gate = nil
                await gate.waitUntilOpen()
            }
            return response
        }
        if streaming {
            while !ended && !closed { try await Task.sleep(for: .milliseconds(10)) }
        }
        return nil
    }
    func close(timeout: Duration) { closed = true }
}

private actor UltimateStreamProbe {
    private(set) var ended = false
    private(set) var changes = 0
    private(set) var failed = false
    func changed() { changes += 1 }
    func finished(failed: Bool = false) { ended = true; self.failed = failed }
}
