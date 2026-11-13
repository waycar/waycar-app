import Foundation
import Testing

@testable import Waycar

@Suite("Zellij snapshot builder")
struct ZellijSnapshotBuilderTests {
    @Test(arguments: ["Idle", "Working", "Done", "Blocked", "Error"])
    func reportedStatusPrecedesHookAndScreen(_ word: String) throws {
        var frame = ZellijFixtures.frame()
        frame.panes["fixture"]?[1].programStatus = [
            .init(id: "child", state: "Blocked"), .init(state: word, app: "claude-code"),
        ]
        frame.documents["zellij:fixture/terminal_0"] = ZellijFixtures.document(status: "idle")
        let snapshot = ZellijSnapshotBuilder.snapshot(
            frame: frame, screenVerdicts: ["zellij:fixture/terminal_0": .working])
        let agent = try #require(snapshot.agents.first)
        #expect(agent.agent == "claude")
        #expect(agent.agentStatus == (word == "Error" ? .blocked : ZellijPaneState.status(word.lowercased())))
    }

    @Test func hookStalenessScreenAndUnknown() throws {
        var frame = ZellijFixtures.frame(panes: #"[{"id":0,"tab_id":7,"pane_command":"claude"}]"#)
        let id = "zellij:fixture/terminal_0"
        frame.documents[id] = ZellijFixtures.document(status: "done")
        let fresh = ZellijSnapshotBuilder.snapshot(
            frame: frame, screenVerdicts: [id: .blocked], firstSeenMs: ["fixture": 100])
        #expect(fresh.agents.first?.agentStatus == .done)
        #expect(fresh.agents.first?.agent == "codex")
        #expect(fresh.agents.first?.agentSession?.kind == .path)
        #expect(fresh.agents.first?.stateChangeSeq == 3)
        let stale = ZellijSnapshotBuilder.snapshot(
            frame: frame, screenVerdicts: [id: .blocked], firstSeenMs: ["fixture": 101])
        #expect(stale.agents.first?.agentStatus == .blocked)
        #expect(stale.agents.first?.agent == "claude")
        #expect(stale.agents.first?.agentSession == nil)
        frame.documents = [:]
        #expect(ZellijSnapshotBuilder.snapshot(frame: frame).agents.first?.agentStatus == .unknown)
    }

    @Test func topologyKindsAndGeneration() throws {
        let frame = ZellijFixtures.frame(
            panes: #"""
                [{"id":4,"is_plugin":true,"tab_id":0},
                 {"id":5,"is_suppressed":true,"tab_id":0},
                 {"id":2,"tab_id":9,"tab_position":1,"tab_name":"Second","pane_command":"codex"},
                 {"id":1,"tab_id":8,"tab_position":0,"tab_name":"First","pane_command":"bash","pane_cwd":"/work"}]
                """#)
        let snapshot = ZellijSnapshotBuilder.snapshot(frame: frame, generations: ["fixture": 3])
        #expect(snapshot.workspaces.count == 1)
        #expect(snapshot.workspaces.first?.workspaceID == "zellij:fixture")
        #expect(snapshot.tabs.map(\.tabID) == ["zellij:fixture/tab_8", "zellij:fixture/tab_9"])
        #expect(snapshot.panes.map(\.paneID) == ["zellij:fixture/terminal_1", "zellij:fixture/terminal_2"])
        #expect(snapshot.panes.first?.terminalID == "zellij:fixture/terminal_1@3")
        #expect(snapshot.agents.map(\.agent) == ["codex"])
        #expect(snapshot.workspaces.first?.paneCount == 2)
        #expect(ZellijSnapshotBuilder.shellActivities(frame: frame)["zellij:fixture/terminal_1"] == .idle)
        let row = try #require(frame.panes["fixture"]?.last)
        #expect(ZellijSnapshotBuilder.kind(row, document: ZellijFixtures.document(kind: "omp")) == "omp")
    }

    @Test func paneFlagsNeverClaimClientOrTabFocus() {
        let frame = ZellijFixtures.frame(
            panes:
                #"[{"id":0,"tab_id":7,"tab_position":0,"is_focused":true},{"id":1,"tab_id":8,"tab_position":1,"is_focused":true}]"#
        )
        let snapshot = ZellijSnapshotBuilder.snapshot(frame: frame)
        #expect(snapshot.tabs.allSatisfy { !$0.focused })
        #expect(snapshot.panes.allSatisfy { !$0.focused })
        #expect(snapshot.workspaces.first?.activeTabID == "zellij:fixture/tab_7")
    }

    @Test func agentNameAndRenameUseTheSameVisibleSource() throws {
        var frame = ZellijFixtures.frame(
            panes:
                #"[{"id":0,"tab_id":7,"tab_name":"Task","title":"First","pane_command":"claude"},{"id":1,"tab_id":7,"is_plugin":true},{"id":2,"tab_id":7,"is_suppressed":true}]"#
        )
        let first = try #require(ZellijPaneID("zellij:fixture/terminal_0"))
        #expect(ZellijSnapshotBuilder.snapshot(frame: frame).agents.first?.name == "Task")
        #expect(ZellijSnapshotBuilder.renameTarget(for: first, frame: frame) == .tab(7))
        frame.panes["fixture"]?.append(
            ZellijPaneRecord(id: 3, title: "Second", tabID: 7, tabName: "Task", paneCommand: "codex"))
        #expect(ZellijSnapshotBuilder.snapshot(frame: frame).agents.map(\.name) == ["First", "Second"])
        #expect(ZellijSnapshotBuilder.renameTarget(for: first, frame: frame) == .pane)
    }

    @Test func doneOverlayExpiresWithReportOrGeneration() throws {
        let row = try #require(ZellijFixtures.frame().panes["fixture"]?.last)
        var done = row
        done.programStatus = [.init(state: "Done", app: "claude", updatedMs: 100)]
        let status = ZellijSnapshotBuilder.status(done, document: nil, screen: nil)
        var overlay = ZellijDoneOverlay()
        overlay.markSeen(terminalID: "p@1", status: status)
        #expect(overlay.presented(status, terminalID: "p@1") == .idle)
        #expect(overlay.presented(status, terminalID: "p@2") == .done)
        var next = status
        next.updatedMs = 101
        #expect(overlay.presented(next, terminalID: "p@1") == .done)
        overlay.prune(keeping: ["p@1": .init(status: .working, source: .program)])
        #expect(overlay.presented(status, terminalID: "p@1") == .done)
        overlay.markSeen(terminalID: "zellij:fixture/terminal_0@0", status: status)
        let frame = ZellijFrame(sessions: [.init(name: "fixture", closed: false)], panes: ["fixture": [done]])
        #expect(
            ZellijSnapshotBuilder.snapshot(frame: frame, overlays: overlay).agents.first?.agentStatus == .idle
        )
    }

    @Test func shellCommandAndAgentSession() {
        let frame = ZellijFixtures.frame(
            panes:
                #"[{"id":0,"tab_id":0,"pane_command":"bash -c sleep 3"},{"id":1,"tab_id":0,"pane_command":"sleep 3"}]"#
        )
        let activities = ZellijSnapshotBuilder.shellActivities(frame: frame)
        #expect(activities["zellij:fixture/terminal_0"] == .running(command: "bash -c sleep 3"))
        #expect(activities["zellij:fixture/terminal_1"] == .running(command: "sleep 3"))
        let state = ZellijPaneState.decode(
            Data(#"{"version":1,"pane":"zellij:fixture/terminal_0","session":"abc"}"#.utf8))
        #expect(ZellijSnapshotBuilder.agentSession(state, kind: "claude")?.kind == .id)
    }
}
