import Foundation
import Testing

@testable import Waycar

@Suite("Watch phone recording rendezvous")
struct WatchRecordingRendezvousMachineTests {
    private let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "pane")
    private let url = URL(fileURLWithPath: "/tmp/watch-voice.m4a")
    private let newerURL = URL(fileURLWithPath: "/tmp/watch-voice-new.m4a")
    private let now = Date(timeIntervalSince1970: 100)

    @Test func fileFirstPairsAndItsLateExpiryIsIgnored() {
        var machine = WatchRecordingRendezvousMachine()
        let id = UUID()
        #expect(machine.handle(.file(id, url, arrived: now, acceptUnclaimed: true)) == [.armExpiry(id, token: 1)])
        #expect(machine.handle(.message(id, agent, token: 10)) == [
            .cancelTimer(1), .transcribe(id, url, agent, messageToken: 10, waiting: nil),
        ])
        #expect(machine.state.records[id] == nil)
        #expect(machine.handle(.fileExpired(id, token: 1)) == [])
        #expect(machine.handle(.file(id, newerURL, arrived: now, acceptUnclaimed: false)) == [.delete(newerURL)])
    }

    @Test func messageFirstKeepsItsHoldThroughPairingAndCancelsTheWait() {
        var machine = WatchRecordingRendezvousMachine()
        let id = UUID()
        #expect(machine.handle(.message(id, agent, token: 10)) == [.waitForFile(id, token: 1)])
        #expect(machine.handle(.message(id, agent, token: 10)) == [])
        #expect(machine.handle(.waitExpired(id, token: 0)) == [])
        #expect(machine.handle(.file(id, url, arrived: now, acceptUnclaimed: false)) == [
            .cancelTimer(1), .transcribe(id, url, agent, messageToken: 10, waiting: 1),
        ])
        #expect(machine.handle(.waitExpired(id, token: 1)) == [])
    }

    @Test func missingFileAllowsALateFileAndARetry() {
        var machine = WatchRecordingRendezvousMachine()
        let id = UUID()
        _ = machine.handle(.message(id, agent, token: 10))
        #expect(machine.handle(.waitExpired(id, token: 1)) == [
            .cancelTimer(1), .missing(id, messageToken: 10, waiting: 1),
        ])
        #expect(machine.handle(.waitExpired(id, token: 1)) == [])
        #expect(machine.handle(.file(id, url, arrived: now, acceptUnclaimed: true)) == [.armExpiry(id, token: 2)])
        #expect(machine.handle(.message(id, agent, token: 11)) == [
            .cancelTimer(2), .transcribe(id, url, agent, messageToken: 11, waiting: nil),
        ])
    }

    @Test func replacementInvalidatesTheOldExpiryAndSweepUsesArrivalTime() {
        var machine = WatchRecordingRendezvousMachine()
        let id = UUID()
        _ = machine.handle(.file(id, url, arrived: now, acceptUnclaimed: true))
        #expect(machine.handle(.file(id, newerURL, arrived: now, acceptUnclaimed: true)) == [
            .cancelTimer(1), .delete(url), .armExpiry(id, token: 2),
        ])
        #expect(machine.handle(.fileExpired(id, token: 1)) == [])
        #expect(machine.handle(.sweep(cutoff: now.addingTimeInterval(-1))) == [])
        #expect(machine.handle(.sweep(cutoff: now)) == [.cancelTimer(2), .delete(newerURL)])
        #expect(machine.state.records[id] == .expired)
        #expect(machine.handle(.fileExpired(id, token: 2)) == [])
        #expect(machine.handle(.message(id, agent, token: 10)) == [.missing(id, messageToken: 10, waiting: nil)])
        #expect(machine.handle(.message(id, agent, token: 11)) == [.waitForFile(id, token: 3)])
    }

    @Test func expiryMemoryIsBoundedAndANewTransferClearsTheTombstone() {
        var machine = WatchRecordingRendezvousMachine(memoryLimit: 1)
        let first = UUID(), second = UUID()
        _ = machine.handle(.file(first, url, arrived: now, acceptUnclaimed: true))
        #expect(machine.handle(.fileExpired(first, token: 1)) == [.cancelTimer(1), .delete(url)])
        _ = machine.handle(.file(second, newerURL, arrived: now, acceptUnclaimed: true))
        _ = machine.handle(.fileExpired(second, token: 2))
        #expect(machine.state.records[first] == nil)
        #expect(machine.state.expiredOrder == [second])
        #expect(machine.handle(.file(second, url, arrived: now, acceptUnclaimed: true)) == [.armExpiry(second, token: 3)])
        #expect(machine.state.expiredOrder.isEmpty)
        #expect(machine.handle(.fileExpired(UUID(), token: 3)) == [])
    }
}
