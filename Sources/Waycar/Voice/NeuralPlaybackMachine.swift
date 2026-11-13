/// A neural line's queued audio, pause state and exactly-once completion.
/// Epochs retain the engine's speak/stop guard. Rendering and synthesis are
/// effects of the owner; only buffers actually played advance audible progress.
struct NeuralPlaybackMachine: StateMachine {
    struct Progress: Equatable, Sendable {
        var sentenceStarts: [Int] = []
        var bufferSentences: [Int] = []
        var synthesizing = 0
        var played = 0
        var scheduledFrames = 0
        var scheduled: Int { bufferSentences.count }
        var spokenOffset: Int {
            let sentence = played < bufferSentences.count ? bufferSentences[played] : synthesizing
            return sentence < sentenceStarts.count ? sentenceStarts[sentence] : 0
        }
    }
    struct Line: Equatable, Sendable {
        let token: Int
        var progress: Progress
    }
    enum Synthesis: Equatable, Sendable { case ongoing, finished }
    enum State: Equatable, Sendable {
        case idle(Progress)
        case synthesizing(Line)
        case playing(Line)
        case paused(Line, Synthesis)
        case draining(Line)
        case ended(Line, spoken: Bool)
    }
    enum Event: Equatable, Sendable {
        case resetProgress
        case start(Int, sentenceStarts: [Int], sentences: [String])
        case sentence(Int, Int)
        case scheduled(Int, frames: Int, sentence: Int)
        case played(Int)
        case synthesized(Int, sentences: Int)
        case failed(Int)
        case pause
        case resume
        case configurationChanged(Int)
        case stop
        case stopLine(Int)
        case released(Int)
    }
    enum Effect: Equatable, Sendable {
        case synthesize(Int, [String])
        case complete(Int, spoken: Bool)
        case releaseResources(Int)
        case ensurePlaying
        case pauseAudio
        case resumeAudio
        case configurationStopped
    }

    private(set) var state: State = .idle(Progress())
    private(set) var token = 0
    var progress: Progress {
        switch state {
        case .idle(let p): p
        case .synthesizing(let l), .playing(let l), .paused(let l, _),
            .draining(let l), .ended(let l, _): l.progress
        }
    }
    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .stop):
            let previous = token
            token &+= 1
            let p = progress
            let complete: [Effect]
            switch state {
            case .synthesizing, .playing, .paused, .draining:
                complete = [.complete(previous, spoken: false)]
            case .idle, .ended:
                complete = []
            }
            state = .idle(p)
            return [.releaseResources(previous)] + complete
        case (_, .stopLine(let current)):
            guard token == current else { return [] }
            return handle(.stop)
        case (.idle(var progress), .resetProgress):
            // speak clears textual offsets before its availability guards;
            // buffer counters reset only when play actually starts, as before.
            progress.sentenceStarts = []
            progress.bufferSentences = []
            progress.synthesizing = 0
            state = .idle(progress)
            return []
        case (.idle, .start(let current, let starts, let sentences)):
            guard token == current else { return [] }
            let line = Line(token: token, progress: Progress(sentenceStarts: starts))
            state = .synthesizing(line)
            return [.synthesize(token, sentences)]
        case (.synthesizing(var l), .sentence(let current, let sentence)),
            (.playing(var l), .sentence(let current, let sentence)):
            guard l.token == current else { return [] }
            l.progress.synthesizing = sentence
            if case .synthesizing = state { state = .synthesizing(l) } else { state = .playing(l) }
            return []
        case (.paused(var l, .ongoing), .sentence(let current, let sentence)):
            guard l.token == current else { return [] }
            l.progress.synthesizing = sentence
            state = .paused(l, .ongoing)
            return []
        case (.synthesizing(var l), .scheduled(let current, let frames, let sentence)),
            (.playing(var l), .scheduled(let current, let frames, let sentence)):
            guard l.token == current, frames > 0 else { return [] }
            l.progress.bufferSentences.append(sentence)
            l.progress.scheduledFrames += frames
            state = .playing(l)
            return [.ensurePlaying]
        case (.paused(var l, .ongoing), .scheduled(let current, let frames, let sentence)):
            guard l.token == current, frames > 0 else { return [] }
            l.progress.bufferSentences.append(sentence)
            l.progress.scheduledFrames += frames
            state = .paused(l, .ongoing)
            return []
        case (.playing(var l), .played(let current)):
            guard l.token == current, l.progress.played < l.progress.scheduled else { return [] }
            l.progress.played += 1
            state = .playing(l)
            return []
        case (.draining(var l), .played(let current)):
            guard l.token == current, l.progress.played < l.progress.scheduled else { return [] }
            l.progress.played += 1
            state = .draining(l)
            return finishIfDrained(l, synthesis: .finished)
        case (.paused(var l, let synthesis), .played(let current)):
            guard l.token == current, l.progress.played < l.progress.scheduled else { return [] }
            l.progress.played += 1
            state = .paused(l, synthesis)
            return finishIfDrained(l, synthesis: synthesis)
        case (.synthesizing(var l), .synthesized(let current, let sentences)),
            (.playing(var l), .synthesized(let current, let sentences)):
            guard l.token == current else { return [] }
            l.progress.synthesizing = sentences
            state = .draining(l)
            return finishIfDrained(l, synthesis: .finished)
        case (.paused(var l, .ongoing), .synthesized(let current, let sentences)):
            guard l.token == current else { return [] }
            l.progress.synthesizing = sentences
            state = .paused(l, .finished)
            return finishIfDrained(l, synthesis: .finished)
        case (.playing(let l), .pause):
            state = .paused(l, .ongoing)
            return [.pauseAudio]
        case (.draining(let l), .pause):
            state = .paused(l, .finished)
            return [.pauseAudio]
        case (.paused, .pause):
            return [.pauseAudio]
        case (.paused(let l, let synthesis), .resume):
            // As before, unpause before the synchronous audio restart; a
            // refused restart reports false but does not re-mark the line paused.
            switch synthesis {
            case .ongoing: state = .playing(l)
            case .finished: state = .draining(l)
            }
            return [.resumeAudio]
        case (.synthesizing(let l), .failed(let current)),
            (.playing(let l), .failed(let current)),
            (.paused(let l, _), .failed(let current)),
            (.draining(let l), .failed(let current)):
            guard l.token == current else { return [] }
            state = .ended(l, spoken: false)
            return [.complete(current, spoken: false)]
        case (.synthesizing(let l), .configurationChanged(let current)),
            (.playing(let l), .configurationChanged(let current)),
            (.draining(let l), .configurationChanged(let current)):
            guard l.token == current else { return [] }
            return [.configurationStopped] + handle(.stop)
        case (.ended(let l, _), .released(let current)):
            guard l.token == current else { return [] }
            return [.releaseResources(current)]
        case (.idle, _), (.synthesizing, _), (.playing, _), (.paused, _),
            (.draining, _), (.ended, _):
            return []
        }
    }

    private mutating func finishIfDrained(_ line: Line, synthesis: Synthesis) -> [Effect] {
        guard synthesis == .finished, line.progress.played == line.progress.scheduled else { return [] }
        let spoken = line.progress.scheduled > 0
        state = .ended(line, spoken: spoken)
        return [.complete(line.token, spoken: spoken)]
    }
}
