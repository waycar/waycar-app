import Foundation
import Testing

@testable import Waycar

// herdr-core terminals mapped onto herdr's snapshot (design §6). The records
// are hand-built after the captured ones (`docs/research/herdr-core/`):
// addresses `t7`/`t1b`/`box/t3`, status words as programs report them,
// `herdr.space`/`herdr.tab` labels as the Herdr app writes them.

private let hello = CoreHello(
    coreID: "0123456789abcdef0123456789abcdef", coreName: "box", version: "0.1.14", generation: 1)

private func term(
    _ address: String, name: String? = nil, labels: [String: String] = [:],
    argv: [String] = ["/usr/bin/bash"], cwd: String = "/home/me/alpha", state: String = "live",
    pid: Int? = nil, status: CoreStatus? = nil, statusMs: Int64? = nil, reported: Bool? = nil,
    turn: Int = 0, title: String = "", foreground: CoreForeground? = nil
) -> CoreTerminal {
    CoreTerminal(
        address: address, name: name, labels: labels, argv: argv, cwd: cwd, state: state,
        pid: pid, status: status, statusMs: statusMs, reported: reported ?? (status != nil),
        turn: turn, title: title, foreground: foreground)
}

private func build(
    _ terminals: [CoreTerminal], overlay: CoreDoneOverlayMachine = CoreDoneOverlayMachine(),
    core: CoreHello? = hello, home: String? = nil
) -> SessionSnapshot {
    CoreSnapshotBuilder.snapshot(terminals: terminals, core: core, overlay: overlay, home: home)
}

private func space(_ key: String, tab: String? = nil) -> [String: String] {
    var labels = ["herdr.space": key]
    if let tab { labels["herdr.tab"] = tab }
    return labels
}

@Suite("core snapshot builder", .timeLimit(.minutes(1)))
struct CoreSnapshotBuilderTests {
    @Test func desktopDocumentNamesAreLabelDrivenAndKeepRemotePrefix() throws {
        let layout = try JSONDecoder().decode(
            CoreAppLayout.Result.self, from: Data(CoreAppLayoutFixture.captured.utf8)).value
        let snapshot = CoreSnapshotBuilder.snapshot(terminals: [
            term("t15", name: "terminal name", labels: CoreAppLayoutFixture.labels, cwd: "/work/tmp"),
            term("t16", cwd: "/work/waycar"),
            term("box/t15", labels: CoreAppLayoutFixture.labels, cwd: "/work/tmp"),
        ], core: hello, overlay: CoreDoneOverlayMachine(), appLayout: layout)
        #expect(snapshot.workspaces.map(\.label) == ["Ultimate", "waycar", "box · Ultimate"])
        #expect(snapshot.tabs.map(\.label) == ["router/caddy", "bash", "router/caddy"])
        #expect(snapshot.workspaces.first?.workspaceID == "hc:ws:" + CoreAppLayoutFixture.labels["herdr.space", default: ""])
    }

    @Test func absentAndEmptyDesktopNamesKeepSynthesizedNames() throws {
        let terminal = term("t15", name: "fallback", labels: CoreAppLayoutFixture.labels, cwd: "/work/tmp")
        for json in [
            #"{"value":null,"version":0}"#,
            CoreAppLayoutFixture.captured.replacingOccurrences(of: "Ultimate", with: "")
                .replacingOccurrences(of: "router/caddy", with: ""),
        ] {
            let layout = try JSONDecoder().decode(CoreAppLayout.Result.self, from: Data(json.utf8)).value
            let snapshot = CoreSnapshotBuilder.snapshot(
                terminals: [terminal], core: hello, overlay: CoreDoneOverlayMachine(), appLayout: layout)
            #expect(snapshot.workspaces.first?.label == "tmp")
            #expect(snapshot.tabs.first?.label == "fallback")
        }
    }

    // MARK: Topology

