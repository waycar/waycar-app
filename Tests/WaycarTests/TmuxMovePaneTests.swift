import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

@Suite("tmux pane moves")
struct TmuxMovePaneTests {
    /// `$1 main` holds `@2` with claude in `%3` beside a shell `%4`; `$5
    /// other` holds `@6` with a shell `%7` alone.
    private static func world() -> FakeTmuxServer {
        FakeTmuxServer(
            sessions: [.init(id: "$1", name: "main"), .init(id: "$5", name: "other")],
            windows: [
                .init(id: "@2", session: "$1", name: "claude"),
                .init(id: "@6", session: "$5", name: "zsh"),
            ],
            panes: [
                .init(id: "%3", window: "@2", command: "claude", agent: "claude"),
                .init(id: "%4", window: "@2", command: "zsh", agent: ""),
                .init(id: "%7", window: "@6", command: "zsh", agent: ""),
            ])
    }

    /// `$1 main` holds `@2` with claude in `%3` alone, so the control client
    /// anchors on a session one pane empties; `$4 other` holds `@5` with
    /// shells `%6` and `%7`; `$8 dest` holds `@8` with a shell `%9`.
    private static func anchorWorld() -> FakeTmuxServer {
        FakeTmuxServer(
            sessions: [
                .init(id: "$1", name: "main"), .init(id: "$4", name: "other"),
                .init(id: "$8", name: "dest"),
            ],
            windows: [
                .init(id: "@2", session: "$1", name: "claude"),
                .init(id: "@5", session: "$4", name: "zsh"),
                .init(id: "@8", session: "$8", name: "zsh"),
            ],
            panes: [
                .init(id: "%3", window: "@2", command: "claude", agent: "claude"),
                .init(id: "%6", window: "@5", command: "zsh", agent: ""),
                .init(id: "%7", window: "@5", command: "zsh", agent: ""),
                .init(id: "%9", window: "@8", command: "zsh", agent: ""),
            ])
    }

    /// A move of `%6` in ``anchorWorld()`` whose line an anchor's `%exit`
    /// leaves unanswered, to each kind of destination.
    enum LostMove: String, CaseIterable, CustomTestStringConvertible {
        case newTabElsewhere, newTabHereFocused, joinFocused, newWorkspace

        var testDescription: String { rawValue }

        var params: PaneMoveParams {
            switch self {
            case .newTabElsewhere:
                PaneMoveParams(
                    destination: .newTab(PaneMoveDestinationNewTab(workspaceID: "tmux:$8")),
                    paneID: "tmux:%6")
            case .newTabHereFocused:
                PaneMoveParams(
                    destination: .newTab(PaneMoveDestinationNewTab(workspaceID: "tmux:$4")),
                    paneID: "tmux:%6", focus: true)
            case .joinFocused:
                PaneMoveParams(
                    destination: .tab(PaneMoveDestinationTab(split: .right, tabID: "tmux:@8")),
                    paneID: "tmux:%6", focus: true)
            case .newWorkspace:
                PaneMoveParams(
                    destination: .newWorkspace(PaneMoveDestinationNewWorkspace()),
                    paneID: "tmux:%6")
            }
        }

        /// The move command alone.
        var move: String {
            switch self {
            case .newTabElsewhere: "break-pane -d -s %6 -t '$8:'"
            case .newTabHereFocused: "break-pane -d -s %6 -t '$4:'"
            case .joinFocused: "join-pane -d -h -s %6 -t @8"
            // The placeholder session the fake numbers `$10`, its window `@11`.
            case .newWorkspace: "break-pane -d -s %6 -t '$10:'"
            }
        }

        /// What follows the move on its line.
        var rest: [String] {
            switch self {
            case .newTabElsewhere: []
            case .newTabHereFocused, .joinFocused: ["select-window -t %6", "select-pane -t %6"]
            case .newWorkspace: ["kill-window -t @11"]
            }
        }

        var line: String { ([move] + rest).joined(separator: " ; ") }

        /// The move's verb, from which its channel holds lines.
        var verb: String { String(move.prefix { $0 != " " }) }

