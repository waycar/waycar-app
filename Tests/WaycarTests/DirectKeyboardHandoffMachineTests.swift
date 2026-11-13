import Foundation
import Testing

@testable import Waycar

@Suite("Direct keyboard handoff machine")
struct DirectKeyboardHandoffMachineTests {
    typealias Machine = DirectKeyboardHandoffMachine
    private static let id = UUID()
    private static let other = UUID()

    @Test func aRequestHoldsComposerForTheTerminalsClaim() {
        var machine = Machine()
        #expect(machine.handle(.begin(Self.id)) == [])
        #expect(machine.state == .requested(Self.id))
        #expect(machine.requestID == Self.id)
        #expect(machine.settlingID == nil)
        #expect(machine.isInFlight)
        // A second switch while one moves is refused.
        #expect(machine.handle(.begin(Self.other)) == [])
        #expect(machine.state == .requested(Self.id))
    }

    @Test func acceptanceRendersDirectInputAndSettles() {
        var machine = Machine().after([.begin(Self.id)])
        #expect(machine.handle(.destinationAnswered(Self.other, accepted: true)) == [])
        #expect(machine.handle(.destinationAnswered(Self.id, accepted: true)) == [.enterDirectInput])
        #expect(machine.state == .settling(Self.id, requestHeld: true))
        #expect(machine.requestID == Self.id)
        #expect(machine.settlingID == Self.id)
        #expect(machine.handle(.destinationSettled(Self.other)) == [])
        #expect(machine.handle(.destinationSettled(Self.id)) == [.endInsetHandoff(Self.id)])
        #expect(machine.state == .idle)
        #expect(!machine.isInFlight)
    }

    @Test func aSettleBeforeAcceptanceIsIgnored() {
        var machine = Machine().after([.begin(Self.id)])
        #expect(machine.handle(.destinationSettled(Self.id)) == [])
        #expect(machine.state == .requested(Self.id))
    }

    @Test func aRefusalDropsTheIntentTheRequestRaised() {
        var machine = Machine().after([.begin(Self.id)])
        #expect(machine.handle(.destinationAnswered(Self.id, accepted: false))
            == [.dropKeyboardIntent, .cancelInsetHandoff(Self.id)])
        #expect(machine.state == .idle)
        #expect(machine.handle(.destinationAnswered(Self.id, accepted: true)) == [])
    }

    @Test func aCancelAfterAcceptanceKeepsTheIntent() {
        var machine = Machine().after([.begin(Self.id), .destinationAnswered(Self.id, accepted: true)])
        #expect(machine.handle(.cancel(Self.other)) == [])
        #expect(machine.handle(.cancel(Self.id)) == [.cancelInsetHandoff(Self.id)])
        #expect(machine.state == .idle)
        #expect(machine.handle(.cancel(Self.id)) == [])
    }

    @Test func cancellingTheCurrentHandoffFindsItInEitherState() {
        var requested = Machine().after([.begin(Self.id)])
        #expect(requested.handle(.cancelCurrent) == [.dropKeyboardIntent, .cancelInsetHandoff(Self.id)])
        var settling = Machine().after([.begin(Self.id), .destinationAnswered(Self.id, accepted: true)])
        #expect(settling.handle(.cancelCurrent) == [.cancelInsetHandoff(Self.id)])
        var idle = Machine()
        #expect(idle.handle(.cancelCurrent) == [])
    }

    @Test func clearingTheRequestLeavesOnlyAnAcceptedHandoffSettling() {
        var requested = Machine().after([.begin(Self.id)])
        #expect(requested.handle(.requestCleared) == [])
        #expect(requested.state == .idle)
        var settling = Machine().after([.begin(Self.id), .destinationAnswered(Self.id, accepted: true)])
        #expect(settling.handle(.requestCleared) == [])
        #expect(settling.state == .settling(Self.id, requestHeld: false))
        #expect(settling.requestID == nil)
        #expect(settling.isInFlight)
        // Without a held request the terminal's answer is no longer this
        // screen's, but a cancel still releases the inset.
        #expect(settling.handle(.destinationAnswered(Self.id, accepted: false)) == [])
        #expect(settling.handle(.cancelCurrent) == [.cancelInsetHandoff(Self.id)])
        var idle = Machine()
        #expect(idle.handle(.requestCleared) == [])
    }
}
