import Testing

@testable import Waycar

/// `TmuxPromptDeliveryMachine`: one prompt's paste, Enter and turn hand-off.
@Suite("tmux prompt delivery machine")
struct TmuxPromptDeliveryMachineTests {
    typealias Machine = TmuxPromptDeliveryMachine

    static func read(
        hook: AgentStatus? = .idle, reported: AgentStatus? = .idle, screen: AgentStatus? = nil,
        draft: Bool = true
    ) -> Machine.EnterRead {
        Machine.EnterRead(
            hookStatus: hook, reportedStatus: reported, screenStatus: screen, draftAwaitsEnter: draft)
    }

    private let awaiting = Machine().after([.typed(entersAfterGap: true)])

    @Test func onlyADraftToAKindWithADelayEntersAfterTheGap() {
        #expect(Machine.entersAfterGap(hasDraft: true, submitDelay: .milliseconds(500)))
        #expect(!Machine.entersAfterGap(hasDraft: false, submitDelay: .milliseconds(500)))
        #expect(!Machine.entersAfterGap(hasDraft: true, submitDelay: .zero))
    }

    @Test func aLineWithItsEnterIsSubmittedAndHandsTheTurnOn() {
        var machine = Machine()
        #expect(machine.handle(.typed(entersAfterGap: false)) == [.releaseTurn])
        #expect(machine.state == .ended(.submitted))
    }

    @Test func aFailureBeforeTheLineIsAnsweredHandsTheTurnOn() {
        var machine = Machine()
        #expect(machine.handle(.failed) == [.releaseTurn])
        #expect(machine.state == .ended(.failed))
    }

    @Test func aPasteWithoutItsEnterHandsTheTurnToTheDelayedEnter() {
        var machine = Machine()
        #expect(machine.handle(.typed(entersAfterGap: true)) == [.awaitEnter])
        #expect(machine.state == .awaitingEnter)
    }

    @Test func aReadShowingTheDraftWaitingSendsTheEnter() {
        var machine = awaiting
        #expect(machine.handle(.read(Self.read())) == [.sendEnter])
        #expect(machine.state == .entering)
        #expect(machine.handle(.entered) == [.releaseTurn])
        #expect(machine.state == .ended(.submitted))
    }

    @Test(arguments: [
        TmuxPromptDeliveryMachineTests.read(hook: .blocked),
        TmuxPromptDeliveryMachineTests.read(reported: .blocked),
        TmuxPromptDeliveryMachineTests.read(screen: .blocked),
        TmuxPromptDeliveryMachineTests.read(draft: false),
    ])
    func anythingBlockedOrNoDraftSkipsTheEnter(read: Machine.EnterRead) {
        var machine = awaiting
        #expect(machine.handle(.read(read)) == [.releaseTurn, .refuseUnsubmitted])
        #expect(machine.state == .ended(.typedUnsubmitted))
    }

    @Test func aFailedReadOrEnterHandsTheTurnOn() {
        var reading = awaiting
        #expect(reading.handle(.failed) == [.releaseTurn])
        #expect(reading.state == .ended(.failed))
        var entering = awaiting.after([.read(Self.read())])
        #expect(entering.handle(.failed) == [.releaseTurn])
        #expect(entering.state == .ended(.failed))
    }

    @Test func theTurnIsHandedOnOnlyOnce() {
        for ended in [
            Machine().after([.typed(entersAfterGap: false)]), Machine().after([.failed]),
            awaiting.after([.read(Self.read(draft: false))]),
            awaiting.after([.read(Self.read()), .entered]),
        ] {
            var machine = ended
            #expect(machine.handle(.failed).isEmpty)
            #expect(machine.handle(.entered).isEmpty)
            #expect(machine.handle(.read(Self.read())).isEmpty)
            #expect(machine.handle(.typed(entersAfterGap: false)).isEmpty)
            #expect(machine.state == ended.state)
        }
    }

    @Test func outOfOrderEventsAreIgnored() {
        var delivering = Machine()
        #expect(delivering.handle(.read(Self.read())).isEmpty)
        #expect(delivering.handle(.entered).isEmpty)
        #expect(delivering.state == .delivering)
        var waiting = awaiting
        #expect(waiting.handle(.typed(entersAfterGap: true)).isEmpty)
        #expect(waiting.handle(.entered).isEmpty)
        #expect(waiting.state == .awaitingEnter)
        var entering = awaiting.after([.read(Self.read())])
        #expect(entering.handle(.typed(entersAfterGap: false)).isEmpty)
        #expect(entering.handle(.read(Self.read())).isEmpty)
        #expect(entering.state == .entering)
    }
}