        /// Whether the pane is where the move sends it.
        func landed(_ pane: PaneInfo) -> Bool {
            switch self {
            case .newTabElsewhere: pane.workspaceID == "tmux:$8"
            case .newTabHereFocused: pane.workspaceID == "tmux:$4" && pane.tabID != "tmux:@5"
            case .joinFocused: pane.tabID == "tmux:@8"
            case .newWorkspace: pane.workspaceID == "tmux:$10"
            }
        }
    }

    @Test func newTabInAnotherWorkspaceBreaksThePaneOut() async throws {
        let server = Self.world()
        let (transport, channel) = try await Self.open(server)

        let response = try await transport.movePane(PaneMoveParams(
            destination: .newTab(PaneMoveDestinationNewTab(label: "agent", workspaceID: "tmux:$5")),
            paneID: "tmux:%3"))

        #expect(channel.writtenLines.contains("break-pane -d -s %3 -t '$5:' -n 'agent'"))
        #expect(!channel.writtenLines.contains { $0.contains("select-pane") })
        let result = response.moveResult
        #expect(result.changed)
        // tmux keeps the pane id: pins and unread marks stay put.
        #expect(result.pane.paneID == "tmux:%3")
        #expect(result.pane.agent == "claude")
        #expect(result.pane.workspaceID == "tmux:$5")
        #expect(result.previousPaneID == "tmux:%3")
        #expect(result.previousTabID == "tmux:@2")
        #expect(result.previousWorkspaceID == "tmux:$1")
        let created = try #require(result.createdTab)
        #expect(created.tabID == result.pane.tabID)
        #expect(created.workspaceID == "tmux:$5")
        #expect(created.label == "agent")
        #expect(result.createdWorkspace == nil)
        #expect(result.closedTabID == nil)
        #expect(result.closedWorkspaceID == nil)
        #expect(result.targetLayout.tabID == result.pane.tabID)
        #expect(result.targetLayout.panes.map(\.paneID) == ["tmux:%3"])
        #expect(result.sourceLayout?.tabID == "tmux:@2")
        #expect(result.sourceLayout?.panes.map(\.paneID) == ["tmux:%4"])
        try await transport.close()
    }

