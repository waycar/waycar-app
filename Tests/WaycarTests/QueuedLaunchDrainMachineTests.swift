import Testing

@testable import Waycar

@Suite("Queued Launch drain machine")
struct QueuedLaunchDrainMachineTests {
    @Test func onlyOneDrainStartsPerVerifiedGeneration() {
        var machine = QueuedLaunchDrainMachine()
        #expect(machine.handle(.wake(generation: nil)).isEmpty)
        #expect(machine.state == .ready)
        #expect(machine.handle(.wake(generation: 10)) == [.start(1)])
        #expect(machine.handle(.wake(generation: 10)).isEmpty)
        #expect(machine.handle(.finished(1)) == [.finish(1), .redrain])
        #expect(machine.state == .attempted(generation: 10))
        #expect(machine.handle(.wake(generation: 10)).isEmpty)
        #expect(machine.handle(.wake(generation: 11)) == [.start(2)])
    }

    @Test func aReplacementVerifiedDuringTheAwaitWaitsForTheOldToken() {
        var machine = QueuedLaunchDrainMachine().after([.wake(generation: 10)])
        #expect(machine.handle(.wake(generation: 11)).isEmpty)
        #expect(machine.state == .draining(token: 1, lastAttemptedGeneration: 10))
        #expect(machine.handle(.finished(1)) == [.finish(1), .redrain])
        #expect(machine.handle(.wake(generation: 11)) == [.start(2)])
        let replacement = machine.state
        #expect(machine.handle(.finished(1)).isEmpty)
        #expect(machine.state == replacement)
    }

    @Test func resettingAnOutstandingDrainRetainsItsTokenButNotItsAllowance() {
        let resets: [QueuedLaunchDrainMachine.Event] = [.invalidate, .wake(generation: nil)]
        for reset in resets {
            var machine = QueuedLaunchDrainMachine().after([.wake(generation: 10)])
            #expect(machine.handle(reset).isEmpty)
            #expect(machine.state == .draining(token: 1, lastAttemptedGeneration: nil))
            #expect(machine.handle(.wake(generation: 10)).isEmpty)
            #expect(machine.handle(.finished(1)) == [.finish(1), .redrain])
            #expect(machine.state == .ready)
            #expect(machine.handle(.wake(generation: 10)) == [.start(2)])
        }
    }

    @Test func enqueueRetryAndForegroundCanReuseAnAlreadyAttemptedConnection() {
        var machine = QueuedLaunchDrainMachine().after([
            .wake(generation: 10), .finished(1),
        ])
        #expect(machine.handle(.invalidate).isEmpty)
        #expect(machine.handle(.wake(generation: 10)) == [.start(2)])
        #expect(machine.handle(.finished(2)) == [.finish(2), .redrain])
        #expect(machine.handle(.wake(generation: nil)).isEmpty)
        #expect(machine.state == .ready)
        #expect(machine.handle(.wake(generation: 10)) == [.start(3)])
    }

    @Test func retargetCancelsAndStaleCompletionsCannotClearTheReplacement() {
        var machine = QueuedLaunchDrainMachine().after([.wake(generation: 10)])
        #expect(machine.handle(.cancel) == [.cancel(1)])
        #expect(machine.state == .ready)
        #expect(machine.handle(.finished(1)).isEmpty)
        #expect(machine.handle(.wake(generation: 10)) == [.start(2)])
        #expect(machine.handle(.finished(1)).isEmpty)
        #expect(machine.state == .draining(token: 2, lastAttemptedGeneration: 10))
        #expect(machine.handle(.finished(2)) == [.finish(2), .redrain])
        #expect(machine.handle(.cancel).isEmpty)
        #expect(machine.state == .ready)
        #expect(machine.handle(.cancel).isEmpty)
        #expect(machine.handle(.finished(2)).isEmpty)
    }
}
