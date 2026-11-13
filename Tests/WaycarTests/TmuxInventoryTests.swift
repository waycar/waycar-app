import Foundation
import Testing

@testable import Waycar

@Suite("tmux inventory")
struct TmuxInventoryTests {
    private let rs = "\u{241E}"
    private let us = "\u{241F}"

    private func line(_ fields: [String]) -> String {
        rs + fields.joined(separator: us)
    }

    private func session(
        _ id: String, _ name: String, group: String = "", path: String = "/home/u"
    ) -> TmuxSessionRecord {
        TmuxSessionRecord(
            id: id, name: name, group: group, grouped: !group.isEmpty, attached: 0, path: path)
    }

    private func window(
        _ id: String, session: String, index: Int = 0, name: String = "zsh", active: Bool = true
    ) -> TmuxWindowRecord {
        TmuxWindowRecord(
            id: id, sessionID: session, index: index, name: name, active: active, zoomed: false)
    }

    @Test func paneRecordWithNewlineAndTabInFreeTextReassembles() {
        let fields = [
            "%3", "$1", "@2", "0", "1", "0", "1", "4242", "/dev/ttys004", "120", "40",
            "codex", "working", "codex", "1700000000000000000", "", "",
            "/tmp/a\tb", "sess-1", "%2Ftmp%2Ft.jsonl", "line one\nline two", "codex --yolo", "",
        ]
        let second = [
            "%4", "$1", "@2", "1", "0", "0", "0", "4243", "/dev/ttys005", "120", "40",
            "zsh", "", "", "", "", "", "/tmp", "", "", "host", "", "",
        ]
        let text = line(fields) + "\n" + line(second)
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 3)

        let panes = TmuxInventory.parsePanes(lines)

