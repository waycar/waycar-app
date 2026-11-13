import CryptoKit
import Foundation
import Testing
import WaycarSSH

@testable import Waycar

/// The tmux backend (ADR 0026) against real sshd and a real tmux server.
///
/// The fixture sshd runs as the developer's own account, so a bare `tmux`
/// would reach their real server. `scripts/run-ci-ios-tests.sh` exports a
/// per-run `TMUX_TMPDIR` into every fixture session, and `TmuxFixtureHost`
/// reads it back over SSH and refuses to run a single tmux command unless it
/// is the fixture's own directory. Every test then starts from an empty
/// private server, seeds it with plain `tmux` over exec, and only then
/// connects the Transport under test.
@Suite(
    "tmux Transport e2e",
    .enabled(
        if: RealSSHFixture.gate(TmuxTransportE2EEnvironment.current != nil),
        "requires the disposable sshd fixture with tmux 3.2 or later"),
    .serialized)
struct TmuxTransportE2ETests {
    /// What a topology change surfaces as: a window added anywhere is
    /// `%window-add` / `%unlinked-window-add` (tab created), and the
    /// `wc-topo` subscription resyncs as pane created.
    private static let resyncKinds: Set<HerdrEventKind> = [
        GlobalEventKind.tabCreated.kind, GlobalEventKind.paneCreated.kind,
    ]

    @Test(
        "backend detection reports the tmux version beside the fixture herdr",
        .enabled(if: TmuxTransportE2EEnvironment.servesHerdr, "needs the fixture's herdr stub"))
    func detectionReportsTheTmuxVersion() async throws {
        try await withTmuxHost { environment, _ in
            let presence = try await SSHTransportConnector().detectBackends(
                settings: environment.settings())
            #expect(presence.tmuxVersion == environment.tmuxVersion)
            #expect(presence.tmuxUsable)
            // The shared fixture puts a herdr stub on the session PATH and
            // serves a fake herdr socket at the default path, so herdr is
            // present too: this Host is the both-installed case.
            #expect(presence.herdr)
            #expect(presence.backends == [.herdr, .tmux])
        }
    }

