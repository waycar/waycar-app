import Foundation
import Testing

@testable import Waycar

/// tmux copy mode as the scroll path of an inline agent's or a shell's tmux
/// pane: one request at a time, rows that pile up meanwhile sent together,
/// input held while the view is away from live, and live reached by
/// leaving copy mode.
@MainActor
@Suite("tmux pane history")
struct TmuxPaneHistoryTests {
    /// Answers each request with the next scripted position, or once the
    /// script runs out from ``pane``: a scroll takes it into copy mode, a
    /// read reports it, a leave takes it out. `holdsNext` keeps the next
    /// request in flight until `release()`.
    @MainActor
    final class Host {
        var scrolls: [(towardOlderContent: Bool, rows: Int)] = []
        var leaves = 0
        var answers: [PaneHistoryPosition] = []
        /// Where the pane's view is: copy mode a desk client entered starts
        /// it at `inHistory`.
        var pane = PaneHistoryPosition.live
        var holdsNext = false
        private var held: CheckedContinuation<Void, Never>?

        func scroll(_ towardOlderContent: Bool, _ rows: Int) async throws -> PaneHistoryScroll {
            scrolls.append((towardOlderContent, rows))
            if holdsNext {
                holdsNext = false
                await withCheckedContinuation { held = $0 }
            }
            if !answers.isEmpty { return PaneHistoryScroll(position: answers.removeFirst()) }
            let entered = rows > 0 && pane != .inHistory
            if rows > 0 { pane = .inHistory }
            return PaneHistoryScroll(position: pane, enteredHistory: entered)
        }

        func release() {
            held?.resume()
            held = nil
        }

        func history() -> TmuxPaneHistory {
            TmuxPaneHistory { [self] towardOlderContent, rows in
                try await scroll(towardOlderContent, rows)
            } leave: { [self] in
                leaves += 1
                pane = .live
            }
        }
    }

    @Test func rowsPilingUpInFlightGoOutTogether() async throws {
        let host = Host()
        let history = host.history()
        host.holdsNext = true
        history.scroll(towardOlderContent: true, rows: 3)
        #expect(await eventually { host.scrolls.count == 1 })
        #expect(history.holdsInput)
        history.scroll(towardOlderContent: true, rows: 2)
        history.scroll(towardOlderContent: false, rows: 1)
        host.release()
        #expect(await eventually { host.scrolls.count == 2 && !history.isMoving })
        #expect(host.scrolls.map(\.towardOlderContent) == [true, true])
        #expect(host.scrolls.map(\.rows) == [3, 1])
        #expect(history.position == .inHistory)
        #expect(history.holdsInput)
    }

    @Test func leaveReturnsToLiveOnlyFromHistory() async throws {
        let host = Host()
        let history = host.history()
        history.scroll(towardOlderContent: true, rows: 4)
        #expect(await eventually { history.position == .inHistory && !history.isMoving })

        await history.leave()
        #expect(host.leaves == 1)
        #expect(history.position == .live)
        #expect(!history.holdsInput)
        await history.leave()
        #expect(host.leaves == 1)
    }

    /// The first read tells whether the pane has history at all: an
    /// alternate-screen application has none, and the chrome hears of it.
    @Test func refreshReportsAvailability() async throws {
        let host = Host()
        host.answers = [.unavailable, .live]
        let history = host.history()
        var changes = 0
        history.onAvailabilityChange = { changes += 1 }

        history.refresh()
        #expect(await eventually { history.position == .unavailable })
        #expect(!history.isAvailable)
        #expect(changes == 0)
        history.refresh()
        #expect(await eventually { history.position == .live })
        #expect(history.isAvailable)
        #expect(changes == 1)
        #expect(host.scrolls.map(\.rows) == [0, 0])
        #expect(!history.holdsInput)
    }

    /// Typed input waits for copy mode to end, then goes out in order; the
    /// terminal's own replies are tmux's and never wait.
    @Test func inputWaitsForCopyModeToEnd() async throws {
        let host = Host()
        let history = host.history()
        history.scroll(towardOlderContent: true, rows: 4)
        #expect(await eventually { history.position == .inHistory && !history.isMoving })

        let input = TerminalInputController(paneHistory: history)
        var writes: [Data] = []
        input.beginSession { writes.append($0) }
        let focusReport = Data("\u{1B}[I".utf8)
        #expect(input.send(Data("a".utf8)))
        #expect(input.send(focusReport))
        #expect(input.send(Data("b".utf8)))
        #expect(writes == [focusReport])

        #expect(await eventually { writes.count == 3 })
        #expect(writes == [focusReport, Data("a".utf8), Data("b".utf8)])
        #expect(host.leaves == 1)
        #expect(input.send(Data("c".utf8)))
        #expect(writes.last == Data("c".utf8))
    }

    @Test func heldInputDiesWithItsSession() async throws {
        let host = Host()
        let history = host.history()
        history.scroll(towardOlderContent: true, rows: 4)
        #expect(await eventually { history.position == .inHistory && !history.isMoving })

        let input = TerminalInputController(paneHistory: history)
        var writes: [Data] = []
        let generation = input.beginSession { writes.append($0) }
        #expect(input.send(Data("a".utf8)))
        input.endSession(generation)
        input.beginSession { writes.append($0) }
        #expect(await eventually { host.leaves == 1 })
        try await Task.sleep(for: .milliseconds(20))
        #expect(writes.isEmpty)
    }

