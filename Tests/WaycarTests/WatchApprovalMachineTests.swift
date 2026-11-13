import Foundation
import Testing
@testable import Waycar

struct WatchApprovalMachineTests {
    private func prompt(_ approval: WatchBlockedPrompt.Approval = .allow) -> WatchBlockedPrompt {
        WatchBlockedPrompt(promptID: UUID(), approval: approval, command: "echo ok", holdReason: nil)
    }

    @Test func readIsSingleFlightAndRejectsWrongToken() {
        var machine = WatchApprovalMachine()
        #expect(machine.prompt == .idle)
        #expect(machine.handle(.load(stampExpired: false)) == [.read(1)])
        #expect(machine.prompt == .loading)
        #expect(machine.handle(.load(stampExpired: true)).isEmpty)
        #expect(machine.handle(.readFinished(99, .loaded(nil))).isEmpty)
        #expect(machine.prompt == .loading)
        #expect(machine.handle(.readFinished(1, .loaded(nil))).isEmpty)
        #expect(machine.prompt == .loaded(nil))
        #expect(machine.handle(.answer(.allow)).isEmpty)
        #expect(machine.handle(.load(stampExpired: false)) == [.read(2)])
        _ = machine.handle(.readFinished(2, .failed("offline")))
        #expect(machine.prompt == .failed("offline"))
    }

    @Test func answeringKeepsPromptIdentityAndSendingGuard() {
        let prompt = prompt()
        var machine = WatchApprovalMachine().after([
            .load(stampExpired: false), .readFinished(1, .loaded(prompt))])
        #expect(machine.handle(.answer(.allow)) == [.answer(2, promptID: prompt.promptID, .allow)])
        #expect(machine.answer == .sending)
        #expect(machine.handle(.load(stampExpired: true)).isEmpty)
        #expect(machine.handle(.answer(.deny)).isEmpty)
        #expect(machine.handle(.answerFinished(2, promptID: UUID(), .promptChanged, spent: false)).isEmpty)
        #expect(machine.handle(.answerFinished(99, promptID: prompt.promptID, .promptChanged, spent: false)).isEmpty)
        #expect(machine.answer == .sending)
        let at = Date(timeIntervalSince1970: 100)
        #expect(machine.handle(.answerFinished(2, promptID: prompt.promptID, .done(.allow, at: at), spent: false)) == [.success])
        #expect(machine.handle(.answer(.deny)).isEmpty)
        #expect(machine.handle(.load(stampExpired: false)).isEmpty)
        #expect(machine.handle(.load(stampExpired: true)) == [.read(3)])
        #expect(machine.answer == .done(.allow, at: at))
        _ = machine.handle(.readFinished(3, .loaded(prompt)))
        #expect(machine.answer == .idle)
    }

    @Test func expiredStampRemainsWhenNoPromptOrReadFails() {
        let prompt = prompt()
        let at = Date(timeIntervalSince1970: 100)
        let reads: [WatchRead<WatchBlockedPrompt?>] = [.loaded(nil), .failed("offline")]
        for read in reads {
            var machine = WatchApprovalMachine().after([
                .load(stampExpired: false), .readFinished(1, .loaded(prompt)), .answer(.deny),
                .answerFinished(2, promptID: prompt.promptID, .done(.deny, at: at), spent: false),
                .load(stampExpired: true)])
            _ = machine.handle(.readFinished(3, read))
            #expect(machine.answer == .done(.deny, at: at))
        }
    }