    /// The fixture's herdr stub on the session PATH answers `herdr=path`
    /// before the socket test can matter, so this runs detection with a PATH
    /// that lacks the stub: herdr is then present only through its socket.
    @Test(
        "backend detection finds the herdr socket with no herdr on the PATH",
        .enabled(if: TmuxTransportE2EEnvironment.servesHerdr, "needs the fixture's herdr stub"))
    func detectionFindsTheSocketWithoutHerdrOnThePath() async throws {
        try await withTmuxHost { environment, host in
            let scratch =
                "\(environment.homePath)/.waycar-ci/detect-\(UUID().uuidString.lowercased())"
            let regularFile = scratch + "-file.sock"
            try await host.shell(": > \(shellQuoted(regularFile))")
            let cases: [(socket: HerdrSocketLocation, served: Bool)] = [
                (.absolutePath(environment.socketPath), true),
                // The home branch: the fixture serves the default path.
                (.defaultSession, true),
                (.absolutePath(scratch + "-missing.sock"), false),
                (.namedSession("absent-\(UUID().uuidString.lowercased())"), false),
                // Only a socket counts, not any file at the path.
                (.absolutePath(regularFile), false),
            ]
            for (socket, served) in cases {
                let output = try await host.shell(
                    "PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH; "
                        + HostBackendDetection.command(
                            socket: socket, probesPlugin: true, searchesSystemDirectories: false))
                let lines = output.split(whereSeparator: \.isNewline).map(String.init)
                #expect(
                    lines.contains(HostBackendDetection.herdrSocketLine) == served,
                    "\(socket) printed \(lines)")
                let presence = try #require(
                    HostBackendDetection.presence(fromOutput: Data(output.utf8)),
                    "\(socket) printed no markers: \(output.debugDescription)")
                let viaPath = lines.contains(HostBackendDetection.herdrBinaryLine)
                #expect(presence.herdr == (served || viaPath), "\(socket) printed \(lines)")
            }
            try await host.shell("rm -f \(shellQuoted(regularFile))")
        }
    }

    /// The fixture sshd runs on the CI runner, whose Homebrew holds real
    /// CLIs: a codex macOS had not approved hung every detection exec
    /// (2026-11-12). Every program detection looks for must resolve inside
    /// the fixture, and codex and OpenCode answer as the fixture's stubs.
    @Test(
        "fixture detection finds every Host program inside the fixture",
        .enabled(if: TmuxTransportE2EEnvironment.hasCLIStubs, "needs the macOS fixture's CLI stubs"))
    func fixtureDetectionStaysInsideTheFixture() async throws {
        try await withTmuxHost { environment, host in
            let stubs = try #require(environment.cliStubs)
            let inside = { (path: String) in path.hasPrefix(stubs.root + "/") }
            let settings = environment.settings()
            let resolved = try await host.shell(
                HostBackendDetection.pathExport(
                    searchesSystemDirectories: settings.detectionSearchesSystemDirectories)
                    + "; for c in herdr herdr-core hc tmux codex opencode; do command -v \"$c\"; done; true")
            let paths = resolved.split(whereSeparator: \.isNewline).map(String.init)
            #expect(paths.count >= 4, "\(paths)")
            for path in paths {
                #expect(inside(path), "\(path) is outside the fixture \(stubs.root)")
            }
            let presence = try await SSHTransportConnector().detectBackends(settings: settings)
            #expect(presence.unansweredProbes == nil)
            let codex = try #require(presence.codex)
            #expect(codex.version == stubs.codex && inside(codex.path), "\(codex)")
            #expect(!presence.codexRunning)
            let opencode = try #require(presence.opencode)
            #expect(opencode.version == stubs.opencode && inside(opencode.path), "\(opencode)")
            #expect(!opencode.isRunning)
            #expect(presence.core == nil)
        }
    }

    /// A program that never answers (here a codex that sleeps) is stopped
    /// after `probeLimitSeconds`: detection still returns well inside its
    /// deadline, names it, and reports everything else.
    @Test("a Host program that never answers times out and detection reports the rest")
    func aHungProgramTimesOutAndTheRestStillReport() async throws {
        try await withTmuxHost { environment, host in
            let directory =
                "\(environment.homePath)/.waycar-ci/hang-\(UUID().uuidString.lowercased())"
            let quoted = shellQuoted(directory)
            try await host.shell(
                "mkdir -p \(quoted) && printf '%s\\n' \(shellQuoted("#!/bin/sh")) "
                    + "\(shellQuoted("echo $$ > \(directory)/pid")) \(shellQuoted("exec sleep 600")) "
                    + "> \(quoted)/codex && chmod 755 \(quoted)/codex")
            let session = try await HostSSHSession.dial(settings: environment.settings())
            let started = ContinuousClock.now
            let detected: Result<HostBackendPresence, any Error>
            do {
                // The login PATH leads Codex's own search, so the stub wins.
                detected = .success(try await session.detectBackends(
                    probingPlugin: true, loginPATH: "\(directory):/usr/bin:/bin:/usr/sbin:/sbin"))
            } catch {
                detected = .failure(error)
            }
            let elapsed = ContinuousClock.now - started
            await session.release()
            let stub = try await host.shell(
                "p=$(cat \(quoted)/pid 2>/dev/null); "
                    + "if [ -n \"$p\" ] && kill -0 \"$p\" 2>/dev/null; then kill -KILL \"$p\"; echo alive; "
                    + "else echo gone; fi; rm -rf \(quoted)")
            let presence = try detected.get()
            #expect(elapsed < .seconds(20), "detection took \(elapsed)")
            #expect(presence.unansweredProbes == [.codexVersion])
            #expect(presence.codex == nil)
            #expect(presence.tmuxVersion == environment.tmuxVersion)
            #expect(presence.waycarPlugin != nil)
            #expect(stub.trimmingCharacters(in: .whitespacesAndNewlines) == "gone", "the stub outlived detection")
        }
    }

    @Test("ping answers as the tmux backend")
    func pingAnswersAsTmux() async throws {
        try await withTmuxHost { environment, host in
            _ = try await host.newSession("main")
            try await withTransport(environment) { transport in
                let info = try await transport.ping()
                #expect(
                    info
                        == ServerInfo(
                            version: environment.tmuxVersion, protocolVersion: 0, backend: .tmux))
            }
        }
    }

    @Test("the Host resource sample reads finite fractions over SSH")
    func hostResourceUsageReadsFiniteFractions() async throws {
        try await withTmuxHost { environment, host in
            _ = try await host.newSession("main")
            try await withTransport(environment) { transport in
                let usage = try await transport.hostResourceUsage()
                for value in [usage.cpu, usage.memory] + (usage.swap.map { [$0] } ?? []) {
                    #expect(value.isFinite && (0...1).contains(value))
                }
            }
        }
    }

    @Test("the snapshot lists sessions, windows and panes under tmux ids")
    func snapshotListsTheServerUnderTmuxIDs() async throws {
        try await withTmuxHost { environment, host in
            let alpha = try await host.newSession("alpha")
            let alphaSplit = try await host.splitWindow(alpha.window)
            let alphaSecond = try await host.newWindow(in: alpha.session, name: "second")
            let beta = try await host.newSession("beta")

            try await withTransport(environment) { transport in
                let snapshot = try await transport.sessionSnapshot()
                #expect(snapshot.version == environment.tmuxVersion)
                #expect(snapshot.protocolVersion == 0)

                #expect(snapshot.workspaces.count == 2)
                let labels = Dictionary(
                    snapshot.workspaces.map { ($0.workspaceID, $0.label) },
                    uniquingKeysWith: { first, _ in first })
                #expect(labels == [app(alpha.session): "alpha", app(beta.session): "beta"])

                #expect(
                    Set(snapshot.tabs.map { "\($0.tabID) in \($0.workspaceID)" }) == [
                        "\(app(alpha.window)) in \(app(alpha.session))",
                        "\(app(alphaSecond.window)) in \(app(alpha.session))",
                        "\(app(beta.window)) in \(app(beta.session))",
                    ])
                #expect(
                    snapshot.tabs.first { $0.tabID == app(alphaSecond.window) }?.label == "second")

                #expect(
                    Set(snapshot.panes.map { "\($0.paneID) in \($0.tabID) in \($0.workspaceID)" })
                        == [
                            "\(app(alpha.pane)) in \(app(alpha.window)) in \(app(alpha.session))",
                            "\(app(alphaSplit)) in \(app(alpha.window)) in \(app(alpha.session))",
                            "\(app(alphaSecond.pane)) in \(app(alphaSecond.window)) in \(app(alpha.session))",
                            "\(app(beta.pane)) in \(app(beta.window)) in \(app(beta.session))",
                        ])
                // The terminal id is the pane id plus the server's identity
                // (design §4.3).
                let server = try await #require(transport as? TmuxTransport).serverIdentity
                #expect(!server.isEmpty)
                #expect(snapshot.panes.allSatisfy { $0.terminalID == $0.paneID + "@" + server })
            }
        }
    }

    @Test("a new window in another session arrives as a resync event")
    func newWindowArrivesAsResync() async throws {
        try await withTmuxHost { environment, host in
            _ = try await host.newSession("alpha")
            let beta = try await host.newSession("beta")

            try await withTransport(environment) { transport in
                try await withEvents(transport) { feed in
                    // beta is not the control client's anchor, so this is
                    // tmux's `%unlinked-window-add` plus a `wc-topo` change.
                    let window = try await host.newWindow(in: beta.session, name: "late")
                    let event = try await feed.next(within: .sshdBudget(30)) {
                        Self.resyncKinds.contains($0.kind)
                    }
                    #expect(event != nil, "no resync event after new-window \(window.window)")
                    let ending = await feed.ending
                    #expect(ending == nil, "the event stream ended")
                }
            }
        }
    }

    @Test("a pane status option change arrives as pane.agent_status_changed")
    func statusOptionArrivesAsStatusChange() async throws {
        try await withTmuxHost { environment, host in
            let agent = try await host.newSession("agent")
            try await host.tmux("set-option -p -t \(shellQuoted(agent.pane)) @waycar_agent claude")
            let paneID = app(agent.pane)

            try await withTransport(environment) { transport in
                try await withEvents(transport) { feed in
                    // The first `wc-status` push is the baseline the snapshot
                    // covers, and tmux checks subscriptions once a second. A
                    // working-then-blocked pair two seconds apart is a status
                    // change on any push after the baseline, so a slow
                    // baseline costs a round rather than the test.
                    var delivered: HerdrEvent?
                    for _ in 0..<4 where delivered == nil {
                        try await host.tmux(
                            "set-option -p -t \(shellQuoted(agent.pane)) @waycar_status working")
                        try await Task.sleep(for: .sshdBudget(2))
                        try await host.tmux(
                            "set-option -p -t \(shellQuoted(agent.pane)) @waycar_status blocked")
                        delivered = try await feed.next(within: .sshdBudget(5)) { event in
                            event.kind == PaneEventKind.agentStatusChanged.kind
                                && event.data["pane_id"]?.stringValue == paneID
                                && event.data["agent_status"]?.stringValue == "blocked"
                        }
                    }
                    #expect(delivered != nil, "no blocked status change for \(paneID)")
                }
            }
        }
    }

    /// A directory name is the user's, so it may hold the reply separators.
    /// One holds ␞ and a forged pane record whose 18 fields plus the real
    /// record's last four make a whole record; another holds ␟, which would
    /// shift the real record's fields. Both panes must list once, with their
    /// paths stripped of the separators, and nothing forged must appear.
    @Test("separators in a pane directory neither forge nor drop a pane")
    func separatorsInAPathNeitherForgeNorDropAPane() async throws {
        try await withTmuxHost { environment, host in
            let main = try await host.newSession("main")
            let forged = [
                "%9999", main.session, main.window, "0", "1", "0", "0", "1", "ttys9", "80", "24",
                "sh", "", "", "", "", "", "forged",
            ]
            let forging = "wc-forge\u{241E}" + forged.joined(separator: "\u{241F}")
            let shifting = "wc-shift\u{241F}one\u{241F}two"
            let scratch =
                "\(environment.homePath)/.waycar-ci/separators-\(UUID().uuidString.lowercased())"
            try await host.shell(
                "mkdir -p \(shellQuoted(scratch + "/" + forging)) "
                    + "\(shellQuoted(scratch + "/" + shifting))")
            let forgingPane = try await host.newWindow(
                in: main.session, name: "forging", cwd: scratch + "/" + forging)
            let shiftingPane = try await host.newWindow(
                in: main.session, name: "shifting", cwd: scratch + "/" + shifting)

            try await withTransport(environment) { transport in
                let snapshot = try await transport.sessionSnapshot()
                #expect(
                    Set(snapshot.panes.map(\.paneID))
                        == [app(main.pane), app(forgingPane.pane), app(shiftingPane.pane)])
                let separators: Set<Character> = ["\u{241E}", "\u{241F}"]
                for (pane, name) in [(forgingPane.pane, forging), (shiftingPane.pane, shifting)] {
                    let cwd = snapshot.panes.first { $0.paneID == app(pane) }?.cwd
                    let stripped = String(name.filter { !separators.contains($0) })
                    #expect(
                        cwd?.hasSuffix("/" + stripped) == true,
                        "\(pane) reported cwd \(cwd ?? "nil")")
                }
            }
            try await host.shell("rm -rf \(shellQuoted(scratch))")
        }
    }

    /// An `@waycar_status` value is written by hooks and could hold ␞ and a
    /// forged `wc-status` row: unstripped, `x␞%B␟blocked` plus the real row's
    /// agent, session and seq is a whole row reporting pane B blocked.
    @Test("separators in a status option forge no status change")
    func separatorsInAStatusOptionForgeNoStatusChange() async throws {
        try await withTmuxHost { environment, host in
            let forger = try await host.newSession("forger")
            // B runs no agent, so nothing but a forged row reports it.
            let target = try await host.newWindow(in: forger.session, name: "target")
            let witness = try await host.newWindow(in: forger.session, name: "witness")
            for pane in [forger.pane, witness.pane] {
                try await host.tmux("set-option -p -t \(shellQuoted(pane)) @waycar_agent claude")
            }
            let targetID = app(target.pane)
            let witnessID = app(witness.pane)

            func setStatus(_ pane: String, _ value: String) async throws {
                try await host.tmux(
                    "set-option -p -t \(shellQuoted(pane)) @waycar_status \(shellQuoted(value))")
            }

            try await withTransport(environment) { transport in
                try await withEvents(transport) { feed in
                    // Each round changes the forged row, then the witness's
                    // real status; once the witness's blocked arrives, every
                    // push carrying a forged row has been handled. Rounds
                    // repeat in case the first lands in the baseline push.
                    var delivered: HerdrEvent?
                    for _ in 0..<4 where delivered == nil {
                        try await setStatus(forger.pane, "working\u{241E}\(target.pane)\u{241F}working")
                        try await setStatus(witness.pane, "working")
                        try await Task.sleep(for: .sshdBudget(2))
                        try await setStatus(forger.pane, "working\u{241E}\(target.pane)\u{241F}blocked")
                        try await setStatus(witness.pane, "blocked")
                        delivered = try await feed.next(within: .sshdBudget(5)) { event in
                            event.kind == PaneEventKind.agentStatusChanged.kind
                                && event.data["pane_id"]?.stringValue == witnessID
                                && event.data["agent_status"]?.stringValue == "blocked"
                        }
                    }
                    #expect(delivered != nil, "no blocked status change for \(witnessID)")
                    let forgedChange = try await feed.next(within: .zero) { event in
                        event.kind == PaneEventKind.agentStatusChanged.kind
                            && event.data["pane_id"]?.stringValue == targetID
                    }
                    #expect(forgedChange == nil, "a forged row reported \(targetID)")
                }
                let snapshot = try await transport.sessionSnapshot()
                let reported = snapshot.panes.first { $0.paneID == targetID }
                #expect(reported != nil)
                #expect(reported?.agentStatus != .blocked)
                #expect(reported?.agentStatus != .working)
            }
        }
    }

    /// herdr's "seen" for tmux must cost exactly one reply per command: a
    /// command that made tmux emit an extra `%begin`/`%end` block would hand
    /// that block to the next request and shift every later reply.
    @Test("focusing a done agent makes it idle and keeps later replies in step")
    func focusTurnsDoneIdleAndKeepsRepliesInStep() async throws {
        try await withTmuxHost { environment, host in
            let done = try await host.newSession("done")
            let working = try await host.newWindow(in: done.session, name: "working")
            let unset = try await host.newWindow(in: done.session, name: "unset")
            try await host.tmux("set-option -p -t \(shellQuoted(done.pane)) @waycar_status done")
            try await host.tmux(
                "set-option -p -t \(shellQuoted(working.pane)) @waycar_status working")

            try await withTransport(environment) { transport in
                let panes: Set<String> = [app(done.pane), app(working.pane), app(unset.pane)]
                for pane in [done.pane, working.pane, unset.pane] {
                    // Focus is two control lines (read the status, then the
                    // `set-option -F` that clears done). Pings and snapshots run back
                    // to back alongside it on the same control channel, so
                    // requests are written behind each focus line before its
                    // reply is read: an extra block from a focus line would
                    // be taken as their replies rather than dropped as
                    // unsolicited.
                    async let focused: Void = transport.focusAgent(AgentTarget(target: app(pane)))
                    var answers: [(ServerInfo, SessionSnapshot)] = []
                    for _ in 0..<4 {
                        async let pinged = transport.ping()
                        async let listed = transport.sessionSnapshot()
                        answers.append((try await pinged, try await listed))
                    }
                    try await focused
                    answers.append((try await transport.ping(), try await transport.sessionSnapshot()))
                    for (info, snapshot) in answers {
                        #expect(info.backend == .tmux)
                        #expect(info.version == environment.tmuxVersion)
                        #expect(snapshot.version == environment.tmuxVersion)
                        #expect(Set(snapshot.panes.map(\.paneID)) == panes)
                        #expect(
                            Set(snapshot.workspaces.map(\.workspaceID)) == [app(done.session)])
                    }
                }
            }

            #expect(
                try await host.tmux("show-options -p -v -t \(shellQuoted(done.pane)) @waycar_status")
                    == "idle")
            #expect(
                try await host.tmux(
                    "show-options -p -v -t \(shellQuoted(working.pane)) @waycar_status")
                    == "working")
            // A pane without the option keeps it unset, not set to "".
            #expect(
                try await host.lines(
                    "show-options -p -t \(shellQuoted(unset.pane)) @waycar_status").isEmpty)
        }
    }

    /// ADR 0026: one pooled `HostSSHSession` carries both backends. One dial,
    /// both backends usable at once, and closing one leaves the other up.
    @Test(
        "herdr and tmux share one pooled SSH session",
        .enabled(if: TmuxTransportE2EEnvironment.servesHerdr, "needs the fixture's herdr stub"))
    func herdrAndTmuxShareOnePooledSession() async throws {
        try await withTmuxHost { environment, host in
            let main = try await host.newSession("main")
            let dials = DialCounter()
            let pool = HostSSHSessionPool(dialer: { settings in
                await dials.increment()
                return try await HostSSHSession.dial(settings: settings)
            })
            let connector = SSHTransportConnector(pool: pool)
            var settings = environment.settings()
            settings.poolKey = "tmux-e2e-\(UUID().uuidString)"

            let herdr = try await connector.connect(settings: settings, backend: .herdr)
            let outcome: Result<Void, any Error>
            do {
                let tmux = try await connector.connect(settings: settings, backend: .tmux)
                #expect(tmux is TmuxTransport)
                #expect(await dials.count == 1)

                let tmuxOutcome: Result<Void, any Error>
                do {
                    async let herdrInfo = herdr.ping()
                    async let tmuxInfo = tmux.ping()
                    async let events = tmux.subscribeToEvents([.global(.tabCreated)])
                    #expect(try await herdrInfo.protocolVersion == 17)
                    let info = try await tmuxInfo
                    #expect(info.backend == .tmux)
                    #expect(info.version == environment.tmuxVersion)
                    let feed = TmuxEventFeed(try await events)
                    let window = try await host.newWindow(in: main.session, name: "late")
                    let event = try await feed.next(within: .sshdBudget(30)) {
                        Self.resyncKinds.contains($0.kind)
                    }
                    #expect(event != nil, "no resync event after new-window \(window.window)")
                    await feed.end()
                    tmuxOutcome = .success(())
                } catch {
                    tmuxOutcome = .failure(error)
                }
                try await tmux.close()
                try tmuxOutcome.get()

                // The shared session outlives the tmux Transport.
                #expect(try await herdr.ping().protocolVersion == 17)
                #expect(await dials.count == 1)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            try? await herdr.close()
            try outcome.get()
        }
    }

    /// Composer delivery is one control line of `set-buffer` with the draft
    /// in double quotes, then `paste-buffer` and Enter (design §4.3, T15).
    /// Every character tmux's parser treats specially inside or around those
    /// quotes is here, and `cat` writes exactly what the pane's tty received.
    @Test("a multi-line draft reaches cat byte-exact")
    func multiLineDraftReachesCatByteExact() async throws {
        try await withTmuxHost { environment, host in
            let path =
                "\(environment.homePath)/.waycar-ci/tmux-input-\(UUID().uuidString.lowercased())"
            let input = try await host.newSession(
                "input", command: "exec cat > \(shellQuoted(path))")
            let draft =
                "cd ~/x && echo \"$HOME\" 'single'; echo after-semicolon\n"
                + "second line: \\ backslash, $(not run), `ticks` and \"double\" ; \n"
                + "~/leading tilde ; trailing"
            // paste-buffer turns each LF into CR, the pane's tty turns CR back
            // into LF, and the Enter that follows the paste ends the last line.
            let expected = Data((draft + "\n").utf8)

            try await withTransport(environment) { transport in
                try await transport.sendPaneInput(
                    PaneSendInputParams(paneID: app(input.pane), keys: ["enter"], text: draft))
                var received = Data()
                _ = try await tmuxEventually {
                    received = try await host.readFile(path)
                    return received.count >= expected.count
                }
                #expect(
                    received == expected,
                    "cat received \(String(decoding: received, as: UTF8.self).debugDescription)")
                // The named buffer is deleted by the paste (`-d`).
                let buffers = try await host.lines("list-buffers -F '#{buffer_name}'")
                #expect(!buffers.contains { $0.hasPrefix("waycar-") }, "left buffers \(buffers)")
            }
        }
    }

    @Test("a shell terminal opens a WAYCAR_SHELL window that renames")
    func shellTerminalOpensMarkedWindowThatRenames() async throws {
        try await withTmuxHost { environment, host in
            let work = try await host.newSession("work")

            try await withTransport(environment) { transport in
                let shell = try await transport.startShellTerminal(
                    ShellLaunchRequest(
                        name: "e2e shell", workspaceID: app(work.session),
                        cwd: environment.homePath))
                #expect(shell.workspaceID == app(work.session))
                #expect(shell.tabID.hasPrefix("tmux:@"))
                #expect(shell.paneID.hasPrefix("tmux:%"))
                let server = try await #require(transport as? TmuxTransport).serverIdentity
                #expect(!server.isEmpty)
                #expect(shell.terminalID == shell.paneID + "@" + server)
                let rawPane = String(shell.paneID.dropFirst("tmux:".count))
                let rawWindow = String(shell.tabID.dropFirst("tmux:".count))

                let placement = try await host.tmux(
                    "display -p -t \(shellQuoted(rawPane)) '#{window_id} #{session_id}'")
                #expect(placement == "\(rawWindow) \(work.session)")
                let name = try await host.windowName(rawWindow)
                #expect(name == "e2e shell")
                let cwd = try await host.tmux(
                    "display -p -t \(shellQuoted(rawPane)) '#{pane_current_path}'")
                #expect(cwd == host.physicalHome)

                // ADR 0018's marker reaches the shell's own environment.
                let marker =
                    "\(environment.homePath)/.waycar-ci/tmux-shell-\(UUID().uuidString.lowercased())"
                let probe =
                    "printf 'WAYCAR_SHELL=%s\\n' \"${WAYCAR_SHELL-}\" > \(shellQuoted(marker))"
                try await host.tmux("send-keys -t \(shellQuoted(rawPane)) -l \(shellQuoted(probe))")
                try await host.tmux("send-keys -t \(shellQuoted(rawPane)) Enter")
                var report = ""
                _ = try await tmuxEventually {
                    report = String(decoding: try await host.readFile(marker), as: UTF8.self)
                    return report.hasSuffix("\n")
                }
                #expect(report == "WAYCAR_SHELL=1\n")

                try await transport.renameShellTab(tabID: shell.tabID, label: "renamed shell")
                let renamed = try await host.windowName(rawWindow)
                #expect(renamed == "renamed shell")
            }
        }
    }

    @Test("closing a pane and a tab removes exactly those")
    func closingAPaneAndATabRemovesExactlyThose() async throws {
        try await withTmuxHost { environment, host in
            let work = try await host.newSession("work")
            let split = try await host.splitWindow(work.window)
            let doomed = try await host.newWindow(in: work.session, name: "doomed")

            try await withTransport(environment) { transport in
                try await transport.closePane(
                    PaneTarget(paneID: app(split)), closesWorktreeGroup: false)
                try await transport.closeTab(TabTarget(tabID: app(doomed.window)))

                let panes = try await host.lines("list-panes -a -F '#{pane_id}'")
                #expect(Set(panes) == [work.pane])
                let windows = try await host.lines("list-windows -a -F '#{window_id}'")
                #expect(Set(windows) == [work.window])
                let snapshot = try await transport.sessionSnapshot()
                #expect(snapshot.panes.map(\.paneID) == [app(work.pane)])
                #expect(snapshot.tabs.map(\.tabID) == [app(work.window)])
            }
        }
    }

    @Test("attach produces output and survives a resize")
    func attachProducesOutputAndSurvivesAResize() async throws {
        try await withTmuxHost { environment, host in
            let echo =
                "printf 'READY\\n'; while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"
            let target = try await host.newSession("attach", command: echo)

            try await withTransport(environment) { transport in
                let session = try await transport.attachTerminal(
                    TerminalAttachRequest(target: .agentPane(app(target.pane)), cols: 80, rows: 24))
                let output = AttachOutputFeed(session)
                let outcome: Result<Void, any Error>
                do {
                    let drew = try await output.waitFor("READY")
                    #expect(drew, "attach drew no pane content")
                    // One private grouped view while attached (design §4.4),
                    // which the Console never lists.
                    let views = try await host.waycarSessions()
                    #expect(views.count == 1)
                    let workspaces = try await transport.sessionSnapshot().workspaces
                    #expect(workspaces.map(\.workspaceID) == [app(target.session)])

                    session.send(Data("hello-attach\r".utf8))
                    let echoed = try await output.waitFor("GOT:hello-attach")
                    #expect(echoed)

                    // The window the phone shows takes the phone's size (T12).
                    session.resize(cols: 109, rows: 47)
                    let resized = try await tmuxEventually {
                        try await host.tmux(
                            "display -p -t \(shellQuoted(target.pane)) '#{pane_width}'") == "109"
                    }
                    #expect(resized, "the pane never took the resized width")
                    session.send(Data("after-resize\r".utf8))
                    let echoedAfterResize = try await output.waitFor("GOT:after-resize")
                    #expect(echoedAfterResize)
                    let ending = await output.ending
                    #expect(ending == nil, "the attach ended")
                    outcome = .success(())
                } catch {
                    outcome = .failure(error)
                }
                await session.end()
                await output.finished()
                try outcome.get()
                // `destroy-unattached` takes the private view with the client.
                let viewGone = try await tmuxEventually { try await host.waycarSessions().isEmpty }
                #expect(viewGone, "the attach session outlived its client")
            }
        }
    }

    /// The anchor dies under the control client while another session lives
    /// (design §4.3): on tmux 3.6+ `no-detach-on-destroy` moves the client,
    /// below it the Transport reattaches. Either way the channel, its event
    /// stream and the Host Connection Status survive.
    @Test("the control channel reattaches after its anchor session is killed")
    func controlChannelReattachesAfterItsAnchorDies() async throws {
        try await withTmuxHost { environment, host in
            let anchor = try await host.newSession("anchor")
            let survivor = try await host.newSession("survivor")

            try await withTransport(environment) { transport in
                try await withEvents(transport) { feed in
                    _ = try await transport.ping()
                    // The lowest-id session is the anchor.
                    let anchored = try await host.controlClientSessions()
                    #expect(anchored == [anchor.session])

                    try await host.tmux("kill-session -t \(shellQuoted(anchor.session))")
                    // A command caught by the reattach may fail; it must not
                    // hang, and the channel must come back on the survivor.
                    let reattached = try await tmuxEventually {
                        guard (try? await transport.ping()) != nil else { return false }
                        return try await host.controlClientSessions() == [survivor.session]
                    }
                    #expect(reattached, "the control channel did not come back on the survivor")
                    let ending = await feed.ending
                    #expect(ending == nil, "the event stream ended at the reattach")
                    let workspaces = try await transport.sessionSnapshot().workspaces
                    #expect(workspaces.map(\.workspaceID) == [app(survivor.session)])

                    // Events still flow once the kill's own events are drained.
                    await feed.settle()
                    let window = try await host.newWindow(in: survivor.session, name: "after")
                    let event = try await feed.next(within: .sshdBudget(30)) {
                        Self.resyncKinds.contains($0.kind)
                    }
                    #expect(event != nil, "no resync event after the reattach")
                    let tabs = try await transport.sessionSnapshot().tabs
                    #expect(tabs.contains { $0.tabID == app(window.window) })
                }
            }
        }
    }

    /// Below tmux 3.6 a control client cannot ask for `no-detach-on-destroy`,
    /// so the anchor's death detaches it with `%exit` and the Transport opens
    /// a new client on a surviving session (design §4.3). CI's tmux is newer,
    /// so this Transport leaves the flag off to get that same `%exit`.
    @Test("without no-detach-on-destroy the control channel reattaches after %exit")
    func controlChannelReattachesAfterTmuxExits() async throws {
        try await withTmuxHost { environment, host in
            let anchor = try await host.newSession("anchor")
            let survivor = try await host.newSession("survivor")
            var configuration = TmuxTransport.Configuration(
                requestTimeout: environment.settings().requestTimeout)
            configuration.requestsNoDetachOnDestroy = false

            try await withTransport(environment, configuration: configuration) { transport in
                try await withEvents(transport) { feed in
                    _ = try await transport.ping()
                    let before = try await host.controlClients()
                    #expect(before.map(\.session) == [anchor.session])
                    // Without the flag tmux detaches rather than moves it.
                    #expect(
                        !before.contains { $0.flags.contains("no-detach-on-destroy") },
                        "the control client asked for no-detach-on-destroy: \(before)")

                    try await host.tmux("kill-session -t \(shellQuoted(anchor.session))")
                    let reattached = try await tmuxEventually {
                        guard (try? await transport.ping()) != nil else { return false }
                        return try await host.controlClients().map(\.session) == [survivor.session]
                    }
                    #expect(reattached, "the control channel did not come back on the survivor")
                    // A new client process, so the old one really exited.
                    let after = try await host.controlClients()
                    #expect(
                        Set(after.map(\.pid)).isDisjoint(with: before.map(\.pid)),
                        "the control client was moved, not replaced: \(before) -> \(after)")
                    let ending = await feed.ending
                    #expect(ending == nil, "the event stream ended at the reattach")
                    let workspaces = try await transport.sessionSnapshot().workspaces
                    #expect(workspaces.map(\.workspaceID) == [app(survivor.session)])

                    // The new client delivers events once the kill's are drained.
                    await feed.settle()
                    let window = try await host.newWindow(in: survivor.session, name: "after")
                    let event = try await feed.next(within: .sshdBudget(30)) {
                        Self.resyncKinds.contains($0.kind)
                    }
                    #expect(event != nil, "no resync event after the reattach")
                    let tabs = try await transport.sessionSnapshot().tabs
                    #expect(tabs.contains { $0.tabID == app(window.window) })
                }
            }
        }
    }

    /// A bulk Close below tmux 3.6 (T24): one close takes the anchor
    /// session's only window, tmux answers it and sends `%exit`, and the
    /// lines it read after that never run. The other closes and two
    /// snapshots follow the anchor's a millisecond apart, as countdowns
    /// running out together do, so some land in those later reads (how many
    /// depends on the link's timing; the unit tests pin the replay itself).
    /// Every window still closes: a kill changes nothing when run twice, so a
    /// lost one goes out again on the replacement client, and so does a lost
    /// snapshot. A replayed kill that found its window gone would mean tmux
    /// ran a line it never answered, against T24; this test fails then,
    /// though the Console would take it as closed. CI's tmux is newer, so
    /// this Transport leaves `no-detach-on-destroy` off to get that same
    /// `%exit`.
    @Test("a bulk Close across the anchor exit closes every window")
    func bulkCloseAcrossTheAnchorExitClosesEveryWindow() async throws {
        try await withTmuxHost { environment, host in
            let anchor = try await host.newSession("anchor")
            let survivor = try await host.newSession("survivor")
            var others: [String] = []
            for index in 0..<6 {
                others.append(try await host.newWindow(in: survivor.session, name: "w\(index)").window)
            }
            var configuration = TmuxTransport.Configuration(
                requestTimeout: environment.settings().requestTimeout)
            configuration.requestsNoDetachOnDestroy = false

            try await withTransport(environment, configuration: configuration) { transport in
                _ = try await transport.ping()
                let before = try await host.controlClients()
                #expect(before.map(\.session) == [anchor.session])
                let anchorTab = app(anchor.window)
                let otherTabs = others.map { app($0) }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await transport.closeTab(TabTarget(tabID: anchorTab)) }
                    for (offset, tabID) in otherTabs.enumerated() {
                        group.addTask {
                            try await Task.sleep(for: .milliseconds(1 + offset))
                            try await transport.closeTab(TabTarget(tabID: tabID))
                        }
                    }
                    for offset in [2, 4] {
                        group.addTask {
                            try await Task.sleep(for: .milliseconds(offset))
                            _ = try await transport.sessionSnapshot()
                        }
                    }
                    try await group.waitForAll()
                }
                let remaining = try await host.lines("list-windows -a -F '#{window_id}'")
                #expect(
                    Set(remaining).isDisjoint(with: [anchor.window] + others),
                    "windows left: \(remaining)")
                #expect(remaining.contains(survivor.window))
                // tmux ended the anchor's client: a new process took over.
                let replaced = try await tmuxEventually {
                    try await host.controlClients().map(\.session) == [survivor.session]
                }
                #expect(replaced, "the control channel did not come back on the survivor")
                let after = try await host.controlClients()
                #expect(
                    Set(after.map(\.pid)).isDisjoint(with: before.map(\.pid)),
                    "the control client was moved, not replaced: \(before) -> \(after)")
            }
        }
    }

    @Test("close leaves no waycar sessions or control clients behind")
    func closeLeavesNothingBehind() async throws {
        try await withTmuxHost { environment, host in
            let main = try await host.newSession("main")
            let transport = try await connect(environment)
            let attach: TerminalAttachSession
            do {
                _ = try await transport.ping()
                // Left attached on purpose: close() must take it down too.
                attach = try await transport.attachTerminal(
                    TerminalAttachRequest(target: .agentPane(app(main.pane)), cols: 80, rows: 24))
                let attached = try await tmuxEventually { try await host.waycarSessions().count == 1 }
                #expect(attached, "the attach created no private session")
                let clients = try await host.controlClientSessions()
                #expect(clients == [main.session])
            } catch {
                try? await transport.close()
                throw error
            }
            try await transport.close()

            let viewGone = try await tmuxEventually { try await host.waycarSessions().isEmpty }
            #expect(viewGone, "close left an attach session")
            let clientGone = try await tmuxEventually {
                try await host.controlClientSessions().isEmpty
            }
            #expect(clientGone, "close left the control client attached")
            let remaining = try await host.lines("list-sessions -F '#{session_name}'")
            #expect(remaining == ["main"])
            await attach.end()
        }
    }

    // MARK: Helpers

    /// Opens the isolated fixture Host, empties its private tmux server, runs
    /// `body`, and empties the server again whatever happened.
    private func withTmuxHost(
        _ body: (TmuxTransportE2EEnvironment, TmuxFixtureHost) async throws -> Void
    ) async throws {
        let environment = try #require(TmuxTransportE2EEnvironment.current)
        let host = try await TmuxFixtureHost.open(environment)
        let outcome: Result<Void, any Error>
        do {
            try await host.resetServer()
            try await body(environment, host)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await host.close()
        try outcome.get()
    }

    /// The production tmux Transport, or, given `configuration`, one opened
    /// on its own SSH session with that configuration.
    private func connect(
        _ environment: TmuxTransportE2EEnvironment,
        configuration: TmuxTransport.Configuration? = nil
    ) async throws -> any Transport {
        guard let configuration else {
            let transport = try await SSHTransportConnector().connect(
                settings: environment.settings(), backend: .tmux)
            #expect(transport is TmuxTransport)
            return transport
        }
        let session = try await HostSSHSession.dial(settings: environment.settings())
        do {
            return try await TmuxTransport.open(session: session, configuration: configuration)
        } catch {
            await session.release()
            throw error
        }
    }

    /// Runs `body` on a fresh tmux Transport and closes it before returning,
    /// so the next step (and the server reset) never races its channels.
    private func withTransport(
        _ environment: TmuxTransportE2EEnvironment,
        configuration: TmuxTransport.Configuration? = nil,
        _ body: (any Transport) async throws -> Void
    ) async throws {
        let transport = try await connect(environment, configuration: configuration)
        let outcome: Result<Void, any Error>
        do {
            try await body(transport)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        try? await transport.close()
        try outcome.get()
    }

    private func withEvents(
        _ transport: any Transport,
        _ body: (TmuxEventFeed) async throws -> Void
    ) async throws {
        let feed = TmuxEventFeed(try await transport.subscribeToEvents([.global(.tabCreated)]))
        let outcome: Result<Void, any Error>
        do {
            try await body(feed)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await feed.end()
        try outcome.get()
    }

    /// The app-side spelling of a raw tmux id, written out rather than taken
    /// from `TmuxID` so the prefix itself is what these tests pin.
    private func app(_ raw: String) -> String {
        "tmux:" + raw
    }
}

/// How many times a test pool's dialer reached the Host.
private actor DialCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

/// Polls `condition` until it holds or `budget` runs out.
private func tmuxEventually(
    within budget: Duration = .sshdBudget(30),
    _ condition: () async throws -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + budget
    while true {
        if try await condition() { return true }
        if ContinuousClock.now >= deadline { return false }
        try await Task.sleep(for: .milliseconds(100))
    }
}

/// POSIX single quoting for the fixture's `/bin/sh` (and tmux, which parses
/// the same `'\''` form).
private func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Exec access to the fixture Host's tmux, for seeding and inspecting the
/// server the Transport under test drives. Only `open` makes one, and it
/// refuses unless the SSH session's tmux is the fixture's private server.
private struct TmuxFixtureHost: Sendable {
    /// Raw tmux ids of one seeded pane and what contains it.
    struct Pane: Sendable {
        let session: String
        let window: String
        let pane: String
    }

    /// One control-mode client as `list-clients` reports it.
    struct ControlClient: Sendable, CustomStringConvertible {
        let pid: String
        let session: String
        let flags: String

        var description: String { "pid \(pid) on \(session) [\(flags)]" }
    }

    static let idleCommand = "exec sleep 86400"

    let connection: SSHConnection
    /// The private socket directory as tmux reports it: tmux resolves
    /// symlinks, and macOS `/tmp` is `/private/tmp`.
    let physicalTmuxDirectory: String
    /// The fixture home as a pane's `pane_current_path` reports it.
    let physicalHome: String

    private static let isolationProbe =
        "printf 'TMUX_TMPDIR=%s\\nTMUX=%s\\nTMUX_TMPDIR_PHYSICAL=%s\\nHOME_PHYSICAL=%s\\n' "
        + "\"${TMUX_TMPDIR-}\" \"${TMUX-}\" "
        + "\"$(cd \"${TMUX_TMPDIR:-/nonexistent}\" 2>/dev/null && pwd -P)\" "
        + "\"$(cd \"$HOME\" && pwd -P)\""

    /// Connects and proves isolation before anything can touch a tmux
    /// server: the session must carry the fixture's `TMUX_TMPDIR` and no
    /// inherited `TMUX`, either of which would point plain `tmux` at the
    /// developer's own server.
    static func open(_ environment: TmuxTransportE2EEnvironment) async throws -> TmuxFixtureHost {
        let connection = try await environment.hostConnection()
        do {
            let probe = String(
                decoding: try await run(on: connection, isolationProbe), as: UTF8.self)
            var values: [String: String] = [:]
            for line in probe.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let separator = line.firstIndex(of: "=") else { continue }
                values[String(line[..<separator])] = String(line[line.index(after: separator)...])
            }
            try #require(
                values["TMUX_TMPDIR"] == environment.tmuxDirectory,
                Comment(
                    rawValue: "fixture sessions export TMUX_TMPDIR="
                        + "\(values["TMUX_TMPDIR"] ?? "nil"), not \(environment.tmuxDirectory); "
                        + "refusing to run tmux against a shared server"))
            try #require(
                values["TMUX"]?.isEmpty == true,
                "fixture sessions inherit TMUX=\(values["TMUX"] ?? "nil"); refusing to run tmux")
            let physicalTmuxDirectory = try #require(
                values["TMUX_TMPDIR_PHYSICAL"].flatMap { $0.isEmpty ? nil : $0 },
                "the fixture TMUX_TMPDIR does not exist on the Host")
            let physicalHome = try #require(
                values["HOME_PHYSICAL"].flatMap { $0.isEmpty ? nil : $0 })
            return TmuxFixtureHost(
                connection: connection,
                physicalTmuxDirectory: physicalTmuxDirectory,
                physicalHome: physicalHome)
        } catch {
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
    }

    /// Empties the private server and closes the exec connection.
    func close() async {
        try? await resetServer()
        try? await connection.close(timeout: .sshdBudget(2))
    }

    /// Kills the private server and waits for its process to exit. tmux
    /// leaves the socket file behind, so the pid is what is waited on.
    func resetServer() async throws {
        try await shell(
            "pid=$(env -u TMUX tmux display -p '#{pid}' 2>/dev/null); "
                + "env -u TMUX tmux kill-server 2>/dev/null; i=0; "
                + "while [ -n \"$pid\" ] && kill -0 \"$pid\" 2>/dev/null && [ $i -lt 50 ]; do "
                + "sleep 0.1; i=$((i+1)); done; true")
    }

    /// Creates a detached session, starting the server with no config file
    /// and `/bin/sh` as the shell for windows created without a command.
    func newSession(
        _ name: String, command: String = TmuxFixtureHost.idleCommand
    ) async throws -> Pane {
        let ids = try await tmux(
            "-f /dev/null new-session -d -s \(shellQuoted(name)) -x 120 -y 40 "
                + "-P -F '#{session_id} #{window_id} #{pane_id}' \(shellQuoted(command)) "
                + "\\; set-option -g default-shell /bin/sh")
        let pane = try Self.pane(from: ids)
        let socket = try await tmux("display -p '#{socket_path}'")
        try #require(
            socket.hasPrefix(physicalTmuxDirectory + "/tmux-"),
            "seeded a tmux server at \(socket), outside \(physicalTmuxDirectory)")
        return pane
    }

    func newWindow(
        in session: String, name: String, cwd: String? = nil,
        command: String = TmuxFixtureHost.idleCommand
    ) async throws -> Pane {
        let directory = cwd.map { "-c \(shellQuoted($0)) " } ?? ""
        return try Self.pane(
            from: try await tmux(
                "new-window -d -t \(shellQuoted(session + ":")) -n \(shellQuoted(name)) "
                    + directory
                    + "-P -F '#{session_id} #{window_id} #{pane_id}' \(shellQuoted(command))"))
    }

    /// Splits `window`; returns the new pane's raw id.
    func splitWindow(
        _ window: String, command: String = TmuxFixtureHost.idleCommand
    ) async throws -> String {
        try await tmux(
            "split-window -d -t \(shellQuoted(window)) -P -F '#{pane_id}' \(shellQuoted(command))")
    }

    func windowName(_ window: String) async throws -> String {
        try await tmux("display -p -t \(shellQuoted(window)) '#{window_name}'")
    }

    /// Sessions Waycar's attach chain created (design §4.4).
    func waycarSessions() async throws -> [String] {
        try await lines("list-sessions -F '#{session_name}'").filter { $0.hasPrefix("waycar-") }
    }

    /// The raw session id each control-mode client is attached to.
    func controlClientSessions() async throws -> [String] {
        try await lines("list-clients -F '#{client_control_mode} #{session_id}'")
            .filter { $0.hasPrefix("1 ") }
            .map { String($0.dropFirst(2)) }
    }

    /// Every control-mode client: its process, session and flags.
    func controlClients() async throws -> [ControlClient] {
        try await lines(
            "list-clients -F '#{client_control_mode} #{client_pid} #{session_id} #{client_flags}'"
        ).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard fields.count >= 3, fields[0] == "1" else { return nil }
            return ControlClient(
                pid: fields[1], session: fields[2], flags: fields.count > 3 ? fields[3] : "")
        }
    }

    /// A tmux listing, one entry per line; empty when no server runs.
    func lines(_ arguments: String) async throws -> [String] {
        try await shell("env -u TMUX tmux \(arguments) 2>/dev/null; true")
            .split(separator: "\n")
            .map(String.init)
    }

    /// The file's bytes; empty while it does not exist yet.
    func readFile(_ path: String) async throws -> Data {
        try await Self.run(on: connection, "cat \(shellQuoted(path)) 2>/dev/null; true")
    }

    /// One tmux command that must succeed; its output without the final
    /// newline.
    @discardableResult
    func tmux(_ arguments: String) async throws -> String {
        try await shell("env -u TMUX tmux \(arguments)")
            .trimmingCharacters(in: .newlines)
    }

    @discardableResult
    func shell(_ command: String) async throws -> String {
        String(decoding: try await Self.run(on: connection, command), as: UTF8.self)
    }

    private static func run(on connection: SSHConnection, _ command: String) async throws -> Data {
        let result = try await connection.execute(command, timeout: .sshdBudget(10))
        guard result.exitStatus == 0 else {
            throw TmuxFixtureError.commandFailed(
                command: command,
                exitStatus: result.exitStatus,
                stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        return result.stdout
    }

    private static func pane(from ids: String) throws -> Pane {
        let fields = ids.split(separator: " ").map(String.init)
        try #require(fields.count == 3, "tmux printed \(ids.debugDescription) for -P")
        return Pane(session: fields[0], window: fields[1], pane: fields[2])
    }
}

private enum TmuxFixtureError: Error, CustomStringConvertible {
    case commandFailed(command: String, exitStatus: Int32, stderr: String)

    var description: String {
        switch self {
        case .commandFailed(let command, let exitStatus, let stderr):
            "`\(command)` exited \(exitStatus): \(stderr)"
        }
    }
}

/// Drains one event stream into a log the test searches, so waiting for one
/// event never consumes another and a stream that dies is visible.
private final class TmuxEventFeed: Sendable {
    private let log: TmuxEventLog
    private let stream: HerdrEventStream
    private let pump: Task<Void, Never>

    init(_ stream: HerdrEventStream) {
        let log = TmuxEventLog()
        self.log = log
        self.stream = stream
        pump = Task {
            do {
                for try await event in stream.events {
                    await log.append(event)
                }
                await log.end("finished")
            } catch {
                await log.end("failed: \(error)")
            }
        }
    }

    /// Why the stream ended; nil while it is open.
    var ending: String? {
        get async { await log.ending }
    }

    /// The first not-yet-taken event matching `predicate`, waiting up to
    /// `budget` for it.
    func next(
        within budget: Duration,
        where predicate: @escaping @Sendable (HerdrEvent) -> Bool
    ) async throws -> HerdrEvent? {
        var found: HerdrEvent?
        _ = try await tmuxEventually(within: budget) {
            found = await self.log.take(where: predicate)
            return found != nil
        }
        return found
    }

    /// Waits for a quiet second and a half, bounded, then marks everything
    /// so far as taken: what follows is caused by what the test does next.
    func settle() async {
        let deadline = ContinuousClock.now + .sshdBudget(10)
        var seen = await log.count
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1500))
            let now = await log.count
            if now == seen { break }
            seen = now
        }
        await log.takeAll()
    }

    func end() async {
        await stream.end()
        await pump.value
    }
}