    @Test func newWorkspaceMovesALonePaneWholeAndDropsThePlaceholder() async throws {
        let server = Self.world()
        let (transport, channel) = try await Self.open(server)

        let response = try await transport.movePane(PaneMoveParams(
            destination: .newWorkspace(
                PaneMoveDestinationNewWorkspace(label: "scratch", tabLabel: "logs")),
            paneID: "tmux:%7", focus: true))

        #expect(channel.writtenLines.contains(TmuxCommand.newSession(
            name: "scratch", cwd: "/home/me/repo", environment: ["WAYCAR_SHELL": "1"],
            command: nil, printFormat: TmuxTransport.launchPrintFormat)))
        // The fake numbers new objects from 10: session $10, placeholder @11 / %12.
        #expect(channel.writtenLines.contains([
            "break-pane -d -s %7 -t '$10:' -n 'logs'", "kill-window -t @11",
            "select-window -t %7", "select-pane -t %7",
        ].joined(separator: " ; ")))
        let result = response.moveResult
        #expect(result.changed)
        #expect(result.pane.paneID == "tmux:%7")
        // A single-pane window moves whole and keeps its id.
        #expect(result.pane.tabID == "tmux:@6")
        #expect(result.pane.workspaceID == "tmux:$10")
        let workspace = try #require(result.createdWorkspace)
        #expect(workspace.workspaceID == "tmux:$10")
        #expect(workspace.label == "scratch")
        #expect(workspace.tabCount == 1)
        #expect(result.createdTab?.tabID == "tmux:@6")
        #expect(result.createdTab?.label == "logs")
        // The window moved rather than closed; the session it left is gone.
        #expect(result.closedTabID == nil)
        #expect(result.closedWorkspaceID == "tmux:$5")
        #expect(result.sourceLayout == nil)
        #expect(result.focusedPaneID == "tmux:%7")
        #expect(server.sessionIDs == ["$1", "$10"])
        try await transport.close()
    }

    @Test func failedBreakOutKillsThePlaceholderSession() async throws {
        let server = Self.world()
        server.failBreakPane()
        let (transport, channel) = try await Self.open(server)

        do {
            _ = try await transport.movePane(PaneMoveParams(
                destination: .newWorkspace(PaneMoveDestinationNewWorkspace()),
                paneID: "tmux:%3"))
            Issue.record("a failed break-pane reported a move")
        } catch let error as HerdrAPIError {
            #expect(error.code == "pane_not_found")
        }
        // The placeholder's only window goes, and its session with it.
        #expect(channel.writtenLines.contains("kill-window -t @11"))
        #expect(server.sessionIDs == ["$1", "$5"])
        try await transport.close()
    }

    /// The move line ran, but its replies never arrived (the channel ended
    /// under it): the cleanup must not take the moved pane with the
    /// placeholder.
    @Test func lostRepliesAfterTheBreakOutKeepTheMovedPane() async throws {
        let server = Self.world()
        let dropper = ReplyDropper()
        let fake = FakeHostSSHServices(
            exec: { command, _ in server.exec(command) },
            control: { line in
                let blocks = server.respond(line)
                guard line.hasPrefix("break-pane"), let channel = dropper.take() else {
                    return blocks
                }
                channel.lose()
                return []
            })
        let transport = try await TmuxTransport.open(
            session: fake, configuration: TmuxTransportTests.configuration())
        dropper.arm(try #require(await fake.controlChannels.first))

        do {
            _ = try await transport.movePane(PaneMoveParams(
                destination: .newWorkspace(PaneMoveDestinationNewWorkspace()),
                paneID: "tmux:%3"))
            Issue.record("a move without replies reported success")
        } catch {}

        #expect(server.paneIDs.contains("%3"))
        #expect(server.sessionIDs == ["$1", "$5", "$10"])
        let channels = await fake.controlChannels
        let lines = channels.flatMap(\.writtenLines)
        #expect(lines.contains("kill-window -t @11"))
        #expect(!lines.contains { $0.hasPrefix("kill-session") })
        try await transport.close()
    }

    /// tmux below 3.6 (T24): the anchor session dies while a move's line is
    /// in flight (another client took its last window, or another move of a
    /// bulk Move did), so `%exit` leaves the line unanswered, and it never
    /// ran. A snapshot from the replacement client finds the pane still at
    /// home, so the whole line goes out once more.
    @Test(arguments: LostMove.allCases)
    func aMoveAnAnchorExitLeftUnansweredGoesOutOnceMore(_ move: LostMove) async throws {
        let server = Self.anchorWorld()
        let (transport, fake, first) = try await Self.openWithFake(server)
        let moving = await Self.startMoveAnAnchorExitLoses(move, transport, server, first)
        first.exitAnswering(0)

        let result = try await moving.value.moveResult
        #expect(result.changed)
        #expect(move.landed(result.pane))
        let second = try #require(await fake.controlChannels.last)
        #expect(second !== first)
        #expect(second.writtenLines.filter { $0 == move.line }.count == 1)
        try await transport.close()
    }

    /// The same lost line, but the pane reached its destination meanwhile
    /// (another client moved it): no move goes out again, which would move
    /// the pane once more, only what the line held besides it (focus, a
    /// placeholder window still standing).
    @Test(arguments: LostMove.allCases)
    func aMoveAnAnchorExitLeftUnansweredIsNotSentAgainOnceThePaneLanded(
        _ move: LostMove
    ) async throws {
        let server = Self.anchorWorld()
        let (transport, fake, first) = try await Self.openWithFake(server)
        let moving = await Self.startMoveAnAnchorExitLoses(move, transport, server, first)
        _ = server.respond(move.move)
        first.exitAnswering(0)

        let result = try await moving.value.moveResult
        #expect(move.landed(result.pane))
        let second = try #require(await fake.controlChannels.last)
        #expect(second !== first)
        #expect(!second.writtenLines.contains { $0.hasPrefix(move.verb) })
        let rest = second.writtenLines.filter { $0.hasPrefix("select-") || $0.hasPrefix("kill-window") }
        #expect(rest == (move.rest.isEmpty ? [] : [move.rest.joined(separator: " ; ")]))
        try await transport.close()
    }

    /// The replacement client reached another server: the lost line's ids
    /// may name other panes there, so the move is neither sent again nor
    /// taken as done, even where that server shows a pane `%6` at the
    /// destination.
    @Test(arguments: [false, true])
    func aMoveAnAnchorExitLeftUnansweredStaysLostOnAnotherServer(
        lookalikeLanded: Bool
    ) async throws {
        let server = Self.anchorWorld()
        let (transport, fake, first) = try await Self.openWithFake(server)
        let move = LostMove.newTabElsewhere
        let moving = await Self.startMoveAnAnchorExitLoses(move, transport, server, first)
        if lookalikeLanded { _ = server.respond(move.move) }
        server.replaceServer()
        first.exitAnswering(0)

        await #expect(throws: TransportError.channelFailed(detail: "tmux control mode exited")) {
            _ = try await moving.value
        }
        let second = try #require(await fake.controlChannels.last)
        #expect(second !== first)
        #expect(!second.writtenLines.contains { $0.hasPrefix(move.verb) })
        try await transport.close()
    }

    /// The replacement client exits too before answering the resent line
    /// (its own anchor died, or the desk detached it): the line is checked
    /// again and goes out on the client after it.
    @Test func aMoveLostToTwoExitsGoesOutOnTheNextClient() async throws {
        let server = Self.anchorWorld()
        let (transport, fake, first) = try await Self.openWithFake(server)
        let move = LostMove.newTabElsewhere
        let moving = await Self.startMoveAnAnchorExitLoses(move, transport, server, first)
        await fake.holdLinesOnNextControlChannel(from: move.verb)
        first.exitAnswering(0)
        #expect(await eventually { await fake.controlChannels.count == 2 })
        let second = try #require(await fake.controlChannels.last)
        #expect(await eventually { second.writtenLines.last == move.line })
        second.exitAnswering(0)

        let result = try await moving.value.moveResult
        #expect(move.landed(result.pane))
        let third = try #require(await fake.controlChannels.last)
        #expect(third !== second)
        #expect(third.writtenLines.filter { $0 == move.line }.count == 1)
        try await transport.close()
    }

    @Test func existingTabJoinsAtTheTargetAndEmptiedPlacesClose() async throws {
        let server = Self.world()
        let (transport, channel) = try await Self.open(server)

        let first = try await transport.movePane(PaneMoveParams(
            destination: .tab(PaneMoveDestinationTab(
                split: .down, tabID: "tmux:@6", ratio: 0.7, targetPaneID: "tmux:%7")),
            paneID: "tmux:%3", focus: true))

        // herdr's ratio is the target's share: the moved pane takes the rest.
        #expect(channel.writtenLines.contains(
            "join-pane -d -v -l 30% -s %3 -t %7 ; select-window -t %3 ; select-pane -t %3"))
        #expect(first.moveResult.pane.paneID == "tmux:%3")
        #expect(first.moveResult.pane.tabID == "tmux:@6")
        #expect(first.moveResult.pane.workspaceID == "tmux:$5")
        #expect(first.moveResult.targetLayout.panes.map(\.paneID) == ["tmux:%7", "tmux:%3"])
        #expect(first.moveResult.focusedPaneID == "tmux:%3")
        #expect(first.moveResult.createdTab == nil)
        #expect(first.moveResult.closedTabID == nil)
        #expect(first.moveResult.sourceLayout?.panes.map(\.paneID) == ["tmux:%4"])

        // The last pane of `@2`, the only window of `$1`: both close.
        let second = try await transport.movePane(PaneMoveParams(
            destination: .tab(PaneMoveDestinationTab(split: .right, tabID: "tmux:@6")),
            paneID: "tmux:%4"))

        #expect(channel.writtenLines.contains("join-pane -d -h -s %4 -t @6"))
        #expect(second.moveResult.closedTabID == "tmux:@2")
        #expect(second.moveResult.closedWorkspaceID == "tmux:$1")
        #expect(second.moveResult.sourceLayout == nil)
        #expect(second.moveResult.targetLayout.panes.map(\.paneID)
            == ["tmux:%7", "tmux:%3", "tmux:%4"])
        try await transport.close()
    }

    @Test func movesToWhereThePaneAlreadyIsChangeNothing() async throws {
        let server = Self.world()
        let (transport, channel) = try await Self.open(server)

        let ownTab = try await transport.movePane(PaneMoveParams(
            destination: .tab(PaneMoveDestinationTab(split: .right, tabID: "tmux:@2")),
            paneID: "tmux:%3"))
        // Already alone in a window of that session.
        let ownWindow = try await transport.movePane(PaneMoveParams(
            destination: .newTab(PaneMoveDestinationNewTab(workspaceID: "tmux:$5")),
            paneID: "tmux:%7"))

        for result in [ownTab.moveResult, ownWindow.moveResult] {
            #expect(!result.changed)
            #expect(result.reason == .sameTab)
            #expect(result.pane.tabID == result.previousTabID)
            #expect(result.targetLayout.tabID == result.previousTabID)
        }
        #expect(!channel.writtenLines.contains { $0.contains("join-pane") || $0.contains("break-pane") })
        try await transport.close()
    }

    @Test func invalidMovesFailBeforeTmuxMovesAnything() async throws {
        let server = Self.world()
        let (transport, channel) = try await Self.open(server)
        let cases: [(PaneMoveDestination, String)] = [
            (.tab(PaneMoveDestinationTab(split: .right, tabID: "tmux:@99")), "tab_not_found"),
            (.tab(PaneMoveDestinationTab(
                split: .right, tabID: "tmux:@6", targetPaneID: "tmux:%4")), "invalid_target"),
            (.tab(PaneMoveDestinationTab(
                split: .down, tabID: "tmux:@6", ratio: .infinity)), "invalid_ratio"),
            (.tab(PaneMoveDestinationTab(
                split: SplitDirection(rawValue: "left"), tabID: "tmux:@6")), "invalid_params"),
            (.newTab(PaneMoveDestinationNewTab(workspaceID: "tmux:$99")), "workspace_not_found"),
        ]

        for (destination, code) in cases {
            do {
                _ = try await transport.movePane(
                    PaneMoveParams(destination: destination, paneID: "tmux:%3"))
                Issue.record("\(destination) moved the pane")
            } catch let error as HerdrAPIError {
                #expect(error.code == code)
            }
        }
        #expect(!channel.writtenLines.contains { $0.contains("join-pane") || $0.contains("break-pane") })
        try await transport.close()
    }

    // MARK: Helpers

    /// Starts `move` with its line held on `first` (tmux has not read it),
    /// waits for that line, then has another client kill the anchor session
    /// `$1`: the `%exit` the test then scripts leaves the line unanswered.
    private static func startMoveAnAnchorExitLoses(
        _ move: LostMove, _ transport: TmuxTransport, _ server: FakeTmuxServer,
        _ first: RespondingControlChannel
    ) async -> Task<PaneMoveResponse, any Error> {
        first.holdLines(from: move.verb)
        let moving = Task { try await transport.movePane(move.params) }
        #expect(await eventually { first.writtenLines.last == move.line })
        _ = server.respond("kill-session -t $1")
        return moving
    }

    private static func open(
        _ server: FakeTmuxServer
    ) async throws -> (TmuxTransport, RespondingControlChannel) {
        let (transport, _, channel) = try await openWithFake(server)
        return (transport, channel)
    }

    /// ``open(_:)``, also handing back the fake that records the control
    /// channels a reattach opens.
    private static func openWithFake(
        _ server: FakeTmuxServer
    ) async throws -> (TmuxTransport, FakeHostSSHServices, RespondingControlChannel) {
        let fake = FakeHostSSHServices(
            exec: { command, _ in server.exec(command) },
            control: { line in server.respond(line) })
        let transport = try await TmuxTransport.open(
            session: fake, configuration: TmuxTransportTests.configuration())
        let channel = try #require(await fake.controlChannels.first)
        return (transport, fake, channel)
    }
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

