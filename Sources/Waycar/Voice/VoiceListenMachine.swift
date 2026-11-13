import Foundation

/// One listen's microphone startup, endpointing and final transcript. A
/// session-local token scopes both tasks; startup timeout cancels the stream,
/// whereas ordinary endpointing finishes it so final words can still arrive.
struct VoiceListenMachine: StateMachine {
    struct Capture: Equatable, Sendable {
        var endpointer: Endpointer
        var finalized = ""
        var volatile = ""
        var heard: String { DictationComposition.join(finalized, volatile) }

        mutating func apply(_ event: DictationEvent, now: ContinuousClock.Instant) {
            switch event {
            case .listening: endpointer.listeningStarted(at: now)
            case .transcript(let text, let isFinal):
                let before = heard
                if isFinal {
                    finalized = DictationComposition.join(finalized, text)
                    volatile = ""
                } else { volatile = text }
                if heard != before, !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    endpointer.heardSpeech(at: now)
                }
            case .downloadingModel, .level: break
            }
        }
    }
    enum State: Equatable, Sendable {
        case starting(UInt64, Capture)
        case listeningQuiet(UInt64, Capture)
        case listeningSpeech(UInt64, Capture)
        case finalizing(UInt64, Capture, Endpointer.Reason)
        case ended(AgentVoiceService.ListenResult)
    }
    enum Event: Sendable {
        case engine(UInt64, DictationEvent, now: ContinuousClock.Instant)
        case tick(UInt64, now: ContinuousClock.Instant)
        case streamEnded(UInt64, failure: String?)
    }
    enum Effect: Equatable, Sendable {
        case cancelConsumer(UInt64)
        case finishEngine(UInt64)
    }
    private(set) var state: State
    /// Minted for this one-shot machine; a new listen owns a new machine.
    let token: UInt64 = 1

    private let startupFailure: String

    init(endpointer: Endpointer, startupFailure: String) {
        state = .starting(1, Capture(endpointer: endpointer))
        self.startupFailure = startupFailure
    }

    var result: AgentVoiceService.ListenResult? {
        if case .ended(let result) = state { result } else { nil }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        let current: UInt64
        var capture: Capture
        let reason: Endpointer.Reason?
        switch state {
        case .starting(let token, let value), .listeningQuiet(let token, let value),
             .listeningSpeech(let token, let value):
            current = token; capture = value; reason = nil
        case .finalizing(let token, let value, let finish):
            current = token; capture = value; reason = finish
        case .ended: return []
        }
        switch event {
        case .engine(let token, let event, let now) where token == current:
            capture.apply(event, now: now)
            if let reason { state = .finalizing(current, capture, reason) }
            else if capture.endpointer.listeningSince == nil { state = .starting(current, capture) }
            else if capture.endpointer.lastSpeechAt == nil { state = .listeningQuiet(current, capture) }
            else { state = .listeningSpeech(current, capture) }
            return []
        case .tick(let token, let now) where token == current:
            guard reason == nil, let finish = capture.endpointer.finishReason(now: now) else { return [] }
            state = .finalizing(current, capture, finish)
            return finish == .startup ? [.cancelConsumer(current), .finishEngine(current)] : [.finishEngine(current)]
        case .streamEnded(let token, let failure) where token == current:
            if reason == .startup { state = .ended(.failed(startupFailure)) }
            else if let failure { state = .ended(.failed(failure)) }
            else {
                let text = capture.heard.trimmingCharacters(in: .whitespacesAndNewlines)
                state = .ended(text.isEmpty ? .silence : .heard(text))
            }
            return []
        case .engine, .tick, .streamEnded: return []
        }
    }
}
