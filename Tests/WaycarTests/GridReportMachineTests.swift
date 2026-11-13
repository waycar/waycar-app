import Foundation
import GhosttyTerminal
import Testing

@testable import Waycar

@Suite("Grid report machine")
struct GridReportMachineTests {
    typealias Machine = GridReportMachine

    private static func viewport(_ columns: UInt16, _ rows: UInt16) -> InMemoryTerminalViewport {
        InMemoryTerminalViewport(columns: columns, rows: rows)
    }

    private static func grid(_ columns: Int, _ rows: Int) -> TerminalGridSize {
        TerminalGridSize(columns: columns, rows: rows)
    }

    @Test func aLiveReportIsCheckedDeliveredThenReported() {
        var machine = Machine()
        let report = Self.viewport(80, 24)
        #expect(machine.handle(.reportArrived(sequence: 1, viewport: report)) == [.checkCurrent(report)])
        #expect(machine.state.lastProcessed == 1)
        #expect(machine.handle(.currentnessChecked(report, isCurrent: true)) == [.deliverViewport(report)])
        #expect(machine.handle(.viewportDelivered(report))
            == [.reportSize(Self.grid(80, 24), then: .completeThenNextReport)])
        #expect(machine.handle(.sizeReported(then: .completeThenNextReport)) == [])
    }

    @Test func reportsAreConsumedInSequence() {
        var machine = Machine()
        let first = Self.viewport(80, 24)
        let second = Self.viewport(81, 24)
        #expect(machine.handle(.reportArrived(sequence: 2, viewport: second)) == [])
        #expect(machine.handle(.reportArrived(sequence: 1, viewport: first)) == [.checkCurrent(first)])
        _ = machine.handle([.currentnessChecked(first, isCurrent: true), .viewportDelivered(first)])
        // The loop continues with the waiting report once the first returns.
        #expect(machine.handle(.sizeReported(then: .completeThenNextReport)) == [.checkCurrent(second)])
        #expect(machine.state.pending.isEmpty)
    }

    @Test func aStaleReportIsSkipped() {
        var machine = Machine().after([.reportArrived(sequence: 1, viewport: Self.viewport(80, 24))])
        #expect(machine.handle(.currentnessChecked(Self.viewport(80, 24), isCurrent: false)) == [])
    }

    @Test func aFreezeDiscardsReportsThatLeftBeforeItAndHoldsLaterOnes() {
        var machine = Machine()
        #expect(machine.handle(.beginFreeze(latest: 1))
            == [.notifyPhase(.deferring, forwarded: nil, then: .nothing)])
        #expect(machine.handle(.phaseNotified(then: .nothing)) == [])
        #expect(machine.handle(.reportArrived(sequence: 1, viewport: Self.viewport(80, 24))) == [])
        let later = Self.viewport(70, 20)
        #expect(machine.handle(.reportArrived(sequence: 2, viewport: later)) == [.checkCurrent(later)])
        _ = machine.handle(.currentnessChecked(later, isCurrent: true))
        #expect(machine.handle(.viewportDelivered(later)) == [])
        #expect(machine.state.phase == .deferring(deferred: Self.grid(70, 20)))
    }

    @Test func aThawWaitsForEveryReportThatHadLeft() {
        var machine = Machine().after([.beginFreeze(latest: 0), .phaseNotified(then: .nothing)])
        #expect(machine.handle(.finishFreeze(latest: 1))
            == [.notifyPhase(.flushing, forwarded: nil, then: .complete)])
        #expect(machine.handle(.phaseNotified(then: .complete)) == [])
        #expect(machine.gridReportPhase == .flushing)
        let report = Self.viewport(60, 12)
        _ = machine.handle([.reportArrived(sequence: 1, viewport: report), .currentnessChecked(report, isCurrent: true)])
        #expect(machine.handle(.viewportDelivered(report))
            == [.forward(Self.grid(60, 12), then: .nextReport)])
        #expect(machine.gridReportPhase == .live)
        #expect(machine.handle(.forwarded(Self.grid(60, 12), delivered: true, then: .nextReport))
            == [.notifyPhase(.live, forwarded: Self.grid(60, 12), then: .nextReport)])
        #expect(machine.state.suppressesDuplicate == Self.grid(60, 12))
    }

    @Test func aThawWithoutAGridOrWithoutACallbackForwardsNothing() {
        var empty = Machine().after([.beginFreeze(latest: 0), .phaseNotified(then: .nothing)])
        #expect(empty.handle(.finishFreeze(latest: 0)).count == 1)
        #expect(empty.handle(.phaseNotified(then: .complete))
            == [.notifyPhase(.live, forwarded: nil, then: .nothing)])
        var unheard = Machine().after([
            .beginFreeze(latest: 0), .provideAuthoritative(Self.grid(60, 12)), .finishFreeze(latest: 0),
        ])
        #expect(unheard.handle(.phaseNotified(then: .complete)) == [.forward(Self.grid(60, 12), then: .nothing)])
        #expect(unheard.handle(.forwarded(Self.grid(60, 12), delivered: false, then: .nothing))
            == [.notifyPhase(.live, forwarded: nil, then: .nothing)])
        #expect(unheard.state.suppressesDuplicate == nil)
    }

    @Test func theThawsDuplicateIsConsumedOnce() {
        var machine = Machine().after([
            .beginFreeze(latest: 0), .provideAuthoritative(Self.grid(60, 12)), .finishFreeze(latest: 0),
            .phaseNotified(then: .complete), .forwarded(Self.grid(60, 12), delivered: true, then: .nothing),
        ])
        let duplicate = Self.viewport(60, 12)
        _ = machine.handle([.reportArrived(sequence: 1, viewport: duplicate), .currentnessChecked(duplicate, isCurrent: true)])
        #expect(machine.handle(.viewportDelivered(duplicate)) == [])
        _ = machine.handle([.reportArrived(sequence: 2, viewport: duplicate), .currentnessChecked(duplicate, isCurrent: true)])
        #expect(machine.handle(.viewportDelivered(duplicate))
            == [.reportSize(Self.grid(60, 12), then: .completeThenNextReport)])
    }

    @Test func aSettledReportIsHeldWhileFrozenAndSuppressesAfterItsCallbackWhileLive() {
        var frozen = Machine().after([.beginFreeze(latest: 0)])
        #expect(frozen.handle(.reportSettled(Self.grid(50, 10))) == [])
        #expect(frozen.state.phase == .deferring(deferred: Self.grid(50, 10)))
        var live = Machine()
        #expect(live.handle(.reportSettled(Self.grid(50, 10)))
            == [.reportSize(Self.grid(50, 10), then: .suppress(Self.grid(50, 10)))])
        #expect(live.state.suppressesDuplicate == nil)
        #expect(live.handle(.sizeReported(then: .suppress(Self.grid(50, 10)))) == [])
        #expect(live.state.suppressesDuplicate == Self.grid(50, 10))
    }

    @Test func cancellingDiscardsWhatLeftAndReturnsLive() {
        var machine = Machine().after([
            .beginFreeze(latest: 0), .phaseNotified(then: .nothing), .provideAuthoritative(Self.grid(60, 12)),
        ])
        #expect(machine.handle(.cancelFreeze(latest: 3))
            == [.notifyPhase(.live, forwarded: nil, then: .nothing)])
        #expect(machine.state.discardsThrough == 3)
        #expect(machine.state.phase == .live)
        // Neither a thaw nor an authoritative grid applies outside a freeze.
        #expect(machine.handle(.finishFreeze(latest: 3)) == [])
        #expect(machine.handle(.provideAuthoritative(Self.grid(1, 1))) == [])
    }

    @Test func anUnchangedPhaseIsNotNotifiedAgain() {
        var machine = Machine().after([.beginFreeze(latest: 0), .phaseNotified(then: .nothing)])
        #expect(machine.handle(.beginFreeze(latest: 0)) == [])
        #expect(machine.state.discardsThrough == 0)
        var thawing = Machine().after([
            .beginFreeze(latest: 0), .phaseNotified(then: .nothing), .finishFreeze(latest: 2),
            .phaseNotified(then: .complete),
        ])
        // A second thaw request moves the fence without another notice.
        #expect(thawing.handle(.finishFreeze(latest: 3)) == [])
        #expect(thawing.state.phase == .flushing(through: 3, deferred: nil))
    }
}
