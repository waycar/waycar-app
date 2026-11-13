import CoreGraphics
import Foundation
import Testing

@testable import Waycar

/// The button a long touch scroll offers, and the walk it starts. `refs #58`.
struct ScrollJumpRunTests {
    private let start = ContinuousClock.now

    @Test func offersAnEndOnlyOnceOneRunHasScrolledFarEnough() {
        var run = ScrollJumpRun()
        run.note(.older, rows: ScrollJumpRun.rowsBeforeOffer - 1, at: start)
        #expect(run.offeredDirection == nil)

        run.note(.older, rows: 1, at: start + .milliseconds(100))
        #expect(run.offeredDirection == .older)
    }

    @Test func turningAroundStartsANewRun() {
        var run = ScrollJumpRun()
        run.note(.older, rows: ScrollJumpRun.rowsBeforeOffer, at: start)
        #expect(run.offeredDirection == .older)

        run.note(.newer, rows: 1, at: start + .milliseconds(100))
        #expect(run.offeredDirection == nil)

        run.note(.newer, rows: ScrollJumpRun.rowsBeforeOffer, at: start + .milliseconds(200))
        #expect(run.offeredDirection == .newer)
    }

    @Test func aRunLapsesOneLingerAfterItsLastScroll() {
        var run = ScrollJumpRun()
        run.note(.older, rows: ScrollJumpRun.rowsBeforeOffer, at: start)
        // Scrolling on inside the window extends it.
        let lastScroll = start + .seconds(2)
        run.note(.older, rows: 1, at: lastScroll)
        #expect(!run.isExpired(at: start + ScrollJumpRun.linger))
        #expect(run.isExpired(at: lastScroll + ScrollJumpRun.linger))

        // A nudge after the run lapsed starts over instead of reviving it.
        run.note(.older, rows: 1, at: lastScroll + ScrollJumpRun.linger)
        #expect(run.offeredDirection == nil)
    }
}

struct ScrollJumpAvailabilityTests {
    private func evaluate(
        canScrollRemoteContent: Bool = true,
        reach: MessageJumpReach = MessageJumpReach(),
        offered: TerminalMessageJumpController.Direction?,
        running: AttachRunningJump? = nil
    ) -> ScrollJumpAvailability {
        ScrollJumpAvailability.evaluate(
            canScrollRemoteContent: canScrollRemoteContent,
            reach: reach,
            offeredDirection: offered,
            runningJump: running)
    }

    @Test func hiddenWhereAScrollCannotReachTheApplicationsHistory() {
        // A plain shell under `herdr terminal attach`: no mouse reporting, so
        // a scroll step would only type cursor keys.
        #expect(evaluate(canScrollRemoteContent: false, offered: .older) == .hidden)
    }

    @Test func offersOnlyAnEndTheViewportIsNotKnownToSitAt() {
        // A fresh session sits at live: scrolling forward has nowhere to go.
        #expect(evaluate(offered: .newer) == .hidden)
        #expect(evaluate(offered: .older) == ScrollJumpAvailability(direction: .older))

        var displaced = MessageJumpReach()
        displaced.noteTouchScroll(towardOlderContent: true)
        #expect(
            evaluate(reach: displaced, offered: .newer)
                == ScrollJumpAvailability(direction: .newer))

        var atOldest = MessageJumpReach()
        atOldest.noteOlderJump(.reachedEnd, movedViewport: true)
        #expect(evaluate(reach: atOldest, offered: .older) == .hidden)
    }

    /// A press hides the button for the whole trip, whichever control
    /// started the walk; the terminal moving is the progress.
    @Test(arguments: [AttachJumpKind.scroll, .message])
    func aRunningJumpHidesTheButton(_ kind: AttachJumpKind) {
        #expect(
            evaluate(offered: .older, running: AttachRunningJump(kind: kind, direction: .older))
                == .hidden)
    }
}

