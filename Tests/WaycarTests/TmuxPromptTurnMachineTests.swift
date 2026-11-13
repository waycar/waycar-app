import Foundation
import Testing

@testable import Waycar

/// `TmuxPromptTurnMachine`: one prompt at a time per tmux pane.
@Suite("tmux prompt turn machine")
struct TmuxPromptTurnMachineTests {
    typealias Machine = TmuxPromptTurnMachine

    private let first = UUID()
    private let second = UUID()
    private let third = UUID()

    @Test func aPaneNoOneHoldsGrantsTheTurnAtOnce() {
        var machine = Machine()
        #expect(machine.handle(.request(first, pane: "%3")) == [.grant(first)])
        #expect(machine["%3"] == Machine.Turn(holder: first))
    }

    @Test func aHeldPaneQueuesLaterPromptsInOrder() {
        var machine = Machine().after([.request(first, pane: "%3")])
        #expect(machine.handle(.request(second, pane: "%3")).isEmpty)
        #expect(machine.handle(.request(third, pane: "%3")).isEmpty)
        #expect(machine["%3"] == Machine.Turn(holder: first, waiting: [second, third]))
    }

    @Test func panesNeverWaitForEachOther() {
        var machine = Machine().after([.request(first, pane: "%3")])
        #expect(machine.handle(.request(second, pane: "%4")) == [.grant(second)])
        #expect(machine["%3"]?.holder == first)
        #expect(machine["%4"]?.holder == second)
    }

    @Test func releaseHandsTheTurnToTheNextInLine() {
        var machine = Machine().after([
            .request(first, pane: "%3"), .request(second, pane: "%3"), .request(third, pane: "%3"),
        ])
        #expect(machine.handle(.release(first, pane: "%3")) == [.grant(second)])
        #expect(machine["%3"] == Machine.Turn(holder: second, waiting: [third]))
        #expect(machine.handle(.release(second, pane: "%3")) == [.grant(third)])
        #expect(machine.handle(.release(third, pane: "%3")).isEmpty)
        #expect(machine["%3"] == nil)
        #expect(machine.state.isEmpty)
    }

    @Test func onlyTheHolderReleases() {
        var machine = Machine().after([.request(first, pane: "%3"), .request(second, pane: "%3")])
        #expect(machine.handle(.release(second, pane: "%3")).isEmpty)
        #expect(machine.handle(.release(first, pane: "%4")).isEmpty)
        #expect(machine["%3"] == Machine.Turn(holder: first, waiting: [second]))
        // A holder that released already releases nothing more.
        _ = machine.handle(.release(first, pane: "%3"))
        #expect(machine.handle(.release(first, pane: "%3")).isEmpty)
        #expect(machine["%3"] == Machine.Turn(holder: second))
    }

    @Test func aCancelledWaiterGivesItsPlaceUpAndIsSkipped() {
        var machine = Machine().after([
            .request(first, pane: "%3"), .request(second, pane: "%3"), .request(third, pane: "%3"),
        ])
        #expect(machine.handle(.withdraw(second, pane: "%3")) == [.cancel(second)])
        #expect(machine["%3"] == Machine.Turn(holder: first, waiting: [third]))
        #expect(machine.handle(.release(first, pane: "%3")) == [.grant(third)])
    }

    @Test func withdrawingAHolderOrAStrangerChangesNothing() {
        var machine = Machine().after([.request(first, pane: "%3")])
        #expect(machine.handle(.withdraw(first, pane: "%3")).isEmpty)
        #expect(machine.handle(.withdraw(second, pane: "%3")).isEmpty)
        #expect(machine.handle(.withdraw(second, pane: "%9")).isEmpty)
        #expect(machine["%3"] == Machine.Turn(holder: first))
    }
}
