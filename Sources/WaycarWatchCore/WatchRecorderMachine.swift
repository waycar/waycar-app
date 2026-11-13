import Foundation

/// Permission, capture and outcome ownership. Audio objects and meter Tasks
/// stay in the watch owner; every delayed permission/sample carries a token.
struct WatchRecorderMachine: StateMachine {
    static let noSpeechCopy = "No speech heard"
    static let permissionCopy = "Turn on the microphone for Waycar in Settings."
    static let startFailedCopy = "Couldn't start recording."
    static let interruptedCopy = "Recording stopped. Nothing sent."

    enum Phase: Equatable, Sendable {
        case idle
        case requestingPermission
        case listening
        case paused(progress: Double)
        case finished(url: URL, duration: Double)
        case cancelled(String?)
    }
    enum State: Equatable, Sendable {
        case idle
        case requestingPermission(UInt64)
        case starting(UInt64)
        case recording(token: UInt64, progress: Double)
        case finished(URL, duration: Double)
        case cancelled(String?)
    }
    enum Event: Equatable, Sendable {
        case start
        case permission(UInt64, granted: Bool)
        case began(UInt64)
        case failed(UInt64)
        case sample(UInt64, SilenceDetector.Decision)
        case stop(URL, duration: Double)
        case cancel
        case interrupt
        /// DEBUG owner only: display a frozen recorder without opening audio.
        case demo(progress: Double)
    }
    enum Haptic: Equatable, Sendable { case start, stop, failure }
    enum Effect: Equatable, Sendable {
        case requestPermission(UInt64)
        case begin(UInt64)
        case meter(UInt64)
        case stop
        case teardown(delete: Bool)
        case stopObservingInterruptions
        case haptic(Haptic)
    }
    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0
    var phase: Phase {
        switch state {
        case .idle: .idle
        case .requestingPermission, .starting: .requestingPermission
        case .recording(_, let progress): progress > 0 ? .paused(progress: progress) : .listening
        case .finished(let url, let duration): .finished(url: url, duration: duration)
        case .cancelled(let reason): .cancelled(reason)
        }
    }
    var isRecording: Bool { if case .recording = state { true } else { false } }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .start), (.requestingPermission, .start), (.finished, .start), (.cancelled, .start):
            lastToken += 1
            state = .requestingPermission(lastToken)
            return [.requestPermission(lastToken)]
        case (.requestingPermission(let token), .permission(let completed, let granted)):
            guard token == completed else { return [] }
            guard granted else {
                state = .cancelled(Self.permissionCopy)
                return [.stopObservingInterruptions, .haptic(.failure)]
            }
            state = .starting(token)
            return [.haptic(.start), .begin(token)]
        case (.starting(let token), .began(let completed)):
            guard token == completed else { return [] }
            state = .recording(token: token, progress: 0)
            return [.meter(token)]
        case (.starting(let token), .failed(let completed)):
            guard token == completed else { return [] }
            return cancel(Self.startFailedCopy, haptic: true)
        case (.recording(let token, _), .sample(let completed, let decision)):
            guard token == completed else { return [] }
            switch decision {
            case .listening(let progress):
                state = .recording(token: token, progress: progress)
                return []
            case .stop(.noSpeech): return cancel(Self.noSpeechCopy, haptic: true)
            case .stop(.silence), .stop(.maximumDuration): return [.stop]
            }
        case (.recording, .stop(let url, let duration)):
            state = .finished(url, duration: duration)
            return [.teardown(delete: false), .haptic(.stop)]
        case (.recording, .interrupt), (.requestingPermission, .interrupt), (.starting, .interrupt):
            return cancel(Self.interruptedCopy, haptic: true)
        case (_, .cancel): return cancel(nil, haptic: isRecording)
        case (_, .demo(let progress)):
            lastToken += 1
            state = .recording(token: lastToken, progress: progress)
            return []
        case (.idle, _), (.requestingPermission, _), (.starting, _), (.recording, _), (.finished, _), (.cancelled, _):
            return []
        }
    }
    private mutating func cancel(_ reason: String?, haptic: Bool) -> [Effect] {
        state = .cancelled(reason)
        return [.teardown(delete: true)] + (haptic ? [.haptic(.failure)] : [])
    }
}