/// Drops the replies to the next `break-pane` line on the armed control
/// channel (the line still runs) and fails that channel, as a link that
/// dies right after tmux executed the line.
private final class ReplyDropper: Sendable {
    private let channel = Mutex<RespondingControlChannel?>(nil)

    func arm(_ channel: RespondingControlChannel) {
        self.channel.withLock { $0 = channel }
    }

    func take() -> RespondingControlChannel? {
        channel.withLock { $0.take() }
    }
}

// MARK: - Stateful fake tmux

/// A tiny tmux server: sessions, windows and panes that `new-session`,
/// `break-pane`, `join-pane`, `kill-window`, `kill-session` and
/// `select-pane` change as tmux 3.7c does (an emptied window or session
/// closes, a single-pane window breaks out whole), answering the inventory
/// and geometry commands from that state. A command list stops at its
/// first error. It reports tmux 3.2a, whose control client takes `%exit`
/// when its anchor session dies (T24, scripted per channel).
private final class FakeTmuxServer: Sendable {
    struct Session {
        let id: String
        var name: String
    }

    struct Window {
        let id: String
        var session: String
        var name: String
    }

    struct Pane {
        let id: String
        var window: String
        let command: String
        let agent: String
    }

    private struct State {
        var sessions: [Session]
        var windows: [Window]
        var panes: [Pane]
        /// Active pane per window.
        var activePane: [String: String] = [:]
        var nextID = 10
        var failBreakPane = false
        /// The server's `#{pid}`, part of its identity.
        var pid = 4242
    }

