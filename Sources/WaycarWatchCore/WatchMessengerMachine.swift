import Foundation

/// Effects for one outbox message. The outbox remains the authority on
/// delivery phases; this machine owns attempt/timer identity and recording
/// retention, including uncertain outcomes that may later become definite.
struct WatchMessengerMachine: StateMachine {
    struct Resources: Equatable, Sendable {
        var recording: URL?
        var attempt: UInt64?
    }
    enum State: Equatable, Sendable {
        case queued(Resources)
        case awaitingAck(Resources)
        case awaitingOutcome(Resources, timer: UInt64?)
        case uncertain(Resources)
        case retryable(Resources)
        case settled
    }
    enum Event: Equatable, Sendable {
        case deliver
        case acknowledged(UInt64)
        case ackFailed(UInt64, reason: String, cancelTransfer: Bool)
        case transferFailed(UInt64)
        case phase(WatchOutgoing.Phase)
        case seed(WatchOutgoing.Phase)
        case restartTimer
        case timerElapsed(UInt64)
        case settle
    }
    enum Effect: Equatable, Sendable {
        case deliver(UInt64, recording: URL?)
        case acknowledged
        case ackFailed(String)
        case transferFailed
        case timedOut
        case armTimer(UInt64)
        case stopTimer
        case forgetAttempt
        case cancelTransfer
        case deleteRecording(URL)
    }
    private(set) var state: State
    private var lastToken: UInt64 = 0
    init(recording: URL?) { state = .queued(Resources(recording: recording, attempt: nil)) }

    private var resources: Resources {
        switch state {
        case .queued(let resources), .awaitingAck(let resources), .awaitingOutcome(let resources, _),
             .uncertain(let resources), .retryable(let resources): resources
        case .settled: Resources(recording: nil, attempt: nil)
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.settled, _): return []
        case (.queued, .deliver), (.awaitingAck, .deliver):
            lastToken += 1
            var next = resources
            next.attempt = lastToken
            state = .awaitingAck(next)
            return [.deliver(lastToken, recording: next.recording)]
        case (_, .acknowledged(let token)):
            guard resources.attempt == token else { return [] }
            return [.acknowledged]
        case (_, .ackFailed(let token, let reason, let cancelTransfer)):
            guard resources.attempt == token else { return [] }
            clearAttempt()
            return (cancelTransfer ? [.cancelTransfer] : []) + [.forgetAttempt, .ackFailed(reason)]
        case (_, .transferFailed(let token)):
            guard resources.attempt == token else { return [] }
            return [.transferFailed]
        case (_, .phase(let phase)):
            return move(to: phase, armTimer: true)
        case (_, .seed(let phase)):
            return move(to: phase, armTimer: false)
        case (.awaitingOutcome, .restartTimer):
            return arm(resources)
        case (.awaitingOutcome(let resources, let timer), .timerElapsed(let token)):
            guard timer == token else { return [] }
            state = .uncertain(resources)
            return [.timedOut]
        case (_, .settle):
            let recording = resources.recording
            state = .settled
            return [.stopTimer, .forgetAttempt] + (recording.map { [.cancelTransfer, .deleteRecording($0)] } ?? [])
        case (.queued, _), (.awaitingAck, _), (.awaitingOutcome, _), (.uncertain, _), (.retryable, _): return []
        }
    }

    private mutating func move(to phase: WatchOutgoing.Phase, armTimer: Bool) -> [Effect] {
        let next = resources
        switch phase {
        case .sending:
            state = .queued(next)
            return []
        case .transcribing, .delivering:
            if armTimer { return arm(next) }
            state = .awaitingOutcome(next, timer: nil)
            return []
        case .notSent:
            state = .retryable(next)
            return [.stopTimer]
        case .unknown:
            state = .uncertain(next)
            return [.stopTimer]
        case .sent, .keptAsDraft, .noWords: return handle(.settle)
        }
    }
    private mutating func arm(_ resources: Resources) -> [Effect] {
        lastToken += 1
        state = .awaitingOutcome(resources, timer: lastToken)
        return [.stopTimer, .armTimer(lastToken)]
    }
    private mutating func clearAttempt() {
        var next = resources
        next.attempt = nil
        switch state {
        case .queued: state = .queued(next)
        case .awaitingAck: state = .awaitingAck(next)
        case .awaitingOutcome(_, let timer): state = .awaitingOutcome(next, timer: timer)
        case .uncertain: state = .uncertain(next)
        case .retryable: state = .retryable(next)
        case .settled: break
        }
    }
}
