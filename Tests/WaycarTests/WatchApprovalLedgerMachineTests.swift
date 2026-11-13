import Foundation
import Testing

@testable import Waycar

@Suite("Watch phone approval ledger")
struct WatchApprovalLedgerMachineTests {
    private let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "pane")

    private func prompt() throws -> WatchApprovalLedgerMachine.Prompt {
        .init(agentID: agent, snapshot: try #require(BlockedPromptSnapshot(
            kind: "claude", fullScreen: TmuxScreenDetectorTests.claudePermission)))
    }

    @Test func readsReplaceOnlyAvailablePromptsAndRejectWrongAgentsOrLockedPhone() throws {
        var machine = WatchApprovalLedgerMachine()
        let first = UUID(), newer = UUID()
        let prompt = try prompt()
        #expect(machine.handle(.read(first, prompt)) == [])
        #expect(machine.handle(.read(newer, prompt)) == [])
        #expect(machine.handle(.answer(first, agent, .allow, unlocked: true)) == [.reply(.answerResult(.promptChanged))])
        let other = ConsoleAgent.ID(hostID: UUID(), paneID: "other")
        #expect(machine.handle(.answer(newer, other, .allow, unlocked: true)) == [.reply(.answerResult(.promptChanged))])
        #expect(machine.handle(.answer(newer, agent, .allow, unlocked: false)) == [.unlockRequired])
        #expect(machine.state.records[newer] == .available(prompt))
    }

    @Test func theFirstChoiceWinsWhileAnsweringAndAfterCompletion() throws {
        var machine = WatchApprovalLedgerMachine()
        let id = UUID(), newer = UUID()
        let prompt = try prompt()
        _ = machine.handle(.read(id, prompt))
        #expect(machine.handle(.answer(id, agent, .allow, unlocked: true)) == [.start(1, prompt, .allow)])
        #expect(machine.handle(.answer(id, agent, .allow, unlocked: false)) == [.join(1, sameChoice: true)])
        #expect(machine.handle(.answer(id, agent, .deny, unlocked: true)) == [.join(1, sameChoice: false)])
        _ = machine.handle(.read(newer, prompt))
        #expect(machine.handle(.completed(id, token: 0, reply: .answerResult(.sent), keep: true)) == [])
        #expect(machine.handle(.completed(id, token: 1, reply: .answerResult(.sent), keep: true)) == [])
        #expect(machine.state.records[id] == .answered(token: 1, choice: .allow, reply: .answerResult(.sent)))
        #expect(machine.state.records[newer] == .available(prompt))
        #expect(machine.handle(.answer(id, agent, .deny, unlocked: true)) == [.join(1, sameChoice: false)])
        #expect(machine.handle(.hostFailed(id, token: 1)) == [])
    }

    @Test func hostFailureRestoresUnlessANewerReadExistsAndOldCompletionsDoNothing() throws {
        var machine = WatchApprovalLedgerMachine()
        let id = UUID(), newer = UUID()
        let prompt = try prompt()
        _ = machine.handle(.read(id, prompt))
        _ = machine.handle(.answer(id, agent, .allow, unlocked: true))
        #expect(machine.handle(.hostFailed(id, token: 0)) == [])
        #expect(machine.handle(.hostFailed(id, token: 1)) == [.forgetTask(1)])
        #expect(machine.state.records[id] == .available(prompt))
        #expect(machine.handle(.answer(id, agent, .deny, unlocked: true)) == [.start(2, prompt, .deny)])
        #expect(machine.handle(.completed(id, token: 1, reply: .answerResult(.sent), keep: true)) == [])
        _ = machine.handle(.read(newer, prompt))
        #expect(machine.handle(.hostFailed(id, token: 2)) == [.forgetTask(2)])
        #expect(machine.state.records[id] == nil)
        #expect(machine.state.records[newer] == .available(prompt))
    }

    @Test func unconfirmedAnswersAreSpentAndBothLedgersAreBounded() throws {
        var machine = WatchApprovalLedgerMachine(memoryLimit: 1)
        let first = UUID(), second = UUID(), third = UUID()
        let prompt = try prompt()
        _ = machine.handle(.read(first, prompt))
        _ = machine.handle(.answer(first, agent, .allow, unlocked: true))
        #expect(machine.handle(.completed(first, token: 1, reply: .answerResult(.failed), keep: false)) == [.forgetTask(1)])
        #expect(machine.handle(.answer(first, agent, .allow, unlocked: true)) == [.reply(.answerResult(.promptChanged))])
        _ = machine.handle(.read(second, prompt))
        _ = machine.handle(.answer(second, agent, .deny, unlocked: true))
        _ = machine.handle(.read(third, prompt))
        #expect(machine.handle(.answer(third, agent, .allow, unlocked: true)) == [.start(3, prompt, .allow), .forgetTask(2)])
        #expect(machine.handle(.completed(second, token: 2, reply: .answerResult(.sent), keep: true)) == [])
        #expect(machine.state.records[second] == nil)
        let other = WatchApprovalLedgerMachine.Prompt(
            agentID: .init(hostID: UUID(), paneID: "other"), snapshot: prompt.snapshot)
        _ = machine.handle(.read(first, prompt))
        _ = machine.handle(.read(second, other))
        #expect(machine.state.records[first] == nil)
        #expect(machine.state.promptOrder == [second])
    }
}
