/// The Agent Attach's lifecycle (``AgentAttachStore``): whether the screen
/// is active, must rejoin with a full replacement, or has left; which
/// queued terminal transition owns recovery presentation; and the
/// foreground return's choice between a repaint, following the pipeline
/// started at intent, a mosh contact check and a full replacement.
///
/// Rules a reader needs:
/// - Recovery ownership is a token. A replacement or rejoin takes it
///   synchronously, so the screen shows recovery during the predecessor's
///   stop; only the transition that still owns it may publish its pipeline,
///   finish recovery, or turn an off-stage abort into `rejoinRequired`.
/// - A transition that turns unwanted finishes its recovery on stage and
///   aborts it off stage: an off-stage abort leaves the screen needing a
///   full replacement when it comes back.
/// - A possible-suspension return that a recovery already serves claims the
///   on-stage lifecycle, so a delayed on-stage leave cannot tear it down
///   (only a deliberate handoff leave does).
/// - A mosh contact check answers only under its own token: a newer return
///   or a leave supersedes it. A heard server keeps the session; an unheard
///   one is replaced (abandoning its predecessor) unless a recovery already
///   runs or the session is reattaching on its own.
/// - Lifecycle transitions run in order; the queue's tail clears only when
///   its latest transition ends.
struct AttachLifecycleMachine: StateMachine {
    enum Lifecycle: Equatable, Sendable {
        case active
        /// A recovery became invalid off stage before SwiftUI delivered the
        /// real leave: the next appearance needs a full replacement.
        case rejoinRequired
        case left
    }

    struct State: Equatable, Sendable {
        var lifecycle = Lifecycle.active
        /// The transition that owns recovery presentation.
        var recoveryOwner: UInt64?
        /// A possible-suspension return claimed the on-stage lifecycle.
        var activationOwnsOnStage = false
        /// The pipeline `startAtIntent()` started that no activation has
        /// looked at yet.
        var unseenIntentPipeline: TerminalSurfaceID?
        /// The mosh contact check in flight.
        var contactCheck: UInt64?
        /// The latest queued lifecycle transition, until it ends.
        var transition: UInt64?
    }

    enum Event: Equatable, Sendable {
        case intentStarted(TerminalSurfaceID)
        case activated(
            afterPossibleSuspension: Bool, onStage: Bool, latchActive: Bool,
            pipeline: TerminalSurfaceID, runsMosh: Bool)
        case contactAnswered(
            UInt64, taskCancelled: Bool, samePipeline: Bool, onStage: Bool,
            heard: Bool, runsMosh: Bool, latchActive: Bool, connecting: Bool)
        /// A replacement passed its wanted check and is queued.
        case replacementRequested(ownsOnStageLifecycle: Bool)
        /// A transition turned unwanted off stage.
        case abortOffStage(UInt64, onStage: Bool)
        case recoveryFinished(UInt64)
        case rejoinRequested(onStage: Bool)
        /// The rejoin transition's checks: still active, still on stage.
        case rejoinGate(UInt64, onStage: Bool)
        case leaveRequested(preservingActivationRecovery: Bool, onStage: Bool)
        case transitionEnqueued
        case transitionEnded(UInt64)
    }

    enum Effect: Equatable, Sendable {
        /// Ask the live terminal to repaint (a short bounce).
        case repaint
        /// DEBUG: start the pending foreground-recovery trace.
        case beginTrace
        /// DEBUG: the pending foreground-recovery trace is abandoned.
        case abortTrace
        case beginLatch
        case clearLatch
        case followIntentPipeline
        /// Cancel the check in hand and start one under `token`.
        case checkMosh(UInt64)
        case cancelContactCheck
        case clearContactCheck
        /// The heard mosh session stays: ask it to repaint.
        case keepMoshSession
        /// Detach input, begin the recovery latch and replace the whole
        /// pipeline, abandoning the predecessor.
        case recover
        case publishLifecycle(Lifecycle)
        case publishRecoveryOwner(UInt64?)
        /// A queued transition takes recovery ownership under the token.
        case ownRecovery(UInt64)
        case enqueueRejoin(UInt64, requiresFullReplacement: Bool)
        case resumeTrayAfterRetention
        case proceed
        /// Hand back the pending transition instead of leaving again.
        case returnPendingTransition
        case tearDown
        case transitionToken(UInt64)
        case clearTransition
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var isActive: Bool { state.lifecycle == .active }
    var lifecycle: Lifecycle { state.lifecycle }

