import Foundation
import Testing

@testable import Waycar

@Suite("Zellij Transport", .timeLimit(.minutes(1)))
struct ZellijTransportTests {
    static let presence = ZellijPresence(version: "0.46.0", path: "/opt/zellij")
    static let pane = "zellij:fixture/terminal_0"
    static let panes =
        #"[{"id":0,"is_plugin":false,"tab_id":2,"tab_position":0,"tab_name":"Agent","title":"Agent","pane_command":"claude","program_status":[{"id":null,"app":"claude-code","state":"Idle","updated_ms":1794484886663}]}]"#

    static func wire(_ panes: String = panes, session: String = "fixture", document: String = "") -> String {
        "\u{1E}B\n\(session) [Created]\n\u{1E}P\n\u{1E}S\(session)\n\(panes)\n\u{1E}H\n\(document)\n\u{1E}E\n"
    }

    struct Rig: Sendable {
        let transport: ZellijTransport
        let session: FakeHostSSHServices
        let channel: FakeHostControlChannel
    }

    static func open(
        panes: String = panes, document: String = "", screenInterval: Duration = .seconds(3),
        launchConfirmationTimeout: Duration = .seconds(5),
        exec: @escaping FakeHostSSHServices.ExecHandler = { command, _ in
            FakeHostSSHServices.result(stdout: command.contains("list-panes") ? panes : "hello")
        }
    ) async throws -> Rig {
        let session = FakeHostSSHServices(exec: exec)
        let channel = FakeHostControlChannel()
        channel.feed(wire(panes, document: document))
        await session.serveZellij(channel)
        var config = ZellijTransport.Configuration(requestTimeout: .seconds(5))
        config.resyncDebounce = .milliseconds(5)
        config.screenInterval = screenInterval
        config.launchConfirmationTimeout = launchConfirmationTimeout
        let transport = try await ZellijTransport.open(
            session: session, presence: presence, configuration: config)
        return Rig(transport: transport, session: session, channel: channel)
    }

    @Test func firstFrameBuildsSnapshotAndUsesDetectedPathAndRememberedHome() async throws {
        let rig = try await Self.open()
        let snapshot = try await rig.transport.sessionSnapshot()
        #expect(snapshot.agents.map(\.paneID) == [Self.pane])
        #expect(snapshot.workspaces.first?.label == "fixture")
        #expect(snapshot.agents.first?.agentStatus == .idle)
        let command = try #require(await rig.session.zellijCommands.first)
        #expect(command.contains("/opt/zellij"))
        #expect(command.contains("/home/me/.local/state/waycar/zellij"))
        try await rig.transport.close()
        #expect(rig.channel.isClosed)
        #expect(await rig.session.releaseCount == 1)
    }

    @Test func statusChangeAndMembershipChangesReachEventStream() async throws {
        let rig = try await Self.open()
        let events = try await rig.transport.subscribeToEvents([])
        let reader = EventReader(events.events)
        rig.channel.feed(Self.wire(Self.panes.replacingOccurrences(of: "Idle", with: "Working")))
        let status = try await reader.next()
        #expect(status?.kind == PaneEventKind.agentStatusChanged.kind)
        #expect(status?.data["pane_id"]?.stringValue == Self.pane)
        #expect(status?.data["agent_status"]?.stringValue == "working")
        rig.channel.feed(Self.wire("[]"))
        #expect(try await reader.next()?.kind == ZellijEvents.resync.kind)
        #expect(try await rig.transport.listAgents().isEmpty)
        await events.end()
        try await rig.transport.close()
    }

    @Test(arguments: [true, false])
    func silenceAndEOFEndStreamAndReleaseChannel(silence: Bool) async throws {
        let rig = try await Self.open()
        let events = try await rig.transport.subscribeToEvents([])
        if silence { rig.channel.timeOutReads(1) } else { rig.channel.finishOutput() }
        let reader = EventReader(events.events)
        await #expect(throws: TransportError.self) { _ = try await reader.next() }
        try await waitUntil { rig.channel.isClosed }
        #expect(await rig.transport.isConnected == false)
        try await rig.transport.close()
    }