@MainActor
struct ScrollJumpPlacementTests {
    @Test(arguments: [false, true])
    func theTabSitsATenthOfTheWayUp(messageJumpTabVisible: Bool) {
        #expect(
            ScrollJumpPlacement.bottomPadding(
                terminalHeight: 700, messageJumpTabVisible: messageJumpTabVisible) == 70)
    }

    @Test func aShortTerminalShowsTheTabWhileItFits() {
        #expect(ScrollJumpPlacement.bottomPadding(terminalHeight: 50) == 5)
        // Too short for a tenth: slides down until it fits.
        #expect(ScrollJumpPlacement.bottomPadding(terminalHeight: 48) == 4)
        #expect(ScrollJumpPlacement.bottomPadding(terminalHeight: 43) == nil)
    }

    @Test func theTabSlidesUnderTheMessageJumpTab() {
        #expect(ScrollJumpPlacement.bottomPadding(terminalHeight: 300) == 30)
        #expect(ScrollJumpPlacement.bottomPadding(terminalHeight: 300, messageJumpTabVisible: true) == 23)
    }

    @Test func theTabNeverMeetsTheMessageJumpTab() {
        var shown = 0
        for height in stride(from: CGFloat(100), through: 1400, by: 10) {
            // The message tab docked as low as it goes, with both buttons and
            // the divider a long scroll leaves offered.
            guard let messageTab = MessageJumpPlacement.frame(
                terminalSize: CGSize(width: 390, height: height),
                chromeSize: CGSize(width: MessageJumpControlView.buttonSize, height: 89),
                edgeFraction: 1)
            else { continue }
            guard let padding = ScrollJumpPlacement.bottomPadding(
                terminalHeight: height,
                messageJumpTabVisible: true)
            else { continue }
            shown += 1
            #expect(
                height - messageTab.maxY
                    >= padding + MessageJumpControlView.buttonSize + ScrollJumpPlacement.gap)
        }
        #expect(shown > 0)
    }

    @Test func theTabHidesWhereItFitsNowhere() {
        #expect(ScrollJumpPlacement.bottomPadding(terminalHeight: 0) == nil)
        #expect(ScrollJumpPlacement.bottomPadding(terminalHeight: 30) == nil)
        #expect(ScrollJumpPlacement.bottomPadding(terminalHeight: 200, messageJumpTabVisible: true) == nil)
    }
}

@MainActor
struct ScrollJumpWiringTests {
    @Test func aLongTouchScrollOffersTheJumpUntilTheRunLapses() async throws {
        let clock = ScrollJumpTestClock()
        let wiring = AgentMessageJumpWiring(
            now: { clock.now }, sleep: { try await clock.sleep(for: $0) })
        let terminal = agentTerminal(for: wiring)

        drag(terminal, towardOlderContent: true, rows: ScrollJumpRun.rowsBeforeOffer - 1)
        #expect(wiring.offeredScrollJump == nil, "a nudge is not a trip through the history")
        drag(terminal, towardOlderContent: true, rows: 1)
        #expect(wiring.offeredScrollJump == .older)
        try await waitUntil("the linger timer should be armed") { clock.pendingSleepCount == 1 }

        // Scrolling on extends the run past the first deadline.
        clock.advance(by: .seconds(2))
        drag(terminal, towardOlderContent: true, rows: 1)
        clock.advance(by: .seconds(1))
        try await waitUntil("the timer should wait out the extension") {
            clock.pendingSleepCount == 1
        }
        #expect(wiring.offeredScrollJump == .older)

        clock.advance(by: .seconds(2))
        try await waitUntil("the offer should lapse") { wiring.offeredScrollJump == nil }
    }

    /// One momentum frame can carry many rows; they all count.
    @Test func oneFlickPastTheThresholdOffersTheJump() throws {
        let wiring = AgentMessageJumpWiring()
        let terminal = agentTerminal(for: wiring)

        let rows = terminal.scrollTouch(
            translationY: 40 * CGFloat(ScrollJumpRun.rowsBeforeOffer))

        try #require(rows >= ScrollJumpRun.rowsBeforeOffer)
        #expect(wiring.offeredScrollJump == .older)
    }

