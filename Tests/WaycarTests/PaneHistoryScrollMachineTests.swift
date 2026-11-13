import Testing

@testable import Waycar

@Suite("Pane history scroll machine")
struct PaneHistoryScrollMachineTests {
    private typealias Machine = PaneHistoryScrollMachine

    @Test func aScrollStartsOnePumpAndRowsPileUpBehindItsRequest() {
        var machine = Machine()
        #expect(machine.handle(.scroll(towardOlderContent: true, rows: 3)) == [.startPump(1)])
        #expect(machine.handle(.scroll(towardOlderContent: true, rows: 2)).isEmpty)
        #expect(machine.holdsInput)
        #expect(machine.handle(.pumpNext(1)) == [.request(1, towardOlderContent: true, rows: 5)])
        #expect(machine.isMoving)
        #expect(machine.handle(.scroll(towardOlderContent: false, rows: 1)).isEmpty)
        #expect(machine.handle(.refresh).isEmpty)
        #expect(machine.handle(.answered(1, PaneHistoryScroll(position: .inHistory, enteredHistory: true)))
            == [.publishPosition(.inHistory), .availabilityChanged])
        #expect(machine.enteredHistory)
        #expect(!machine.isMoving)
        #expect(machine.handle(.pumpNext(1)) == [.request(1, towardOlderContent: false, rows: 1)])
        #expect(machine.handle(.answered(1, PaneHistoryScroll(position: .inHistory))).isEmpty)
        #expect(machine.enteredHistory, "a scroll that joined copy mode keeps the earlier entry")
        #expect(machine.handle(.pumpNext(1)) == [.pumpEnded(1)])
        #expect(machine.state.pump == .idle)
        #expect(machine.handle(.refresh) == [.startPump(2)])
    }

    @Test func aBareReadIsNotMovingAndLeavingCopyModeForgetsTheEntry() {
        var machine = Machine().after([
            .scroll(towardOlderContent: true, rows: 1), .pumpNext(1),
            .answered(1, PaneHistoryScroll(position: .inHistory, enteredHistory: true)),
            .pumpNext(1), .refresh,
        ])
        #expect(machine.handle(.pumpNext(2)) == [.request(2, towardOlderContent: false, rows: 0)])
        #expect(!machine.isMoving)
        #expect(machine.handle(.answered(2, PaneHistoryScroll(position: .live))) == [.publishPosition(.live)])
        #expect(!machine.enteredHistory)
        #expect(machine.handle(.answered(2, PaneHistoryScroll(position: .unavailable))).isEmpty,
            "an answer with no request in flight is stale")
    }

    @Test func aFailedRequestDropsWhatIsPendingAndEndsThePump() {
        var machine = Machine().after([.scroll(towardOlderContent: true, rows: 2), .pumpNext(1)])
        _ = machine.handle(.scroll(towardOlderContent: true, rows: 6))
        _ = machine.handle(.refresh)
        #expect(machine.handle(.answered(1, nil)) == [.pumpEnded(1)])
        #expect(machine.state.pendingRows == 0)
        #expect(!machine.state.wantsRefresh)
        #expect(machine.state.pump == .idle)
        #expect(!machine.holdsInput)
        #expect(machine.handle(.pumpNext(1)).isEmpty)
    }

    @Test func aLeaveRefusesScrollsDropsPendingRowsAndLeavesOnlyFromCopyMode() {
        var machine = Machine().after([
            .scroll(towardOlderContent: true, rows: 3), .pumpNext(1),
            .scroll(towardOlderContent: true, rows: 5),
        ])
        #expect(machine.handle(.leaveRequested(onlyIfEntered: false)) == [.startLeave(2, onlyIfEntered: false)])
        #expect(machine.handle(.scroll(towardOlderContent: true, rows: 7)).isEmpty)
        #expect(machine.handle(.refresh).isEmpty)
        #expect(machine.state.pendingRows == 5, "pending rows go only once the leave runs")
        #expect(machine.handle(.leaveStarted(2)).isEmpty)
        #expect(machine.state.pendingRows == 0)
        #expect(machine.holdsInput)
        _ = machine.handle(.answered(1, PaneHistoryScroll(position: .inHistory, enteredHistory: true)))
        #expect(machine.handle(.pumpNext(1)) == [.pumpEnded(1)])
        #expect(machine.handle(.pumpDrained(2)) == [.leaveCopyMode(2)])
        #expect(machine.handle(.copyModeLeft(2)) == [.publishPosition(.live)])
        #expect(machine.holdsInput)
        #expect(machine.handle(.leaveEnded(2)).isEmpty)
        #expect(!machine.holdsInput)
        #expect(machine.handle(.leaveEnded(2)).isEmpty)
    }

    @Test func aLeaveAtLiveLeavesNothing() {
        var machine = Machine().after([
            .refresh, .pumpNext(1), .answered(1, PaneHistoryScroll(position: .live)), .pumpNext(1),
            .leaveRequested(onlyIfEntered: false), .leaveStarted(2),
        ])
        #expect(machine.handle(.pumpDrained(2)).isEmpty)
        #expect(machine.handle(.leaveEnded(2)).isEmpty)
        #expect(machine.state.leave == .none)
    }

    @Test func aDepartureKeepsCopyModeItDidNotEnter() {
        var machine = Machine().after([
            .refresh, .pumpNext(1), .answered(1, PaneHistoryScroll(position: .inHistory)), .pumpNext(1),
            .leaveRequested(onlyIfEntered: true), .leaveStarted(2),
        ])
        #expect(machine.handle(.pumpDrained(2)).isEmpty)
        _ = machine.handle(.leaveEnded(2))
        #expect(machine.position == .inHistory)
        var entered = Machine().after([
            .scroll(towardOlderContent: true, rows: 1), .pumpNext(1),
            .answered(1, PaneHistoryScroll(position: .inHistory, enteredHistory: true)), .pumpNext(1),
            .leaveRequested(onlyIfEntered: true), .leaveStarted(2),
        ])
        #expect(entered.handle(.pumpDrained(2)) == [.leaveCopyMode(2)])
    }

    @Test func aLeaveDuringALeaveJoinsItAndOnlyInputGoesAgain() {
        var machine = Machine().after([
            .refresh, .pumpNext(1), .answered(1, PaneHistoryScroll(position: .inHistory)), .pumpNext(1),
            .leaveRequested(onlyIfEntered: true),
        ])
        #expect(machine.handle(.leaveRequested(onlyIfEntered: false)) == [.joinLeave])
        #expect(machine.handle(.leaveRequested(onlyIfEntered: true)) == [.joinLeave])
        _ = machine.handle([.leaveStarted(2), .pumpDrained(2), .leaveEnded(2)])
        #expect(machine.handle(.joinedLeaveEnded(onlyIfEntered: true)).isEmpty)
        #expect(machine.handle(.joinedLeaveEnded(onlyIfEntered: false)) == [.leaveAgain])
        #expect(machine.handle(.leaveRequested(onlyIfEntered: false)) == [.startLeave(3, onlyIfEntered: false)])
        _ = machine.handle([.leaveStarted(3), .pumpDrained(3), .copyModeLeft(3), .leaveEnded(3)])
        #expect(machine.handle(.joinedLeaveEnded(onlyIfEntered: false)).isEmpty)
    }

    @Test func staleLeaveStepsAreIgnored() {
        var machine = Machine().after([
            .refresh, .pumpNext(1), .answered(1, PaneHistoryScroll(position: .inHistory)), .pumpNext(1),
            .leaveRequested(onlyIfEntered: false),
        ])
        #expect(machine.handle(.leaveStarted(9)).isEmpty)
        #expect(machine.handle(.pumpDrained(9)).isEmpty)
        #expect(machine.handle(.copyModeLeft(9)).isEmpty)
        #expect(machine.handle(.leaveEnded(9)).isEmpty)
        #expect(machine.isLeaving)
        #expect(machine.position == .inHistory)
    }
}
