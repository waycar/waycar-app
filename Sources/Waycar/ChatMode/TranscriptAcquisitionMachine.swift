/// How `ChatTranscriptStore` gets its transcript and keeps getting it: the
/// two read coalescers (the transcript and the Blocked screen), the cursor
/// (in full until a full read lands, or again after the transcript moved),
/// and the retry and plugin-recheck budgets.
///
/// Each reader runs one pass at a time under a token; a request during a
/// pass runs it once more after it, and one that lands before the pass
/// began is absorbed into it. Stopping, or discarding the screen read,
/// retires the pass's token: its answer is dropped by the owner's
/// cancellation check and its loop finishes nothing.
///
/// A read that did not find the transcript is retried after `retryDelays`
/// while started (the attempt picks the delay, the last repeats); a found
/// read and a start reset the attempt. A missing or outdated plugin is
/// believed, except for the budget a plugin update grants (one try per
/// delay), which only a start resets. A public refresh reads while stopped
/// too, but never arms a retry.
struct TranscriptAcquisitionMachine: StateMachine {
    enum Reader: Equatable, Sendable {
        case transcript
        case screen
    }

    enum Pass: Equatable, Sendable {
        case idle
        /// `again`: asked for during this pass; it runs once more.
        case running(token: UInt64, again: Bool)
    }

    enum Retry: Equatable, Sendable {
        case none
        case waiting(token: UInt64)
    }

    struct State: Equatable, Sendable {
        var isStarted = false
        var transcript: Pass = .idle
        var screen: Pass = .idle
        var needsFullRead = true
        /// The transcript the last found read came from. Another path is a
        /// new conversation (`/clear`), read in full and shown in its place.
        var transcriptPath: String?
        var retry: Retry = .none
        /// Reads in a row that did not find the transcript.
        var retryAttempt = 0
        /// Plugin-missing or outdated answers still retried after a plugin
        /// update.
        var pluginRechecksLeft = 0
    }

    /// What a read's header said.
    enum Answer: Equatable, Sendable {
        /// `wholeList`: read in full, or the reader no longer knew the
        /// after-id and answered with every message.
        case found(transcript: String?, wholeList: Bool)
        case notFound
        case unsupported
        case readerError
    }

    enum Event: Equatable, Sendable {
        case start
        case stop
        case requested(Reader)
        case passBegan(Reader, UInt64)
        case passEnded(Reader, UInt64)
        /// The Blocked screen's read is obsolete: the status left Blocked,
        /// or a structured answer must not see a read begun before it.
        case screenDiscarded
        /// The read threw; `pluginGap` when no plugin or an outdated one.
        case readFailed(pluginGap: Bool)
        case answered(Answer)
        case retryElapsed(UInt64)
        /// The plugin now meets this build's minimum (the owner saw it
        /// missing or outdated).
        case pluginUpdated
    }

    enum Effect: Equatable, Sendable {
        case startPass(Reader, UInt64)
        /// Cancel and forget the reader's pass Task, if any.
        case cancelPass(Reader)
        /// The pass's loop goes round once more.
        case runAgain
        /// The pass ended: forget its Task (and, for the transcript, follow
        /// the polling demand again).
        case passFinished(Reader)
        /// Sleep, then send `retryElapsed`; the owner forgets the Task once
        /// that is accepted.
        case armRetry(UInt64, after: Duration)
        /// Cancel and forget the retry Task, if any.
        case cancelRetry
        case scheduleRead
        /// The found read replaces the list.
        case show
        /// The found read appends to the list.
        case merge
    }

    let retryDelays: [Duration]
    private(set) var state = State()
    private var lastToken: UInt64 = 0

    init(retryDelays: [Duration]) {
        self.retryDelays = retryDelays
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .start:
            guard !state.isStarted else { return [] }
            state.isStarted = true
            state.needsFullRead = true
            state.retryAttempt = 0
            state.pluginRechecksLeft = 0
            state.retry = .none
            return [.cancelRetry]
        case .stop:
            state.isStarted = false
            state.screen = .idle
            state.transcript = .idle
            state.retry = .none
            return [.cancelPass(.screen), .cancelPass(.transcript), .cancelRetry]
        case .requested(let reader):
            switch pass(reader) {
            case .running(let token, _):
                setPass(reader, .running(token: token, again: true))
                return []
            case .idle:
                let token = nextToken()
                setPass(reader, .running(token: token, again: false))
                return [.startPass(reader, token)]
            }
        case .passBegan(let reader, let token):
            if case .running(token: token, again: _) = pass(reader) {
                setPass(reader, .running(token: token, again: false))
            }
            return []
        case .passEnded(let reader, let token):
            switch pass(reader) {
            case .running(token: token, again: true):
                return [.runAgain]
            case .running(token: token, again: false):
                setPass(reader, .idle)
                return [.passFinished(reader)]
            case .running, .idle:
                return []
            }
        case .screenDiscarded:
            state.screen = .idle
            return [.cancelPass(.screen)]
        case .readFailed(pluginGap: true):
            guard state.pluginRechecksLeft > 0 else {
                state.retry = .none
                return [.cancelRetry]
            }
            state.pluginRechecksLeft -= 1
            return scheduleRetry()
        case .readFailed(pluginGap: false):
            return scheduleRetry()
        case .answered(.found(let transcript, let wholeList)):
            state.retryAttempt = 0
            state.retry = .none
            let previous = state.transcriptPath
            if let transcript { state.transcriptPath = transcript }
            if wholeList {
                state.needsFullRead = false
                return [.cancelRetry, .show]
            }
            guard let previous, let transcript, transcript != previous else {
                return [.cancelRetry, .merge]
            }
            // The after-id belonged to the old conversation: read the new
            // one in full, then show it in place of the old.
            state.needsFullRead = true
            if case .running(let token, _) = state.transcript {
                state.transcript = .running(token: token, again: true)
            }
            return [.cancelRetry]
        case .answered(.notFound), .answered(.readerError):
            return scheduleRetry()
        case .answered(.unsupported):
            state.retry = .none
            return [.cancelRetry]
        case .retryElapsed(let token):
            guard state.retry == .waiting(token: token), state.isStarted else { return [] }
            state.retry = .none
            return [.scheduleRead]
        case .pluginUpdated:
            guard state.isStarted else { return [] }
            state.pluginRechecksLeft = retryDelays.count
            state.retryAttempt = 0
            return [.scheduleRead]
        }
    }

    /// Reads again after the next delay, replacing a retry already waiting.
    /// Nothing is retried while stopped.
    private mutating func scheduleRetry() -> [Effect] {
        state.retry = .none
        guard state.isStarted, !retryDelays.isEmpty else { return [.cancelRetry] }
        let delay = retryDelays[min(state.retryAttempt, retryDelays.count - 1)]
        state.retryAttempt += 1
        let token = nextToken()
        state.retry = .waiting(token: token)
        return [.cancelRetry, .armRetry(token, after: delay)]
    }

    private func pass(_ reader: Reader) -> Pass {
        switch reader {
        case .transcript: state.transcript
        case .screen: state.screen
        }
    }

    private mutating func setPass(_ reader: Reader, _ pass: Pass) {
        switch reader {
        case .transcript: state.transcript = pass
        case .screen: state.screen = pass
        }
    }

    private mutating func nextToken() -> UInt64 {
        lastToken += 1
        return lastToken
    }
}