private actor TmuxEventLog {
    private var events: [HerdrEvent] = []
    private var taken = 0
    private(set) var ending: String?

    var count: Int { events.count }

    func append(_ event: HerdrEvent) {
        events.append(event)
    }

    func end(_ reason: String) {
        ending = reason
    }

    func take(where predicate: @Sendable (HerdrEvent) -> Bool) -> HerdrEvent? {
        guard let index = events[taken...].firstIndex(where: predicate) else { return nil }
        taken = index + 1
        return events[index]
    }

    func takeAll() {
        taken = events.count
    }
}

/// Accumulates an Attach's raw output so the test can wait for a marker with
/// a deadline instead of blocking on the next chunk.
private final class AttachOutputFeed: Sendable {
    private let log: AttachOutputLog
    private let pump: Task<Void, Never>

    init(_ session: TerminalAttachSession) {
        let log = AttachOutputLog()
        self.log = log
        pump = Task {
            do {
                for try await chunk in session.output {
                    await log.append(chunk)
                }
                await log.end("finished")
            } catch {
                await log.end("failed: \(error)")
            }
        }
    }

    var ending: String? {
        get async { await log.ending }
    }

    func waitFor(_ marker: String, within budget: Duration = .sshdBudget(30)) async throws -> Bool {
        try await tmuxEventually(within: budget) { await self.log.contains(marker) }
    }

