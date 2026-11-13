/// One car utterance, including its retry and fallback. Session ownership is
/// deliberately outside this machine (VOICE-04). `stops` is the line's
/// ownership epoch: an old completion must never release a replacement.
struct CarSpeakerLineMachine: StateMachine {
    enum Attempt: Equatable, Sendable { case primary, retry, system }
    struct Line: Equatable, Sendable {
        let token: Int
        let attempt: Attempt
        let text: String
    }
    enum State: Equatable, Sendable {
        case idle
        case playing(Line)
        case held(Line, watch: UInt64)
        case watchingResume(Line, watch: UInt64, progress: Int)
        case retrying(Line)
        case systemFallback(Line)
    }
    enum Outcome: Equatable, Sendable {
        case spoken, stopped, silenced
        case failed(rest: String, usedSystem: Bool)
    }
    enum Event: Sendable {
        case start(String)
        case stop
        case completed(Int, Outcome)
        case retryReady(Int, cancelled: Bool)
        case hold
        case resume(progress: Int, succeeded: Bool)
        case holdExpired(UInt64)
        case progress(UInt64, Int)
    }
    enum Effect: Equatable, Sendable {
        case play(Line)
        case waitForInterruption(Int)
        case finished(Bool)
        case release
        case stopEngine
        case watchHold(UInt64)
        case watchProgress(UInt64)
    }
    private(set) var state: State = .idle
    private(set) var stops = 0
    private var watch: UInt64 = 0

    var line: Line? {
        switch state {
        case .idle: nil
        case .playing(let line), .held(let line, _), .watchingResume(let line, _, _),
             .retrying(let line), .systemFallback(let line): line
        }
    }
    var isHeld: Bool { if case .held = state { true } else { false } }
    func holds(_ token: UInt64) -> Bool {
        if case .held(_, let current) = state { current == token } else { false }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .stop:
            stops += 1
            state = .idle
            return [.stopEngine, .release]
        case .start(let text):
            let line = Line(token: stops, attempt: .primary, text: text)
            state = .playing(line)
            return [.play(line)]
        case .completed(let token, let outcome):
            // VOICE-03: even when the replacement uses the same engine,
            // the old line cannot clear its callback or hold.
            guard stops == token, let line, line.token == token else { return [.finished(false)] }
            switch outcome {
            case .spoken, .stopped, .silenced:
                state = .idle
                return [.release, .finished(outcome == .spoken)]
            case .failed(let rest, let usedSystem):
                switch line.attempt {
                case .primary:
                    state = .retrying(Line(token: token, attempt: .retry, text: rest))
                    return [.release, .waitForInterruption(token)]
                case .retry where !usedSystem:
                    let fallback = Line(token: token, attempt: .system, text: rest)
                    state = .systemFallback(fallback)
                    return [.release, .play(fallback)]
                case .retry, .system:
                    state = .idle
                    return [.release, .finished(false)]
                }
            }
        case .retryReady(let token, let cancelled):
            guard case .retrying(let line) = state, stops == token, line.token == token else {
                return [.finished(false)]
            }
            if cancelled {
                state = .idle
                return [.finished(false)]
            }
            state = .playing(line)
            return [.play(line)]
        case .hold:
            guard let line else { return [] }
            switch state {
            case .playing, .systemFallback, .watchingResume, .held:
                watch += 1
                state = .held(line, watch: watch)
                return [.watchHold(watch)]
            case .idle, .retrying: return []
            }
        case .resume(let progress, let succeeded):
            guard case .held(let line, _) = state else { return [] }
            if succeeded {
                watch += 1
                state = .watchingResume(line, watch: watch, progress: progress)
                return [.release, .watchProgress(watch)]
            }
            state = line.attempt == .system ? .systemFallback(line) : .playing(line)
            return [.release, .stopEngine]
        case .holdExpired(let token):
            guard case .held(let line, let current) = state, current == token else { return [] }
            state = line.attempt == .system ? .systemFallback(line) : .playing(line)
            return [.stopEngine]
        case .progress(let token, let progress):
            guard case .watchingResume(let line, let current, let last) = state,
                  token == current else { return [] }
            guard progress != last else {
                state = line.attempt == .system ? .systemFallback(line) : .playing(line)
                return [.stopEngine]
            }
            state = .watchingResume(line, watch: current, progress: progress)
            return []
        }
    }
}
