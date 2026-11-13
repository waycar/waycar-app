import Foundation
import Testing

@testable import Waycar

@Suite("CarPlay turn presentation machine")
struct CarPlayTurnMachineTests {
    private let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
    private var blocked: AgentVoiceService.BlockedTurn {
        .init(agentID: agent, identity: "Agent", question: "Allow?", buttons: .denyAndAllow, snapshot: nil)
    }

    private func awaiting() -> CarPlayTurnMachine {
        CarPlayTurnMachine().after([
            .open(.blocked, agent), .announce(1, blocked), .spoken(1),
        ])
    }

    @Test func opensEveryKindAndCloses() {
        for kind in [CarPlayTurnMachine.Kind.briefing, .conversation, .blocked] {
            var machine = CarPlayTurnMachine()
            #expect(machine.handle(.open(kind, agent)).isEmpty)
            let t = CarPlayTurnMachine.Turn(template: 1, step: 1, agent: agent)
            switch kind {
            case .briefing: #expect(machine.state == .briefing(t))
            case .conversation: #expect(machine.state == .conversation(t))
            case .blocked: #expect(machine.state == .checking(t, nil))
            }
            #expect(machine.handle(.close) == [.closed])
            #expect(machine.state == .none)
        }
    }

    @Test func initialDenyCanClaimDuringSpeechButOnlyOnce() {
        var machine = CarPlayTurnMachine().after([.open(.blocked, agent), .announce(1, blocked)])
        #expect(machine.handle(.answer) == [.answer(blocked)])
        #expect(machine.handle(.answer).isEmpty)
        #expect(machine.handle(.sendCorrection).isEmpty)
        #expect(machine.pendingText == nil)
    }

    @Test func answeredPromptStaysClaimedUntilReplacementSpeechCompletes() {
        var machine = awaiting()
        #expect(machine.handle(.answer) == [.answer(blocked)])
        #expect(machine.handle(.replaceStep).isEmpty)
        #expect(machine.handle(.announce(2, blocked)).isEmpty)
        #expect(machine.state == .rechecking(.init(template: 1, step: 2, agent: agent), blocked))
        #expect(machine.handle(.answer).isEmpty)
        #expect(machine.handle(.spoken(1)).isEmpty)
        #expect(machine.handle(.spoken(2)).isEmpty)
        #expect(machine.handle(.answer) == [.answer(blocked)])
    }

    @Test func correctionIsConsumedBeforeDispatchAndNeverSalvagedAfterClaim() {
        var machine = awaiting()
        #expect(machine.handle(.correction(1, "use pnpm")).isEmpty)
        #expect(machine.pendingText == "use pnpm")
        #expect(machine.handle(.finish(1)).isEmpty)
        #expect(machine.pendingText == "use pnpm")
        #expect(machine.handle(.sendCorrection) == [.correct(blocked, "use pnpm")])
        #expect(machine.pendingText == nil)
        #expect(machine.handle(.sendCorrection).isEmpty)
        #expect(machine.handle(.close) == [.closed])
    }

    @Test func closeReplacementAndCancelSalvageOnlyUnsentWords() {
        for event in [CarPlayTurnMachine.Event.close, .open(.briefing, nil), .draft, .disappeared(1)] {
            var machine = awaiting().after([.correction(1, "use pnpm")])
            let effects = machine.handle(event)
            #expect(effects.contains(.draft(agent, "use pnpm")))
            #expect(machine.pendingText == nil)
            #expect(!machine.handle(.close).contains(.draft(agent, "use pnpm")))
        }
    }

    @Test func heldAndActedTurnsDoNotPermitAnotherAction() {
        var held = awaiting()
        #expect(held.handle(.hold) == [.held])
        #expect(held.handle(.hold).isEmpty)
        #expect(held.handle(.answer).isEmpty)
        var finishing = awaiting().after([.answer])
        #expect(finishing.handle(.finish(1)).isEmpty)
        #expect(finishing.state == .finishing(.init(template: 1, step: 1, agent: agent), answerable: nil))
        #expect(finishing.handle(.answer).isEmpty)
    }