    private static let separator = "\u{241F}"
    private let state: Mutex<State>

    init(sessions: [Session], windows: [Window], panes: [Pane]) {
        var initial = State(sessions: sessions, windows: windows, panes: panes)
        for window in windows {
            initial.activePane[window.id] = panes.first { $0.window == window.id }?.id
        }
        state = Mutex(initial)
    }

    var sessionIDs: [String] { state.withLock { $0.sessions.map(\.id) } }

    var paneIDs: [String] { state.withLock { $0.panes.map(\.id) } }

    func failBreakPane() {
        state.withLock { $0.failBreakPane = true }
    }

    /// Another tmux server took the socket over: its identity differs.
    func replaceServer() {
        state.withLock { $0.pid += 1 }
    }

    func exec(_ command: String) -> SSHExecResult {
        if command.contains("exec tmux -V") {
            return FakeHostSSHServices.result(stdout: "tmux 3.2a\n")
        }
        if command.contains("tmux ls -F") {
            let sessions = state.withLock { $0.sessions }
            let lines = sessions.map { session in "\(session.id) off \(session.name)\n" }
            return FakeHostSSHServices.result(stdout: lines.joined())
        }
        return FakeHostSSHServices.result()
    }

    func respond(_ line: String) -> [FakeTmuxBlock] {
        if line.hasPrefix(TmuxTransport.versionFlagsCommand) {
            let pid = state.withLock { $0.pid }
            let answer = ["3.2a", "no-output", "1790979932", String(pid)]
            return [.ok([answer.joined(separator: Self.separator)]), .ok([]), .ok([])]
        }
        return state.withLock { state in
            var blocks: [FakeTmuxBlock] = []
            for command in line.components(separatedBy: " ; ") {
                let block = Self.run(Self.words(command), &state)
                blocks.append(block)
                if case .error = block { break }
            }
            return blocks
        }
    }