    @Test func unlabelledTerminalsShareAWorkspacePerFolderAndAreATabEach() throws {
        let snapshot = build([
            term("t1", cwd: "/home/me/alpha"),
            term("t2", cwd: "/home/me/alpha/"),
            term("t3", cwd: "/home/me/beta"),
        ])

        #expect(snapshot.workspaces.map(\.workspaceID)
            == ["hc:ws:/home/me/alpha", "hc:ws:/home/me/beta"])
        #expect(snapshot.workspaces.map(\.label) == ["alpha", "beta"])
        #expect(snapshot.workspaces.map(\.number) == [1, 2])
        #expect(snapshot.workspaces.map(\.tabCount) == [2, 1])
        #expect(snapshot.workspaces.map(\.paneCount) == [2, 1])
        #expect(snapshot.workspaces.map(\.activeTabID) == ["hc:tab:t1", "hc:tab:t3"])
        #expect(snapshot.tabs.map(\.tabID) == ["hc:tab:t1", "hc:tab:t2", "hc:tab:t3"])
        #expect(snapshot.tabs.map(\.number) == [1, 2, 1])
        #expect(snapshot.tabs.map(\.paneCount) == [1, 1, 1])
        #expect(snapshot.tabs.map(\.workspaceID) == [
            "hc:ws:/home/me/alpha", "hc:ws:/home/me/alpha", "hc:ws:/home/me/beta",
        ])
        #expect(snapshot.panes.map(\.paneID) == ["hc:t1", "hc:t2", "hc:t3"])
        #expect(snapshot.panes.map(\.terminalID) == [
            "hc:01234567:t1", "hc:01234567:t2", "hc:01234567:t3",
        ])
        #expect(snapshot.panes.map(\.tabID) == snapshot.tabs.map(\.tabID))
        #expect(snapshot.workspaces.allSatisfy { !$0.focused })
        #expect(snapshot.tabs.allSatisfy { !$0.focused })
        #expect(snapshot.panes.allSatisfy { !$0.focused })
        #expect(snapshot.version == "0.1.14")
        #expect(snapshot.protocolVersion == 1)
        #expect(snapshot.layouts.isEmpty)
        #expect(snapshot.focusedPaneID == nil)
    }

    @Test func aTabLabelAndSpaceLabelGroupTerminalsAndStayInsideTheirWorkspace() throws {
        let snapshot = build([
            term("t7", name: "main", labels: space("sp1", tab: "tb1"), cwd: "/srv/app"),
            term("t8", labels: space("sp1", tab: "tb1"), cwd: "/srv/app/web"),
            term("t9", labels: space("sp1", tab: "tb2"), cwd: "/srv/app"),
            term("t10", labels: space("sp2", tab: "tb1"), cwd: "/srv/docs"),
        ])

        #expect(snapshot.workspaces.map(\.workspaceID) == ["hc:ws:sp1", "hc:ws:sp2"])
        // The space's label is its first terminal's folder, not the label key.
        #expect(snapshot.workspaces.map(\.label) == ["app", "docs"])
        #expect(snapshot.workspaces.map(\.tabCount) == [2, 1])
        #expect(snapshot.workspaces.map(\.paneCount) == [3, 1])

        // sp2's tb1 is not sp1's tb1.
        #expect(snapshot.tabs.map(\.tabID) == [
            "hc:tab:sp1#tb1", "hc:tab:sp1#tb2", "hc:tab:sp2#tb1",
        ])
        #expect(snapshot.tabs.map(\.paneCount) == [2, 1, 1])
        #expect(snapshot.tabs.map(\.number) == [1, 2, 1])
        #expect(snapshot.tabs.map(\.label) == ["main", "bash", "bash"])
        #expect(snapshot.workspaces[0].activeTabID == "hc:tab:sp1#tb1")

        let first = snapshot.panes.filter { $0.tabID == "hc:tab:sp1#tb1" }
        #expect(first.map(\.paneID) == ["hc:t7", "hc:t8"])
        #expect(Set(first.map(\.workspaceID)) == ["hc:ws:sp1"])
    }

    @Test func aParkedTerminalFallsBackToItsFolderAndAWhitespaceLabelCountsAsParked() throws {
        let snapshot = build([
            term("t1", labels: ["herdr.space": "", "herdr.tab": ""], cwd: "/srv/app"),
            term("t2", cwd: "/srv/app"),
            term("t3", labels: ["herdr.space": "  ", "herdr.tab": " "], cwd: "/srv/app"),
            term("t4", labels: space("sp1"), cwd: "/srv/app"),
        ])

        #expect(snapshot.workspaces.map(\.workspaceID) == ["hc:ws:/srv/app", "hc:ws:sp1"])
        #expect(snapshot.workspaces.map(\.paneCount) == [3, 1])
        // Parked: one Tab per terminal.
        #expect(snapshot.workspaces[0].tabCount == 3)
        #expect(snapshot.tabs.prefix(3).map(\.tabID) == ["hc:tab:t1", "hc:tab:t2", "hc:tab:t3"])
    }

    @Test func workspaceLabelsNameTheFolderAndHomeAndUnknown() throws {
        let snapshot = build(
            [
                term("t1", cwd: "/home/me"),
                term("t2", cwd: "~"),
                term("t3", cwd: ""),
                term("t4", cwd: "/"),
                term("t5", cwd: "/home/me/work/"),
            ],
            home: "/home/me/")

        #expect(snapshot.workspaces.map(\.label) == ["~", "~", "Terminals", "/", "work"])
        // Home is a label, not a different key: ids still follow the folder.
        #expect(snapshot.workspaces.map(\.workspaceID) == [
            "hc:ws:/home/me", "hc:ws:~", "hc:ws:", "hc:ws:/", "hc:ws:/home/me/work",
        ])
        // Without a known home, the home folder is just a folder.
        #expect(build([term("t1", cwd: "/home/me")]).workspaces.map(\.label) == ["me"])
        // No start folder: the foreground's names it.
        let moved = term("t1", cwd: "", foreground: CoreForeground(cwd: "/tmp/scratch"))
        #expect(build([moved]).workspaces.map(\.label) == ["scratch"])
    }

    @Test func remoteTerminalsKeepTheirMachineInKeysAndLabels() throws {
        let snapshot = build([
            term("t1", cwd: "/srv/api"),
            term("box/t3", cwd: "/srv/api"),
            term("box/t4", cwd: "/srv/api"),
            term("box/t5", labels: space("sp1"), cwd: "/srv/web"),
        ])

        #expect(snapshot.workspaces.map(\.workspaceID) == [
            "hc:ws:/srv/api", "hc:ws:box//srv/api", "hc:ws:box/sp1",
        ])
        #expect(snapshot.workspaces.map(\.label) == ["api", "box · api", "box · web"])
        #expect(snapshot.panes.map(\.paneID) == ["hc:t1", "hc:box/t3", "hc:box/t4", "hc:box/t5"])
        #expect(snapshot.panes[1].terminalID == "hc:01234567:box/t3")
        #expect(snapshot.tabs.map(\.tabID).contains("hc:tab:box/t3"))
        #expect(CoreID.address(ofPane: snapshot.panes[1].paneID) == "box/t3")
    }

    @Test func finishedTerminalsAreNotRowsAndDoNotNameTheirWorkspace() throws {
        let finished = term(
            "t1", labels: space("sp1"), cwd: "/x/finished", state: "finished",
            status: CoreStatus(state: "done", app: "claude-code"), turn: 1)
        let live = term("t2", labels: space("sp1"), cwd: "/x/live")
        let onlyFinished = term("t3", cwd: "/x/gone", state: "finished")
        let snapshot = build([finished, live, onlyFinished])

        #expect(snapshot.workspaces.map(\.workspaceID) == ["hc:ws:sp1"])
        #expect(snapshot.workspaces.map(\.label) == ["live"])
        #expect(snapshot.panes.map(\.paneID) == ["hc:t2"])
        #expect(snapshot.agents.isEmpty)
        #expect(CoreSnapshotBuilder.paneInfo(for: finished, core: hello, overlay: .init()) == nil)
        #expect(CoreSnapshotBuilder.agentInfo(for: finished, core: hello, overlay: .init()) == nil)
        #expect(CoreSnapshotBuilder.shellActivities(terminals: [onlyFinished]).isEmpty)
    }

    @Test func tabLabelIsTheNameThenTheTitleThenTheProgram() throws {
        let snapshot = build([
            term("t1", name: "api", cwd: "/a", title: "ignored"),
            term("t2", cwd: "/b", title: "  notes.md - vim  "),
            term("t3", cwd: "/c", foreground: CoreForeground(pid: 9, name: "htop")),
            term("t4", argv: ["/usr/local/bin/fish"], cwd: "/d"),
            term("t5", argv: [], cwd: "/e"),
        ])
        #expect(snapshot.tabs.map(\.label) == ["api", "notes.md - vim", "htop", "fish", "Terminal"])
    }

    @Test func tabsFollowCoreNumberingNotTheListOrder() throws {
        // Core counts t1..t9, t10..t19, t1b..t1z, t20: a longer id is newer
        // and the alphabet has no vowels. Machines follow the core's own.
        let addresses = ["t20", "box/t1", "t1b", "t10", "t9", "t19", "t1z", "t2"]
        let expected = ["t2", "t9", "t10", "t19", "t1b", "t1z", "t20", "box/t1"]
        let terminals = addresses.enumerated().map { offset, address in
            term(address, cwd: "/w/\(offset)")
        }
        let snapshot = build(terminals)

        #expect(snapshot.panes.map(\.paneID) == expected.map { "hc:" + $0 })
        #expect(snapshot.workspaces.map(\.number) == Array(1...addresses.count))
        // The same table listed backwards is the same snapshot.
        let reversed = build(Array(terminals.reversed()))
        #expect(reversed.panes.map(\.paneID) == snapshot.panes.map(\.paneID))
        #expect(reversed.tabs.map(\.tabID) == snapshot.tabs.map(\.tabID))
        #expect(reversed.workspaces.map(\.workspaceID) == snapshot.workspaces.map(\.workspaceID))
    }

    @Test func noCoreYetUsesAPlaceholderPrefixAndEmptyVersion() throws {
        let snapshot = build([term("t1")], core: nil)
        #expect(snapshot.version.isEmpty)
        #expect(snapshot.protocolVersion == 0)
        #expect(snapshot.panes.map(\.terminalID) == ["hc:core:t1"])
        let blank = CoreHello(coreID: "", version: "0.1.14")
        #expect(build([term("t1")], core: blank).panes.map(\.terminalID) == ["hc:core:t1"])
        let short = CoreHello(coreID: "abc", version: "0.1.14")
        #expect(build([term("t1")], core: short).panes.map(\.terminalID) == ["hc:abc:t1"])
    }

    @Test func idsRoundTripAndRejectOtherBackends() {
        #expect(CoreID.pane("t7") == "hc:t7")
        #expect(CoreID.address(ofPane: "hc:t7") == "t7")
        #expect(CoreID.address(ofPane: "hc:box/t3") == "box/t3")
        #expect(CoreID.address(ofPane: "hc:") == nil)
        #expect(CoreID.address(ofPane: "tmux:%1") == nil)
        #expect(CoreID.address(ofPane: "w1:p1") == nil)
        #expect(CoreID.isCorePane("hc:t1b"))
        #expect(!CoreID.isCorePane("tmux:%1"))
        #expect(CoreID.terminal(corePrefix: "01234567", address: "t7") == "hc:01234567:t7")
        #expect(CoreID.tab(key: "k") == "hc:tab:k")
        #expect(CoreID.workspace(key: "k") == "hc:ws:k")

        let parts = CoreID.parts(ofTerminal: "hc:01234567:box/t3")
        #expect(parts?.corePrefix == "01234567")
        #expect(parts?.address == "box/t3")
        #expect(CoreID.parts(ofTerminal: CoreID.terminal(corePrefix: "core", address: "t1b"))?
            .address == "t1b")
        for malformed in ["hc:t7", "hc::t7", "hc:01234567:", "hc:a:b:c", "tmux:%1", "01234567:t7", ""] {
            #expect(CoreID.parts(ofTerminal: malformed) == nil, "\(malformed)")
        }
    }

    // MARK: Agents and kinds

    struct KindCase: Sendable {
        var app: String?
        var foreground: [String]
        var start: [String]
        var kind: String?
    }

    @Test(arguments: [
        // The report's `app`: a kind's raw value, executable or alias.
        KindCase(app: "claude-code", foreground: ["bash"], start: ["bash"], kind: "claude"),
        KindCase(app: "Claude Code", foreground: [], start: ["bash"], kind: "claude"),
        KindCase(app: "codex", foreground: [], start: ["bash"], kind: "codex"),
        KindCase(app: "cursor-agent", foreground: [], start: ["bash"], kind: "cursor"),
        KindCase(app: "kiro-cli", foreground: [], start: ["bash"], kind: "kiro"),
        KindCase(app: "antigravity", foreground: [], start: ["bash"], kind: "agy"),
        KindCase(app: "gemini_cli", foreground: [], start: ["bash"], kind: "gemini"),
        // The app wins over what the foreground looks like.
        KindCase(app: "claude-code", foreground: ["vim", "notes"], start: ["bash"], kind: "claude"),
        // Argv: an interpreter's script, Claude's renamed process, a plain program.
        KindCase(
            app: nil,
            foreground: ["node", "/usr/lib/node_modules/@openai/codex/bin/codex", "--model", "x"],
            start: ["bash"], kind: "codex"),
        KindCase(app: nil, foreground: ["2.1.286"], start: ["claude"], kind: "claude"),
        KindCase(app: nil, foreground: ["/home/me/.local/bin/claude", "--resume"], start: ["bash"],
                 kind: "claude"),
        KindCase(
            app: nil, foreground: [],
            start: ["/home/me/.local/bin/cursor-agent", "--use-system-ca",
                    "/x/cursor-agent/versions/1/index.js"],
            kind: "cursor"),
        // An unknown app does not hide a recognizable program.
        KindCase(app: "zoo", foreground: ["claude"], start: ["bash"], kind: "claude"),
        // Nothing recognizable.
        KindCase(app: "zoo", foreground: ["sh", "fake-agent.sh"], start: ["bash"], kind: nil),
        KindCase(app: nil, foreground: ["bash"], start: ["/usr/bin/bash"], kind: nil),
        KindCase(app: nil, foreground: ["vim", "claude.md"], start: ["bash"], kind: nil),
        KindCase(app: nil, foreground: [], start: [], kind: nil),
    ])
    func kindComesFromTheAppThenTheForegroundThenTheStartCommand(_ item: KindCase) {
        let terminal = term(
            "t1", argv: item.start, status: item.app.map { CoreStatus(state: "idle", app: $0) },
            foreground: item.foreground.isEmpty ? nil : CoreForeground(argv: item.foreground))
        #expect(CoreSnapshotBuilder.kind(of: terminal) == item.kind)
    }

    @Test func aTerminalIsAnAgentWhenReportedOrRecognizedElseAShell() throws {
        let snapshot = build([
            // Recognized by argv, never reported.
            term("t1", foreground: CoreForeground(pid: 9, argv: ["node", "/x/bin/codex"])),
            // Reported under a name Waycar does not know: kept as the display name.
            term("t2", status: CoreStatus(state: "working", app: "Zoo")),
            // Reported with no app and nothing recognizable.
            term("t3", status: CoreStatus(state: "idle")),
            // A shell.
            term("t4", foreground: CoreForeground(pid: 9, argv: ["vim", "notes.md"])),
            // Has an `app` string but never reported: not an Agent.
            term("t5", status: CoreStatus(state: "idle", app: "zoo"), reported: false),
        ])

        #expect(snapshot.agents.map(\.paneID) == ["hc:t1", "hc:t2", "hc:t3"])
        #expect(snapshot.agents.map(\.agent) == ["codex", "zoo", "unknown"])
        #expect(snapshot.panes.map(\.agent) == ["codex", "zoo", "unknown", nil, nil])
        #expect(snapshot.panes.map(\.agentStatus) == [.unknown, .working, .idle, .unknown, .unknown])
        // The same row `pane.updated` carries for one terminal.
        #expect(Agent(snapshot.agents[1]).displayName == "zoo")
        #expect(Agent(snapshot.agents[2]).kind == Agent.unidentifiedKind)
    }

    @Test func agentRowCarriesNameStatusSequenceAndFolders() throws {
        let terminal = term(
            "t7", name: "reviewer", cwd: "/srv/app",
            status: CoreStatus(state: "blocked", kind: "permission", app: "claude-code"),
            statusMs: 1_793_309_051_624, turn: 2, title: "Allow rm?",
            foreground: CoreForeground(pid: 11, name: "claude", argv: ["claude"], cwd: "/srv/app/web"))
        let agent = try #require(
            CoreSnapshotBuilder.agentInfo(for: terminal, core: hello, overlay: .init()))

        #expect(agent.agent == "claude")
        #expect(agent.name == "reviewer")
        #expect(agent.agentStatus == .blocked)
        #expect(agent.stateChangeSeq == 1_793_309_051_624)
        #expect(agent.agentSession == nil)
        #expect(agent.launchPending == false)
        #expect(agent.interactiveReady == true)
        #expect(agent.cwd == "/srv/app/web")
        #expect(agent.foregroundCwd == "/srv/app/web")
        #expect(agent.terminalTitle == "Allow rm?")
        #expect(agent.paneID == "hc:t7")
        #expect(agent.terminalID == "hc:01234567:t7")
        #expect(agent.tabID == "hc:tab:t7")
        #expect(agent.workspaceID == "hc:ws:/srv/app")

        let pane = try #require(
            CoreSnapshotBuilder.paneInfo(for: terminal, core: hello, overlay: .init()))
        #expect(pane.agent == "claude")
        #expect(pane.agentStatus == .blocked)
        #expect(pane.cwd == "/srv/app/web")
        #expect(pane.terminalTitle == "Allow rm?")
        #expect(pane.tabID == agent.tabID && pane.workspaceID == agent.workspaceID)
    }

    /// Waycar starts core terminals unnamed and keeps the name it launched
    /// an Agent with in `waycar.name`; core's own terminal name still wins.
    @Test func waycarNameLabelNamesAnUnnamedAgentAndItsTab() throws {
        let labels = ["waycar": "1", "waycar.kind": "omp", "waycar.name": "offline"]
        let status = CoreStatus(state: "idle", app: "omp")
        let unnamed = term("t3", labels: labels, argv: ["omp"], status: status)
        let agent = try #require(
            CoreSnapshotBuilder.agentInfo(for: unnamed, core: hello, overlay: .init()))
        #expect(agent.name == "offline")
        #expect(CoreSnapshotBuilder.tabLabel(of: unnamed) == "offline")

        let named = term("t4", name: "core-name", labels: labels, argv: ["omp"], status: status)
        let coreNamed = try #require(
            CoreSnapshotBuilder.agentInfo(for: named, core: hello, overlay: .init()))
        #expect(coreNamed.name == "core-name")
    }

    @Test func missingStatusTimeAndTitleStayAbsent() throws {
        let terminal = term("t1", status: CoreStatus(state: "idle", app: "codex"))
        let agent = try #require(
            CoreSnapshotBuilder.agentInfo(for: terminal, core: hello, overlay: .init()))
        #expect(agent.stateChangeSeq == nil)
        #expect(agent.name == nil)
        #expect(agent.terminalTitle == nil)
        // No foreground yet: the start folder is the current one.
        #expect(agent.cwd == "/home/me/alpha")
    }

    @Test func paneUpdatedRowsMatchTheSnapshotRows() throws {
        let terminals = [
            term("t7", labels: space("sp1", tab: "tb1"), cwd: "/srv/app",
                 status: CoreStatus(state: "working", app: "codex")),
            term("t8", labels: space("sp1", tab: "tb1"), cwd: "/srv/app"),
        ]
        let snapshot = build(terminals)
        for terminal in terminals {
            let pane = try #require(
                CoreSnapshotBuilder.paneInfo(for: terminal, core: hello, overlay: .init()))
            #expect(snapshot.panes.contains(pane))
        }
        let agent = try #require(
            CoreSnapshotBuilder.agentInfo(for: terminals[0], core: hello, overlay: .init()))
        #expect(snapshot.agents == [agent])
        #expect(
            CoreSnapshotBuilder.agentInfo(for: terminals[1], core: hello, overlay: .init()) == nil)
        // `pane.updated` reads the row out of the snapshot already built.
        #expect(CoreSnapshotBuilder.paneInfo(
            for: terminals[0], in: snapshot, overlay: .init()) == snapshot.panes[0])
        #expect(CoreSnapshotBuilder.paneInfo(
            for: term("t9"), in: snapshot, overlay: .init()) == nil)
        var finished = terminals[1]
        finished.state = "finished"
        #expect(CoreSnapshotBuilder.paneInfo(
            for: finished, in: build([finished]), overlay: .init()) == nil)
    }

    // MARK: Status

    @Test(arguments: [
        ("idle", true, AgentStatus.idle),
        ("working", true, AgentStatus.working),
        ("done", true, AgentStatus.done),
        ("blocked", true, AgentStatus.blocked),
        ("error", true, AgentStatus.blocked),
        ("paused", true, AgentStatus.unknown),
        ("", true, AgentStatus.unknown),
        ("working", false, AgentStatus.unknown),
        ("done", false, AgentStatus.unknown),
    ] as [(String, Bool, AgentStatus)])
    func statusWordsMapToAgentStatus(word: String, reported: Bool, expected: AgentStatus) {
        let terminal = term("t1", status: CoreStatus(state: word), reported: reported)
        #expect(CoreSnapshotBuilder.rawStatus(of: terminal) == expected)
        #expect(CoreSnapshotBuilder.agentStatus(of: terminal, overlay: .init()) == expected)
    }

    @Test func noStatusIsUnknownEvenWhenReported() {
        let terminal = term("t1", status: nil, reported: true)
        #expect(CoreSnapshotBuilder.rawStatus(of: terminal) == .unknown)
    }

    @Test func rollUpsTakeTheMostUrgentAgentStatusAndIgnoreShells() throws {
        func agent(_ address: String, _ word: String, _ labels: [String: String]) -> CoreTerminal {
            term(address, labels: labels, status: CoreStatus(state: word, app: "claude-code"))
        }
        let snapshot = build([
            agent("t1", "idle", space("a", tab: "x")),
            agent("t2", "error", space("a", tab: "x")),
            agent("t3", "working", space("a", tab: "y")),
            agent("t4", "done", space("b")),
            agent("t5", "idle", space("b")),
            term("t6", labels: space("c")),
            term("t7", labels: space("d"), status: CoreStatus(state: "paused", app: "zoo")),
        ])

        #expect(snapshot.workspaces.map(\.agentStatus) == [
            .blocked, .done, .unknown, .unknown,
        ])
        #expect(snapshot.tabs.map(\.agentStatus) == [
            .blocked, .working, .done, .idle, .unknown, .unknown,
        ])
        // A shell counts as a pane, not as a status.
        #expect(snapshot.workspaces[2].paneCount == 1)
        #expect(snapshot.tabs[4].paneCount == 1)
    }

    // MARK: Done overlay

    private func done(turn: Int = 1, word: String = "done") -> CoreTerminal {
        term("t1", status: CoreStatus(state: word, app: "claude-code"), turn: turn)
    }

    @Test func openingADoneAgentPresentsIdleUntilItsWordOrTurnMoves() {
        var overlay = CoreDoneOverlayMachine()
        let opened = done()
        #expect(CoreSnapshotBuilder.agentStatus(of: opened, overlay: overlay) == .done)

        _ = overlay.handle(.focused(address: "t1", terminal: opened))
        #expect(CoreSnapshotBuilder.agentStatus(of: opened, overlay: overlay) == .idle)
        #expect(CoreSnapshotBuilder.rawStatus(of: opened) == .done)

        // Back to work: whatever the overlay holds, a non-Done status is shown.
        #expect(CoreSnapshotBuilder.agentStatus(of: done(word: "working"), overlay: overlay)
            == .working)
        #expect(CoreSnapshotBuilder.agentStatus(of: done(word: "blocked"), overlay: overlay)
            == .blocked)

        // Another turn finished: a new Done the user has not seen.
        #expect(CoreSnapshotBuilder.agentStatus(of: done(turn: 2), overlay: overlay) == .done)
    }

    @Test func theOverlayReachesRowsAndRollUps() throws {
        var overlay = CoreDoneOverlayMachine()
        let terminals = [
            term("t1", labels: space("a"), status: CoreStatus(state: "done", app: "codex"), turn: 1),
            term("t2", labels: space("a"), status: CoreStatus(state: "done", app: "codex"), turn: 1),
        ]
        _ = overlay.handle(.focused(address: "t1", terminal: terminals[0]))
        let snapshot = build(terminals, overlay: overlay)

        #expect(snapshot.panes.map(\.agentStatus) == [.idle, .done])
        #expect(snapshot.agents.map(\.agentStatus) == [.idle, .done])
        #expect(snapshot.workspaces.map(\.agentStatus) == [.done])

        _ = overlay.handle(.focused(address: "t2", terminal: terminals[1]))
        let seen = build(terminals, overlay: overlay)
        #expect(seen.agents.map(\.agentStatus) == [.idle, .idle])
        #expect(seen.workspaces.map(\.agentStatus) == [.idle])
        #expect(seen.tabs.map(\.agentStatus) == [.idle, .idle])
    }

    // MARK: Shell Activity

    @Test func shellActivityFollowsTheForegroundProcess() {
        let terminals = [
            // The shell itself is in front.
            term("t1", pid: 100, foreground: CoreForeground(pid: 100, name: "bash", argv: ["bash"])),
            // Something else is.
            term("t2", pid: 200, foreground: CoreForeground(
                pid: 250, name: "sleep", argv: ["sleep", "30"])),
            // Name only: argv not read yet.
            term("t3", pid: 300, foreground: CoreForeground(pid: 350, name: "htop", argv: [])),
            // Unknown: no foreground yet, or no pids to compare.
            term("t4", pid: 400),
            term("t5", foreground: CoreForeground(pid: 550, name: "sleep", argv: ["sleep"])),
            term("t6", pid: 600, foreground: CoreForeground(name: "sleep", argv: ["sleep"])),
            // Never a Shell Activity: an Agent, a finished terminal.
            term("t7", pid: 700, status: CoreStatus(state: "idle", app: "codex"),
                 foreground: CoreForeground(pid: 750, argv: ["codex"])),
            term("t8", state: "finished", pid: 800),
            // A machine's terminal is keyed by its own address.
            term("box/t3", pid: 900, foreground: CoreForeground(
                pid: 950, name: "make", argv: ["make", "-j8"])),
        ]
        let activities = CoreSnapshotBuilder.shellActivities(terminals: terminals)

        #expect(activities == [
            "hc:t1": .idle,
            "hc:t2": .running(command: "sleep 30"),
            "hc:t3": .running(command: "htop"),
            "hc:box/t3": .running(command: "make -j8"),
        ])
    }

    @Test func aRunningCommandIsOneSanitizedLine() {
        let terminal = term(
            "t1", pid: 1,
            foreground: CoreForeground(pid: 2, argv: ["echo", "a\u{1B}[31m\nb", "x"]))
        let activity = CoreSnapshotBuilder.shellActivities(terminals: [terminal])["hc:t1"]
        guard case .running(let command) = activity else {
            Issue.record("expected a running command, got \(String(describing: activity))")
            return
        }
        #expect(!command.contains("\u{1B}"))
        #expect(!command.contains("\n"))
    }
}