    /// The scroll-jump button's way to live leaves copy mode at once
    /// instead of stepping down row by row.
    @Test func jumpToLiveLeavesCopyMode() async throws {
        let host = Host()
        let history = host.history()
        let wiring = AgentMessageJumpWiring()
        wiring.scrollControl.paneHistory = history
        history.scroll(towardOlderContent: true, rows: 4)
        #expect(await eventually { history.position == .inHistory && !history.isMoving })

        let outcome = await wiring.jumpToScrollEnd(.newer, in: wiring.liveGeneration)
        #expect(outcome == .reachedEnd)
        #expect(host.leaves == 1)
        #expect(host.scrolls.count == 1)
        #expect(!wiring.reach.canJumpNewer)
    }

    /// Leaving the Attach undoes only the copy mode this history's own
    /// scroll entered: a desk client keeps its scroll position. Input still
    /// leaves any copy mode, which would take its keys.
    @Test func departureLeavesOnlyTheCopyModeItEntered() async throws {
        let host = Host()
        host.pane = .inHistory
        let history = host.history()
        history.refresh()
        #expect(await eventually { history.position == .inHistory })
        // Scrolling the desk's copy mode does not make it this history's.
        history.scroll(towardOlderContent: true, rows: 2)
        #expect(await eventually { host.scrolls.count == 2 && !history.isMoving })
        await history.depart()
        #expect(host.leaves == 0)
        #expect(history.position == .inHistory)
        await history.leave()
        #expect(host.leaves == 1)

        history.scroll(towardOlderContent: true, rows: 2)
        #expect(await eventually { history.position == .inHistory && !history.isMoving })
        await history.depart()
        #expect(host.leaves == 2)
        #expect(history.position == .live)
    }

    /// A desk client entered copy mode after the last read: the phone's
    /// scroll joins it rather than entering it, so leaving the Attach keeps
    /// it, though the position last read was live.
    @Test func departureKeepsCopyModeADeskClientEnteredSinceTheLastRead() async throws {
        let host = Host()
        let history = host.history()
        history.refresh()
        #expect(await eventually { history.position == .live })
        host.pane = .inHistory
        history.scroll(towardOlderContent: true, rows: 2)
        #expect(await eventually { history.position == .inHistory && !history.isMoving })
        #expect(!history.enteredHistory)
        await history.depart()
        #expect(host.leaves == 0)
        #expect(history.position == .inHistory)
    }

    /// Input that arrives while a departure keeps a desk client's copy mode
    /// still gets its own leave.
    @Test func inputLeavesTheCopyModeADepartureKept() async throws {
        let host = Host()
        host.pane = .inHistory
        let history = host.history()
        history.refresh()
        #expect(await eventually { history.position == .inHistory })
        host.holdsNext = true
        history.refresh()
        #expect(await eventually { host.scrolls.count == 2 })

        let departure = Task { await history.depart() }
        await Task.yield()
        let input = Task { await history.leave() }
        await Task.yield()
        host.release()
        await departure.value
        await input.value
        #expect(host.leaves == 1)
        #expect(history.position == .live)
    }

    /// The Attach owns the one pane history its input holds on, and its
    /// departure (leaving, or stepping into retention) leaves only the copy
    /// mode that history entered.
    @Test func attachDepartureLeavesOnlyItsOwnCopyMode() async throws {
        let host = Host()
        host.pane = .inHistory
        let attach = AgentAttachStore(
            target: .agentPane("tmux:%3"),
            transportGeneration: nil,
            recordsNetworkTelemetry: true,
            isOnStage: { true },
            runTerminal: { _, _ in },
            stageImage: { _, _ in throw TransportError.cancelled },
            stageFile: { _, _ in throw TransportError.cancelled },
            composer: AgentComposerStore(target: "tmux:%3") { _ in throw TransportError.cancelled },
            paneHistory: host.history(),
            closePane: {})
        let history = try #require(attach.paneHistory)
        #expect(attach.input.paneHistory === history)
        history.refresh()
        #expect(await eventually { history.position == .inHistory })

        attach.leaveInteractionsForRetention()
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.leaves == 0)

        await history.leave()
        history.scroll(towardOlderContent: true, rows: 3)
        #expect(await eventually { history.position == .inHistory && !history.isMoving })
        await attach.leave().value
        #expect(await eventually { host.leaves == 2 })
    }

    /// SwiftUI rebuilds the Agent view on every parent re-render; the
    /// throwaway copies wire the Attach's pane history into scroll controls
    /// that never mount. The control on screen keeps hearing whether the
    /// pane has history to scroll.
    @Test func availabilityReachesTheMountedScrollControl() async throws {
        let host = Host()
        host.answers = [.unavailable, .live]
        let history = host.history()
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        let mounted = TerminalScrollControl()
        mounted.terminal = terminal
        mounted.paneHistory = history
        history.refresh()
        #expect(await eventually { history.position == .unavailable })
        #expect(!mounted.canScrollRemoteContent)

        let throwaway = TerminalScrollControl()
        throwaway.paneHistory = history
        history.refresh()
        #expect(await eventually { history.position == .live })
        #expect(mounted.canScrollRemoteContent)
        withExtendedLifetime(terminal) {}
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
private func eventually(
    _ timeout: Duration = .waitCeiling, _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