    @Test func noDelayPromptIsOneExecPastingThenEnterToTheExactPane() async throws {
        let rig = try await Self.open()
        _ = try await rig.transport.promptAgent(
            AgentPromptParams(target: Self.pane, text: "a 'quoted' prompt"))
        let commands = try ZellijCommand(zellij: Self.presence.path)
        let expected = try commands.pasteAndEnter(Self.paneID(), text: "a 'quoted' prompt")
        #expect(await rig.session.execs.last?.command == expected.command)
        #expect(await rig.session.execs.last?.input == "a 'quoted' prompt")
        #expect(!expected.command.contains("a 'quoted' prompt"))
        #expect(expected.command.contains(" && "))
        try await rig.transport.close()
    }

    @Test func blockedPromptSendsNothing() async throws {
        let rig = try await Self.open(panes: Self.panes.replacingOccurrences(of: "Idle", with: "Blocked"))
        do {
            _ = try await rig.transport.promptAgent(AgentPromptParams(target: Self.pane, text: "never type"))
            Issue.record("blocked prompt unexpectedly delivered")
        } catch {
            #expect((error as? HerdrAPIError)?.code == "agent_blocked")
        }
        #expect(await rig.session.execs(containing: " action paste ").isEmpty)
        try await rig.transport.close()
    }

    @Test func delayedEnterIsSeparateAndTargetsSamePane() async throws {
        let hermes = Self.panes.replacingOccurrences(of: "claude", with: "hermes")
        let rig = try await Self.open(panes: hermes) { command, _ in
            FakeHostSSHServices.result(stdout: command.contains("list-panes") ? hermes : "❯ draft")
        }
        _ = try await rig.transport.promptAgent(AgentPromptParams(target: Self.pane, text: "draft"))
        let paste = await rig.session.execs(containing: " action paste ")
        let enter = await rig.session.execs(containing: " action send-keys ")
        #expect(paste.count == 1 && enter.count == 1)
        #expect(paste.first?.command.contains(" && ") == false)
        #expect(enter.first?.command.contains("terminal_0 -- Enter") == true)
        try await rig.transport.close()
    }

    @Test func delayedEnterWorksWithoutHostToolsStateDirectory() async throws {
        let hermes = Self.panes.replacingOccurrences(of: "claude", with: "hermes")
        let rig = try await Self.open(panes: hermes) { command, _ in
            if command.hasPrefix("if [ -f ") { return FakeHostSSHServices.result() }
            return FakeHostSSHServices.result(stdout: command.contains("list-panes") ? hermes : "❯ draft")
        }
        // The production SFTP config reader throws when its directory is absent.
        await rig.session.failConfigFileReads()
        _ = try await rig.transport.promptAgent(AgentPromptParams(target: Self.pane, text: "draft"))
        #expect(await rig.session.execs(containing: "if [ -f ").count == 1)
        #expect(await rig.session.execs(containing: " action send-keys ").count == 1)
        try await rig.transport.close()
    }