    private static func run(_ words: [String], _ state: inout State) -> FakeTmuxBlock {
        func value(_ flag: String) -> String? {
            guard let index = words.firstIndex(of: flag), index + 1 < words.count else {
                return nil
            }
            return words[index + 1]
        }
        switch words.first ?? "" {
        case "list-sessions":
            return .ok(state.sessions.map { TmuxTransportTests.sessionRecord($0.id, $0.name) })
        case "list-windows":
            return .ok(state.windows.map {
                TmuxTransportTests.windowRecord($0.id, session: $0.session, name: $0.name)
            })
        case "list-panes" where words.contains("-a"):
            let windows = state.windows
            return .ok(state.panes.compactMap { pane in
                guard let window = windows.first(where: { $0.id == pane.window }) else {
                    return nil
                }
                return TmuxTransportTests.paneRecord(
                    pane.id, session: window.session, window: window.id, command: pane.command,
                    agent: pane.agent, status: pane.agent.isEmpty ? "" : "idle")
            })
        case "list-panes":
            let window = value("-t") ?? ""
            let rows = state.panes.filter { $0.window == window }
            let active = state.activePane[window]
            return .ok(rows.enumerated().map { offset, pane in
                [pane.id, "0", String(offset * 10), "80", "9", active == pane.id ? "1" : "0"]
                    .joined(separator: separator)
            })
        case "display":
            if let target = value("-t"), target.hasPrefix("@") {
                return .ok(["80\(separator)30\(separator)0"])
            }
            return .ok(["3.7c"])
        case "new-session":
            let session = "$\(state.nextID)"
            let window = "@\(state.nextID + 1)"
            let pane = "%\(state.nextID + 2)"
            state.nextID += 3
            state.sessions.append(Session(id: session, name: value("-s") ?? session))
            state.windows.append(Window(id: window, session: session, name: "zsh"))
            state.panes.append(Pane(id: pane, window: window, command: "zsh", agent: ""))
            state.activePane[window] = pane
            return .ok([[pane, window, session].joined(separator: separator)])
        case "break-pane":
            guard !state.failBreakPane else { return .error(["can't find pane: %0"]) }
            guard let paneID = value("-s"),
                let index = state.panes.firstIndex(where: { $0.id == paneID }),
                let target = value("-t")
            else { return .error(["usage: break-pane"]) }
            let session = target.hasSuffix(":") ? String(target.dropLast()) : target
            guard state.sessions.contains(where: { $0.id == session }) else {
                return .error(["can't find session: \(session)"])
            }
            let source = state.panes[index].window
            if state.panes.filter({ $0.window == source }).count == 1,
                let windowIndex = state.windows.firstIndex(where: { $0.id == source })
            {
                var moved = state.windows.remove(at: windowIndex)
                moved.session = session
                if let name = value("-n") { moved.name = name }
                state.windows.append(moved)
            } else {
                let window = "@\(state.nextID)"
                state.nextID += 1
                state.windows.append(Window(id: window, session: session, name: value("-n") ?? "zsh"))
                state.panes[index].window = window
                state.activePane[window] = paneID
            }
            prune(&state)
            return .ok([])
        case "join-pane":
            guard let paneID = value("-s"),
                let index = state.panes.firstIndex(where: { $0.id == paneID }),
                let target = value("-t")
            else { return .error(["usage: join-pane"]) }
            let window = target.hasPrefix("%")
                ? state.panes.first(where: { $0.id == target })?.window : target
            guard let window, state.windows.contains(where: { $0.id == window }) else {
                return .error(["can't find window: \(target)"])
            }
            var pane = state.panes.remove(at: index)
            pane.window = window
            state.panes.append(pane)
            prune(&state)
            return .ok([])
        case "kill-window":
            let window = value("-t")
            state.panes.removeAll { $0.window == window }
            prune(&state)
            return .ok([])
        case "kill-session":
            let session = value("-t")
            let windows = Set(state.windows.filter { $0.session == session }.map(\.id))
            state.panes.removeAll { windows.contains($0.window) }
            prune(&state)
            return .ok([])
        case "select-pane":
            if let paneID = value("-t"), let pane = state.panes.first(where: { $0.id == paneID }) {
                state.activePane[pane.window] = paneID
            }
            return .ok([])
        default:
            return .ok([])
        }
    }

    /// Windows without panes close, then sessions without windows.
    private static func prune(_ state: inout State) {
        let paneWindows = Set(state.panes.map(\.window))
        state.windows.removeAll { !paneWindows.contains($0.id) }
        let windowSessions = Set(state.windows.map(\.session))
        state.sessions.removeAll { !windowSessions.contains($0.id) }
        for window in state.windows {
            let panes = state.panes.filter { $0.window == window.id }.map(\.id)
            if !panes.contains(state.activePane[window.id] ?? "") {
                state.activePane[window.id] = panes.first
            }
        }
    }

    /// A tmux command's words, single quotes removed.
    private static func words(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quoted = false
        for character in command {
            if quoted {
                if character == "'" { quoted = false } else { current.append(character) }
                continue
            }
            switch character {
            case "'":
                quoted = true
                inWord = true
            case " ":
                if inWord { words.append(current) }
                current = ""
                inWord = false
            default:
                current.append(character)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