    func ownsRecovery(_ token: UInt64) -> Bool { state.recoveryOwner == token }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .intentStarted(let pipeline):
            state.unseenIntentPipeline = pipeline
            return []
        case .activated(let afterSuspension, let onStage, let latchActive, let pipeline, let runsMosh):
            guard isActive, onStage else { return [] }
            let intent = state.unseenIntentPipeline
            state.unseenIntentPipeline = nil
            guard afterSuspension else { return [.repaint] }
            var effects: [Effect] = latchActive ? [] : [.beginTrace]
            if latchActive {
                state.activationOwnsOnStage = true
                return effects
            }
            if state.recoveryOwner != nil {
                state.activationOwnsOnStage = true
                return effects + [.beginLatch]
            }
            if intent == pipeline { return effects + [.followIntentPipeline] }
            if runsMosh {
                let token = nextToken()
                state.contactCheck = token
                effects.append(.checkMosh(token))
                return effects
            }
            return effects + [.recover]
        case .contactAnswered(
            let token, let taskCancelled, let samePipeline, let onStage,
            let heard, let runsMosh, let latchActive, let connecting):
            guard !taskCancelled, state.contactCheck == token, samePipeline, isActive, onStage
            else { return [] }
            state.contactCheck = nil
            if heard, runsMosh { return [.clearContactCheck, .abortTrace, .keepMoshSession] }
            // A session that failed meanwhile and is already reattaching on
            // its own (a lost link) needs no second replacement.
            guard state.recoveryOwner == nil, !latchActive, runsMosh || !connecting
            else { return [.clearContactCheck] }
            return [.clearContactCheck, .recover]
        case .replacementRequested(let ownsOnStage):
            let token = nextToken()
            state.recoveryOwner = token
            state.activationOwnsOnStage = state.activationOwnsOnStage || ownsOnStage
            return [.ownRecovery(token)]
        case .abortOffStage(let token, let onStage):
            return abortOffStage(token, onStage: onStage)
        case .recoveryFinished(let token):
            return finishRecovery(token)
        case .rejoinRequested(let onStage):
            guard !isActive else { return [.resumeTrayAfterRetention] }
            guard onStage else { return [] }
            let requiresFull = state.lifecycle == .rejoinRequired
            state.lifecycle = .active
            let token = nextToken()
            state.recoveryOwner = token
            return [
                .clearLatch, .publishLifecycle(.active), .ownRecovery(token),
                .enqueueRejoin(token, requiresFullReplacement: requiresFull),
            ]
        case .rejoinGate(let token, let onStage):
            guard isActive else { return finishRecovery(token) }
            guard onStage else { return abortOffStage(token, onStage: onStage) }
            return [.proceed]
        case .leaveRequested(let preserving, let onStage):
            guard state.lifecycle != .left else { return [.returnPendingTransition] }
            if preserving, isActive, state.activationOwnsOnStage, state.recoveryOwner != nil, onStage {
                return [.returnPendingTransition]
            }
            state.lifecycle = .left
            state.recoveryOwner = nil
            state.activationOwnsOnStage = false
            state.contactCheck = nil
            state.unseenIntentPipeline = nil
            return [
                .abortTrace, .publishLifecycle(.left), .publishRecoveryOwner(nil), .clearLatch,
                .cancelContactCheck, .tearDown,
            ]
        case .transitionEnqueued:
            let token = nextToken()
            state.transition = token
            return [.transitionToken(token)]
        case .transitionEnded(let token):
            guard state.transition == token else { return [] }
            state.transition = nil
            return [.clearTransition]
        }
    }

    private mutating func finishRecovery(_ token: UInt64) -> [Effect] {
        guard state.recoveryOwner == token else { return [] }
        state.recoveryOwner = nil
        state.activationOwnsOnStage = false
        return [.publishRecoveryOwner(nil)]
    }

    /// Only the transition that still owns recovery may change this state;
    /// a stale operation must not turn a newer on-stage transition back into
    /// a leave.
    private mutating func abortOffStage(_ token: UInt64, onStage: Bool) -> [Effect] {
        guard state.recoveryOwner == token, isActive, !onStage else { return [] }
        state.lifecycle = .rejoinRequired
        return [.publishLifecycle(.rejoinRequired), .abortTrace, .clearLatch] + finishRecovery(token)
    }

    private mutating func nextToken() -> UInt64 {
        lastToken += 1
        return lastToken
    }
}