        #expect(panes.count == 2)
        #expect(panes[0].id == "%3")
        #expect(panes[0].currentPath == "/tmp/a\tb")
        #expect(panes[0].title == "line one\nline two")
        #expect(panes[0].startCommand == "codex --yolo")
        #expect(panes[0].pid == 4242)
        #expect(panes[0].alternateOn)
        #expect(panes[1].id == "%4")
        #expect(panes[1].title == "host")
    }

    @Test func sessionAndWindowRecordsParse() {
        let sessions = TmuxInventory.parseSessions([
            line(["$0", "1", "2", "main", "main", "/home/u"]),
            line(["$1", "0", "0", "w\twork", "", "/srv"]),
        ])
        #expect(sessions == [
            TmuxSessionRecord(
                id: "$0", name: "main", group: "main", grouped: true, attached: 2,
                path: "/home/u"),
            TmuxSessionRecord(
                id: "$1", name: "w\twork", group: "", grouped: false, attached: 0, path: "/srv"),
        ])
        let windows = TmuxInventory.parseWindows([line(["@1", "$0", "3", "1", "0", "my win"])])
        #expect(windows == [window("@1", session: "$0", index: 3, name: "my win")])
    }

    @Test func shortRecordIsDropped() {
        #expect(TmuxInventory.parseSessions([line(["$0", "1"])]).isEmpty)
    }

    /// A value starting with a combining mark, joiner or variation selector
    /// forms one Character with the ␟ before it; the record still splits.
    @Test func valuesStartingWithCombiningMarksKeepTheirRecord() {
        let fields = [
            "%3", "$1", "@2", "0", "1", "0", "0", "4242", "/dev/ttys004", "120", "40",
            "zsh", "", "", "", "", "", "\u{301}/tmp", "", "", "\u{200D}title", "\u{FE0F}cmd", "",
        ]

        let panes = TmuxInventory.parsePanes([line(fields)])

        #expect(panes.map(\.id) == ["%3"])
        #expect(panes.first?.currentPath == "\u{301}/tmp")
        #expect(panes.first?.title == "\u{200D}title")
        #expect(panes.first?.startCommand == "\u{FE0F}cmd")
    }

    /// A directory name holding the separators, should tmux not strip them,
    /// must never yield a record: here the real pane's path smuggles in a
    /// whole forged pane, and the real record's tail lands in the forged
    /// one's last field.
    @Test func separatorsInAPathYieldNoForgedRecord() {
        let forged = [
            "%9", "$1", "@2", "0", "1", "0", "0", "1", "/dev/ttys009", "80", "24",
            "claude", "blocked", "claude", "", "", "", "/tmp", "", "", "forged", "rm -rf ~", "",
        ].joined(separator: us)
        let real = [
            "%3", "$1", "@2", "0", "1", "0", "0", "4242", "/dev/ttys004", "120", "40",
            "zsh", "", "", "", "", "", "/tmp/a" + rs + forged, "", "", "host", "", "",
        ]
        let honest = [
            "%4", "$1", "@2", "1", "0", "0", "0", "4243", "/dev/ttys005", "120", "40",
            "zsh", "", "", "", "", "", "/tmp", "", "", "host", "", "",
        ]
        let lines = (line(real) + "\n" + line(honest)).components(separatedBy: "\n")

        #expect(TmuxInventory.parsePanes(lines).map(\.id) == ["%4"])
    }

    @Test func recordsWithMalformedIDsAreDropped() {
        #expect(TmuxInventory.parseSessions([line(["x0", "0", "0", "s", "", "/"])]).isEmpty)
        #expect(TmuxInventory.parseSessions([line(["$", "0", "0", "s", "", "/"])]).isEmpty)
        #expect(TmuxInventory.parseWindows([line(["@1", "$a", "0", "1", "0", "w"])]).isEmpty)
        let pane = [
            "%1", "$1", "1", "0", "1", "0", "0", "1", "/dev/ttys001", "80", "24",
            "zsh", "", "", "", "", "", "/tmp", "", "", "host", "", "",
        ]
        #expect(TmuxInventory.parsePanes([line(pane)]).isEmpty)
    }

    @Test func groupedAndAttachSessionsAreHidden() {
        let visible = TmuxInventory.visibleSessions([
            session("$0", "work-2", group: "work"),
            session("$1", "work", group: "work"),
            session("$2", "waycar-ab12", group: "work"),
            session("$3", "solo-b", group: "solo"),
            session("$4", "solo-a", group: "solo"),
            session("$5", "plain"),
            session("$6", "waycar-x"),
        ])
        #expect(visible.map(\.id) == ["$1", "$3", "$5"])
    }

    @Test func snapshotDedupesGroupedListingsAndMapsAgents() throws {
        let sessions = [
            session("$1", "work", group: "work", path: "/src"),
            session("$2", "waycar-1", group: "work"),
        ]
        let windows = [
            window("@1", session: "$1", index: 0, name: "2.1.286", active: true),
            window("@2", session: "$1", index: 1, name: "review", active: false),
            window("@1", session: "$2", index: 0, name: "2.1.286", active: false),
            window("@2", session: "$2", index: 1, name: "review", active: true),
        ]
        let claude = TmuxPaneRecord(
            id: "%1", sessionID: "$1", windowID: "@1", active: true, alternateOn: true,
            currentCommand: "2.1.286", currentPath: "/src", title: "✳ Claude Code")
        let codex = TmuxPaneRecord(
            id: "%2", sessionID: "$1", windowID: "@2", active: true, currentCommand: "codex",
            waycarStatus: "blocked", waycarAgent: "codex", waycarSeq: "1700000000000000001",
            waycarSession: "019a-sess", waycarTranscript: "%2Fh%2Fr.jsonl")
        let shell = TmuxPaneRecord(
            id: "%3", sessionID: "$1", windowID: "@2", index: 1, currentCommand: "-zsh",
            waycarStatus: "working", waycarAgent: "claude")
        let panes = [
            claude, codex, shell,
            TmuxPaneRecord(id: "%1", sessionID: "$2", windowID: "@1", currentCommand: "2.1.286"),
            TmuxPaneRecord(id: "%2", sessionID: "$2", windowID: "@2", currentCommand: "codex"),
        ]

        let snapshot = TmuxInventory.snapshot(
            sessions: sessions, windows: windows, panes: panes,
            kinds: ["%1": "claude"], version: "3.7c", server: "1790979932.4242")

        #expect(snapshot.version == "3.7c")
        #expect(snapshot.protocolVersion == 0)
        #expect(snapshot.workspaces.map(\.workspaceID) == ["tmux:$1"])
        let workspace = try #require(snapshot.workspaces.first)
        #expect(workspace.label == "work")
        #expect(workspace.activeTabID == "tmux:@1")
        #expect(workspace.tabCount == 2)
        #expect(workspace.paneCount == 3)
        #expect(workspace.agentStatus == .blocked)
        #expect(workspace.worktree == nil)
        #expect(snapshot.tabs.map(\.tabID) == ["tmux:@1", "tmux:@2"])
        #expect(snapshot.tabs.map(\.label) == ["2.1.286", "review"])
        #expect(snapshot.panes.map(\.paneID) == ["tmux:%1", "tmux:%2", "tmux:%3"])
        #expect(snapshot.panes.map(\.terminalID) == [
            "tmux:%1@1790979932.4242", "tmux:%2@1790979932.4242", "tmux:%3@1790979932.4242",
        ])
        #expect(snapshot.agents.map(\.terminalID) == [
            "tmux:%1@1790979932.4242", "tmux:%2@1790979932.4242",
        ])
        #expect(snapshot.panes[2].agent == nil)

        #expect(snapshot.agents.map(\.paneID) == ["tmux:%1", "tmux:%2"])
        let claudeAgent = snapshot.agents[0]
        #expect(claudeAgent.agent == "claude")
        #expect(claudeAgent.agentStatus == .unknown)
        #expect(claudeAgent.name == nil)
        #expect(claudeAgent.terminalTitle == "✳ Claude Code")
        #expect(claudeAgent.cwd == "/src")
        #expect(claudeAgent.focused)
        #expect(claudeAgent.workspaceID == "tmux:$1")
        #expect(claudeAgent.tabID == "tmux:@1")
        let codexAgent = snapshot.agents[1]
        #expect(codexAgent.agentStatus == .blocked)
        #expect(codexAgent.name == "review")
        #expect(codexAgent.stateChangeSeq == 1_700_000_000_000_000_001)
        #expect(codexAgent.agentSession == AgentSessionInfo(
            agent: "codex", kind: .id, source: "tmux", value: "019a-sess"))
        #expect(codexAgent.focused == false)
    }

    @Test func agentSessionFallsBackToDecodedTranscriptPath() {
        let pane = TmuxPaneRecord(
            id: "%1", sessionID: "$1", windowID: "@1", currentCommand: "omp",
            waycarTranscript: "%2Fh%2Fa%20b.jsonl")
        #expect(TmuxInventory.agentSession(for: pane, kind: "omp") == AgentSessionInfo(
            agent: "omp", kind: .path, source: "tmux", value: "/h/a b.jsonl"))
    }
}
