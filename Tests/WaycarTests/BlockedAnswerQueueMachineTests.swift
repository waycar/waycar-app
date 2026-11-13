import Foundation
import Testing

@testable import Waycar

@Suite("Blocked answer queue machine")
struct BlockedAnswerQueueMachineTests {
    private let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")

    private func entry(for agent: ConsoleAgent.ID? = nil) -> BlockedAnswerQueue.Entry {
        BlockedAnswerQueue.Entry(
            id: UUID(), agentID: agent ?? self.agent,
            pending: PendingBlockedAnswer(label: "Allow", keys: ["enter"], shown: "screen", snapshot: nil),
            queuedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func enqueueArmsExpiryAndReplacementCancelsTheOldTimer() {
        var machine = BlockedAnswerQueueMachine()
        let first = entry()
        let second = entry()
        #expect(machine.handle(.enqueue(first)) == [.armExpiry(first)])
        #expect(machine.entries == [agent: first])
        #expect(machine.handle(.enqueue(second)) == [.cancelExpiry(first.id), .armExpiry(second)])
        #expect(machine.entries == [agent: second])
        #expect(machine.handle(.finish(first, .expired)) == [])
        #expect(machine.handle(.claim(first)) == [])
    }

    @Test func claimDisarmsExpiryAndOnlyOneClaimSucceeds() {
        let entry = entry()
        var machine = BlockedAnswerQueueMachine().after([.enqueue(entry)])
        #expect(machine.handle(.claim(entry)) == [.cancelExpiry(entry.id), .claimed(entry.id)])
        #expect(machine.handle(.claim(entry)) == [])
        #expect(machine.handle(.finish(entry, .expired)) == [])
        #expect(machine.entries == [agent: entry])
        #expect(machine.handle(.finish(entry, .sent)) == [.cancelExpiry(entry.id), .report(entry, .sent)])
        #expect(machine.entries.isEmpty)
        #expect(machine.handle(.finish(entry, .sent)) == [])
    }

    @Test(arguments: [BlockedAnswerQueue.Finish.sent, .promptChanged, .notConfirmed, .expired])
    func queuedOutcomeReportsOnce(outcome: BlockedAnswerQueue.Finish) {
        let entry = entry()
        var machine = BlockedAnswerQueueMachine().after([.enqueue(entry)])
        #expect(machine.handle(.finish(entry, outcome)) == [.cancelExpiry(entry.id), .report(entry, outcome)])
        #expect(machine.entries.isEmpty)
        #expect(machine.handle(.finish(entry, outcome)) == [])
    }

    @Test(arguments: [BlockedAnswerQueue.Finish.sent, .promptChanged, .notConfirmed])
    func sendingOutcomeReportsOnce(outcome: BlockedAnswerQueue.Finish) {
        let entry = entry()
        var machine = BlockedAnswerQueueMachine().after([.enqueue(entry), .claim(entry)])
        #expect(machine.handle(.finish(entry, outcome)) == [.cancelExpiry(entry.id), .report(entry, outcome)])
        #expect(machine.entries.isEmpty)
    }

    @Test(arguments: [false, true])
    func withdrawIsSilentAndLateResultsAreIgnored(sending: Bool) {
        let entry = entry()
        var machine = BlockedAnswerQueueMachine().after([.enqueue(entry)])
        if sending { _ = machine.handle(.claim(entry)) }
        #expect(machine.handle(.withdraw(agent)) == [.cancelExpiry(entry.id)])
        #expect(machine.handle([.withdraw(agent), .finish(entry, .sent), .claim(entry)]) == [])
        #expect(machine.entries.isEmpty)
    }

    @Test func replacingSendingEntryDoesNotAdoptItsOutcome() {
        let first = entry()
        let second = entry()
        var machine = BlockedAnswerQueueMachine().after([.enqueue(first), .claim(first)])
        #expect(machine.handle(.enqueue(second)) == [.cancelExpiry(first.id), .armExpiry(second)])
        #expect(machine.handle(.finish(first, .sent)) == [])
        #expect(machine.entries == [agent: second])
        #expect(machine.handle(.finish(second, .expired)) == [.cancelExpiry(second.id), .report(second, .expired)])
    }

    @Test func agentsHaveIndependentAnswers() {
        let first = entry()
        let other = entry(for: ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1"))
        var machine = BlockedAnswerQueueMachine().after([.enqueue(first), .enqueue(other), .claim(first)])
        #expect(machine.handle(.finish(other, .expired)) == [.cancelExpiry(other.id), .report(other, .expired)])
        #expect(machine.entries == [agent: first])
        #expect(machine.handle(.finish(first, .expired)) == [])
    }

    @Test func absentAnswersIgnoreCompletionsAndClaims() {
        let entry = entry()
        var machine = BlockedAnswerQueueMachine()
        #expect(machine.handle([.claim(entry), .finish(entry, .expired), .withdraw(agent)]) == [])
        #expect(machine.entries.isEmpty)
    }
}