    @Test(arguments: [TerminalMessageJumpController.Direction.older, .newer])
    func aScrollJumpThatReachesItsEndWithdrawsTheButton(
        _ direction: TerminalMessageJumpController.Direction
    ) async {
        let wiring = AgentMessageJumpWiring()
        var wheel: [Data] = []
        // Every step repaints the same frame: that end of the history is here.
        let terminal = agentTerminal(for: wiring) { sequence, _ in
            wheel.append(sequence)
            wiring.deliverViewportText("settled")
        }
        // Leave live first, so the newer end has somewhere to be.
        drag(terminal, towardOlderContent: true, rows: 1)
        drag(terminal, towardOlderContent: direction == .older, rows: ScrollJumpRun.rowsBeforeOffer)
        #expect(wiring.scrollJumpAvailability == ScrollJumpAvailability(direction: direction))
        wheel.removeAll()

        let outcome = await wiring.jumpToScrollEnd(direction, in: wiring.liveGeneration)

        // SGR wheel reports: button 64 scrolls back, 65 forward.
        let button = direction == .older ? "64" : "65"
        #expect(!wheel.isEmpty)
        #expect(wheel.allSatisfy { $0.starts(with: Data("\u{1B}[<\(button);".utf8)) })
        #expect(outcome == .reachedEnd)
        #expect(wiring.scrollJumpAvailability == .hidden)
    }

    /// A walk that runs out of steps short of the end withdraws the button
    /// too: it only ever answers the user's own scrolling.
    @Test func aScrollJumpThatRunsOutOfStepsWithdrawsTheButton() async {
        // The clock never moves, so the drag's offer cannot lapse on its own
        // while the walk runs: only the finished walk can withdraw it.
        let clock = ScrollJumpTestClock()
        let wiring = AgentMessageJumpWiring(
            now: { clock.now }, sleep: { try await clock.sleep(for: $0) })
        var repaints = 0
        // Every step repaints something new: the history outlasts the budget.
        let terminal = agentTerminal(for: wiring) { _, _ in
            repaints += 1
            wiring.deliverViewportText("history row \(repaints)")
        }
        drag(terminal, towardOlderContent: true, rows: ScrollJumpRun.rowsBeforeOffer)
        #expect(wiring.scrollJumpAvailability == ScrollJumpAvailability(direction: .older))

        let outcome = await wiring.jumpToScrollEnd(.older, in: wiring.liveGeneration)

        #expect(outcome == .exhausted)
        #expect(wiring.scrollJumpAvailability == .hidden)
        // More history lies above: nothing marked the top as reached.
        #expect(wiring.reach.canJumpOlder)
    }

    /// A drag stops a walk (`touchScrollCancelsAnInFlightJump`); the button
    /// it then offers is the drag's own.
    @Test func aDragThatStopsAScrollJumpOffersItsOwnEnd() async throws {
        let wiring = AgentMessageJumpWiring()
        var stepped = false
        // No frame ever comes back, so the walk waits on its first step.
        let terminal = agentTerminal(for: wiring) { _, _ in stepped = true }
        drag(terminal, towardOlderContent: true, rows: ScrollJumpRun.rowsBeforeOffer)
        stepped = false
        var outcome: TerminalMessageJumpController.Outcome?
        wiring.runJump(.older, kind: .scroll) { session in
            outcome = await wiring.jumpToScrollEnd(.older, in: session)
        }
        try await waitUntil("the walk should take its first step") { stepped }
        #expect(wiring.scrollJumpAvailability == .hidden, "the press hides the button for the trip")

        drag(terminal, towardOlderContent: false, rows: ScrollJumpRun.rowsBeforeOffer)

        try await waitUntil("the drag should stop the walk") { outcome != nil }
        #expect(outcome == .cancelled)
        #expect(wiring.scrollJumpAvailability == ScrollJumpAvailability(direction: .newer))
    }

    /// A press lands while a flick is still coasting; the flick's next row
    /// would otherwise cancel the walk the press started.
    @Test func pressingAJumpMidFlickStopsTheFlick() {
        let wiring = AgentMessageJumpWiring()
        let terminal = agentTerminal(for: wiring)
        terminal.startTouchScrollMomentum(velocityY: 2_000)
        #expect(terminal.isTouchScrollMomentumRunning)

        wiring.runJump(.older, kind: .scroll) { _ in }

        #expect(!terminal.isTouchScrollMomentumRunning)
    }