    @Test func delayedEnterStillRefusesAFreshHookBlocker() async throws {
        let hermes =
            #"[{"id":0,"is_plugin":false,"tab_id":2,"tab_position":0,"tab_name":"Agent","pane_command":"hermes"}]"#
        let hook =
            #"{"version":1,"pane":"zellij:fixture/terminal_0","kind":"hermes","status":"blocked","updated_ms":1794484886663}"#
        let rig = try await Self.open(panes: hermes) { command, _ in
            if command.hasPrefix("if [ -f ") { return FakeHostSSHServices.result(stdout: hook) }
            return FakeHostSSHServices.result(stdout: command.contains("list-panes") ? hermes : "❯ draft")
        }
        do {
            _ = try await rig.transport.promptAgent(AgentPromptParams(target: Self.pane, text: "draft"))
            Issue.record("a fresh hook blocker received Enter")
        } catch let error as HerdrAPIError { #expect(error.code == "prompt_not_submitted") }
        #expect(await rig.session.execs(containing: " action send-keys ").isEmpty)
        try await rig.transport.close()
    }

    @Test func metadataOnlyHookDocumentStillGetsScreenDetection() async throws {
        let panes =
            #"[{"id":0,"is_plugin":false,"tab_id":2,"tab_position":0,"tab_name":"Agent","pane_command":"codex"}]"#
        let document =
            #"{"version":1,"pane":"zellij:fixture/terminal_0","kind":"codex","session":"session-id","updated_ms":1794484886663}"#
        let rig = try await Self.open(panes: panes, document: document, screenInterval: .milliseconds(10)) {
            _, _ in
            FakeHostSSHServices.result(stdout: "› \n• Working (1s • esc to interrupt)\n")
        }
        let events = try await rig.transport.subscribeToEvents([])
        try await waitUntil { try await rig.transport.listAgents().first?.status == .working }
        #expect(await rig.session.execs(containing: "dump-screen").count >= 1)
        await events.end()
        try await rig.transport.close()
    }

    @Test func screenPollingRotatesPastEightPanesAndSkipsUnsupportedKinds() async throws {
        let codex = (0..<9).map {
            #"{"id":\#($0),"is_plugin":false,"tab_id":2,"tab_position":0,"tab_name":"Agents","pane_command":"codex"}"#
        }
        let unsupported =
            #"{"id":99,"is_plugin":false,"tab_id":2,"tab_position":0,"tab_name":"Agents","pane_command":"pi"}"#
        let panes = "[" + (codex + [unsupported]).joined(separator: ",") + "]"
        let rig = try await Self.open(panes: panes, screenInterval: .milliseconds(10)) { _, _ in
            FakeHostSSHServices.result(stdout: "› \n• Working (1s • esc to interrupt)\n")
        }
        let events = try await rig.transport.subscribeToEvents([])
        try await waitUntil { await rig.session.execs(containing: "terminal_8").count > 0 }
        #expect(await rig.session.execs(containing: "terminal_99").isEmpty)
        await events.end()
        try await rig.transport.close()
    }

    @Test func delayedEnterIsSkippedWhenFreshReportTurnsBlocked() async throws {
        let hermes = Self.panes.replacingOccurrences(of: "claude", with: "hermes")
        let blocked = hermes.replacingOccurrences(of: "Idle", with: "Blocked")
        let rig = try await Self.open(panes: hermes) { command, _ in
            FakeHostSSHServices.result(stdout: command.contains("list-panes") ? blocked : "❯ draft")
        }
        do {
            _ = try await rig.transport.promptAgent(AgentPromptParams(target: Self.pane, text: "draft"))
            Issue.record("the delayed Enter answered a blocker")
        } catch let error as HerdrAPIError { #expect(error.code == "prompt_not_submitted") }
        #expect(await rig.session.execs(containing: " action paste ").count == 1)
        #expect(await rig.session.execs(containing: " action send-keys ").isEmpty)
        try await rig.transport.close()
    }

    @Test func keysCloseAndRenameUseAddressedCommands() async throws {
        let rig = try await Self.open()
        let commands = try ZellijCommand(zellij: Self.presence.path)
        let pane = try Self.paneID()
        try await rig.transport.sendAgentKeys(
            AgentSendKeysParams(keys: ["ctrl+c", "enter"], target: Self.pane))
        #expect(
            await rig.session.execs.last?.command == (try commands.sendKeys(pane, keys: ["ctrl+c", "enter"])))
        try await rig.transport.renameAgent(AgentRenameParams(target: Self.pane, name: "renamed"))
        #expect(
            await rig.session.execs.last?.command
                == commands.renameTab(session: "fixture", tabID: 2, name: "renamed"))
        try await rig.transport.renameShellTab(tabID: "zellij:fixture/tab_2", label: "Tab")
        #expect(
            await rig.session.execs.last?.command
                == commands.renameTab(session: "fixture", tabID: 2, name: "Tab"))
        try await rig.transport.closeTab(TabTarget(tabID: "zellij:fixture/tab_2"))
        #expect(await rig.session.execs.last?.command == commands.closeTab(session: "fixture", tabID: 2))
        try await rig.transport.closePane(PaneTarget(paneID: Self.pane), closesWorktreeGroup: false)
        #expect(await rig.session.execs.last?.command == commands.closePane(pane))
        try await rig.transport.close()
    }

    @Test func splitTabAgentRenamesOnlyItsPane() async throws {
        let panes =
            #"[{"id":0,"is_plugin":false,"tab_id":2,"tab_position":0,"tab_name":"Agent","pane_command":"claude"},{"id":1,"is_plugin":false,"tab_id":2,"tab_position":0,"tab_name":"Agent","pane_command":"zsh"}]"#
        let rig = try await Self.open(panes: panes)
        try await rig.transport.renameAgent(AgentRenameParams(target: Self.pane, name: "renamed"))
        let commands = try ZellijCommand(zellij: Self.presence.path)
        let pane = try Self.paneID()
        #expect(await rig.session.execs.last?.command == commands.renamePane(pane, name: "renamed"))
        try await rig.transport.close()
    }

    @Test func readsUseDumpScreenFullOnlyForHistory() async throws {
        let rig = try await Self.open { _, _ in FakeHostSSHServices.result(stdout: "one\ntwo\nthree\n") }
        let visible = try await rig.transport.readPane(PaneReadParams(paneID: Self.pane, source: .visible))
        #expect(visible.text == "one\ntwo\nthree")
        #expect(await rig.session.execs.last?.command.contains("--full") == false)
        let history = try await rig.transport.readAgent(
            AgentReadParams(source: .recent, target: Self.pane, lines: 2))
        #expect(history.text == "two\nthree" && history.truncated)
        #expect(await rig.session.execs.last?.command.contains("--full") == true)
        try await rig.transport.close()
    }

    @Test func sessionReappearanceChangesTerminalGeneration() async throws {
        let rig = try await Self.open()
        let old = try #require(try await rig.transport.sessionSnapshot().agents.first?.terminalID)
        rig.channel.feed("\u{1E}B\n\u{1E}P\n\u{1E}H\n\u{1E}E\n")
        try await waitUntil { try await rig.transport.sessionSnapshot().panes.isEmpty }
        rig.channel.feed(Self.wire())
        try await waitUntil { try await rig.transport.sessionSnapshot().agents.count == 1 }
        #expect(try await rig.transport.sessionSnapshot().agents.first?.terminalID != old)
        try await rig.transport.close()
    }

    @Test func openingDoneAgentAcknowledgesOnlyThatReport() async throws {
        let done = Self.panes.replacingOccurrences(of: "Idle", with: "Done")
        let rig = try await Self.open(panes: done)
        try await rig.transport.focusAgent(AgentTarget(target: Self.pane))
        #expect(try await rig.transport.listAgents().first?.status == .idle)
        rig.channel.feed(Self.wire(Self.panes.replacingOccurrences(of: "Idle", with: "Working")))
        try await waitUntil { try await rig.transport.listAgents().first?.status == .working }
        rig.channel.feed(Self.wire(done))
        try await waitUntil { try await rig.transport.listAgents().first?.status == .done }
        try await rig.transport.close()
    }

    @Test func emptySessionListPassesPing() async throws {
        let rig = try await Self.open { _, _ in
            FakeHostSSHServices.result(stderr: "No active zellij sessions found.", exitStatus: 1)
        }
        #expect(try await rig.transport.ping().backend == .zellij)
        try await rig.transport.close()
    }

    static func paneID() throws -> ZellijPaneID { try #require(ZellijPaneID(pane)) }
}
