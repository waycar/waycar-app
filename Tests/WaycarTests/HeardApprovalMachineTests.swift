import Foundation
import Testing
@testable import Waycar

@Suite("Heard approval machine")
struct HeardApprovalMachineTests {
    private let agentID = ConsoleAgent.ID(hostID: UUID(), paneID: "pane")
    private func question(
        text: String = "Question", identity: String = "Agent",
        buttons: AgentVoiceService.BlockedButtons = .denyAndAllow, hasSnapshot: Bool = true
    ) -> AgentVoiceService.BlockedTurn {
        .init(agentID: agentID, identity: identity, question: text, buttons: buttons,
              snapshot: hasSnapshot ? BlockedPromptSnapshot(kind: "claude", fullScreen: "Question") : nil)
    }

    @Test func heardQuestionIsConsumedExactlyOnce() throws {
        let question = question()
        let snapshot = try #require(question.snapshot)
        var machine = HeardApprovalMachine()
        #expect(machine.handle(.allow(question)).isEmpty)
        #expect(machine.handle(.announce(question)) == [.speak(1)])
        #expect(machine.state == .speaking(question, token: 1))
        #expect(machine.handle(.allow(question)).isEmpty)
        #expect(machine.handle(.completed(1, spoken: true)).isEmpty)
        #expect(machine.state == .heard(question))
        #expect(machine.handle(.allow(question)) == [.authorize(snapshot)])
        #expect(machine.state == .consumed)
        #expect(machine.handle(.allow(question)).isEmpty)
        #expect(machine.handle(.completed(1, spoken: true)).isEmpty)
        #expect(machine.state == .consumed)
    }

    @Test func onlyTheCurrentSuccessfulSpeechAuthorizes() {
        let first = question()
        let next = question(text: "Next")
        var machine = HeardApprovalMachine().after([.announce(first)])
        #expect(machine.handle(.announce(next)) == [.speak(2)])
        #expect(machine.handle(.completed(1, spoken: true)).isEmpty)
        #expect(machine.state == .speaking(next, token: 2))
        _ = machine.handle(.completed(2, spoken: false))
        #expect(machine.state == .unheard)
        _ = machine.handle(.completed(1, spoken: true))
        #expect(machine.state == .unheard)
        #expect(machine.handle(.announce(first)) == [.speak(3)])
        _ = machine.handle(.completed(3, spoken: true))
        #expect(machine.state == .heard(first))
    }

    @Test func fullQuestionEqualityIncludesIdentityButtonsAndSnapshot() {
        let first = question()
        var machine = HeardApprovalMachine().after([.announce(first), .completed(1, spoken: true)])
        for other in [question(text: "Other"), question(identity: "Other"),
                      question(buttons: .denyAndHold), question(hasSnapshot: false)] {
            #expect(machine.handle(.allow(other)).isEmpty)
            #expect(machine.state == .heard(first))
        }
        #expect(machine.handle(.announce(first)) == [.speak(2)])
        #expect(machine.state == .speaking(first, token: 2), "Re-announcement revokes the heard claim")
    }

    @Test func heldReadOnlyAndSnapshotlessQuestionsNeverAuthorize() {
        for question in [question(buttons: .denyAndHold), question(buttons: .readOnly), question(hasSnapshot: false)] {
            var machine = HeardApprovalMachine().after([.announce(question), .completed(1, spoken: true)])
            #expect(machine.handle(.allow(question)).isEmpty)
            #expect(machine.state == .heard(question))
        }
    }

    @Test func consumedCanAnnounceAgainWithoutReusingTheSpeechToken() {
        let question = question()
        var machine = HeardApprovalMachine().after([.announce(question), .completed(1, spoken: true), .allow(question)])
        #expect(machine.handle(.announce(question)) == [.speak(2)])
        #expect(machine.handle(.completed(1, spoken: true)).isEmpty)
        #expect(machine.state == .speaking(question, token: 2))
        var unheard = HeardApprovalMachine()
        #expect(unheard.handle(.completed(1, spoken: true)).isEmpty)
        #expect(unheard.state == .unheard)
    }
}