    @Test func anUnclaimedPromptStillAcceptsDenyDuringItsFinalDwell() {
        var machine = awaiting()
        #expect(machine.handle(.finish(1)).isEmpty)
        #expect(machine.state == .finishing(.init(template: 1, step: 1, agent: agent), answerable: blocked))
        #expect(machine.handle(.answer) == [.answer(blocked)])
        #expect(machine.handle(.answer).isEmpty)
        var drafted = awaiting().after([.correction(1, "words"), .draft])
        #expect(drafted.handle(.hold) == [.held])
    }

    @Test func templateAndStepIdentityFenceAllSuspendedWork() {
        var machine = awaiting().after([.replaceStep])
        #expect(machine.turn?.template == 1)
        #expect(machine.turn?.step == 2)
        #expect(machine.handle(.checkpoint(1)).isEmpty)
        #expect(machine.handle(.checkpoint(2)) == [.proceed])
        #expect(machine.handle(.correction(1, "old words")).isEmpty)
        #expect(machine.handle(.finish(1)).isEmpty)
        #expect(machine.handle(.announce(1, blocked)).isEmpty)
        #expect(machine.handle(.open(.conversation, agent)).isEmpty)
        #expect(machine.turn?.template == 3)
        #expect(machine.handle(.disappeared(1)).isEmpty)
        #expect(machine.handle(.checkpoint(2)).isEmpty)
        #expect(machine.handle(.disappeared(3)) == [.closed])
    }

    @Test func unrelatedEventsAreIgnoredWithoutAnAnswerablePrompt() {
        for setup in [
            [CarPlayTurnMachine.Event](), [.open(.briefing, nil)],
            [.open(.conversation, agent)], [.open(.blocked, agent)],
        ] {
            var machine = CarPlayTurnMachine().after(setup)
            #expect(machine.handle([
                .answer, .sendCorrection, .draft, .spoken(99), .announce(99, blocked),
                .correction(99, "stale"), .finish(99), .disappeared(99),
            ]).isEmpty)
        }
    }

    @Test func denyAndHoldCanConsumeAnUnsentCorrection() {
        var denying = awaiting().after([.correction(1, "correction")])
        #expect(denying.handle(.answer) == [.answer(blocked)])
        #expect(denying.handle(.close) == [.closed])
        var holding = awaiting().after([.correction(1, "correction")])
        #expect(holding.handle(.hold) == [.held])
        #expect(holding.handle(.close) == [.closed])
        var checking = CarPlayTurnMachine().after([.open(.blocked, agent)])
        #expect(checking.handle(.hold) == [.held])
    }

    @Test func everyActiveStageCanReplaceItsStepAndFinish() {
        let setups: [[CarPlayTurnMachine.Event]] = [
            [.open(.briefing, nil)], [.open(.conversation, agent)], [.open(.blocked, agent)],
            [.open(.blocked, agent), .announce(1, blocked)],
            [.open(.blocked, agent), .announce(1, blocked), .spoken(1)],
            [.open(.blocked, agent), .announce(1, blocked), .answer],
            [.open(.blocked, agent), .announce(1, blocked), .answer, .announce(1, blocked)],
            [.open(.blocked, agent), .finish(1)],
        ]
        for setup in setups {
            var machine = CarPlayTurnMachine().after(setup)
            #expect(machine.handle(.replaceStep).isEmpty)
            #expect(machine.turn?.step == 2)
            #expect(machine.turn?.template == 1)
            #expect(machine.handle(.finish(1)).isEmpty)
            #expect(machine.handle(.finish(2)).isEmpty)
            if case .finishing(let turn, _) = machine.state {
                #expect(turn.template == 1)
                #expect(turn.step == 2)
            } else {
                Issue.record("The active stage did not finish")
            }
        }
    }

    @Test func awaitingAndConfirmingPromptsCanBeReannouncedOrDenied() {
        for correction in [false, true] {
            var machine = awaiting()
            if correction { _ = machine.handle(.correction(1, "correction")) }
            #expect(machine.handle(.announce(1, blocked)).isEmpty)
            #expect(machine.state == .checking(.init(template: 1, step: 1, agent: agent), blocked))
            #expect(machine.handle(.spoken(1)).isEmpty)
            #expect(machine.handle(.answer) == [.answer(blocked)])
        }
    }
}
