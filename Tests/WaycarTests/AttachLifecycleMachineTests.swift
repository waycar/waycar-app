import Testing

@testable import Waycar

@Suite("Attach lifecycle machine")
struct AttachLifecycleMachineTests {
    private typealias Machine = AttachLifecycleMachine
    private let pipeline = TerminalSurfaceID()
    private let other = TerminalSurfaceID()

    private func activated(
        _ machine: inout Machine, afterSuspension: Bool = true, onStage: Bool = true,
        latchActive: Bool = false, pipeline: TerminalSurfaceID? = nil, runsMosh: Bool = false
    ) -> [Machine.Effect] {
        machine.handle(.activated(
            afterPossibleSuspension: afterSuspension, onStage: onStage, latchActive: latchActive,
            pipeline: pipeline ?? self.pipeline, runsMosh: runsMosh))
    }

    @Test func aShortBounceRepaintsAndAnOffStageOrLeftScreenIgnoresActivation() {
        var machine = Machine()
        #expect(activated(&machine, afterSuspension: false) == [.repaint])
        #expect(activated(&machine, onStage: false).isEmpty)
        _ = machine.handle(.leaveRequested(preservingActivationRecovery: false, onStage: true))
        #expect(activated(&machine).isEmpty)
    }

    @Test func aReturnChoosesFollowCheckOrReplace() {
        var intent = Machine().after([.intentStarted(pipeline)])
        #expect(activated(&intent) == [.beginTrace, .followIntentPipeline])
        #expect(intent.state.unseenIntentPipeline == nil)
        #expect(activated(&intent) == [.beginTrace, .recover], "the intent pipeline is seen once")
        var mosh = Machine()
        #expect(activated(&mosh, runsMosh: true) == [.beginTrace, .checkMosh(1)])
        var stale = Machine().after([.intentStarted(other)])
        #expect(activated(&stale) == [.beginTrace, .recover])
    }