    /// Returns once the output stream has finished.
    func finished() async {
        await pump.value
    }
}

private actor AttachOutputLog {
    private var bytes = Data()
    private(set) var ending: String?

    func append(_ chunk: Data) {
        bytes.append(chunk)
    }

    func end(_ reason: String) {
        ending = reason
    }

    func contains(_ marker: String) -> Bool {
        bytes.range(of: Data(marker.utf8)) != nil
    }
}

/// The disposable fixture as `scripts/run-ci-ios-tests.sh` describes it in
/// `WAYCAR_SSH_E2E_CONFIG`, present only when the runner has tmux 3.2 or
/// later (the script refuses to start merge CI without it), or a Linux test
/// box as `scripts/run-tmux-e2e-remote.sh` describes it in the same shape.
struct TmuxTransportE2EEnvironment: Sendable {
    let host: String
    let port: UInt16
    let username: String
    let deviceKey: Curve25519.Signing.PrivateKey
    /// The fixture's fake herdr socket at the default path; nothing serves it
    /// when `herdrStub` is false.
    let socketPath: String
    let homePath: String
    /// The per-run directory every fixture session exports as `TMUX_TMPDIR`.
    let tmuxDirectory: String
    /// What `tmux -V` reports on the fixture Host, without the `tmux ` prefix.
    let tmuxVersion: String
    /// False only for a Host that serves no herdr stub
    /// (`scripts/run-tmux-e2e-remote.sh` on a box without Python 3.9+).
    let herdrStub: Bool
    /// The macOS fixture's codex and OpenCode stubs and the directory every
    /// program its sessions find must live in; nil on a Linux test box,
    /// whose own programs are the Host's.
    let cliStubs: CLIStubs?

