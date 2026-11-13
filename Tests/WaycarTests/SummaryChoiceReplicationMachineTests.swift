import Foundation
import Testing

@testable import Waycar

struct SummaryChoiceReplicationMachineTests {
    private let host = UUID()
    private let other = UUID()

    @Test func unconfirmedWritesOnceAndConfirmedChoiceSkipsLaterPasses() {
        var machine = SummaryChoiceReplicationMachine()
        _ = machine.handle(.catalogChanged([host]))
        #expect(machine.state.replicas[host] == .unconfirmed)
        #expect(machine.handle(.apply(true, hosts: [host], updating: [])) == [
            .write(host, 1, choice: true), .waitForWrites(batch: 2, writes: [1])
        ])
        #expect(machine.inFlight(for: host) == 1)
        #expect(machine.handle(.writeFinished(host, 1, succeeded: true)) == [])
        #expect(machine.confirmedChoice(for: host) == true)
        #expect(machine.handle(.batchFinished(2, currentChoice: true)) == [])
        #expect(machine.handle(.apply(true, hosts: [host], updating: [])) == [.waitForWrites(batch: 3, writes: [])])
        #expect(machine.handle(.batchFinished(3, currentChoice: true)) == [])
        #expect(machine.state.batches.isEmpty)
    }

    @Test func failureKeepsTheOldConfirmationAndRetriesOnNextApply() {
        var machine = SummaryChoiceReplicationMachine().after([.registrationConfirmed(host, false)])
        _ = machine.handle(.apply(true, hosts: [host], updating: []))
        _ = machine.handle(.writeFinished(host, 1, succeeded: false))
        #expect(machine.state.replicas[host] == .retryPending(choice: true, confirmed: false))
        #expect(machine.confirmedChoice(for: host) == false)
        #expect(machine.handle(.batchFinished(2, currentChoice: true)) == [])
        #expect(machine.handle(.apply(true, hosts: [host], updating: [])) == [
            .write(host, 3, choice: true), .waitForWrites(batch: 4, writes: [3])
        ])
    }

    @Test func joinsAndChangedChoicesReplayAfterTheBatchFinishes() {
        var machine = SummaryChoiceReplicationMachine()
        _ = machine.handle(.apply(true, hosts: [host], updating: []))
        #expect(machine.handle(.apply(false, hosts: [host], updating: [])) == [.waitForWrites(batch: 3, writes: [1])])
        _ = machine.handle(.writeFinished(host, 1, succeeded: true))
        #expect(machine.handle(.batchFinished(2, currentChoice: false)) == [.reapply])
        #expect(machine.handle(.batchFinished(3, currentChoice: false)) == [.reapply])
        #expect(machine.handle(.batchFinished(3, currentChoice: true)) == [])
    }

    @Test func aJoinedFailureStillGetsOneFreshPass() {
        var machine = SummaryChoiceReplicationMachine()
        _ = machine.handle(.apply(true, hosts: [host], updating: []))
        _ = machine.handle(.apply(true, hosts: [host], updating: []))
        _ = machine.handle(.writeFinished(host, 1, succeeded: false))
        #expect(machine.handle(.batchFinished(2, currentChoice: true)) == [])
        #expect(machine.handle(.batchFinished(3, currentChoice: true)) == [.reapply])
    }

    @Test func registrationExcludesSummaryWritesAndCanConfirmItsChoice() {
        var machine = SummaryChoiceReplicationMachine()
        #expect(machine.handle(.apply(true, hosts: [host, other], updating: [host])) == [
            .write(other, 1, choice: true), .waitForWrites(batch: 2, writes: [1])
        ])
        #expect(machine.inFlight(for: host) == nil)
        _ = machine.handle(.registrationConfirmed(host, true))
        #expect(machine.confirmedChoice(for: host) == true)
        _ = machine.handle(.registrationConfirmed(other, false))
        #expect(machine.inFlight(for: other) == 1)
        #expect(machine.confirmedChoice(for: other) == false)
    }

    @Test func staleWritesAndBatchCompletionsCannotChangeCurrentWork() {
        var machine = SummaryChoiceReplicationMachine()
        _ = machine.handle(.apply(true, hosts: [host], updating: []))
        let state = machine.state
        let stale: [SummaryChoiceReplicationMachine.Event] = [
            .writeFinished(host, 0, succeeded: true), .writeFinished(other, 1, succeeded: true),
            .batchFinished(0, currentChoice: false)
        ]
        for event in stale {
            #expect(machine.handle(event) == [])
            #expect(machine.state == state)
        }
        _ = machine.handle([.writeFinished(host, 1, succeeded: true), .batchFinished(2, currentChoice: true)])
        let confirmed = machine.state
        #expect(machine.handle(.writeFinished(host, 1, succeeded: false)) == [])
        #expect(machine.state == confirmed)
    }

    @Test func catalogPrunesConfirmationButDoesNotAbandonAJoinableWrite() {
        var machine = SummaryChoiceReplicationMachine().after([
            .registrationConfirmed(host, false), .registrationConfirmed(other, true),
            .apply(true, hosts: [host], updating: []), .catalogChanged([])
        ])
        #expect(machine.state.replicas[other] == nil)
        #expect(machine.confirmedChoice(for: host) == nil)
        #expect(machine.inFlight(for: host) == 1)
        _ = machine.handle(.catalogChanged([host]))
        #expect(machine.handle(.apply(true, hosts: [host], updating: [])) == [.waitForWrites(batch: 3, writes: [1])])
        _ = machine.handle(.writeFinished(host, 1, succeeded: true))
        #expect(machine.confirmedChoice(for: host) == true)
    }
}
