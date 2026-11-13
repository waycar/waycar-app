import CryptoKit
import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

@Suite("tmux transport")
struct TmuxTransportTests {
    @Test("a tagged retry returns its earlier Agent without creating or joining")
    func taggedRetryReturnsEarlierAgent() async throws {
        let id = UUID()
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.paneRecords = [Self.paneRecord(
                "%3", session: "$1", window: "@2", command: "claude", agent: "claude",
                status: "idle", launch: id.uuidString)]
        }
        let (transport, fake) = try await Self.open(host)
        let steps = LaunchStepLog()
        let agent = try await steps.recording {
            try await transport.startAgent(AgentLaunchRequest(
                kind: "claude", name: "claude-1", workspaceID: "tmux:$1",
                launchID: id, mayHaveStarted: true))
        }
        #expect(agent.paneID == "tmux:%3")
        let channel = try #require(await fake.controlChannels.first)
        #expect(!channel.writtenLines.contains { $0.hasPrefix("new-window") })
        #expect(!steps.all.contains(.joiningRunningAgent))
        try await transport.close()
    }

    @Test("a tagged pane still in shell startup is returned without another window")
    func taggedPaneBeforeKindDetectionIsReturned() async throws {
        let id = UUID()
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.paneRecords = [Self.paneRecord(
                "%3", session: "$1", window: "@2", command: "zsh", launch: id.uuidString)]
            $0.lineRules = [("new-window", [.ok(["%9\u{241F}@9\u{241F}$1"])])]
        }
        let (transport, fake) = try await Self.open(host)
        let agent = try await transport.startAgent(AgentLaunchRequest(
            kind: "opencode", name: "opencode-1", workspaceID: "tmux:$1",
            launchID: id, mayHaveStarted: true))
        #expect(agent.paneID == "tmux:%3")
        #expect(agent.kind == "opencode")
        let channel = try #require(await fake.controlChannels.first)
        #expect(!channel.writtenLines.contains { $0.hasPrefix("new-window") })
        try await transport.close()
    }

    @Test func detectedCodexAvoidsBareSSHProbeAndMissingProbeIsNotCached() async throws {
        let (transport, fake) = try await Self.open(TmuxHostScript.withClaudePane())
        let before = await fake.execs.count
        await fake.setCodexPresence(.init(version: "0.167.1", path: "/home/u/.nvm/bin/codex"))
        let line = try await transport.agentCommandLine(.init(kind: "codex", name: "c"))
        #expect(line == "codex --no-daemon")
        let joining = try await transport.agentCommandLine(.init(kind: "codex", name: "c", joinsCodexServer: true))
        #expect(joining == "codex")
        #expect(await fake.execs.count == before)
        await fake.setCodexPresence(nil)
        #expect(await transport.codexSupportsNoDaemon() == false)
        #expect(await transport.codexSupportsNoDaemon() == false)
        #expect(await fake.execs.count == before + 2)
        try await transport.close()
    }

    // MARK: Version gate

    @Test func missingTmuxIsNotInstalledAndKeepsTheCallersHold() async {
        let host = TmuxHostScript()
        host.update {
            $0.versionExit = 127
            $0.versionOutput = ""
            $0.versionStderr = "sh: 1: exec: tmux: not found"
        }
        let fake = host.makeFake()
        await #expect(throws: TransportError.tmuxNotInstalled) {
            try await TmuxTransport.open(session: fake, configuration: Self.configuration())
        }
        #expect(await fake.releaseCount == 0)
        #expect(await fake.controlChannels.isEmpty)
    }

    @Test func tmuxBelowTheFloorIsTooOld() async {
        let host = TmuxHostScript()
        host.update { $0.versionOutput = "tmux 3.1c\n" }
        let fake = host.makeFake()
        await #expect(throws: TransportError.tmuxTooOld(found: "3.1c")) {
            try await TmuxTransport.open(session: fake, configuration: Self.configuration())
        }
        #expect(await fake.execs(containing: "tmux ls").isEmpty)
    }

    @Test(arguments: [
        ("3.2a", "no-output", false),
        ("3.7c", "no-output,no-detach-on-destroy", true),
    ])
    func supportedVersionsAttachAndReportTheirVersion(
        version: String, flags: String, noDetach: Bool
    ) async throws {
        let host = TmuxHostScript()
        host.update {
            $0.versionOutput = "tmux \(version)\n"
            $0.serverVersion = version
            $0.flags = flags
        }
        let (transport, fake) = try await Self.open(host)
        #expect(try await transport.ping() == ServerInfo(
            version: version, protocolVersion: 0, backend: .tmux))
        #expect(await transport.noDetachOnDestroy == noDetach)
        let channel = try #require(await fake.controlChannels.first)
        #expect(channel.command.contains(
            "exec env -u TMUX tmux -u -C attach -f no-output,no-detach-on-destroy -t \"$1\""))
        #expect(channel.command.hasSuffix(" '$1'"))
        #expect(channel.writtenLines.first == [
            TmuxTransport.versionFlagsCommand, TmuxEvents.topologySubscribeCommand,
            TmuxEvents.statusSubscribeCommand,
        ].joined(separator: " ; "))
        // A line starting with `#` is a comment to tmux, which answers nothing.
        #expect(TmuxTransport.versionFlagsCommand.hasPrefix("display -p "))
        try await transport.close()
        try await transport.close()
        #expect(await fake.releaseCount == 1)
        #expect(channel.isClosed)
    }

    @Test func anchorSkipsAttachSessionsAndDestroyUnattached() async throws {
        let host = TmuxHostScript()
        host.update {
            $0.sessions = ["$0 off waycar-0a1b2c3d", "$1 on scratch", "$4 off later", "$2 off work"]
        }
        let (transport, fake) = try await Self.open(host)
        #expect(await fake.controlCommands.map { $0.hasSuffix(" '$2'") } == [true])
        try await transport.close()
    }

    // MARK: Idle mode

    @Test func idleServerGivesAnEmptySnapshotUntilSessionsAppear() async throws {
        let host = TmuxHostScript()
        host.update { $0.sessions = nil }
        let (transport, fake) = try await Self.open(host)
        #expect(await fake.controlChannels.isEmpty)
        #expect(try await transport.sessionSnapshot() == TmuxTransport.emptySnapshot(version: "3.7c"))
        #expect(try await transport.ping().backend == .tmux)
        #expect(await transport.isConnected)

        host.update {
            $0.sessions = ["$1 off main"]
            $0.sessionRecords = [Self.sessionRecord("$1", "main")]
            $0.windowRecords = [Self.windowRecord("@1", session: "$1", name: "zsh")]
            $0.paneRecords = [Self.paneRecord("%1", session: "$1", window: "@1", command: "zsh")]
        }
        let snapshot = try await transport.sessionSnapshot()
        #expect(snapshot.workspaces.map(\.workspaceID) == ["tmux:$1"])
        #expect(snapshot.panes.map(\.paneID) == ["tmux:%1"])
        #expect(await fake.controlChannels.count == 1)
        try await transport.close()
    }

    @Test func idleEventStreamPollsAndResyncsWhenSessionsAppear() async throws {
        let host = TmuxHostScript()
        host.update { $0.sessions = nil }
        let (transport, fake) = try await Self.open(host, poll: .milliseconds(30))
        let events = EventCollector(try await transport.subscribeToEvents([]))
        await #expect(throws: TransportError.eventsChannelAlreadyOpen) {
            try await transport.subscribeToEvents([])
        }

        host.update { $0.sessions = ["$3 off late"] }
        #expect(await eventually { await fake.controlChannels.count == 1 })
        #expect(await eventually { events.kinds.contains(TmuxEvents.resyncKind) })
        #expect(!events.isFinished)
        try await transport.close()
        #expect(await eventually { events.isFinished })
    }

    @Test func dualHostIdleRechecksOnlyOnActivationAndRevalidation() async throws {
        let host = TmuxHostScript()
        host.update { $0.sessions = nil }
        let (transport, fake) = try await Self.open(
            host, poll: .milliseconds(10), role: .dual)
        let events = EventCollector(try await transport.subscribeToEvents([]))
        // Activation asked; no poll follows, and keepalive pings ask nothing.
        #expect(await transport.idlePoll == nil)
        let asked = await fake.execs(containing: "tmux ls").count
        host.update { $0.sessions = ["$3 off late"] }
        #expect(try await transport.ping().backend == .tmux)
        #expect(try await transport.ping().backend == .tmux)
        #expect(await fake.execs(containing: "tmux ls").count == asked)
        #expect(await fake.controlChannels.isEmpty)

        // A foreground return asks again, and finds the new session.
        #expect(try await transport.revalidate().backend == .tmux)
        #expect(await fake.execs(containing: "tmux ls").count == asked + 1)
        #expect(await fake.controlChannels.count == 1)
        #expect(await eventually { events.kinds.contains(TmuxEvents.resyncKind) })
        try await transport.close()
    }

    @Test func tmuxOnlyHostIdlePollsAndKeepaliveRechecks() async throws {
        let host = TmuxHostScript()
        host.update { $0.sessions = nil }
        let (transport, fake) = try await Self.open(host, role: .tmuxOnly)
        let events = EventCollector(try await transport.subscribeToEvents([]))
        #expect(await transport.idlePoll != nil)
        let asked = await fake.execs(containing: "tmux ls").count
        #expect(try await transport.ping().backend == .tmux)
        #expect(await fake.execs(containing: "tmux ls").count == asked + 1)
        #expect(!events.isFinished)
        try await transport.close()
    }

    @Test func detectedPresenceStandsInForTheVersionProbeAndSetsTheRole() async throws {
        let host = TmuxHostScript()
        let settings = Self.settings()
        let dualFake = host.makeFake()
        let dual = try await TmuxTransport.open(
            session: dualFake, settings: settings,
            presence: HostBackendPresence(herdr: true, tmuxVersion: "3.4"))
        #expect(await dual.configuration.hostRole == .dual)
        #expect(await dualFake.execs(containing: "tmux -V").isEmpty)
        try await dual.close()

        let tmuxOnly = try await TmuxTransport.open(
            session: host.makeFake(), settings: settings,
            presence: HostBackendPresence(herdr: false, tmuxVersion: "3.7c"))
        #expect(await tmuxOnly.configuration.hostRole == .tmuxOnly)
        try await tmuxOnly.close()

        let refused = host.makeFake()
        await #expect(throws: TransportError.tmuxNotInstalled) {
            try await TmuxTransport.open(
                session: refused, settings: settings,
                presence: HostBackendPresence(herdr: true, tmuxVersion: nil))
        }
        await #expect(throws: TransportError.tmuxTooOld(found: "3.1c")) {
            try await TmuxTransport.open(
                session: refused, settings: settings,
                presence: HostBackendPresence(herdr: true, tmuxVersion: "3.1c"))
        }
        #expect(await refused.execs.isEmpty)
        #expect(await refused.releaseCount == 0)
    }

    // MARK: Inventory

    @Test func firstStatusPushAfterSnapshotReportsTheChange() async throws {
        let (transport, fake) = try await Self.open(TmuxHostScript.withClaudePane())
        let events = EventCollector(try await transport.subscribeToEvents([]))
        let snapshot = try await transport.sessionSnapshot()
        #expect(snapshot.agents.first?.agentStatus == .idle)
        let channel = try #require(await fake.controlChannels.first)
        channel.push([Self.statusPush([["%3", "blocked", "claude", "", "1"]])])
        #expect(await eventually {
            events.events.contains(TmuxEvents.statusChanged(paneID: "%3", status: "blocked"))
        })
        try await transport.close()
    }

    @Test func olderSnapshotKeepsANewLaunchGate() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                ("display -p -t %7", [.ok([Self.readiness("%7", command: "opencode")])]),
            ]
        }
        let (transport, fake) = try await Self.open(host)
        let gate = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()
        await fake.holdNextExec(containing: "rev-parse", entered: entered.continuation, until: gate.stream)
        let snapshot = Task { try await transport.sessionSnapshot() }
        var entry = entered.stream.makeAsyncIterator()
        _ = await entry.next()
        host.update {
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@4", command: "opencode"))
        }
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "opencode", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))
        gate.continuation.yield(())
        _ = try await snapshot.value
        #expect(await transport.launchGates["%7"]?.kind == "opencode")
        await Self.expectNotReady(transport, pane: "tmux:%7")
        let channel = try #require(await fake.controlChannels.first)
        #expect(!channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    @Test func screenReadForAReplacedAgentIsDiscarded() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.paneRecords = [Self.paneRecord(
                "%3", session: "$1", window: "@2", command: "claude")]
            $0.lineRules = [("capture-pane", [
                .ok(TmuxScreenDetectorTests.claudeTrust.components(separatedBy: "\n")), .ok([""]),
            ])]
        }
        let fake = host.makeFake()
        var configuration = Self.configuration()
        configuration.screenWatch.tick = .seconds(3_600)
        let transport = try await TmuxTransport.open(session: fake, configuration: configuration)
        let events = EventCollector(try await transport.subscribeToEvents([]))
        _ = try await transport.sessionSnapshot()
        let snapshotEntered = AsyncStream<Void>.makeStream()
        let snapshotRelease = AsyncStream<Void>.makeStream()
        await fake.holdNextExec(
            containing: "rev-parse", entered: snapshotEntered.continuation, until: snapshotRelease.stream)
        host.update {
            $0.sessionRecords = [Self.sessionRecord("$1", "main")
                .replacingOccurrences(of: "/home/me", with: "/work/other")]
            $0.paneRecords = [Self.paneRecord(
                "%3", session: "$1", window: "@2", command: "copilot")]
        }
        let snapshot = Task { try await transport.sessionSnapshot() }
        var snapshotEntry = snapshotEntered.stream.makeAsyncIterator()
        _ = await snapshotEntry.next()
        let channel = try #require(await fake.controlChannels.first)
        let readEntered = AsyncStream<Void>.makeStream()
        let readRelease = AsyncStream<Void>.makeStream()
        channel.holdNextReply(
            from: "capture-pane", entered: readEntered.continuation, until: readRelease.stream)
        let poll = Task { await transport.pollScreens() }
        var readEntry = readEntered.stream.makeAsyncIterator()
        _ = await readEntry.next()
        snapshotRelease.continuation.yield(())
        #expect(try await snapshot.value.agents.first?.agent == "copilot")
        readRelease.continuation.yield(())
        #expect(await poll.value)
        #expect(await transport.reportedStatus(ofPane: "%3") == .unknown)
        #expect(!events.events.contains(TmuxEvents.statusChanged(paneID: "%3", status: "blocked")))
        try await transport.close()
    }

    @Test func snapshotResolvesAClaudeVersionPaneOnceOverPs() async throws {
        let host = TmuxHostScript()
        host.update {
            $0.sessionRecords = [Self.sessionRecord("$1", "main")]
            $0.windowRecords = [Self.windowRecord("@2", session: "$1", name: "2.1.286")]
            $0.paneRecords = [
                Self.paneRecord(
                    "%3", session: "$1", window: "@2", command: "2.1.286", pid: 4242,
                    tty: "/dev/ttys004")
            ]
            $0.execRules = [(
                "ps -t",
                FakeHostSSHServices.result(stdout: """
                    __WAYCAR_TTY__=ttys004
                     4242  4242  5000 Ss   -zsh
                     5001  5000  5000 S+   node helper.js
                     5000  5000  5000 S+   claude --resume abc

                    """)
            )]
        }
        let (transport, fake) = try await Self.open(host)
        let snapshot = try await transport.sessionSnapshot()
        let agent = try #require(snapshot.agents.first)
        #expect(agent.paneID == "tmux:%3")
        #expect(agent.agent == "claude")
        // The window name is tmux's automatic-rename artifact: no name.
        #expect(agent.name == nil)
        let probes = await fake.execs(containing: "ps -t")
        #expect(probes.count == 1)
        #expect(probes.first?.command.hasSuffix(" sh 'ttys004'") == true)

        _ = try await transport.sessionSnapshot()
        #expect(await fake.execs(containing: "ps -t").count == 1)
        try await transport.close()
    }

    @Test func codexResumeFactsRefreshWhenThePaneAndCommandStayTheSame() async throws {
        let host = TmuxHostScript()
        func show(_ thread: String) {
            host.update {
                $0.sessionRecords = [Self.sessionRecord("$1", "main")]
                $0.windowRecords = [Self.windowRecord("@2", session: "$1", name: "codex")]
                $0.paneRecords = [Self.paneRecord("%3", session: "$1", window: "@2",
                    command: "codex", pid: 4242, tty: "/dev/ttys004")]
                $0.execRules = [("ps -t", FakeHostSSHServices.result(stdout: """
                    __WAYCAR_TTY__=ttys004
                     4242 4242 5000 Ss -zsh
                     5000 5000 5000 S+ codex resume \(thread)

                    """))]
            }
        }
        show("A")
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        #expect(await transport.serverSessionLinkFacts().commandLines == ["tmux:%3": "codex resume A"])
        show("B")
        _ = try await transport.sessionSnapshot()
        #expect(await transport.serverSessionLinkFacts().commandLines == ["tmux:%3": "codex resume B"])
        // Exactly one batched process lookup per snapshot, no extra link probe.
        #expect(await fake.execs(containing: "ps -t").count == 2)
        try await transport.close()
    }

    /// A desk `opencode` pane's command line must reach the session links,
    /// though `opencode` is a known executable that needs no kind lookup.
    @Test func openCodeDeskPanesLinkFromTheSnapshotsBatchedPsRead() async throws {
        let host = TmuxHostScript()
        func show(_ session: String) {
            host.update {
                $0.sessionRecords = [Self.sessionRecord("$1", "main")]
                $0.windowRecords = [Self.windowRecord("@2", session: "$1", name: "opencode")]
                $0.paneRecords = [
                    Self.paneRecord("%3", session: "$1", window: "@2",
                        command: "opencode", pid: 4242, tty: "/dev/ttys004"),
                    Self.paneRecord("%4", session: "$1", window: "@2",
                        command: "opencode", pid: 4343, tty: "/dev/ttys005"),
                ]
                $0.execRules = [("ps -t", FakeHostSSHServices.result(stdout: """
                    __WAYCAR_TTY__=ttys004
                     4242 4242 5000 Ss -zsh
                     5000 5000 5000 S+ opencode --session \(session)
                    __WAYCAR_TTY__=ttys005
                     4343 4343 5100 Ss -zsh
                     5100 5100 5100 S+ opencode

                    """))]
            }
        }
        show("ses_a")
        let (transport, fake) = try await Self.open(host)
        let snapshot = try await transport.sessionSnapshot()
        let facts = await transport.serverSessionLinkFacts()
        #expect(facts.commandLines == ["tmux:%3": "opencode --session ses_a", "tmux:%4": "opencode"])
        let merged = await MainActor.run {
            ServerSessionLinks.merge(Self.linkRows(snapshot, facts: facts, sessions: [
                ("ses_a", "/elsewhere", "waycar"), ("ses_desk", "/home/me/repo", "user"),
            ])) { _ in nil }
        }
        // Both panes are hidden behind their sessions' Show Terminal.
        #expect(merged.map(\.agent.paneID).sorted() == ["opencode:ses_a", "opencode:ses_desk"])
        #expect(merged.first { $0.agent.paneID == "opencode:ses_a" }?.linkedTerminal?.id.paneID == "tmux:%3")
        #expect(merged.first { $0.agent.paneID == "opencode:ses_desk" }?.linkedTerminal?.id.paneID == "tmux:%4")
        // Refreshed like Codex: the same process can name another session.
        show("ses_b")
        _ = try await transport.sessionSnapshot()
        #expect(await transport.serverSessionLinkFacts().commandLines["tmux:%3"] == "opencode --session ses_b")
        // One batched process lookup per snapshot, no extra link probe.
        #expect(await fake.execs(containing: "ps -t").count == 2)
        try await transport.close()
    }

    /// Console rows for a tmux snapshot's Agents and OpenCode sessions, as
    /// the projection builds them for `ServerSessionLinks`.
    @MainActor
    private static func linkRows(
        _ snapshot: SessionSnapshot, facts: ServerSessionLinkFacts,
        sessions: [(id: String, cwd: String, origin: String)]
    ) -> [ConsoleAgent] {
        let host = Host.fixture()
        let panes = snapshot.agents.map { info in
            var row = ConsoleAgent(hostID: host.id, hostName: host.displayName, agent: Agent(info),
                workspaceLabel: nil, repositoryCheckout: nil, backend: .tmux)
            row.paneCommandLine = facts.commandLines[info.paneID]
            return row
        }
        return panes + sessions.map { session in
            let paneID = "opencode:\(session.id)"
            var row = ConsoleAgent(hostID: host.id, hostName: host.displayName,
                agent: Agent(terminalID: paneID, kind: "opencode", title: "Task", status: .idle,
                    workspaceID: "opencode:cwd:\(session.cwd)", tabID: paneID, paneID: paneID,
                    cwd: session.cwd, revision: 1),
                workspaceLabel: nil, repositoryCheckout: nil, backend: .opencode)
            row.serverSessionOrigin = session.origin
            return row
        }
    }

    @Test func shellActivityComesFromTheSnapshotsPsLeader() async throws {
        let host = TmuxHostScript()
        func show(_ command: String, leader: String) {
            host.update {
                $0.sessionRecords = [Self.sessionRecord("$1", "main")]
                $0.windowRecords = [Self.windowRecord("@2", session: "$1", name: "sh")]
                $0.paneRecords = [
                    Self.paneRecord(
                        "%3", session: "$1", window: "@2", command: command, pid: 4242,
                        tty: "/dev/ttys004")
                ]
                $0.execRules = [(
                    "ps -t",
                    FakeHostSSHServices.result(stdout: """
                        __WAYCAR_TTY__=ttys004
                         4242  4242  5000 Ss   -zsh
                         5000  5000  5000 S+   \(leader)

                        """)
                )]
            }
        }
        show("sudo", leader: "sudo apt update")
        let (transport, fake) = try await Self.open(host)
        let snapshot = try await transport.sessionSnapshot()
        #expect(snapshot.agents.isEmpty)
        #expect(try await transport.shellActivities(paneIDs: ["tmux:%3", "tmux:%9"])
            == ["tmux:%3": .running(command: "sudo apt update")])
        #expect(await fake.execs(containing: "ps -t").count == 1)

        _ = try await transport.sessionSnapshot()
        #expect(await fake.execs(containing: "ps -t").count == 1)

        show("zsh", leader: "zsh")
        _ = try await transport.sessionSnapshot()
        #expect(try await transport.shellActivities(paneIDs: ["tmux:%3"]) == ["tmux:%3": .idle])
        #expect(await fake.execs(containing: "ps -t").count == 1)

        show("sudo", leader: "sudo apt upgrade")
        _ = try await transport.sessionSnapshot()
        #expect(await fake.execs(containing: "ps -t").count == 2)
        #expect(try await transport.shellActivities(paneIDs: ["tmux:%3"])
            == ["tmux:%3": .running(command: "sudo apt upgrade")])
        try await transport.close()
    }

    // MARK: Input

    @Test func promptIsOneLineOfBufferPasteAndEnter() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)
        let draft = "fix the \"bug\" in $HOME\nthen ~/run it"

        let agent = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: draft))
        #expect(agent.paneID == "tmux:%3")
        #expect(agent.kind == "claude")
        let line = try #require(channel.writtenLines.last)
        let buffer = try #require(
            line.split(separator: " ").dropFirst(2).first.map(String.init))
        #expect(buffer.hasPrefix("waycar-"))
        #expect(line == [
            TmuxCommand.setBuffer(name: buffer, text: draft),
            "copy-mode -q -t %3",
            TmuxCommand.pasteBuffer(name: buffer, target: "%3"),
            "send-keys -t %3 Enter",
        ].joined(separator: " ; "))

        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: ""))
        #expect(channel.writtenLines.last == "copy-mode -q -t %3 ; send-keys -t %3 Enter")
        try await transport.close()
    }

    @Test func promptErrorReplyMapsToHerdrCodes() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update { $0.lineRules = [("copy-mode -q -t %9", [.error(["can't find pane: %9"])])] }
        let (transport, _) = try await Self.open(host)
        do {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%9", text: ""))
            Issue.record("prompt to a missing pane succeeded")
        } catch let error as HerdrAPIError {
            #expect(error.code == "pane_not_found")
        }
        try await transport.close()
    }

    /// `paste-buffer -d` deletes the buffer only after a paste, so a prompt
    /// whose paste fails clears the draft's buffer itself.
    @Test func failedPromptDeletesItsBuffer() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [("set-buffer", [.ok([]), .error(["can't find pane: %3"])])]
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        do {
            _ = try await transport.promptAgent(
                AgentPromptParams(target: "tmux:%3", text: "the secret draft"))
            Issue.record("a prompt whose paste failed succeeded")
        } catch let error as HerdrAPIError {
            #expect(error.code == "pane_not_found")
        }
        let line = try #require(channel.writtenLines.first { $0.hasPrefix("set-buffer") })
        let buffer = try #require(line.split(separator: " ").dropFirst(2).first.map(String.init))
        #expect(buffer.hasPrefix("waycar-"))
        #expect(await eventually { channel.writtenLines.contains("delete-buffer -b \(buffer)") })
        try await transport.close()
    }

    /// The cleanup never connects: a prompt whose channel was lost under it
    /// fails at once, without a `tmux ls` or a new control client.
    @Test func failedPromptOnALostChannelReturnsWithoutReconnecting() async throws {
        let host = TmuxHostScript.withClaudePane()
        // tmux never answers the line.
        host.update { $0.lineRules = [("set-buffer", [])] }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        let listings = await fake.execs(containing: "tmux ls").count

        let prompt = Task {
            try await transport.promptAgent(
                AgentPromptParams(target: "tmux:%3", text: "the secret draft"))
        }
        #expect(await eventually { channel.writtenLines.contains { $0.hasPrefix("set-buffer") } })
        channel.lose()
        await #expect(throws: (any Error).self) { _ = try await prompt.value }

        #expect(await fake.execs(containing: "tmux ls").count == listings)
        #expect(await fake.controlChannels.count == 1)
        #expect(!channel.writtenLines.contains { $0.hasPrefix("delete-buffer") })
        try await transport.close()
    }

    /// herdr refuses `agent.prompt` for a Blocked Agent (`agent_blocked`):
    /// Enter would answer its question. Nothing reaches the pane.
    @Test(arguments: ["claude", "pi"])
    func blockedAgentRefusesPrompts(kind: String) async throws {
        let host = TmuxHostScript()
        host.update {
            $0.sessionRecords = [Self.sessionRecord("$1", "main")]
            $0.windowRecords = [Self.windowRecord("@2", session: "$1", name: kind)]
            $0.paneRecords = [
                Self.paneRecord(
                    "%3", session: "$1", window: "@2", command: kind, agent: kind,
                    status: "blocked")
            ]
        }
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)
        let written = channel.writtenLines.count
        do {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "yes"))
            Issue.record("prompted a blocked agent")
        } catch let error as HerdrAPIError {
            #expect(error.code == "agent_blocked")
        }
        #expect(channel.writtenLines.count == written)
        try await transport.close()
    }

    @Test func keysMapToSendKeysAndUnknownNamesSendNothing() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)

        try await transport.sendAgentKeys(AgentSendKeysParams(keys: ["esc", "enter"], target: "tmux:%3"))
        #expect(channel.writtenLines.last
            == "copy-mode -q -t %3 ; send-keys -t %3 Escape ; send-keys -t %3 Enter")

        try await transport.sendPaneInput(
            PaneSendInputParams(paneID: "tmux:%3", keys: ["enter"], text: "ls"))
        let input = try #require(channel.writtenLines.last)
        #expect(input.hasPrefix("set-buffer -b waycar-"))
        #expect(input.hasSuffix(" ; send-keys -t %3 Enter"))

        let written = channel.writtenLines.count
        do {
            try await transport.sendAgentKeys(
                AgentSendKeysParams(keys: ["enter", "hyperspace"], target: "tmux:%3"))
            Issue.record("an unknown key was sent")
        } catch let error as HerdrAPIError {
            #expect(error.code == "invalid_key")
        }
        #expect(channel.writtenLines.count == written)
        try await transport.close()
    }

    // MARK: Launch

    @Test(arguments: [true, false], [true, false])
    func agentLaunchRunsTheWrapperInAMarkedWindow(
        codexKnowsNoDaemon: Bool, joinsCodexServer: Bool
    ) async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.execRules = [(
                "codex --help",
                FakeHostSSHServices.result(
                    stdout: codexKnowsNoDaemon
                        ? "Usage: codex [OPTIONS]\n      --no-daemon  Run in-process\n"
                        : "Usage: codex [OPTIONS]\n")
            )]
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                ("display -p -t %7", [.ok([Self.readiness("%7", command: "zsh")])]),
            ]
            // The new pane is listed, still running the login shell.
            $0.paneRecords.append(
                Self.paneRecord("%7", session: "$1", window: "@4", command: "zsh"))
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        let steps = Recorder<LaunchStep>()
        let request = AgentLaunchRequest(
            kind: "codex", name: "fix bug", arguments: ["resume", "a b"], workspaceID: "tmux:$1",
            cwd: "/work/repo", joinsCodexServer: joinsCodexServer)

        let agent = try await LaunchProgress.$reporter.withValue({ step in
            steps.append(step)
        }) {
            try await transport.startAgent(request)
        }

        let agentCommand =
            codexKnowsNoDaemon && !joinsCodexServer
                ? "codex --no-daemon resume 'a b'" : "codex resume 'a b'"
        let launchLine = channel.writtenLines.first { $0.hasPrefix("new-window") }
        #expect(launchLine == TmuxCommand.newWindow(
            sessionTarget: "$1", cwd: "/work/repo", name: "fix bug",
            environment: ["WAYCAR_SHELL": "1"],
            command: TmuxCommand.loginShellWrapper(agentCommand: agentCommand),
            printFormat: TmuxTransport.launchPrintFormat))
        #expect(steps.values == [.creatingTab, .startingAgent])
        #expect(agent.paneID == "tmux:%7")
        #expect(agent.terminalID == "tmux:%7@\(TmuxHostScript.serverIdentity)")
        #expect(agent.tabID == "tmux:@4")
        #expect(agent.workspaceID == "tmux:$1")
        #expect(agent.kind == "codex")

        // Still a shell in front: the launch gate holds the first prompt.
        do {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
            Issue.record("prompted an agent that has not started")
        } catch let error as HerdrAPIError {
            #expect(error.code == "agent_not_ready")
        }
        #expect(!channel.writtenLines.contains { $0.hasPrefix("set-buffer") })

        // A shared-server pane skips the probe; ordinary launches cache it.
        _ = try await transport.startAgent(request)
        #expect(await fake.execs(containing: "codex --help").count == (joinsCodexServer ? 0 : 1))
        try await transport.close()
    }

    /// A launch's pane variables (a Chat Prompt route) ride an `env` prefix
    /// inside the wrapper, so they reach the agent alone and not the login
    /// shell left when it exits; the window keeps only `WAYCAR_SHELL`.
    @Test func launchEnvironmentReachesOnlyTheAgent() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                ("display -p -t %7", [.ok([Self.readiness("%7", command: "zsh")])]),
            ]
            $0.paneRecords.append(Self.paneRecord("%7", session: "$1", window: "@4", command: "zsh"))
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)

        _ = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "hermes", name: "chat", arguments: ["chat"], workspaceID: "tmux:$1",
                cwd: "/work/repo",
                environment: ["HERMES_EPHEMERAL_SYSTEM_PROMPT": "Text back, it's short.", "A_B": "1"]))

        let launchLine = channel.writtenLines.first { $0.hasPrefix("new-window") }
        #expect(launchLine == TmuxCommand.newWindow(
            sessionTarget: "$1", cwd: "/work/repo", name: "chat",
            environment: ["WAYCAR_SHELL": "1"],
            command: TmuxCommand.loginShellWrapper(
                agentCommand: #"env A_B=1 'HERMES_EPHEMERAL_SYSTEM_PROMPT=Text back, it'\''s short.' hermes chat"#),
            printFormat: TmuxTransport.launchPrintFormat))
        await #expect(throws: HerdrAPIError.self) {
            try await transport.startAgent(
                AgentLaunchRequest(
                    kind: "hermes", name: "chat", workspaceID: "tmux:$1", environment: ["1X; rm": "x"]))
        }
        try await transport.close()
    }

    @Test func claudeLaunchWaitsForItsSessionHook() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                // claude runs, its SessionStart hook has not set anything yet.
                ("display -p -t %7", [.ok([Self.readiness("%7", command: "claude")])]),
            ]
            // The new pane is listed, so the launch's snapshot keeps its gate.
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@4", command: "claude", pid: 4300,
                tty: "/dev/ttys009"))
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "claude", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))

        await Self.expectNotReady(transport, pane: "tmux:%7")
        #expect(!channel.writtenLines.contains { $0.hasPrefix("set-buffer") })

        host.update {
            $0.lineRules[1] = (
                "display -p -t %7",
                [.ok([Self.readiness("%7", command: "claude", agent: "claude", session: "session-1")])]
            )
        }
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    @Test func claudeLaunchWithoutHooksIsPromptableOnceTheGateExpires() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                // No Status Hooks on this Host: `@waycar_session` never appears.
                ("display -p -t %7", [.ok([Self.readiness("%7", command: "claude")])]),
            ]
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@4", command: "claude", pid: 4300,
                tty: "/dev/ttys009"))
        }
        let timeout = Duration.seconds(1)
        let (transport, fake) = try await Self.open(host, claudeReadyTimeout: timeout)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "claude", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))
        // The gate started inside startAgent, so it expires by `launched + timeout`.
        let launched = ContinuousClock.now

        await Self.expectNotReady(transport, pane: "tmux:%7")

        try await Task.sleep(until: launched + timeout + .milliseconds(100), clock: .continuous)
        let readinessChecks = channel.writtenLines.filter { $0.hasPrefix("display -p -t %7") }.count
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        // An expired gate takes a screen read, not another readiness probe.
        #expect(channel.writtenLines.filter { $0.hasPrefix("display -p -t %7") }.count
            == readinessChecks)
        try await transport.close()
    }

    /// Past the timeout a claude still on its folder-trust dialog keeps the
    /// gate closed: the prompt's Enter would trust the folder.
    @Test func claudeTrustDialogHoldsTheGatePastTheTimeout() async throws {
        let host = TmuxHostScript.withClaudePane()
        let trustDialog = [
            String(repeating: "─", count: 40),
            " Do you trust the files in this folder?",
            " /work/repo",
            " ❯ 1. Yes, proceed",
            "   2. No, exit",
        ]
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                ("display -p -t %7", [.ok([Self.readiness("%7", command: "claude")])]),
                ("capture-pane", [.ok(trustDialog), .ok(["claude"])]),
            ]
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@4", command: "claude", pid: 4300,
                tty: "/dev/ttys009"))
        }
        // The timeout has passed as soon as the launch returns.
        let (transport, fake) = try await Self.open(host, claudeReadyTimeout: .zero)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "claude", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))

        await Self.expectNotReady(transport, pane: "tmux:%7")
        #expect(!channel.writtenLines.contains { $0.hasPrefix("set-buffer") })

        // The user answered the dialog.
        host.update { $0.lineRules.removeLast() }
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    /// A launched opencode drops input until its TUI draws the input box
    /// (6–24 s on Linux Hosts), so the gate reads the screen until then; a
    /// shell's output from before opencode took the alternate screen never
    /// counts.
    @Test func opencodeLaunchWaitsForItsInputBox() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                // opencode runs, the shell's rc output still on screen.
                ("display -p -t %7", [.ok([Self.readiness("%7", command: "opencode")])]),
                ("capture-pane", [.ok(["  ┃ motd box", "me@host:~$ opencode"])]),
            ]
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@4", command: "opencode", pid: 4300,
                tty: "/dev/ttys009"))
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "opencode", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))

        await Self.expectNotReady(transport, pane: "tmux:%7")

        // Its alternate screen, still blank: the TUI is loading.
        host.update {
            $0.lineRules[1] = (
                "display -p -t %7",
                [.ok([Self.readiness("%7", command: "opencode", alternateScreen: true)])])
            $0.lineRules[2] = ("capture-pane", [.ok(["", "", ""])])
        }
        await Self.expectNotReady(transport, pane: "tmux:%7")
        #expect(!channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        // Past `launchReadyDelay` (50 ms here): still gated on the screen.
        try await Task.sleep(for: .milliseconds(100))
        await Self.expectNotReady(transport, pane: "tmux:%7")

        host.update {
            $0.lineRules[2] = ("capture-pane", [.ok(TmuxScreenDetectorTests.opencodeHome)])
        }
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    /// A status on the pane means opencode has taken input already (typed
    /// in the terminal): no screen read is needed.
    @Test func opencodeWithAStatusIsPromptableAtOnce() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                ("display -p -t %7", [.ok([Self.readiness(
                    "%7", command: "opencode", agent: "opencode", status: "working",
                    alternateScreen: true)])]),
            ]
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@4", command: "opencode", pid: 4300,
                tty: "/dev/ttys009"))
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "opencode", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))

        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        #expect(!channel.writtenLines.contains { $0.hasPrefix("capture-pane") && $0.hasSuffix("-t %7") })
        try await transport.close()
    }

    /// An opencode whose input box never shows (another UI, an unknown
    /// release) is promptable once the cap has passed, without a read.
    @Test func opencodeLaunchIsPromptableOnceTheCapExpires() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                ("display -p -t %7", [.ok([Self.readiness(
                    "%7", command: "opencode", alternateScreen: true)])]),
                ("capture-pane", [.ok(["  Loading plugins…"])]),
            ]
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@4", command: "opencode", pid: 4300,
                tty: "/dev/ttys009"))
        }
        let cap = Duration.seconds(1)
        let (transport, fake) = try await Self.open(host, inputReadyTimeout: cap)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "opencode", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))
        // The gate started inside startAgent, so it expires by `launched + cap`.
        let launched = ContinuousClock.now

        await Self.expectNotReady(transport, pane: "tmux:%7")

        try await Task.sleep(until: launched + cap + .milliseconds(100), clock: .continuous)
        let reads = channel.writtenLines.filter {
            $0.hasPrefix("display -p -t %7") || $0.hasPrefix("capture-pane") && $0.hasSuffix("-t %7")
        }.count
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        #expect(channel.writtenLines.filter {
            $0.hasPrefix("display -p -t %7") || $0.hasPrefix("capture-pane") && $0.hasSuffix("-t %7")
        }.count == reads)
        try await transport.close()
    }

    /// Other kinds keep the plain delay after detection: no screen read,
    /// no hook wait.
    @Test func piLaunchIsPromptableTheDelayAfterDetection() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                ("display -p -t %7", [.ok([Self.readiness("%7", command: "pi")])]),
            ]
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@4", command: "pi", pid: 4300,
                tty: "/dev/ttys009"))
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "pi", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))

        // Detected now; promptable `launchReadyDelay` (50 ms here) later.
        await Self.expectNotReady(transport, pane: "tmux:%7")
        try await Task.sleep(for: .milliseconds(100))
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        #expect(!channel.writtenLines.contains { $0.hasPrefix("capture-pane") && $0.hasSuffix("-t %7") })
        try await transport.close()
    }

    /// kilo drops input until its `┃` box draws, cline until its `❯`
    /// composer does (kilo.md, cline.md): the same screen gate as
    /// opencode's, each on its own marker.
    @Test(arguments: [
        ("kilo", AgentScreenTests.kiloReady), ("cline", AgentScreenTests.clineReady),
    ])
    func markerLaunchWaitsForItsInput(kind: String, ready: [String]) async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                // cline's delayed CR reads status, screen and title first.
                (
                    TmuxCommand.display(format: "#{@waycar_status}", target: "%7"),
                    [.ok([""]), .ok(["❯ hi"]), .ok([""])]
                ),
                ("display -p -t %7", [.ok([Self.readiness(
                    "%7", command: kind, alternateScreen: true)])]),
                ("capture-pane", [.ok(["", "", ""])]),
            ]
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@4", command: kind, pid: 4300,
                tty: "/dev/ttys009"))
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: kind, name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))

        // Past `launchReadyDelay` (50 ms here): still gated on the screen.
        try await Task.sleep(for: .milliseconds(100))
        await Self.expectNotReady(transport, pane: "tmux:%7")
        #expect(!channel.writtenLines.contains { $0.hasPrefix("set-buffer") })

        host.update { $0.lineRules[3] = ("capture-pane", [.ok(ready)]) }
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    /// copilot lost a paste 0.3 s after launch and nothing on screen tells
    /// (copilot.md): it waits out its minimum delay from detection, since
    /// the lab timed that from the agent's own start and the login shell's
    /// rc files can run for seconds after `new-window` returns.
    @Test func minimumDelayKindWaitsPastDetection() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                ("display -p -t %7", [.ok([Self.readiness("%7", command: "copilot")])]),
            ]
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@4", command: "copilot", pid: 4300,
                tty: "/dev/ttys009"))
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "copilot", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))

        // The delay passes since launch before the agent is first seen.
        let delay = AgentScreen.readiness(kind: "copilot").minimumDelay
        try await Task.sleep(for: delay)
        await Self.expectNotReady(transport, pane: "tmux:%7")
        let detected = ContinuousClock.now
        // Detected for longer than `launchReadyDelay` (50 ms here).
        try await Task.sleep(for: .milliseconds(100))
        await Self.expectNotReady(transport, pane: "tmux:%7")

        try await Task.sleep(until: detected + delay, clock: .continuous)
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    /// `copilot --resume=<id>` while the session's last process lives opens
    /// "Session in use" before any hook can fire; its Enter picks "Resume
    /// anyway" and the prompt's text is lost (harness lab, copilot 1.0.96).
    /// The gate holds while a dialog shows, and opens once it is answered.
    @Test func launchGateHoldsWhileADialogShows() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                ("display -p -t %7", [.ok([Self.readiness("%7", command: "copilot")])]),
                ("capture-pane", [.ok(TmuxScreenDetectorTests.copilotSessionInUse), .ok([""])]),
            ]
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@4", command: "copilot", pid: 4300,
                tty: "/dev/ttys009"))
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "copilot", name: "", arguments: ["--resume=s1"], workspaceID: "tmux:$1",
            cwd: "/work/repo"))

        await Self.expectNotReady(transport, pane: "tmux:%7")
        try await Task.sleep(for: AgentScreen.readiness(kind: "copilot").minimumDelay)
        await Self.expectNotReady(transport, pane: "tmux:%7")
        #expect(channel.writtenLines.contains { $0.hasPrefix("capture-pane") })
        #expect(!channel.writtenLines.contains { $0.hasPrefix("set-buffer") })

        host.update {
            $0.lineRules[2] = ("capture-pane", [.ok(TmuxScreenDetectorTests.copilotIdle), .ok([""])])
        }
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    /// cursor, devin and kiro open on a sign-in screen where a prompt's text
    /// and Enter drive the login (herdr-backend.md): the prompt is refused
    /// with nothing typed, until the screen shows something else.
    @Test func signInScreenRefusesThePrompt() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("capture-pane", [.ok(AgentScreenTests.cursorFirstScreen)]),
            ]
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@2", command: "cursor-agent", pid: 4300,
                tty: "/dev/ttys009"))
        }
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        await #expect(throws: AgentSignInRequiredError(kind: "cursor", target: "tmux:%7")) {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        }
        #expect(!channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        #expect(!channel.writtenLines.contains { $0.contains("send-keys -t %7") })

        host.update { $0.lineRules = [("capture-pane", [.ok(["> ready"])])] }
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    /// A launch gate outlives its Agent when the user quits it at the desk
    /// and starts another in the login shell the launch leaves: the screen
    /// is read for the Agent the pane now runs, not the launch's kind.
    @Test func signInCheckReadsTheDetectedKindOverAStaleLaunchGate() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@2\u{241F}$1"])]),
                ("capture-pane", [.ok(AgentScreenTests.cursorFirstScreen)]),
            ]
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@2", command: "cursor-agent", pid: 4300,
                tty: "/dev/ttys009"))
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "opencode", name: "", workspaceID: "tmux:$1", cwd: "/work/repo"))
        _ = try await transport.sessionSnapshot()

        await #expect(throws: AgentSignInRequiredError(kind: "cursor", target: "tmux:%7")) {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        }
        #expect(!channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    /// grok's folder-trust dialog takes `y` as "trust" and `n` as "quit",
    /// and qwen's hook reports idle under its dialog (harness lab,
    /// 2026-10-12): a prompt to such a kind reads the screen first and is
    /// refused, nothing typed, while the dialog shows, whatever the hook
    /// says; once it is answered the prompt goes.
    @Test func trustDialogRefusesThePrompt() async throws {
        let host = TmuxHostScript()
        host.update {
            $0.sessionRecords = [Self.sessionRecord("$1", "main")]
            $0.windowRecords = [Self.windowRecord("@2", session: "$1", name: "grok")]
            $0.paneRecords = [
                Self.paneRecord(
                    "%3", session: "$1", window: "@2", command: "grok", agent: "grok",
                    status: "idle")
            ]
            $0.lineRules = [("capture-pane", [.ok(AgentScreenTests.grokTrust)])]
        }
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        await #expect(throws: AgentFolderTrustRequiredError(kind: "grok", target: "tmux:%3")) {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "hey"))
        }
        #expect(!channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        #expect(!channel.writtenLines.contains { $0.contains("send-keys -t %3") })

        host.update { $0.lineRules = [("capture-pane", [.ok(AgentScreenTests.grokIdle)])] }
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "hey"))
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    /// tmux's screen rules read grok's trust dialog as Blocked, and the
    /// Composer types into a Blocked Agent's Attach: it asks this check
    /// first, which reads the screen, writes no input, and refuses while
    /// the dialog shows.
    @Test func inputScreenCheckRefusesABlockedTrustDialog() async throws {
        let host = TmuxHostScript()
        host.update {
            $0.sessionRecords = [Self.sessionRecord("$1", "main")]
            $0.windowRecords = [Self.windowRecord("@2", session: "$1", name: "grok")]
            $0.paneRecords = [
                Self.paneRecord(
                    "%3", session: "$1", window: "@2", command: "grok", agent: "grok",
                    status: "blocked")
            ]
            $0.lineRules = [("capture-pane", [.ok(AgentScreenTests.grokTrust)])]
        }
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        await #expect(throws: AgentFolderTrustRequiredError(kind: "grok", target: "tmux:%3")) {
            try await transport.checkAgentInputScreen(target: "tmux:%3")
        }
        #expect(!channel.writtenLines.contains { $0.contains("paste-buffer") || $0.contains("send-keys") })

        host.update { $0.lineRules = [("capture-pane", [.ok(AgentScreenTests.grokIdle)])] }
        try await transport.checkAgentInputScreen(target: "tmux:%3")
        try await transport.close()
    }

    /// hermes, gemini and cline leave a paste unsubmitted when its Enter
    /// comes on the same control line (hermes.md, gemini.md, cline.md): a
    /// raw CR, the bytes a terminal's Enter sends, goes on a line of its own
    /// after the kind's delay, once one read shows the draft still waiting
    /// in the input.
    @Test(arguments: [("hermes", "❯ draft"), ("gemini", " > draft"), ("cline", "❯ draft")])
    func delayedSubmitSendsACarriageReturnOnItsOwnLine(kind: String, inputRow: String) async throws {
        let host = TmuxHostScript()
        host.update {
            $0.sessionRecords = [Self.sessionRecord("$1", "main")]
            $0.windowRecords = [Self.windowRecord("@2", session: "$1", name: kind)]
            $0.paneRecords = [
                Self.paneRecord(
                    "%3", session: "$1", window: "@2", command: "node", agent: kind,
                    status: "idle")
            ]
            $0.lineRules = [Self.submitRead(status: "idle", screen: [inputRow])]
        }
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        let sent = ContinuousClock.now
        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
        #expect(sent.duration(to: .now) >= AgentScreen.readiness(kind: kind).submitDelay)
        let lines = Array(channel.writtenLines.suffix(3))
        let buffer = try #require(
            lines.first?.split(separator: " ").dropFirst(2).first.map(String.init))
        #expect(lines == [
            [
                TmuxCommand.setBuffer(name: buffer, text: "draft"),
                "copy-mode -q -t %3",
                TmuxCommand.pasteBuffer(name: buffer, target: "%3"),
            ].joined(separator: " ; "),
            Self.submitReadLine,
            "copy-mode -q -t %3 ; send-keys -t %3 -H 0d",
        ])
        try await transport.close()
    }

    /// The one read before a delayed submit's CR: `%3`'s `@waycar_status`,
    /// visible screen and title.
    static let submitReadLine = [
        TmuxCommand.display(format: "#{@waycar_status}", target: "%3"),
        TmuxCommand.capturePane(target: "%3", lines: 0),
        TmuxCommand.display(format: "#{pane_title}", target: "%3"),
    ].joined(separator: " ; ")

    static func submitRead(status: String, screen: [String]) -> (String, [FakeTmuxBlock]) {
        (submitReadLine, [.ok([status]), .ok(screen), .ok([""])])
    }

    /// An idle `kind` Agent (gemini: a 500 ms `submitDelay`) in `%3`, the
    /// read before its CR answering `status` and `screen`.
    private static func submitPaneHost(
        kind: String = "gemini", status: String = "idle",
        screen: [String] = AgentScreenTests.geminiDraft
    ) -> TmuxHostScript {
        let host = TmuxHostScript()
        host.update {
            $0.sessionRecords = [Self.sessionRecord("$1", "main")]
            $0.windowRecords = [Self.windowRecord("@2", session: "$1", name: kind)]
            $0.paneRecords = [
                Self.paneRecord(
                    "%3", session: "$1", window: "@2", command: "node", agent: kind,
                    status: "idle")
            ]
            $0.lineRules = [Self.submitRead(status: status, screen: screen)]
        }
        return host
    }

    /// Once the paste is in, the delayed CR goes even when the caller is
    /// cancelled: a draft left unsubmitted would be sent with the next one.
    @Test func delayedSubmitOutlivesTheCallersCancellation() async throws {
        let (transport, fake) = try await Self.open(Self.submitPaneHost())
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        let prompt = Task {
            try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
        }
        #expect(await eventually { channel.writtenLines.contains { $0.hasPrefix("set-buffer") } })
        // Inside gemini's 500 ms gap, once the paste's reply is in.
        try await Task.sleep(for: .milliseconds(200))
        prompt.cancel()
        _ = try? await prompt.value
        #expect(channel.writtenLines.last == "copy-mode -q -t %3 ; send-keys -t %3 -H 0d")
        try await transport.close()
    }

    /// A second prompt sent inside the first one's gap waits for that CR:
    /// pasted in the gap, it would join the first draft and go with it.
    @Test func aSecondPromptWaitsForTheFirstOnesDelayedEnter() async throws {
        let (transport, fake) = try await Self.open(Self.submitPaneHost())
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)
        let release = try await Self.holdFirstPromptBeforeItsEnter(on: transport, channel)

        let first = release.prompt
        let second = Task {
            try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
        }
        #expect(await eventually { await transport.promptTurns["%3"]?.waiting.count == 1 })
        #expect(channel.writtenLines.filter { $0.hasPrefix("set-buffer") }.count == 1)
        release.continuation.yield(())
        _ = try await first.value
        _ = try await second.value
        let order = channel.writtenLines.compactMap { line -> String? in
            if line.hasPrefix("set-buffer") { return "paste" }
            if line.hasSuffix("-H 0d") { return "enter" }
            return nil
        }
        #expect(order == ["paste", "enter", "paste", "enter"])
        try await transport.close()
    }

    /// A prompt cancelled while it waits for the pane gives its place up
    /// with nothing sent; the turn passes over it to the next one in line.
    @Test func aPromptCancelledWhileWaitingSendsNothing() async throws {
        let (transport, fake) = try await Self.open(Self.submitPaneHost())
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)
        let release = try await Self.holdFirstPromptBeforeItsEnter(on: transport, channel)

        let cancelled = Task {
            try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
        }
        #expect(await eventually { await transport.promptTurns["%3"]?.waiting.count == 1 })
        let third = Task {
            try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
        }
        #expect(await eventually { await transport.promptTurns["%3"]?.waiting.count == 2 })
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(await transport.promptTurns["%3"]?.waiting.count == 1)
        release.continuation.yield(())
        _ = try await release.prompt.value
        _ = try await third.value
        #expect(channel.writtenLines.filter { $0.hasPrefix("set-buffer") }.count == 2)
        #expect(channel.writtenLines.filter { $0.hasSuffix("-H 0d") }.count == 2)
        #expect(await transport.promptTurns["%3"] == nil)
        try await transport.close()
    }

    /// Starts a prompt to `%3` and holds it between its paste and its
    /// delayed Enter: the read before the CR gets no reply until the test
    /// yields on the returned continuation.
    private static func holdFirstPromptBeforeItsEnter(
        on transport: TmuxTransport, _ channel: RespondingControlChannel
    ) async throws -> (
        prompt: Task<Agent, any Error>, continuation: AsyncStream<Void>.Continuation
    ) {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        channel.holdNextReply(
            from: submitReadLine, entered: entered.continuation, until: release.stream)
        let prompt = Task {
            try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
        }
        var entry = entered.stream.makeAsyncIterator()
        _ = await entry.next()
        return (prompt, release.continuation)
    }

    /// An approval that opens during the gap would take the CR as its
    /// answer: the draft stays typed, unsubmitted, and the prompt fails
    /// with a code a sender does not requeue on.
    @Test func delayedSubmitSkipsTheEnterOnceTheAgentIsBlocked() async throws {
        let (transport, fake) = try await Self.open(Self.submitPaneHost())
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        let prompt = Task {
            try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
        }
        #expect(await eventually { channel.writtenLines.contains { $0.hasPrefix("set-buffer") } })
        channel.push([Self.statusPush([["%3", "blocked", "gemini", "", "5"]])])
        do {
            _ = try await prompt.value
            Issue.record("submitted into a blocked agent")
        } catch let error as HerdrAPIError {
            #expect(error.code == "prompt_not_submitted")
        }
        #expect(!channel.writtenLines.contains { $0.contains("-H 0d") })
        try await transport.close()
    }

    /// The hook's `blocked` may land after the gap: the read before the CR
    /// takes the pane's own `@waycar_status`, not the cached one.
    @Test func delayedSubmitSkipsTheEnterWhenTheFreshStatusIsBlocked() async throws {
        let (transport, fake) = try await Self.open(Self.submitPaneHost(status: "blocked"))
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        await #expect(throws: HerdrAPIError.self) {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
        }
        #expect(channel.writtenLines.contains(Self.submitReadLine))
        #expect(!channel.writtenLines.contains { $0.contains("-H 0d") })
        try await transport.close()
    }

    /// gemini's tool approval opened during the gap, its hook not yet in:
    /// the screen shows the dialog and no draft, so no CR answers it
    /// (gemini 0.63.0, live capture).
    @Test func delayedSubmitSkipsTheEnterWhenADialogShows() async throws {
        let (transport, fake) = try await Self.open(
            Self.submitPaneHost(screen: AgentScreenTests.geminiApproval))
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        do {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
            Issue.record("submitted into a dialog")
        } catch let error as HerdrAPIError {
            #expect(error.code == "prompt_not_submitted")
        }
        #expect(!channel.writtenLines.contains { $0.contains("-H 0d") })
        try await transport.close()
    }

    /// cline asked a question during the gap: a draft matching an option's
    /// text shows on screen, but tmux's screen rules read the question as
    /// Blocked, so no CR picks the highlighted option.
    @Test func delayedSubmitSkipsTheEnterWhenTheScreenRulesReadBlocked() async throws {
        let draft = "Use the colour from the brand guide"
        let screen = TmuxScreenDetectorTests.clineQuestion
        #expect(AgentScreen.draftAwaitsEnter(
            kind: "cline", draft: draft, screen: AgentScreenTests.screen(screen)))
        let (transport, fake) = try await Self.open(Self.submitPaneHost(kind: "cline", screen: screen))
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        do {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: draft))
            Issue.record("submitted into a question")
        } catch let error as HerdrAPIError {
            #expect(error.code == "prompt_not_submitted")
        }
        #expect(channel.writtenLines.contains(Self.submitReadLine))
        #expect(!channel.writtenLines.contains { $0.contains("-H 0d") })
        try await transport.close()
    }

    // MARK: Pane history (copy mode)

    /// A tmux attach shows only tmux's redraw, so an inline agent's or a
    /// shell's history scrolls in the pane's copy mode: entered on the first
    /// older scroll (`-e` leaves it at the bottom), moved, and read again;
    /// once in it, moved only, and not reported as entered by this call.
    @Test func paneHistoryScrollsInCopyMode() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("display -p -t %3", [.ok(["0\u{241F}"])]),
                ("copy-mode -e -t %3", [.ok([]), .ok([]), .ok(["1"])]),
            ]
        }
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)
        let readBack = TmuxCommand.display(format: "#{pane_in_mode}", target: "%3")

        #expect(try await transport.scrollPaneHistory(
            paneID: "tmux:%3", towardOlderContent: true, rows: 5)
            == PaneHistoryScroll(position: .inHistory, enteredHistory: true))
        #expect(channel.writtenLines.last
            == "copy-mode -e -t %3 ; send-keys -X -N 5 -t %3 scroll-up ; \(readBack)")

        host.update {
            $0.lineRules = [
                ("display -p -t %3", [.ok(["0\u{241F}copy-mode"])]),
                ("send-keys -X", [.ok([]), .ok(["1"])]),
            ]
        }
        #expect(try await transport.scrollPaneHistory(
            paneID: "tmux:%3", towardOlderContent: false, rows: 2)
            == PaneHistoryScroll(position: .inHistory))
        #expect(channel.writtenLines.last == "send-keys -X -N 2 -t %3 scroll-down ; \(readBack)")
        // Older in a copy mode already there (a desk client's): not entered.
        #expect(try await transport.scrollPaneHistory(
            paneID: "tmux:%3", towardOlderContent: true, rows: 2)
            == PaneHistoryScroll(position: .inHistory))
        #expect(channel.writtenLines.last == "send-keys -X -N 2 -t %3 scroll-up ; \(readBack)")
        // Reading only, in copy mode.
        let written = channel.writtenLines.count
        #expect(try await transport.scrollPaneHistory(
            paneID: "tmux:%3", towardOlderContent: false, rows: 0)
            == PaneHistoryScroll(position: .inHistory))
        #expect(channel.writtenLines.count == written + 1)

        try await transport.close()
    }

    /// Keys sent to a pane in a mode go to the mode (copy mode's Enter
    /// copies and leaves), so every input line leaves it first, whoever
    /// entered it: another device, a transport since replaced, a desk
    /// client. This transport never scrolled the pane. Out of a mode the
    /// leave is a no-op.
    @Test func inputLeavesAnyModeOnItsOwnLine() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)
        let leave = "copy-mode -q -t %3"

        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "hi"))
        let prompt = try #require(channel.writtenLines.last)
        let buffer = try #require(prompt.split(separator: " ").dropFirst(2).first.map(String.init))
        #expect(prompt == [
            TmuxCommand.setBuffer(name: buffer, text: "hi"), leave,
            TmuxCommand.pasteBuffer(name: buffer, target: "%3"), "send-keys -t %3 Enter",
        ].joined(separator: " ; "))

        try await transport.sendAgentKeys(AgentSendKeysParams(keys: ["enter"], target: "tmux:%3"))
        #expect(channel.writtenLines.last == "\(leave) ; send-keys -t %3 Enter")

        try await transport.sendPaneInput(PaneSendInputParams(paneID: "tmux:%3", keys: ["esc"]))
        #expect(channel.writtenLines.last == "\(leave) ; send-keys -t %3 Escape")
        try await transport.close()
    }

    /// Scrolling down to the bottom leaves copy mode (`-e`): live again.
    @Test func paneHistoryScrolledToTheBottomIsLive() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [
                ("display -p -t %3", [.ok(["0\u{241F}copy-mode"])]),
                ("send-keys -X", [.ok([]), .ok(["0"])]),
            ]
        }
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        #expect(try await transport.scrollPaneHistory(
            paneID: "tmux:%3", towardOlderContent: false, rows: 40) == PaneHistoryScroll(position: .live))

        try await transport.leavePaneHistory(paneID: "tmux:%3")
        #expect(channel.writtenLines.last == "copy-mode -q -t %3")
        try await transport.close()
    }

    /// Copy mode has nothing to show over an alternate screen, and another
    /// mode is not the app's to drive; live, newer has nowhere to go. None
    /// sends anything but the read.
    @Test(arguments: [
        ("1\u{241F}", true, PaneHistoryPosition.unavailable),
        ("0\u{241F}view-mode", true, PaneHistoryPosition.unavailable),
        ("0\u{241F}", false, PaneHistoryPosition.live),
        ("1\u{241F}", false, PaneHistoryPosition.unavailable),
    ])
    func paneHistoryLeavesOtherScreensAlone(
        state: String, towardOlderContent: Bool, expected: PaneHistoryPosition
    ) async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update { $0.lineRules = [("display -p -t %3", [.ok([state])])] }
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)
        let written = channel.writtenLines.count

        #expect(try await transport.scrollPaneHistory(
            paneID: "tmux:%3", towardOlderContent: towardOlderContent, rows: 3)
            == PaneHistoryScroll(position: expected))
        #expect(channel.writtenLines.count == written + 1)
        #expect(!channel.writtenLines.contains { $0.contains("copy-mode") })
        try await transport.close()
    }

    @Test func shellLaunchHasNoCommandAndReturnsTmuxIDs() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update { $0.lineRules = [("new-window", [.ok(["%8\u{241F}@5\u{241F}$1"])])] }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)

        let shell = try await transport.startShellTerminal(
            ShellLaunchRequest(name: "logs", workspaceID: "tmux:$1", cwd: "/var/log"))
        #expect(shell == ShellLaunchResult(
            paneID: "tmux:%8", tabID: "tmux:@5",
            terminalID: "tmux:%8@\(TmuxHostScript.serverIdentity)", workspaceID: "tmux:$1"))
        #expect(channel.writtenLines.last == TmuxCommand.newWindow(
            sessionTarget: "$1", cwd: "/var/log", name: "logs",
            environment: ["WAYCAR_SHELL": "1"], command: nil,
            printFormat: TmuxTransport.launchPrintFormat))
        try await transport.close()
    }

    @Test func newWorkspaceWithoutSessionsStartsTheServerOverExec() async throws {
        let host = TmuxHostScript()
        host.update {
            $0.sessions = nil
            $0.execRules = [(
                "source-file -", FakeHostSSHServices.result(stdout: "%0\u{241F}@0\u{241F}$0\n")
            )]
        }
        let (transport, fake) = try await Self.open(host)
        host.update { $0.sessionsAfterOneShot = ["$0 off repo"] }

        let shell = try await transport.startShellTerminalInNewWorkspace(
            ShellLaunchRequest(), workspace: NewWorkspaceSpec(directory: "/home/me/repo"))
        #expect(shell.workspaceID == "tmux:$0")
        #expect(shell.paneID == "tmux:%0")
        // The server it started answers its identity once control attaches.
        #expect(shell.terminalID == "tmux:%0@\(TmuxHostScript.serverIdentity)")
        let exec = try #require(await fake.execs(containing: "source-file -").first)
        #expect(!exec.command.contains("LC_ALL=C"))
        #expect(exec.input == TmuxCommand.newSession(
            name: "repo", cwd: "/home/me/repo", environment: ["WAYCAR_SHELL": "1"],
            command: nil, printFormat: TmuxTransport.launchPrintFormat) + "\n")
        // Control mode attaches to the session it made.
        #expect(await fake.controlCommands.count == 1)
        try await transport.close()
    }

    /// tmux 3.2–3.6 store `.` and `:` in a session name as `_`, so a new
    /// Workspace at `waycar.dev` would collide with an existing `waycar_dev`
    /// there: the name is normalized first and made unique against that.
    @Test func newWorkspaceNameIsNormalizedBeforeTheUniquenessCheck() async throws {
        let host = TmuxHostScript()
        host.update {
            $0.sessionRecords = [Self.sessionRecord("$1", "waycar_dev")]
            $0.lineRules = [("new-session", [.ok(["%8\u{241F}@5\u{241F}$6"])])]
        }
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        _ = try await transport.startShellTerminalInNewWorkspace(
            ShellLaunchRequest(), workspace: NewWorkspaceSpec(directory: "/home/me/waycar.dev"))

        #expect(channel.writtenLines.contains(TmuxCommand.newSession(
            name: "waycar_dev-2", cwd: "/home/me/waycar.dev", environment: ["WAYCAR_SHELL": "1"],
            command: nil, printFormat: TmuxTransport.launchPrintFormat)))
        try await transport.close()
    }

    /// An idle transport knows no session, so a second Start Session, or a
    /// replay of one whose answer was lost, asks for `main` again: tmux's
    /// duplicate refusal means it exists, and control mode attaches to it.
    @Test func startMainSessionTakesAnExistingMainAsStarted() async throws {
        let host = TmuxHostScript()
        host.update { $0.sessions = nil }
        let (transport, fake) = try await Self.open(host)
        let mainLine = TmuxCommand.newSession(
            name: "main", cwd: FakeHostSSHServices.homeDirectory,
            environment: TmuxTransport.windowEnvironment, command: nil,
            printFormat: TmuxTransport.launchPrintFormat)

        // Over the one-shot exec: `main` appeared after `tmux ls` said none.
        host.update {
            $0.execRules = [(
                "source-file -",
                FakeHostSSHServices.result(stderr: "duplicate session: main\n", exitStatus: 1)
            )]
            $0.sessionsAfterOneShot = ["$1 off main"]
        }
        try await transport.startMainSession()
        #expect(await fake.execs(containing: "source-file -").first?.input == mainLine + "\n")
        let channel = try #require(await fake.controlChannels.first)

        // Over control mode.
        host.update { $0.lineRules = [("new-session", [.error(["duplicate session: main"])])] }
        try await transport.startMainSession()
        #expect(channel.writtenLines.contains(mainLine))
        #expect(await fake.controlChannels.count == 1)

        // Any other refusal is still an error.
        host.update { $0.lineRules = [("new-session", [.error(["create window failed"])])] }
        await #expect(throws: HerdrAPIError.self) { try await transport.startMainSession() }
        try await transport.close()
    }

    // MARK: Attach

    @Test func attachTargetsThePaneFromTheLastSnapshot() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()

        await #expect(throws: FakeHostSSHServices.Unsupported(operation: "attachTerminal")) {
            try await transport.attachTerminal(
                TerminalAttachRequest(target: .agentPane("tmux:%3"), takeover: true, cols: 80, rows: 24))
        }
        let command = try #require(await fake.attachCommands.first)
        #expect(command.contains("new-session -d -t '\\''$1'\\'' -s '\\''waycar-"))
        #expect(command.contains(":@2'\\'' \\; select-pane -t '\\''%3'\\''"))

        // close() sweeps orphaned attach sessions off the caller's path,
        // then returns the connection hold.
        try await transport.close()
        #expect(await eventually { await !fake.execs(containing: "kill-session").isEmpty })
        #expect(await eventually { await fake.releaseCount == 1 })
    }

    /// Suspension closes every transport: a half-dead link must not hold
    /// close() for an exec's request budget.
    @Test func closeNeverWaitsOnTheAttachSessionSweep() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        await #expect(throws: FakeHostSSHServices.Unsupported(operation: "attachTerminal")) {
            try await transport.attachTerminal(
                TerminalAttachRequest(target: .agentPane("tmux:%3"), cols: 80, rows: 24))
        }
        await fake.stallExecs(containing: "kill-session")

        let clock = ContinuousClock()
        let started = clock.now
        try await transport.close()
        #expect(clock.now - started < TmuxTransport.attachSweepBudget)
        #expect(await eventually { await !fake.execs(containing: "kill-session").isEmpty })
        // The sweep's budget runs out, and the hold still comes back.
        #expect(await eventually { await fake.releaseCount == 1 })
    }

    /// EventsSession dropped the transport after a link failure without
    /// closing it: its control slot goes to the replacement, it never opens
    /// control again, and Terminals still open on it.
    @Test func distrustedTransportGivesUpControlButKeepsAttach() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let events = EventCollector(try await transport.subscribeToEvents([]))
        let channel = try #require(await fake.controlChannels.first)

        await transport.transportDistrusted()

        #expect(channel.isClosed)
        #expect(await eventually { events.isFinished })
        #expect(await !transport.isConnected)
        await #expect(throws: TransportError.sshUnreachable(detail: "the tmux transport was replaced")) {
            _ = try await transport.ping()
        }
        #expect(await fake.controlChannels.count == 1)
        await #expect(throws: FakeHostSSHServices.Unsupported(operation: "attachTerminal")) {
            try await transport.attachTerminal(
                TerminalAttachRequest(target: .agentPane("tmux:%3"), cols: 80, rows: 24))
        }
        #expect(await fake.releaseCount == 0)

        let replacement = try await TmuxTransport.open(
            session: fake, configuration: Self.configuration())
        #expect(await fake.controlChannels.count == 2)
        #expect(try await replacement.ping().backend == .tmux)
        try await replacement.close()
        try await transport.close()
    }

    @Test func attachAsksTmuxForAPaneOutsideTheSnapshot() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update { $0.lineRules = [("display -p -t %9", [.ok(["$5\u{241F}@8"])])] }
        let (transport, _) = try await Self.open(host)

        let target = try await transport.attachTarget(
            TerminalAttachRequest(
                target: .terminal("tmux:%9@\(TmuxHostScript.serverIdentity)"), cols: 80, rows: 24))
        #expect(target == TmuxAttachCommand.Target(sessionID: "$5", windowID: "@8", paneID: "%9"))
        let bare = try await transport.attachTarget(
            TerminalAttachRequest(target: .terminal("tmux:%9"), cols: 80, rows: 24))
        #expect(bare == target)
        try await transport.close()
    }

    /// A restarted server hands `%3` out again: the pane id stays, the
    /// terminal id carries the new server's identity, so nothing keyed by
    /// the old terminal (a Chat Marker) applies to the new pane.
    @Test func restartedServerGivesARecycledPaneANewTerminalID() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, _) = try await Self.open(host)
        let before = try await transport.sessionSnapshot()
        #expect(await transport.serverIdentity == TmuxHostScript.serverIdentity)

        host.update {
            $0.serverStartTime = "1790990000"
            $0.serverPID = "5151"
        }
        try await transport.connect()
        let after = try await transport.sessionSnapshot()

        #expect(before.panes.map(\.paneID) == ["tmux:%3"])
        #expect(after.panes.map(\.paneID) == ["tmux:%3"])
        #expect(before.panes.map(\.terminalID) == ["tmux:%3@\(TmuxHostScript.serverIdentity)"])
        #expect(after.panes.map(\.terminalID) == ["tmux:%3@1790990000.5151"])
        #expect(after.agents.map(\.terminalID) == ["tmux:%3@1790990000.5151"])
        let agent = await transport.agent(forPane: "%9")
        #expect(agent.terminalID == "tmux:%9@1790990000.5151")
        try await transport.close()
    }

    @Test func startupAnswerReadsTheServerIdentity() throws {
        let line = "3.2a\u{241F}attached,control-mode,UTF-8\u{241F}1790980039\u{241F}45775"
        let answer = try TmuxTransport.startupAnswer([
            TmuxReply(commandNumber: 1, flags: 1, lines: [line], isError: false),
            TmuxReply(commandNumber: 2, flags: 1, lines: [], isError: false),
            TmuxReply(commandNumber: 3, flags: 1, lines: [], isError: false),
        ])
        #expect(answer == TmuxTransport.StartupAnswer(
            version: "3.2a", flags: "attached,control-mode,UTF-8",
            serverIdentity: "1790980039.45775"))
        #expect(TmuxTransport.serverIdentity(startTime: "", pid: "45775") == "")
        #expect(TmuxTransport.serverIdentity(startTime: "17x", pid: "45775") == "")
    }

    @Test func paneAndTerminalIDsResolveToTheRawPane() throws {
        #expect(try TmuxTransport.rawPane("tmux:%3") == "%3")
        #expect(try TmuxTransport.rawPane("tmux:%3@1790980039.45775") == "%3")
        #expect(throws: HerdrAPIError.self) { try TmuxTransport.rawPane("tmux:@3") }
        #expect(throws: HerdrAPIError.self) { try TmuxTransport.rawPane("%3@1790980039.45775") }
    }

    @Test func moshRunsTheChainWithoutQuotesOrBackslashes() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()

        await #expect(throws: FakeHostSSHServices.Unsupported(operation: "runMoshBootstrap")) {
            try await transport.runMoshBootstrap(
                TerminalAttachRequest(target: .agentPane("tmux:%3"), cols: 80, rows: 24))
        }
        let command = try #require(await fake.moshCommands.first)
        let name = try #require(
            command.split(separator: " ").first { $0.hasPrefix("waycar-") }.map(String.init))
        #expect(command == "tmux -u new-session -d -t \"$\"1 -s \(name) \";\" "
            + "set-option -t \(name) destroy-unattached on \";\" "
            + "select-window -t \(name):@2 \";\" select-pane -t %3 \";\" attach -t \(name)")
        #expect(!command.contains("'") && !command.contains("\\"))
        try await transport.close()
    }

    // MARK: Events

    @Test func statusSubscriptionChangeBecomesAStatusEvent() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        let events = EventCollector(try await transport.subscribeToEvents([.global(.paneCreated)]))
        let channel = try #require(await fake.controlChannels.first)

        // A notification between the two pushes keeps the channel from
        // coalescing them into one.
        channel.push([
            Self.statusPush([["%3", "idle", "claude", "s1", "4"]]),
            "%session-window-changed $1 @2",
            Self.statusPush([["%3", "working", "claude", "s1", "4"]]),
        ])
        #expect(await eventually {
            events.events.contains { $0.kind == PaneEventKind.agentStatusChanged.kind }
        })
        let change = try #require(events.events.first {
            $0.kind == PaneEventKind.agentStatusChanged.kind
        })
        #expect(change.data["pane_id"]?.stringValue == "tmux:%3")
        #expect(change.data["agent_status"]?.stringValue == "working")
        try await transport.close()
    }

    @Test func topologyNotificationsCoalesceIntoOneResync() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host, debounce: .milliseconds(60))
        let events = EventCollector(try await transport.subscribeToEvents([]))
        let channel = try #require(await fake.controlChannels.first)

        channel.push([
            "%window-add @5", "%layout-change @2 b25d,80x24,0,0,3", "%unlinked-window-add @6",
            "%window-add @7",
        ])
        #expect(await eventually { !events.events.isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        #expect(events.events == [
            HerdrEvent(kind: GlobalEventKind.tabCreated.kind, data: .object([:]))
        ])
        try await transport.close()
    }

    @Test func exitedChannelReattachesToANewAnchor() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        let events = EventCollector(try await transport.subscribeToEvents([]))
        let first = try #require(await fake.controlChannels.first)

        host.update { $0.sessions = ["$2 off survivor"] }
        first.exit(reason: "detached")
        #expect(await eventually { await fake.controlChannels.count == 2 })
        #expect(await fake.controlCommands.last?.hasSuffix(" '$2'") == true)
        #expect(await eventually { events.kinds.contains(TmuxEvents.resyncKind) })
        #expect(!events.isFinished)
        #expect(await transport.isConnected)
        try await transport.close()
    }

    @Test func exitWithNoSessionsLeftGoesIdle() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        let events = EventCollector(try await transport.subscribeToEvents([]))
        let first = try #require(await fake.controlChannels.first)

        host.update { $0.sessions = nil }
        first.exit(reason: "server exited")
        #expect(await eventually { events.kinds.contains(TmuxEvents.resyncKind) })
        #expect(!events.isFinished)
        #expect(await fake.controlChannels.count == 1)
        #expect(try await transport.sessionSnapshot().workspaces.isEmpty)
        try await transport.close()
    }

    /// tmux below 3.6 (T24): a bulk Close kills the anchor session's only
    /// window, tmux answers that line and sends `%exit`, and the lines
    /// written behind it never ran. The other close, the snapshot and the
    /// keepalive ping go out again on the replacement client, since running
    /// them twice changes nothing; the keystroke does not (ADR 0018).
    @Test func linesAnAnchorExitLeftUnansweredGoOutAgainWhenIdempotent() async throws {
        let host = Self.belowNoDetachOnDestroy()
        let (transport, fake) = try await Self.open(host)
        let first = try #require(await fake.controlChannels.first)
        first.holdLines()

        let anchorTab = Task { try await transport.closeTab(TabTarget(tabID: "tmux:@2")) }
        #expect(await eventually { first.writtenLines.last == "kill-window -t @2" })
        let otherTab = Task { try await transport.closeTab(TabTarget(tabID: "tmux:@5")) }
        let snapshot = Task { try await transport.sessionSnapshot() }
        let ping = Task { try await transport.ping() }
        let keys = Task {
            try await transport.sendAgentKeys(AgentSendKeysParams(keys: ["Enter"], target: "tmux:%3"))
        }
        let version = "display -p '#{version}'"
        #expect(await eventually {
            let lines = first.writtenLines
            return lines.contains("kill-window -t @5") && lines.contains { $0.hasPrefix("list-sessions") }
                && lines.contains(version) && lines.contains { $0.contains("send-keys -t %3") }
        })

        host.update { $0.sessions = ["$4 off work"] }
        first.exitAnswering(1)

        try await anchorTab.value
        try await otherTab.value
        _ = try await snapshot.value
        #expect(try await ping.value.version == "3.2a")
        await #expect(throws: TransportError.channelFailed(detail: "tmux control mode exited")) {
            try await keys.value
        }
        let second = try #require(await fake.controlChannels.last)
        #expect(second !== first)
        #expect(second.writtenLines.contains("kill-window -t @5"))
        #expect(second.writtenLines.contains { $0.hasPrefix("list-sessions") })
        #expect(second.writtenLines.contains(version))
        #expect(!second.writtenLines.contains("kill-window -t @2"))
        #expect(!second.writtenLines.contains { $0.contains("send-keys -t %3") })
        try await transport.close()
    }

    /// The replacement client reached another server (the old one died and
    /// a new one started): a lost line names the old server's windows, which
    /// the new one may number alike, so nothing goes out again.
    @Test func linesAnAnchorExitLeftUnansweredStayLostOnAnotherServer() async throws {
        let host = Self.belowNoDetachOnDestroy()
        let (transport, fake) = try await Self.open(host)
        let first = try #require(await fake.controlChannels.first)
        first.holdLines()

        let anchorTab = Task { try await transport.closeTab(TabTarget(tabID: "tmux:@2")) }
        #expect(await eventually { first.writtenLines.last == "kill-window -t @2" })
        let otherTab = Task { try await transport.closeTab(TabTarget(tabID: "tmux:@5")) }
        #expect(await eventually { first.writtenLines.last == "kill-window -t @5" })

        host.update {
            $0.sessions = ["$4 off work"]
            $0.serverPID = "4343"
        }
        first.exitAnswering(1)

        try await anchorTab.value
        await #expect(throws: TransportError.channelFailed(detail: "tmux control mode exited")) {
            try await otherTab.value
        }
        #expect(await eventually { await fake.controlChannels.count == 2 })
        let second = try #require(await fake.controlChannels.last)
        #expect(!second.writtenLines.contains("kill-window -t @5"))
        try await transport.close()
    }

    /// A bulk Close that empties several sessions: the replacement client
    /// anchors on the next one, whose only window a resent close takes, so
    /// tmux ends that client too and drops what it had not read. Those lines
    /// go out again on the client after it, and every close lands.
    @Test func linesLostToSuccessiveAnchorExitsGoOutUntilAnswered() async throws {
        let host = Self.belowNoDetachOnDestroy()
        host.update { $0.sessions = ["$1 off main", "$4 off work", "$6 off spare"] }
        let (transport, fake) = try await Self.open(host)
        let first = try #require(await fake.controlChannels.first)
        first.holdLines()

        let anchorTab = Task { try await transport.closeTab(TabTarget(tabID: "tmux:@2")) }
        #expect(await eventually { first.writtenLines.last == "kill-window -t @2" })
        let otherTabs = ["tmux:@5", "tmux:@8"].map { tabID in
            Task { try await transport.closeTab(TabTarget(tabID: tabID)) }
        }
        #expect(await eventually {
            ["kill-window -t @5", "kill-window -t @8"].allSatisfy { first.writtenLines.contains($0) }
        })

        await fake.holdLinesOnNextControlChannel(from: "kill-window")
        host.update { $0.sessions = ["$4 off work", "$6 off spare"] }
        first.exitAnswering(1)
        #expect(await eventually { await fake.controlChannels.count == 2 })
        let second = try #require(await fake.controlChannels.last)
        #expect(await eventually {
            second.writtenLines.filter { $0.hasPrefix("kill-window") }.count == 2
        })

        host.update { $0.sessions = ["$6 off spare"] }
        second.exitAnswering(1)

        try await anchorTab.value
        for close in otherTabs { try await close.value }
        let third = try #require(await fake.controlChannels.last)
        #expect(third !== second)
        #expect(third.writtenLines.filter { $0.hasPrefix("kill-window") }.count == 1)
        try await transport.close()
    }

    /// The anchor's death took the server's last session, so nothing is left
    /// to send a lost line to: a lost close answers herdr's `tab_not_found`,
    /// which the Console takes as closed, and a lost snapshot an empty one.
    @Test func linesAnAnchorExitLeftUnansweredMeetAnEmptyServer() async throws {
        let host = Self.belowNoDetachOnDestroy()
        let (transport, fake) = try await Self.open(host)
        let first = try #require(await fake.controlChannels.first)
        first.holdLines()

        let anchorTab = Task { try await transport.closeTab(TabTarget(tabID: "tmux:@2")) }
        #expect(await eventually { first.writtenLines.last == "kill-window -t @2" })
        let otherTab = Task { try await transport.closeTab(TabTarget(tabID: "tmux:@5")) }
        let snapshot = Task { try await transport.sessionSnapshot() }
        #expect(await eventually {
            first.writtenLines.contains("kill-window -t @5")
                && first.writtenLines.contains { $0.hasPrefix("list-sessions") }
        })

        host.update { $0.sessions = nil }
        first.exitAnswering(1)

        try await anchorTab.value
        do {
            try await otherTab.value
            Issue.record("a close lost with the server's last session reported nothing")
        } catch let error as HerdrAPIError {
            #expect(error.code == "tab_not_found")
        }
        #expect(try await snapshot.value.workspaces.isEmpty)
        #expect(await fake.controlChannels.count == 1)
        try await transport.close()
    }

    /// A link that drops without `%exit` says nothing about what tmux ran,
    /// so not even an idempotent line goes out again.
    @Test func linesALostLinkLeftUnansweredAreNotSentAgain() async throws {
        let host = Self.belowNoDetachOnDestroy()
        let (transport, fake) = try await Self.open(host)
        let first = try #require(await fake.controlChannels.first)
        first.holdLines()

        let close = Task { try await transport.closeTab(TabTarget(tabID: "tmux:@5")) }
        #expect(await eventually { first.writtenLines.last == "kill-window -t @5" })
        first.lose()

        do {
            try await close.value
            Issue.record("a close on a dropped link reported success")
        } catch let error as TransportError {
            guard case .channelFailed = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        let channels = await fake.controlChannels
        #expect(channels.flatMap(\.writtenLines).filter { $0 == "kill-window -t @5" }.count == 1)
        try await transport.close()
    }

    @Test func lostChannelFailsTheEventStream() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        let events = EventCollector(try await transport.subscribeToEvents([]))
        let channel = try #require(await fake.controlChannels.first)

        channel.lose()
        #expect(await eventually { events.isFinished })
        guard case .channelFailed = events.failure as? TransportError else {
            Issue.record("the stream ended with \(String(describing: events.failure))")
            return
        }
        let connected = await transport.isConnected
        #expect(!connected)
        try await transport.close()
    }

    // MARK: Subscription baseline (TMUX-01)

    /// Without a snapshot there is nothing to diff the first status push
    /// against: it asks for one, and says nothing about the pane.
    @Test func firstStatusPushWithoutASnapshotAsksForOne() async throws {
        let (transport, fake) = try await Self.open(TmuxHostScript.withClaudePane())
        let events = EventCollector(try await transport.subscribeToEvents([]))
        let channel = try #require(await fake.controlChannels.first)

        channel.push([Self.statusPush([["%3", "blocked", "claude", "", "1"]])])
        #expect(await eventually { events.kinds.contains(TmuxEvents.resyncKind) })
        #expect(!events.kinds.contains(PaneEventKind.agentStatusChanged.kind))
        try await transport.close()
    }

    /// A replacement control client starts without a baseline: its first
    /// status push diffs against the last snapshot again, not against what
    /// the old client pushed last.
    @Test func aReplacedChannelDiffsItsFirstPushAgainstTheSnapshot() async throws {
        let (transport, fake) = try await Self.open(TmuxHostScript.withClaudePane())
        let events = EventCollector(try await transport.subscribeToEvents([]))
        _ = try await transport.sessionSnapshot()
        let first = try #require(await fake.controlChannels.first)
        let blocked = TmuxEvents.statusChanged(paneID: "%3", status: "blocked")

        first.push([Self.statusPush([["%3", "blocked", "claude", "", "1"]])])
        #expect(await eventually { events.events.contains(blocked) })

        first.exit(reason: "detached")
        #expect(await eventually { await fake.controlChannels.count == 2 })
        let second = try #require(await fake.controlChannels.last)
        second.push([Self.statusPush([["%3", "blocked", "claude", "", "1"]])])
        #expect(await eventually { events.events.filter { $0 == blocked }.count == 2 })
        #expect(!events.isFinished)
        try await transport.close()
    }

    /// A server left with no session drops the baseline too: the client a
    /// later session brings diffs its first push against the snapshot.
    @Test func aServerThatWentIdleForgetsTheBaseline() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        let events = EventCollector(try await transport.subscribeToEvents([]))
        _ = try await transport.sessionSnapshot()
        let first = try #require(await fake.controlChannels.first)
        let blocked = TmuxEvents.statusChanged(paneID: "%3", status: "blocked")
        first.push([Self.statusPush([["%3", "blocked", "claude", "", "1"]])])
        #expect(await eventually { events.events.contains(blocked) })

        host.update { $0.sessions = nil }
        first.exit(reason: "server exited")
        #expect(await eventually { events.kinds.contains(TmuxEvents.resyncKind) })
        host.update { $0.sessions = ["$1 off main"] }
        #expect(try await transport.revalidate().backend == .tmux)
        #expect(await fake.controlChannels.count == 2)
        let second = try #require(await fake.controlChannels.last)
        second.push([Self.statusPush([["%3", "blocked", "claude", "", "1"]])])
        #expect(await eventually { events.events.filter { $0 == blocked }.count == 2 })
        try await transport.close()
    }

    /// A kind without screen rules reports the latest `wc-status` push; a
    /// replaced client has none yet, so the snapshot's status stands.
    @Test func reportedStatusFollowsTheLatestPushUntilTheChannelIsReplaced() async throws {
        let host = TmuxHostScript()
        host.update {
            $0.sessionRecords = [Self.sessionRecord("$1", "main")]
            $0.windowRecords = [Self.windowRecord("@2", session: "$1", name: "pi")]
            $0.paneRecords = [
                Self.paneRecord(
                    "%3", session: "$1", window: "@2", command: "pi", agent: "pi", status: "idle")
            ]
        }
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        #expect(await transport.reportedStatus(ofPane: "%3") == .idle)
        let first = try #require(await fake.controlChannels.first)

        first.push([Self.statusPush([["%3", "working", "pi", "", "2"]])])
        #expect(await eventually { await transport.reportedStatus(ofPane: "%3") == .working })

        first.exit(reason: "detached")
        #expect(await eventually { await fake.controlChannels.count == 2 })
        #expect(await eventually { await transport.reportedStatus(ofPane: "%3") == .idle })
        try await transport.close()
    }

    // MARK: Launch readiness gate (TMUX-02)

    /// A launched pane that died opens its gate: nothing will start there,
    /// and the prompt fails or lands on its own.
    @Test func aDeadLaunchedPaneOpensItsGate() async throws {
        let host = TmuxHostScript.withClaudePane()
        let dead = ["%7", "1", "4300", "/dev/ttys009", "zsh", "", "", "", "0"]
            .joined(separator: "\u{241F}")
        host.update {
            $0.lineRules = [
                ("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])]),
                ("display -p -t %7", [.ok([dead])]),
            ]
            $0.paneRecords.append(Self.paneRecord("%7", session: "$1", window: "@4", command: "zsh"))
        }
        let (transport, fake) = try await Self.open(host)
        let channel = try #require(await fake.controlChannels.first)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "pi", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))
        #expect(await transport.launchGates["%7"]?.kind == "pi")

        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%7", text: "hi"))
        #expect(await transport.launchGates["%7"] == nil)
        #expect(channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    /// A snapshot that no longer lists a launched pane drops its gate, and
    /// closing the transport drops every gate.
    @Test func aSnapshotWithoutTheLaunchedPaneDropsItsGate() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [("new-window", [.ok(["%7\u{241F}@4\u{241F}$1"])])]
            $0.paneRecords.append(Self.paneRecord("%7", session: "$1", window: "@4", command: "zsh"))
        }
        let (transport, _) = try await Self.open(host)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "pi", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))
        #expect(await transport.launchGates["%7"]?.kind == "pi")

        host.update { $0.paneRecords.removeLast() }
        _ = try await transport.sessionSnapshot()
        #expect(await transport.launchGates["%7"] == nil)

        host.update {
            $0.lineRules = [("new-window", [.ok(["%8\u{241F}@5\u{241F}$1"])])]
            $0.paneRecords.append(Self.paneRecord("%8", session: "$1", window: "@5", command: "zsh"))
        }
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "pi", name: "", arguments: [], workspaceID: "tmux:$1", cwd: "/work/repo"))
        #expect(await transport.launchGates["%8"]?.kind == "pi")
        try await transport.close()
        #expect(await transport.launchGates.isEmpty)
    }

    /// A tagged retry that finds its earlier pane restores the same gate a
    /// fresh start sets: the shell still in front holds the first prompt.
    @Test func aTaggedRetryRestoresTheLaunchGate() async throws {
        let id = UUID()
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.paneRecords = [Self.paneRecord(
                "%3", session: "$1", window: "@2", command: "zsh", launch: id.uuidString)]
            $0.lineRules = [("display -p -t %3", [.ok([Self.readiness("%3", command: "zsh")])])]
        }
        let (transport, fake) = try await Self.open(host)
        #expect(await transport.launchGates.isEmpty)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "pi", name: "pi-1", workspaceID: "tmux:$1", launchID: id, mayHaveStarted: true))
        #expect(await transport.launchGates["%3"]?.kind == "pi")
        await Self.expectNotReady(transport, pane: "tmux:%3")
        let channel = try #require(await fake.controlChannels.first)
        #expect(!channel.writtenLines.contains { $0.hasPrefix("set-buffer") })
        try await transport.close()
    }

    // MARK: Prompt turns (TMUX-03)

    /// A prompt refused before anything is typed hands its turn on at once:
    /// the next prompt is not held behind it.
    @Test func aRefusedPromptHandsItsTurnOn() async throws {
        let host = TmuxHostScript()
        host.update {
            $0.sessionRecords = [Self.sessionRecord("$1", "main")]
            $0.windowRecords = [Self.windowRecord("@2", session: "$1", name: "pi")]
            $0.paneRecords = [
                Self.paneRecord(
                    "%3", session: "$1", window: "@2", command: "pi", agent: "pi",
                    status: "blocked")
            ]
        }
        let (transport, _) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        for _ in 0..<2 {
            await #expect(throws: HerdrAPIError.self) {
                _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "yes"))
            }
            #expect(await transport.promptTurns["%3"] == nil)
        }
        try await transport.close()
    }

    /// A prompt whose paste tmux refuses hands its turn on too.
    @Test func aFailedPasteHandsItsTurnOn() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.lineRules = [("set-buffer", [.ok([]), .error(["can't find pane: %3"])])]
        }
        let (transport, _) = try await Self.open(host)
        await #expect(throws: HerdrAPIError.self) {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
        }
        #expect(await transport.promptTurns["%3"] == nil)
        try await transport.close()
    }

    // MARK: Paste and Enter delivery (TMUX-15)

    /// An empty prompt to a kind with a delayed Enter is Enter alone, at
    /// once: there is no paste to wait out.
    @Test func anEmptyPromptToADelayedKindIsEnterAlone() async throws {
        let (transport, fake) = try await Self.open(Self.submitPaneHost())
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: ""))
        #expect(channel.writtenLines.last == "copy-mode -q -t %3 ; send-keys -t %3 Enter")
        #expect(!channel.writtenLines.contains(Self.submitReadLine))
        #expect(!channel.writtenLines.contains { $0.contains("-H 0d") })
        #expect(await transport.promptTurns["%3"] == nil)
        try await transport.close()
    }

    /// The read before a delayed Enter failing leaves the draft typed and
    /// unsubmitted: no CR goes, and the pane's turn is handed on.
    @Test func aDelayedSubmitWhoseReadFailsSendsNoEnter() async throws {
        let host = Self.submitPaneHost()
        host.update { $0.lineRules = [(Self.submitReadLine, [.error(["can't find pane: %3"])])] }
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)

        await #expect(throws: HerdrAPIError.self) {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
        }
        #expect(channel.writtenLines.contains(Self.submitReadLine))
        #expect(!channel.writtenLines.contains { $0.contains("-H 0d") })
        #expect(await transport.promptTurns["%3"] == nil)
        try await transport.close()
    }

    /// A skipped Enter hands the turn on as well.
    @Test func aSkippedEnterHandsTheTurnOn() async throws {
        let (transport, _) = try await Self.open(Self.submitPaneHost(status: "blocked"))
        _ = try await transport.sessionSnapshot()

        do {
            _ = try await transport.promptAgent(AgentPromptParams(target: "tmux:%3", text: "draft"))
            Issue.record("submitted into a blocked agent")
        } catch let error as HerdrAPIError {
            #expect(error.code == "prompt_not_submitted")
        }
        #expect(await transport.promptTurns["%3"] == nil)
        try await transport.close()
    }

    /// The delayed Enter goes on the channel its paste went on: one lost in
    /// the gap fails the prompt, never a CR on a new client.
    @Test func aDelayedSubmitNeverReconnects() async throws {
        let (transport, fake) = try await Self.open(Self.submitPaneHost())
        _ = try await transport.sessionSnapshot()
        let channel = try #require(await fake.controlChannels.first)
        // Held at the read before the CR: the channel is lost in the gap,
        // whatever the scheduler does.
        let held = try await Self.holdFirstPromptBeforeItsEnter(on: transport, channel)
        channel.lose()
        await #expect(throws: (any Error).self) { _ = try await held.prompt.value }
        held.continuation.finish()
        #expect(!channel.writtenLines.contains { $0.contains("-H 0d") })
        #expect(await fake.controlChannels.count == 1)
        #expect(await transport.promptTurns["%3"] == nil)
        try await transport.close()
    }

    // MARK: Control link lifetime (TMUX-04)

    /// An open whose control client fails its startup answer closes that
    /// client, and the caller keeps its hold on the connection.
    @Test func anOpenWhoseStartupFailsClosesItsClientAndKeepsTheHold() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update { $0.serverVersion = "3.1c" }
        let fake = host.makeFake()
        await #expect(throws: TransportError.tmuxTooOld(found: "3.1c")) {
            try await TmuxTransport.open(session: fake, configuration: Self.configuration())
        }
        let channel = try #require(await fake.controlChannels.first)
        #expect(channel.isClosed)
        #expect(await fake.releaseCount == 0)
    }

    /// A lost link is dialed again by the next call that needs it, and the
    /// transport counts as connected while that dial runs.
    @Test func aLostLinkRedialsOnTheNextCallAndIsConnectedWhileItDials() async throws {
        let (transport, fake) = try await Self.open(TmuxHostScript.withClaudePane())
        let first = try #require(await fake.controlChannels.first)
        first.lose()
        #expect(await eventually { await !transport.isConnected })

        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        await fake.holdNextExec(
            containing: "tmux ls", entered: entered.continuation, until: release.stream)
        let ping = Task { try await transport.ping() }
        var entry = entered.stream.makeAsyncIterator()
        _ = await entry.next()
        #expect(await transport.isConnected)
        release.continuation.yield(())
        #expect(try await ping.value.backend == .tmux)
        #expect(await fake.controlChannels.count == 2)
        #expect(await transport.isConnected)
        try await transport.close()
    }

    /// Closing while a dial lists the server's sessions opens no control
    /// client: the dial fails closed and the hold is returned once.
    @Test func closingWhileADialListsSessionsOpensNoClient() async throws {
        let host = TmuxHostScript()
        host.update { $0.sessions = nil }
        let (transport, fake) = try await Self.open(host)
        host.update { $0.sessions = ["$1 off main"] }
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        await fake.holdNextExec(
            containing: "tmux ls", entered: entered.continuation, until: release.stream)
        let dial = Task { try await transport.connect() }
        var entry = entered.stream.makeAsyncIterator()
        _ = await entry.next()

        try await transport.close()
        release.continuation.yield(())
        await #expect(throws: TransportError.sshUnreachable(detail: "the tmux transport is closed")) {
            _ = try await dial.value
        }
        #expect(await fake.controlChannels.isEmpty)
        #expect(await fake.releaseCount == 1)
        #expect(await !transport.isConnected)
        await #expect(throws: TransportError.sshUnreachable(detail: "the tmux transport is closed")) {
            _ = try await transport.ping()
        }
    }

    /// EventsSession replacing the transport while a reconnect waits for
    /// its startup answer: that client is closed and the dial fails as
    /// replaced, never becoming the link.
    @Test func aDialDistrustedBeforeItsStartupAnswerClosesItsClient() async throws {
        let (transport, fake) = try await Self.open(TmuxHostScript.withClaudePane())
        let first = try #require(await fake.controlChannels.first)
        await fake.holdLinesOnNextControlChannel(from: "display -p")
        let dial = Task { try await transport.connect() }
        #expect(await eventually {
            guard await fake.controlChannels.count == 2 else { return false }
            return await fake.controlChannels.last?.writtenLines.isEmpty == false
        })
        let second = try #require(await fake.controlChannels.last)
        #expect(first.isClosed)

        await transport.transportDistrusted()
        second.exitAnswering(1)
        await #expect(throws: TransportError.sshUnreachable(detail: "the tmux transport was replaced")) {
            _ = try await dial.value
        }
        #expect(second.isClosed)
        #expect(await !transport.isConnected)
        #expect(await fake.controlChannels.count == 2)
        try await transport.close()
    }

    // MARK: Inventory publication (TMUX-06)

    /// Two refreshes in flight at once each answer their own caller with
    /// what they listed.
    @Test func overlappingRefreshesEachAnswerTheirOwnListing() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        await fake.holdNextExec(
            containing: "rev-parse", entered: entered.continuation, until: release.stream)
        let older = Task { try await transport.sessionSnapshot() }
        var entry = entered.stream.makeAsyncIterator()
        _ = await entry.next()

        host.update {
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@2", command: "pi", agent: "pi", status: "idle"))
        }
        let newer = try await transport.sessionSnapshot()
        #expect(newer.panes.map(\.paneID).sorted() == ["tmux:%3", "tmux:%7"])
        release.continuation.yield(())
        #expect(try await older.value.panes.map(\.paneID) == ["tmux:%3"])
        try await transport.close()
    }

    /// B-24: a refresh that started first and finishes last never
    /// publishes over the newer one: the transport keeps the newer
    /// inventory for attach targets, Agent lookups and launch gates.
    @Test func anOlderRefreshNeverPublishesOverANewerOne() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        await fake.holdNextExec(
            containing: "rev-parse", entered: entered.continuation, until: release.stream)
        let older = Task { try await transport.sessionSnapshot() }
        var entry = entered.stream.makeAsyncIterator()
        _ = await entry.next()

        host.update {
            $0.paneRecords.append(Self.paneRecord(
                "%7", session: "$1", window: "@2", command: "pi", agent: "pi", status: "idle"))
        }
        _ = try await transport.sessionSnapshot()
        release.continuation.yield(())
        _ = try await older.value

        #expect(await transport.lastSnapshot?.panes.map(\.paneID).sorted() == ["tmux:%3", "tmux:%7"])
        #expect(await transport.records.panes.map(\.id).sorted() == ["%3", "%7"])
        #expect(await transport.agent(forPane: "%7").kind == "pi")
        try await transport.close()
    }

    /// A refresh that finds no session left publishes an empty inventory:
    /// no records, no Shell Activity, no Agent behind a pane id.
    @Test func aRefreshWithNoSessionLeftClearsTheInventory() async throws {
        let host = TmuxHostScript.withClaudePane()
        let (transport, fake) = try await Self.open(host)
        _ = try await transport.sessionSnapshot()
        #expect(await transport.agent(forPane: "%3").kind == "claude")
        let first = try #require(await fake.controlChannels.first)

        host.update { $0.sessions = nil }
        first.exit(reason: "server exited")
        #expect(try await transport.sessionSnapshot() == TmuxTransport.emptySnapshot(version: "3.7c"))
        #expect(await transport.records == TmuxRecords())
        #expect(await transport.lastShellActivities.isEmpty)
        #expect(await transport.agent(forPane: "%3").kind == Agent.unidentifiedKind)
        try await transport.close()
    }

    // MARK: Host tools

    @Test func registrationDirectoryIsTheHerdrPluginsWhenItIsEnabled() throws {
        let output = Self.probeOutput(
            pluginList: #"{"result":{"plugins":[{"plugin_id":"herdr-mobile.pairing","enabled":true},{"plugin_id":"waycar","enabled":false}]}}"#,
            pluginDirs: [
                "waycar": "/home/me/.config/herdr/plugins/waycar",
                "herdr-mobile.pairing": "/home/me/.config/herdr/plugins/herdr-mobile.pairing",
            ],
            cli: "/home/me/.local/bin/waycar")
        #expect(try HostToolsService.hostTools(fromProbeOutput: output) == HostToolsLocation(
            configDirectory: "/home/me/.config/herdr/plugins/herdr-mobile.pairing",
            cli: "/home/me/.local/bin/waycar"))
    }

    @Test func registrationDirectoryFallsBackToXDGConfigWithHostToolsOnly() throws {
        let tools = Self.probeOutput(pluginList: "", pluginDirs: [:], cli: "/home/me/.local/bin/waycar")
        #expect(try HostToolsService.hostTools(fromProbeOutput: tools) == HostToolsLocation(
            configDirectory: "/xdg/waycar", cli: "/home/me/.local/bin/waycar"))

        let neither = Self.probeOutput(pluginList: "", pluginDirs: [:], cli: "")
        #expect(try HostToolsService.hostTools(fromProbeOutput: neither) == HostToolsLocation(
            configDirectory: nil, cli: nil))

        let brokenPlugin = Self.probeOutput(
            pluginList: #"{"result":{"plugins":[{"plugin_id":"waycar"}]}}"#,
            pluginDirs: ["waycar": ""], cli: "")
        #expect(throws: NotificationRegistrationError.self) {
            try HostToolsService.hostTools(fromProbeOutput: brokenPlugin)
        }
    }

    @Test func notificationFilesUseTheResolvedDirectoryOnce() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.execRules = [(
                "herdr plugin list",
                FakeHostSSHServices.result(stdout: Self.probeOutput(
                    pluginList: "", pluginDirs: [:], cli: "/home/me/.local/bin/waycar"))
            )]
        }
        let (transport, fake) = try await Self.open(host)
        await fake.setFile("/xdg/waycar/notifications.json", Data("{\"v\":1}".utf8))

        #expect(try await transport.readNotificationRegistration() == Data("{\"v\":1}".utf8))
        try await transport.replaceNotificationConfig(Data("{}".utf8))
        #expect(await fake.files["/xdg/waycar/notify.json"] == Data("{}".utf8))
        #expect(await fake.execs(containing: "herdr plugin list").count == 1)
        try await transport.close()
    }

    @Test func notificationFilesNeedTheHostToolsOrThePlugin() async throws {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.execRules = [(
                "herdr plugin list",
                FakeHostSSHServices.result(stdout: Self.probeOutput(
                    pluginList: "", pluginDirs: [:], cli: ""))
            )]
        }
        let (transport, _) = try await Self.open(host)
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.readNotificationRegistration()
        }
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.statusHooksReport()
        }
        try await transport.close()
    }

    @Test func statusHooksReportDecodesTheCLIsJSON() async throws {
        let host = TmuxHostScript.withClaudePane()
        let report = """
            {"version":1,"hostTools":{"version":"0.9.0","pluginRoot":"/home/me/.local/share/waycar/plugin"},\
            "backends":{"herdr":false,"tmux":"3.7c"},"configDir":"/xdg/waycar",\
            "agents":[{"agent":"claude","installed":true,"configPath":"/home/me/.claude/settings.json",\
            "needsCodexReview":false},{"agent":"codex","installed":true,"configPath":null,\
            "needsCodexReview":true}]}
            """
        host.update {
            $0.execRules = [
                ("herdr plugin list", FakeHostSSHServices.result(stdout: Self.probeOutput(
                    pluginList: "", pluginDirs: [:], cli: "/home/me/.local/bin/waycar"))),
                ("hooks status --json", FakeHostSSHServices.result(stdout: "rc noise\n" + report + "\n")),
            ]
        }
        let (transport, fake) = try await Self.open(host)

        let decoded = try await transport.statusHooksReport()
        #expect(decoded.backends == StatusHooksReport.Backends(herdr: false, tmux: "3.7c"))
        #expect(decoded.configDir == "/xdg/waycar")
        #expect(decoded.agents.map(\.agent) == ["claude", "codex"])
        #expect(decoded.agents.last?.needsCodexReview == true)
        let exec = try #require(await fake.execs(containing: "hooks status --json").first)
        #expect(exec.command.hasSuffix(" '/home/me/.local/bin/waycar'"))
        try await transport.close()
    }

    // MARK: Helpers

    static func configuration(
        debounce: Duration = .milliseconds(20), poll: Duration = .seconds(60),
        claudeReadyTimeout: Duration = .seconds(60),
        inputReadyTimeout: Duration = .seconds(60),
        role: TmuxTransport.HostRole = .tmuxOnly
    ) -> TmuxTransport.Configuration {
        var configuration = TmuxTransport.Configuration(requestTimeout: .seconds(5))
        configuration.resyncDebounce = debounce
        configuration.idlePollInterval = poll
        configuration.launchReadyDelay = .milliseconds(50)
        configuration.claudeLaunchReadyTimeout = claudeReadyTimeout
        configuration.inputReadyTimeout = inputReadyTimeout
        configuration.hostRole = role
        return configuration
    }

    /// tmux 3.2a, which drops `no-detach-on-destroy`, with the claude pane's
    /// session `$1` (the anchor) and a second session `$4`.
    fileprivate static func belowNoDetachOnDestroy() -> TmuxHostScript {
        let host = TmuxHostScript.withClaudePane()
        host.update {
            $0.sessions = ["$1 off main", "$4 off work"]
            $0.serverVersion = "3.2a"
            $0.flags = "no-output"
        }
        return host
    }

    fileprivate static func open(
        _ host: TmuxHostScript, debounce: Duration = .milliseconds(20),
        poll: Duration = .seconds(60), claudeReadyTimeout: Duration = .seconds(60),
        inputReadyTimeout: Duration = .seconds(60),
        role: TmuxTransport.HostRole = .tmuxOnly
    ) async throws -> (TmuxTransport, FakeHostSSHServices) {
        let fake = host.makeFake()
        let transport = try await TmuxTransport.open(
            session: fake,
            configuration: configuration(
                debounce: debounce, poll: poll, claudeReadyTimeout: claudeReadyTimeout,
                inputReadyTimeout: inputReadyTimeout, role: role))
        return (transport, fake)
    }

    static func settings() -> SSHTransportSettings {
        SSHTransportSettings(
            host: "example.invalid", port: 22, username: "u",
            credentials: .ed25519(Curve25519.Signing.PrivateKey()),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false },
            socket: .defaultSession)
    }

    static func expectNotReady(_ transport: TmuxTransport, pane: String) async {
        do {
            _ = try await transport.promptAgent(AgentPromptParams(target: pane, text: "hi"))
            Issue.record("prompted an agent whose launch gate holds")
        } catch let error as HerdrAPIError {
            #expect(error.code == "agent_not_ready")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// One reply to ``TmuxTransport/readinessFormat``.
    static func readiness(
        _ pane: String, command: String, agent: String = "", session: String = "",
        status: String = "", alternateScreen: Bool = false
    ) -> String {
        [pane, "0", "4300", "/dev/ttys009", command, agent, session, status, alternateScreen ? "1" : "0"]
            .joined(separator: "\u{241F}")
    }

    static func sessionRecord(_ id: String, _ name: String) -> String {
        "\u{241E}" + [id, "0", "1", name, "", "/home/me"].joined(separator: "\u{241F}")
    }

    static func windowRecord(_ id: String, session: String, name: String) -> String {
        "\u{241E}" + [id, session, "1", "1", "0", name].joined(separator: "\u{241F}")
    }

    static func paneRecord(
        _ id: String, session: String, window: String, command: String, pid: Int = 100,
        tty: String = "/dev/ttys001", agent: String = "", status: String = "", launch: String = ""
    ) -> String {
        let fields = [
            id, session, window, "0", "1", "0", "0", String(pid), tty, "80", "24", command,
            status, agent, "", "", "", "/home/me/repo", "", "", "host", "", launch,
        ]
        return "\u{241E}" + fields.joined(separator: "\u{241F}")
    }

    static func statusPush(_ rows: [[String]]) -> String {
        let value = rows.map { $0.joined(separator: "\u{241F}") + "\u{241E}" }.joined()
        return "%subscription-changed \(TmuxEvents.statusName) $1 - - - : \(value)"
    }

    static func probeOutput(pluginList: String, pluginDirs: [String: String], cli: String) -> String {
        var lines = ["login chatter", HostToolsService.pluginListBegin, pluginList, HostToolsService.pluginListEnd]
        for (id, directory) in pluginDirs.sorted(by: { $0.key < $1.key }) {
            lines.append("\(HostToolsService.pluginDirMarker)\(id)=\(directory)")
        }
        lines.append("\(HostToolsService.fallbackConfigDirMarker)/xdg/waycar")
        lines.append("\(HostToolsService.cliMarker)\(cli)")
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Scripted tmux host

/// What the fake Host's tmux answers: `tmux -V`, `tmux ls`, the control
/// client's startup and list lines, plus per-test exec and line rules
/// (first match wins: exec rules by substring, line rules by prefix).
private final class TmuxHostScript: Sendable {
    struct State {
        var versionOutput = "tmux 3.7c\n"
        var versionStderr = ""
        var versionExit: Int32 = 0
        /// `tmux ls` lines; nil when no server runs.
        var sessions: [String]? = ["$1 off main"]
        var serverVersion = "3.7c"
        var flags = "no-output,no-detach-on-destroy"
        var serverStartTime = "1790979932"
        var serverPID = "4242"
        var sessionRecords: [String] = []
        var windowRecords: [String] = []
        var paneRecords: [String] = []
        var execRules: [(String, SSHExecResult)] = []
        var lineRules: [(String, [FakeTmuxBlock])] = []
        /// `tmux ls` after a one-shot `source-file -` exec started a session.
        var sessionsAfterOneShot: [String]?
    }

    private let state = Mutex(State())

    /// The default server's `#{start_time}.#{pid}`.
    static let serverIdentity = "1790979932.4242"

    /// One session `$1` with window `@2` whose pane `%3` runs claude (its
    /// hook set `@waycar_agent`).
    static func withClaudePane() -> TmuxHostScript {
        let host = TmuxHostScript()
        host.update {
            $0.sessionRecords = [TmuxTransportTests.sessionRecord("$1", "main")]
            $0.windowRecords = [TmuxTransportTests.windowRecord("@2", session: "$1", name: "claude")]
            $0.paneRecords = [
                TmuxTransportTests.paneRecord(
                    "%3", session: "$1", window: "@2", command: "2.1.286", agent: "claude",
                    status: "idle")
            ]
        }
        return host
    }

    func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func makeFake() -> FakeHostSSHServices {
        FakeHostSSHServices(
            exec: { [self] command, input in exec(command, input) },
            control: { [self] line in respond(line) })
    }

    private func exec(_ command: String, _ input: Data) -> SSHExecResult {
        let current = state.withLock { $0 }
        if command.contains("exec tmux -V") {
            return FakeHostSSHServices.result(
                stdout: current.versionOutput, stderr: current.versionStderr,
                exitStatus: current.versionExit)
        }
        if command.contains("source-file -") {
            state.withLock { state in
                if let sessions = state.sessionsAfterOneShot { state.sessions = sessions }
            }
        }
        if command.contains("tmux ls -F") {
            guard let sessions = current.sessions else {
                return FakeHostSSHServices.result(
                    stderr: "no server running on /tmp/tmux-1000/default\n", exitStatus: 1)
            }
            return FakeHostSSHServices.result(stdout: sessions.map { $0 + "\n" }.joined())
        }
        for (match, result) in current.execRules where command.contains(match) {
            return result
        }
        return FakeHostSSHServices.result()
    }

    private func respond(_ line: String) -> [FakeTmuxBlock] {
        // tmux takes a line starting with `#` for a comment and answers no
        // block for it, so a startup line sent as a bare format never ends.
        if line.hasPrefix("#") { return [] }
        let current = state.withLock { $0 }
        for (prefix, blocks) in current.lineRules where line.hasPrefix(prefix) {
            return blocks
        }
        if line.hasPrefix(TmuxTransport.versionFlagsCommand) {
            let fields = [
                current.serverVersion, current.flags, current.serverStartTime, current.serverPID,
            ]
            return [.ok([fields.joined(separator: "\u{241F}")]), .ok([]), .ok([])]
        }
        if line.hasPrefix("list-sessions") {
            return [
                .ok(current.sessionRecords), .ok(current.windowRecords), .ok(current.paneRecords),
            ]
        }
        if line == "display -p '#{version}'" {
            return [.ok([current.serverVersion])]
        }
        return line.components(separatedBy: " ; ").map { _ in .ok([]) }
    }
}

// MARK: - Event collection

/// Drains one event stream in the background.
private final class EventCollector: Sendable {
    private struct State {
        var events: [HerdrEvent] = []
        var finished = false
        var failure: (any Error)?
    }

    private let state = Mutex(State())

    init(_ stream: HerdrEventStream) {
        Task { [self] in
            do {
                for try await event in stream.events {
                    state.withLock { $0.events.append(event) }
                }
                state.withLock { $0.finished = true }
            } catch {
                state.withLock {
                    $0.failure = error
                    $0.finished = true
                }
            }
        }
    }

    var events: [HerdrEvent] { state.withLock { $0.events } }
    var kinds: [HerdrEventKind] { events.map(\.kind) }
    var isFinished: Bool { state.withLock { $0.finished } }
    var failure: (any Error)? { state.withLock { $0.failure } }
}

/// Polls `condition` until it holds or `timeout` passes.
private func eventually(
    _ timeout: Duration = .waitCeiling, _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Values a `@Sendable` callback reported, in order.
private final class Recorder<Value: Sendable>: Sendable {
    private let state = Mutex<[Value]>([])

    func append(_ value: Value) {
        state.withLock { $0.append(value) }
    }

    var values: [Value] { state.withLock { $0 } }
}