    @Test func aReturnARecoveryServesClaimsTheOnStageLifecycle() {
        var latched = Machine()
        #expect(activated(&latched, latchActive: true).isEmpty)
        #expect(latched.state.activationOwnsOnStage)
        var owned = Machine().after([.replacementRequested(ownsOnStageLifecycle: false)])
        #expect(activated(&owned) == [.beginTrace, .beginLatch])
        #expect(owned.state.activationOwnsOnStage)
        #expect(owned.handle(.leaveRequested(preservingActivationRecovery: true, onStage: true))
            == [.returnPendingTransition])
        #expect(owned.handle(.leaveRequested(preservingActivationRecovery: false, onStage: true)).contains(.tearDown))
    }

    @Test func onlyTheNewestContactCheckDecides() {
        var machine = Machine()
        _ = activated(&machine, runsMosh: true)
        _ = activated(&machine, runsMosh: true)
        let answer: (UInt64, Bool) -> Machine.Event = { token, heard in
            .contactAnswered(
                token, taskCancelled: false, samePipeline: true, onStage: true,
                heard: heard, runsMosh: true, latchActive: false, connecting: false)
        }
        #expect(machine.handle(answer(1, false)).isEmpty)
        #expect(machine.handle(answer(2, true)) == [.clearContactCheck, .abortTrace, .keepMoshSession])
        #expect(machine.handle(answer(2, false)).isEmpty)
    }

    @Test func anUnheardServerIsReplacedUnlessARecoveryRunsOrItReattaches() {
        func check(recovering: Bool = false, latchActive: Bool = false, runsMosh: Bool, connecting: Bool)
            -> [Machine.Effect]
        {
            var machine = Machine()
            _ = machine.handle(.activated(
                afterPossibleSuspension: true, onStage: true, latchActive: false,
                pipeline: pipeline, runsMosh: true))
            if recovering { _ = machine.handle(.replacementRequested(ownsOnStageLifecycle: false)) }
            return machine.handle(.contactAnswered(
                1, taskCancelled: false, samePipeline: true, onStage: true,
                heard: false, runsMosh: runsMosh, latchActive: latchActive, connecting: connecting))
        }
        #expect(check(runsMosh: true, connecting: false) == [.clearContactCheck, .recover])
        #expect(check(runsMosh: false, connecting: false) == [.clearContactCheck, .recover])
        #expect(check(runsMosh: false, connecting: true) == [.clearContactCheck])
        #expect(check(latchActive: true, runsMosh: true, connecting: false) == [.clearContactCheck])
        #expect(check(recovering: true, runsMosh: true, connecting: false) == [.clearContactCheck])
    }

    @Test func aRecoveryOrRejoinOwnsPresentationUntilItsOwnFinish() {
        var machine = Machine()
        #expect(machine.handle(.replacementRequested(ownsOnStageLifecycle: true)) == [.ownRecovery(1)])
        #expect(machine.handle(.replacementRequested(ownsOnStageLifecycle: false)) == [.ownRecovery(2)])
        #expect(machine.state.activationOwnsOnStage, "a later replacement keeps the claim")
        #expect(machine.handle(.recoveryFinished(1)).isEmpty)
        #expect(machine.ownsRecovery(2))
        #expect(machine.handle(.recoveryFinished(2)) == [.publishRecoveryOwner(nil)])
        #expect(!machine.state.activationOwnsOnStage)
    }

    @Test func anOffStageAbortRequiresAFullRejoin() {
        var machine = Machine().after([.replacementRequested(ownsOnStageLifecycle: false)])
        #expect(machine.handle(.abortOffStage(1, onStage: true)).isEmpty)
        #expect(machine.handle(.abortOffStage(9, onStage: false)).isEmpty)
        #expect(machine.handle(.abortOffStage(1, onStage: false)) == [
            .publishLifecycle(.rejoinRequired), .abortTrace, .clearLatch, .publishRecoveryOwner(nil),
        ])
        #expect(machine.handle(.rejoinRequested(onStage: false)).isEmpty)
        #expect(machine.handle(.rejoinRequested(onStage: true)) == [
            .clearLatch, .publishLifecycle(.active), .ownRecovery(2),
            .enqueueRejoin(2, requiresFullReplacement: true),
        ])
        #expect(machine.handle(.rejoinRequested(onStage: true)) == [.resumeTrayAfterRetention])
    }

    @Test func theRejoinGateFinishesAfterALeaveAndAbortsOffStage() {
        var machine = Machine().after([
            .leaveRequested(preservingActivationRecovery: false, onStage: true),
            .rejoinRequested(onStage: true),
        ])
        #expect(machine.state.lifecycle == .active)
        #expect(machine.handle(.rejoinGate(1, onStage: true)) == [.proceed])
        var offStage = machine
        #expect(offStage.handle(.rejoinGate(1, onStage: false)) == [
            .publishLifecycle(.rejoinRequired), .abortTrace, .clearLatch, .publishRecoveryOwner(nil),
        ])
        _ = machine.handle(.leaveRequested(preservingActivationRecovery: false, onStage: true))
        #expect(machine.handle(.rejoinGate(1, onStage: true)).isEmpty, "the leave already took ownership")
    }

    @Test func aLeaveTearsDownOnceAndForgetsEverything() {
        var machine = Machine().after([
            .intentStarted(pipeline), .replacementRequested(ownsOnStageLifecycle: false),
        ])
        #expect(machine.handle(.leaveRequested(preservingActivationRecovery: true, onStage: true)) == [
            .abortTrace, .publishLifecycle(.left), .publishRecoveryOwner(nil), .clearLatch,
            .cancelContactCheck, .tearDown,
        ])
        #expect(machine.state == Machine.State(lifecycle: .left))
        #expect(machine.handle(.leaveRequested(preservingActivationRecovery: false, onStage: true))
            == [.returnPendingTransition])
        #expect(machine.handle(.recoveryFinished(1)).isEmpty)
    }

    @Test func theQueueTailClearsOnlyForTheLatestTransition() {
        var machine = Machine()
        #expect(machine.handle(.transitionEnqueued) == [.transitionToken(1)])
        #expect(machine.handle(.transitionEnqueued) == [.transitionToken(2)])
        #expect(machine.handle(.transitionEnded(1)).isEmpty)
        #expect(machine.handle(.transitionEnded(2)) == [.clearTransition])
        #expect(machine.handle(.transitionEnded(2)).isEmpty)
    }
}
