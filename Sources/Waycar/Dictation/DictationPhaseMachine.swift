/// The store's session identity and visible phases. Cancelling retains its
/// current presentation until the stream ends; finishing suppresses queued
/// microphone/progress events but still accepts the recognizer's last words.
struct DictationPhaseMachine: StateMachine {
    struct Capture: Equatable, Sendable {
        let token: UInt64
        var level: Float = 0
    }

    enum ActivePhase: Equatable, Sendable {
        case starting, downloading(Double), listening, finishing
    }

    enum State: Equatable, Sendable {
        case idle(DictationStore.Failure?)
        case starting(Capture)
        case downloading(Capture, fraction: Double)
        case listening(Capture)
        case finishing(Capture)
        case cancelling(Capture, showing: ActivePhase)
    }

    enum Event: Equatable, Sendable {
        case start
        case engine(UInt64, DictationEvent)
        case stop
        case cancel
        case ended(UInt64, DictationStore.Failure?)
        case dismissFailure
    }

    enum Effect: Equatable, Sendable {
        case start(UInt64)
        case finish(UInt64)
        case cancel(UInt64)
        case transcript(UInt64, String, isFinal: Bool)
        case end(UInt64)
    }

    private(set) var state: State = .idle(nil)
    private var lastToken: UInt64 = 0

    private var capture: Capture? {
        switch state {
        case .idle: nil
        case .starting(let value), .downloading(let value, _), .listening(let value),
            .finishing(let value), .cancelling(let value, _): value
        }
    }

    var token: UInt64? { capture?.token }
    var level: Float { capture?.level ?? 0 }
    var failure: DictationStore.Failure? {
        if case .idle(let failure) = state { failure } else { nil }
    }

    private var activePhase: ActivePhase? {
        switch state {
        case .idle: nil
        case .starting: .starting
        case .downloading(_, let fraction): .downloading(fraction)
        case .listening: .listening
        case .finishing: .finishing
        case .cancelling(_, let phase): phase
        }
    }

    var phase: DictationStore.Phase {
        switch activePhase {
        case nil: .idle
        case .starting: .starting
        case .downloading(let fraction): .downloadingModel(fraction: fraction)
        case .listening: .listening
        case .finishing: .finishing
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .start):
            lastToken += 1
            state = .starting(Capture(token: lastToken))
            return [.start(lastToken)]
        case (_, .engine(let token, let event)):
            guard var capture, capture.token == token, var phase = activePhase else { return [] }
            switch event {
            case .transcript(let text, let isFinal):
                return [.transcript(token, text, isFinal: isFinal)]
            case .downloadingModel(let fraction):
                guard phase != .finishing else { return [] }
                phase = .downloading(fraction)
            case .listening:
                guard phase != .finishing else { return [] }
                phase = .listening
            case .level(let level):
                guard phase != .finishing else { return [] }
                capture.level = level
            }
            set(capture, phase: phase)
            return []
        case (_, .stop):
            guard var capture, let phase = activePhase else { return [] }
            switch phase {
            case .starting, .downloading:
                state = .cancelling(capture, showing: phase)
                return [.cancel(capture.token)]
            case .listening:
                capture.level = 0
                set(capture, phase: .finishing)
                return [.finish(capture.token)]
            case .finishing:
                return []
            }
        case (_, .cancel):
            guard let capture, let phase = activePhase else { return [] }
            state = .cancelling(capture, showing: phase)
            return [.cancel(capture.token)]
        case (_, .ended(let token, let failure)):
            guard capture?.token == token else { return [] }
            state = .idle(failure)
            return [.end(token)]
        case (.idle, .dismissFailure):
            state = .idle(nil)
            return []
        case (.starting, _), (.downloading, _), (.listening, _), (.finishing, _),
            (.cancelling, _):
            return []
        }
    }

    private mutating func set(_ capture: Capture, phase: ActivePhase) {
        if case .cancelling = state {
            state = .cancelling(capture, showing: phase)
            return
        }
        switch phase {
        case .starting: state = .starting(capture)
        case .downloading(let fraction): state = .downloading(capture, fraction: fraction)
        case .listening: state = .listening(capture)
        case .finishing: state = .finishing(capture)
        }
    }
}