    struct CLIStubs: Sendable, Decodable {
        let root: String
        let codex: String
        let opencode: String
    }

    /// Gates the tests that need the fixture's herdr stub. True when no
    /// fixture is configured, so a required-but-missing fixture still fails.
    static var servesHerdr: Bool {
        current?.herdrStub ?? true
    }

    /// Gates the tests that need the macOS fixture's CLI stubs; true when no
    /// fixture is configured, like `servesHerdr`.
    static var hasCLIStubs: Bool {
        current.map { $0.cliStubs != nil } ?? true
    }

    static let current: TmuxTransportE2EEnvironment? = {
        guard
            let encoded = ProcessInfo.processInfo.environment["WAYCAR_SSH_E2E_CONFIG"],
            let data = Data(base64Encoded: encoded),
            let fixture = try? JSONDecoder().decode(Fixture.self, from: data),
            let tmux = fixture.tmux,
            let deviceKey = try? RealSSHFixture.deviceKey(seed: fixture.deviceKeySeed)
        else { return nil }
        return TmuxTransportE2EEnvironment(
            host: fixture.host,
            port: fixture.port,
            username: fixture.username,
            deviceKey: deviceKey,
            socketPath: fixture.socketPath,
            homePath: fixture.homePath,
            tmuxDirectory: tmux.directory,
            tmuxVersion: tmux.version,
            herdrStub: tmux.herdrStub ?? true,
            cliStubs: tmux.cliStubs)
    }()

    func settings() -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: host,
            port: Int(port),
            username: username,
            credentials: .ed25519(deviceKey),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .absolutePath(socketPath))
        settings.requestTimeout = .sshdBudget(15)
        settings.wakesInLoginSession = false
        settings.detectionSearchesSystemDirectories = false
        return settings
    }

    /// A bare exec connection for seeding and inspecting the tmux server.
    func hostConnection() async throws -> SSHConnection {
        let key = DeviceKey(privateKey: deviceKey)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: host, port: port), timeout: .sshdBudget(5))
        do {
            try await connection.authenticate(
                username: username,
                publicKey: key.publicKeyBlob,
                signer: { data in try key.privateKey.signature(for: data) },
                timeout: .sshdBudget(5))
            return connection
        } catch {
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
    }

    private struct Fixture: Decodable {
        let host: String
        let port: UInt16
        let username: String
        let deviceKeySeed: String
        let socketPath: String
        let homePath: String
        let tmux: TmuxFixture?
    }

    private struct TmuxFixture: Decodable {
        let directory: String
        let version: String
        /// Absent from the macOS fixture, which always serves the stub.
        let herdrStub: Bool?
        /// Only the macOS fixture has them.
        let cliStubs: CLIStubs?
    }
}