    @Test func approvalRulesAndNonSpentFailures() {
        for approval in [WatchBlockedPrompt.Approval.hold, .readOnly] {
            let prompt = prompt(approval)
            var machine = WatchApprovalMachine().after([
                .load(stampExpired: false), .readFinished(1, .loaded(prompt))])
            #expect(machine.handle(.answer(.allow)).isEmpty)
            if approval == .hold {
                #expect(machine.handle(.answer(.deny)) == [.answer(2, promptID: prompt.promptID, .deny)])
                #expect(machine.handle(.answerFinished(2, promptID: prompt.promptID, .promptChanged, spent: false)) == [.failure])
                #expect(machine.handle(.load(stampExpired: false)) == [.read(3)])
                #expect(machine.answer == .idle)
            } else { #expect(machine.handle(.answer(.deny)).isEmpty) }
        }
    }

    @Test func spentAnswerRereadsWithoutLosingFailure() {
        let prompt = prompt()
        var machine = WatchApprovalMachine().after([
            .load(stampExpired: false), .readFinished(1, .loaded(prompt)), .answer(.allow)])
        #expect(machine.handle(.answerFinished(2, promptID: prompt.promptID, .failed("timeout"), spent: true)) == [.failure, .read(3)])
        #expect(machine.answer == .failed("timeout"))
        #expect(machine.prompt == .loading)
        _ = machine.handle(.readFinished(3, .loaded(self.prompt())))
        #expect(machine.answer == .failed("timeout"))
        #expect(machine.handle(.answer(.deny)).count == 1)
    }

    @Test func newEpisodeRejectsAnInFlightPromptRead() {
        let oldPrompt = prompt()
        var machine = WatchApprovalMachine().after([.load(stampExpired: false)])
        _ = machine.handle(.blockedEpisode)
        _ = machine.handle(.readFinished(1, .loaded(oldPrompt)))
        #expect(machine.prompt == .idle)
        #expect(machine.answer == .idle)
        #expect(machine.handle(.answer(.allow)).isEmpty)
        #expect(machine.handle(.load(stampExpired: false)) == [.read(2)])
        let currentPrompt = prompt()
        _ = machine.handle(.readFinished(2, .loaded(currentPrompt)))
        _ = machine.handle(.readFinished(1, .loaded(oldPrompt)))
        #expect(machine.prompt == .loaded(currentPrompt))
    }

    @Test func newEpisodeAlsoRejectsOldReadFailures() {
        var machine = WatchApprovalMachine().after([.load(stampExpired: false)])
        _ = machine.handle(.blockedEpisode)
        _ = machine.handle(.blockedEpisode)
        _ = machine.handle(.readFinished(1, .failed("old failure")))
        #expect(machine.prompt == .idle)
        #expect(machine.handle(.load(stampExpired: false)) == [.read(2)])
    }

    /// The detail screen loads again when a new Blocked episode arrives; if
    /// the old episode's read is still out, that load must not be lost, or
    /// the screen stays on "Reading prompt…" with nothing pending.
    @Test func aLoadWaitingOnAStaleReadGetsAFreshRead() {
        var machine = WatchApprovalMachine().after([.load(stampExpired: false), .blockedEpisode])
        #expect(machine.handle(.load(stampExpired: false)).isEmpty, "old read still owns its single-flight slot")
        #expect(machine.handle(.readFinished(1, .failed("old failure"))) == [.read(2)])
        #expect(machine.prompt == .loading)
        #expect(machine.handle(.load(stampExpired: false)).isEmpty)
        let current = prompt()
        _ = machine.handle(.readFinished(2, .loaded(current)))
        #expect(machine.prompt == .loaded(current))
    }

    /// A load during a read of the current episode is still answered by that
    /// read: no second read.
    @Test func aLoadDuringACurrentReadIsAnsweredByIt() {
        let current = prompt()
        var machine = WatchApprovalMachine().after([.load(stampExpired: false), .load(stampExpired: false)])
        #expect(machine.handle(.readFinished(1, .loaded(current))).isEmpty)
        #expect(machine.prompt == .loaded(current))
    }

    @Test func newEpisodeDropsOldAnswerAndItsLateCompletion() {
        let prompt = prompt()
        var machine = WatchApprovalMachine().after([
            .load(stampExpired: false), .readFinished(1, .loaded(prompt)), .answer(.allow)])
        #expect(machine.handle(.blockedEpisode).isEmpty)
        #expect(machine.prompt == .idle)
        #expect(machine.answer == .idle)
        #expect(machine.handle(.answerFinished(2, promptID: prompt.promptID, .failed("late"), spent: true)).isEmpty)
        #expect(machine.handle(.load(stampExpired: false)) == [.read(3)])
        _ = machine.handle(.blockedEpisode)
        #expect(machine.prompt == .idle)
        #expect(machine.handle(.load(stampExpired: false)).isEmpty)
    }
}