    /// The agent exits mid-walk and takes its mouse reporting with it: every
    /// further step would be a cursor key typed into whatever runs next.
    @Test func losingMouseReportingStopsTheWalkAndWithdrawsTheOffer() async throws {
        let wiring = AgentMessageJumpWiring()
        var sent: [Data] = []
        // No frame ever comes back, so the walk waits on its first step.
        let terminal = agentTerminal(for: wiring) { sequence, _ in sent.append(sequence) }
        drag(terminal, towardOlderContent: true, rows: ScrollJumpRun.rowsBeforeOffer)
        sent.removeAll()
        var outcome: TerminalMessageJumpController.Outcome?
        wiring.runJump(.older, kind: .scroll) { session in
            outcome = await wiring.jumpToScrollEnd(.older, in: session)
        }
        try await waitUntil("the walk should take its first step") { !sent.isEmpty }

        terminal.receive(Data("\u{1B}[?1000l".utf8))

        try await waitUntil("the walk should stop") { outcome != nil }
        #expect(outcome == .cancelled)
        #expect(!sent.contains(Data([0x1B, 0x5B, 0x41])), "no cursor key reached the pane")
        #expect(wiring.offeredScrollJump == nil)
        // A stopped walk proves nothing about the top.
        #expect(wiring.reach.canJumpOlder)
    }

    /// Over mosh the Agent's `?1049h` never reaches the phone, but its mouse
    /// modes do: mosh-server 1.4.0 forwards `?1002h` and `?1006h`. The
    /// terminal stays on the primary screen while a drag still scrolls the
    /// Agent, and the button must follow the drag.
    @Test func overMoshThePrimaryScreenStillOffersTheJump() {
        let wiring = AgentMessageJumpWiring()
        let terminal = TerminalScreenView.makeConfiguredTerminal(onScroll: { _, _ in })
        wiring.scrollControl.terminal = terminal
        // mosh-server 1.4.0's frame for a command that printed
        // `?1049h ?1000h ?1002h ?1006h`. mosh keeps one mouse-reporting mode,
        // the last one set, so `?1000h` is absent on purpose.
        terminal.receive(Data("\u{1B}[?25l\u{1B}[?25h\u{1B}[?1002h\u{1B}[?1006h".utf8))
        #expect(!wiring.scrollControl.isAlternateScreen)

        drag(terminal, towardOlderContent: true, rows: ScrollJumpRun.rowsBeforeOffer)

        #expect(wiring.scrollJumpAvailability == ScrollJumpAvailability(direction: .older))
    }

    @Test func aNewAttachSessionWithdrawsTheOffer() {
        let wiring = AgentMessageJumpWiring()
        let terminal = agentTerminal(for: wiring)
        drag(terminal, towardOlderContent: false, rows: ScrollJumpRun.rowsBeforeOffer)
        #expect(wiring.offeredScrollJump == .newer)

        wiring.resetSession()

        #expect(wiring.offeredScrollJump == nil)
    }

    /// What `herdr agent attach` leaves for an agent TUI: the alternate
    /// screen with SGR mouse reporting, so drags and walk steps are wheel
    /// reports through `onScroll`.
    private func agentTerminal(
        for wiring: AgentMessageJumpWiring,
        onScroll: @escaping (Data, Int) -> Void = { _, _ in }
    ) -> WaycarTerminalView {
        let terminal = TerminalScreenView.makeConfiguredTerminal(onScroll: onScroll)
        wiring.scrollControl.terminal = terminal
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        return terminal
    }

    /// Touch-scrolls `terminal` until it has moved `rows` rows one way.
    private func drag(_ terminal: WaycarTerminalView, towardOlderContent: Bool, rows: Int) {
        var scrolled = 0
        for _ in 0..<10_000 where scrolled < rows {
            scrolled += abs(terminal.scrollTouch(translationY: towardOlderContent ? 4 : -4))
        }
    }

    /// Polls until `condition` holds, yielding so the wiring's tasks
    /// progress; stops the test at the first wait that never comes true.
    private func waitUntil(
        _ comment: Comment, timeout: Duration = .waitCeiling,
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), comment)
    }
}

/// A clock the test moves by hand. A sleeper wakes once the clock passes its
/// deadline, and throws when cancelled, as `Task.sleep` does.
@MainActor
private final class ScrollJumpTestClock {
    private struct Sleeper {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let wake: CheckedContinuation<Void, any Error>
    }

    private(set) var now = ContinuousClock.now
    private var sleepers: [Sleeper] = []

    var pendingSleepCount: Int { sleepers.count }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let deadline = now + duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers.append(Sleeper(id: id, deadline: deadline, wake: continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancelSleeper(id) }
        }
    }

    func advance(by duration: Duration) {
        now = now + duration
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in due {
            sleeper.wake.resume()
        }
    }

    private func cancelSleeper(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).wake.resume(throwing: CancellationError())
    }
}
