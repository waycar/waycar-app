import Foundation
import Testing

@testable import Waycar

@Suite("Pending tab close machine")
struct PendingTabCloseMachineTests {
    private typealias Machine = PendingTabCloseMachine
    private let host = Host.fixture()
    private let otherHost = Host.fixture(name: "other", address: "other.example")
    private let deadline = Date(timeIntervalSince1970: 1_000)

    private func row(_ paneID: String, on host: Host? = nil) -> ConsoleAgent {
        let host = host ?? self.host
        return ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID)),
            workspaceLabel: "w1", repositoryCheckout: nil, summary: nil, backend: .herdr)
    }

    @Test func aSwipeCountsDownOnceAndAgainDoesNothing() {
        let first = row("w1:p1")
        var machine = Machine()
        #expect(machine.handle(.schedule(first, deadline: deadline))
            == [.startCountdown(first, token: 1)])
        #expect(machine.state.closes[first.id]
            == ConsoleStore.PendingTabClose(agent: first, deadline: deadline, phase: .counting))
        #expect(machine.handle(.schedule(first, deadline: deadline.addingTimeInterval(1))).isEmpty)
        #expect(machine.state.closes[first.id]?.deadline == deadline)
    }

    @Test func aCountdownRunningOutClosesItsLiveTab() {
        let first = row("w1:p1")
        var machine = Machine().after([.schedule(first, deadline: deadline)])
        #expect(machine.handle(.countdownEnded(token: 1, liveTabs: [first.id: "w1:t9"]))
            == [.dropCountdown(first.id), .close(tabID: "w1:t9")])
        #expect(machine.state.closes[first.id]?.phase == .closing)
        #expect(machine.state.countdowns.isEmpty && machine.state.held.isEmpty)
    }

    @Test func aRowNoLongerListedClosesTheTabCapturedAtTheSwipe() {
        let first = row("w1:p1")
        var machine = Machine().after([.schedule(first, deadline: deadline)])
        #expect(machine.handle(.countdownEnded(token: 1, liveTabs: [:]))
            == [.dropCountdown(first.id), .close(tabID: "w1:t1")])
    }

    @Test func aCountdownRunningOutBesideAClosingSiblingRidesAlong() {
        let first = row("w1:p1")
        let second = row("w1:p2")
        var machine = Machine().after([
            .schedule(first, deadline: deadline), .schedule(second, deadline: deadline),
            .countdownEnded(token: 1, liveTabs: [:]),
        ])
        #expect(machine.handle(.countdownEnded(token: 2, liveTabs: [:])) == [.dropCountdown(second.id)])
        #expect(machine.state.closes[second.id]?.phase == .closing)
    }

    @Test func ridingAlongNeedsTheSameHostAndTheSameLiveTab() {
        let first = row("w1:p1")
        let moved = row("w1:p2")
        let elsewhere = row("w1:p3", on: otherHost)
        var machine = Machine().after([
            .schedule(first, deadline: deadline), .schedule(moved, deadline: deadline),
            .schedule(elsewhere, deadline: deadline),
            .countdownEnded(token: 1, liveTabs: [:]),
        ])
        #expect(machine.handle(.countdownEnded(token: 2, liveTabs: [moved.id: "w1:t2"]))
            == [.dropCountdown(moved.id), .close(tabID: "w1:t2")])
        #expect(machine.handle(.countdownEnded(token: 3, liveTabs: [:]))
            == [.dropCountdown(elsewhere.id), .close(tabID: "w1:t1")])
    }

    @Test func aSucceedingCloseStopsTheSiblingsCountingOnItsTab() {
        let first = row("w1:p1")
        let second = row("w1:p2")
        let moved = row("w1:p3")
        var machine = Machine().after([
            .schedule(first, deadline: deadline), .countdownEnded(token: 1, liveTabs: [:]),
            .schedule(second, deadline: deadline), .schedule(moved, deadline: deadline),
        ])
        #expect(machine.handle(.closed(first, tabID: "w1:t1", liveTabs: [moved.id: "w1:t2"]))
            == [.cancelCountdown(second.id)])
        #expect(machine.state.closes[second.id]?.phase == .closing)
        #expect(machine.state.closes[moved.id]?.phase == .counting)
        #expect(machine.state.countdowns.keys.sorted() == [3])
        // Nothing is left to undo.
        #expect(machine.handle(.undo(second.id)).isEmpty)
        #expect(machine.state.closes[second.id]?.phase == .closing)
    }

    @Test func aFailedCloseReleasesItsRowAndItsRidersOnly() {
        let first = row("w1:p1")
        let rider = row("w1:p2")
        let counting = row("w1:p3")
        let movedRider = row("w1:p4")
        var machine = Machine().after([
            .schedule(first, deadline: deadline), .schedule(rider, deadline: deadline),
            .schedule(counting, deadline: deadline), .schedule(movedRider, deadline: deadline),
            .countdownEnded(token: 1, liveTabs: [:]),
            .countdownEnded(token: 2, liveTabs: [:]),
            .countdownEnded(token: 4, liveTabs: [:]),
        ])
        #expect(machine.handle(.closeFailed(first, tabID: "w1:t1", liveTabs: [movedRider.id: "w1:t2"]))
            .isEmpty)
        #expect(machine.state.closes[first.id] == nil)
        #expect(machine.state.closes[rider.id] == nil)
        #expect(machine.state.closes[counting.id]?.phase == .counting)
        // A rider herdr moved off the tab is left closing, as before.
        #expect(machine.state.closes[movedRider.id]?.phase == .closing)
    }

    /// A failure releases by row: an older Close in flight clears the row's
    /// newer Close, whose countdown still runs out with its own Agent.
    @Test func aCountdownOutlivesItsRowsCloseBeingReleased() {
        let second = row("w1:p2")
        var machine = Machine().after([
            .schedule(second, deadline: deadline), .countdownEnded(token: 1, liveTabs: [:]),
            .closeFailed(second, tabID: "w1:t1", liveTabs: [:]),
            .schedule(second, deadline: deadline),
        ])
        #expect(machine.handle(.closeFailed(second, tabID: "w1:t1", liveTabs: [:])).isEmpty)
        #expect(machine.state.closes.isEmpty)
        #expect(machine.state.countdowns == [2: second])
        #expect(machine.handle(.countdownEnded(token: 2, liveTabs: [second.id: "w1:t3"]))
            == [.dropCountdown(second.id), .close(tabID: "w1:t3")])
        #expect(machine.state.closes.isEmpty)
    }

    /// Swiped again while an older countdown still runs, the row's Task is
    /// replaced: both run out, and the older one's end drops the newer's
    /// Task, so the newer can no longer be undone.
    @Test func aRowSwipedAgainKeepsItsOlderCountdownRunning() {
        let second = row("w1:p2")
        var machine = Machine().after([
            .schedule(second, deadline: deadline), .countdownEnded(token: 1, liveTabs: [:]),
            .closeFailed(second, tabID: "w1:t1", liveTabs: [:]),
            .schedule(second, deadline: deadline),
            .closeFailed(second, tabID: "w1:t1", liveTabs: [:]),
        ])
        #expect(machine.handle(.schedule(second, deadline: deadline))
            == [.startCountdown(second, token: 3)])
        #expect(machine.state.held == [second.id: 3])
        #expect(machine.handle(.countdownEnded(token: 2, liveTabs: [:]))
            == [.dropCountdown(second.id), .close(tabID: "w1:t1")])
        #expect(machine.state.closes[second.id]?.phase == .closing)
        #expect(machine.handle(.undo(second.id)).isEmpty)
        #expect(machine.handle(.countdownEnded(token: 3, liveTabs: [:]))
            == [.dropCountdown(second.id), .close(tabID: "w1:t1")])
    }

    @Test func undoEndsOnlyTheHeldCountdown() {
        let first = row("w1:p1")
        var machine = Machine().after([.schedule(first, deadline: deadline)])
        #expect(machine.handle(.undo(first.id)) == [.cancelCountdown(first.id)])
        #expect(machine.state == Machine.State())
        #expect(machine.handle(.undo(first.id)).isEmpty)
        // A countdown undone and swiped again gets a new token.
        #expect(machine.handle(.schedule(first, deadline: deadline))
            == [.startCountdown(first, token: 2)])
        #expect(machine.handle(.countdownEnded(token: 1, liveTabs: [:])).isEmpty)
    }

    @Test func rowsLeavingTheListDropTheirClosesAndStopTheirCountdowns() {
        let counting = row("w1:p1")
        let closing = row("w1:p2")
        let kept = row("w1:p3")
        var machine = Machine().after([
            .schedule(counting, deadline: deadline), .schedule(closing, deadline: deadline),
            .schedule(kept, deadline: deadline),
            .countdownEnded(token: 2, liveTabs: [:]),
        ])
        #expect(machine.handle(.rowsGone([counting.id, closing.id])) == [.cancelCountdown(counting.id)])
        #expect(Set(machine.state.closes.keys) == [kept.id])
        #expect(machine.state.held == [kept.id: 3])
        #expect(machine.state.countdowns.keys.sorted() == [3])
    }
}
