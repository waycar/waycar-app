import Foundation
import Testing

@testable import Waycar

@Suite("Watch phone message ledger")
struct WatchMessageLedgerMachineTests {
    private let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "pane")

    @Test func processingDeduplicatesAndUnknownIsFinal() {
        var machine = WatchMessageLedgerMachine()
        let id = UUID()
        #expect(machine.handle(.receive(id)) == [])
        #expect(machine.handle(.begin(id, agent)) == [.process(token: 1, transcript: nil)])
        #expect(machine.handle(.receive(id)) == [.acknowledge])
        #expect(machine.handle(.begin(id, agent)) == [])
        let event = WatchEvent.delivery(messageID: id, WatchAgentID(agent), .unknown)
        #expect(machine.handle(.finished(id, token: 1, delivery: .unknown, transcript: nil)) == [.deliver(event)])
        #expect(machine.handle(.receive(id)) == [.acknowledge, .deliver(event)])
        #expect(machine.handle(.begin(id, agent)) == [])
        #expect(machine.handle(.finished(id, token: 1, delivery: .sent(text: "late"), transcript: nil)) == [])
    }

    @Test func definiteFailureRetriesTheTranscriptWithANewToken() {
        var machine = WatchMessageLedgerMachine()
        let id = UUID()
        _ = machine.handle(.begin(id, agent))
        _ = machine.handle(.finished(id, token: 1, delivery: .notSent(reason: "offline"), transcript: "words"))
        #expect(machine.handle(.receive(id)) == [])
        #expect(machine.handle(.begin(id, agent)) == [.process(token: 2, transcript: "words")])
        #expect(machine.handle(.finished(id, token: 1, delivery: .unknown, transcript: nil)) == [])
        #expect(machine.handle(.finished(UUID(), token: 2, delivery: .unknown, transcript: nil)) == [])
        let event = WatchEvent.delivery(messageID: id, WatchAgentID(agent), .sent(text: "words"))
        #expect(machine.handle(.finished(id, token: 2, delivery: .sent(text: "words"), transcript: "words")) == [.deliver(event)])
    }

    @Test func trimmingStopsAtTheOldestProcessingMessage() {
        var machine = WatchMessageLedgerMachine(memoryLimit: 1)
        let first = UUID(), second = UUID()
        _ = machine.handle(.begin(first, agent))
        _ = machine.handle(.begin(second, agent))
        _ = machine.handle(.finished(second, token: 2, delivery: .noWords, transcript: nil))
        #expect(machine.state.order == [first, second])
        _ = machine.handle(.finished(first, token: 1, delivery: .noWords, transcript: nil))
        #expect(machine.state.order == [second])
        #expect(machine.handle(.receive(first)) == [])
        #expect(machine.handle(.finished(first, token: 1, delivery: .unknown, transcript: nil)) == [])
    }
}
