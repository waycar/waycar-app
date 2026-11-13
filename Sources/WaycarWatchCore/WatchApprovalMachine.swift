import Foundation

/// A read displayed by a watch screen, including a named failure.
enum WatchRead<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

/// One Agent's approval episode. Reads are single flight; answers belong to
/// both their request token and the prompt id that was on screen.
struct WatchApprovalMachine: StateMachine {
    enum AnswerState: Equatable, Sendable {
        case idle
        case sending
        case done(WatchAnswer, at: Date)
        case failed(String)
        case promptChanged
    }

    enum State: Equatable, Sendable {
        case resting(WatchRead<WatchBlockedPrompt?>, AnswerState)
        // An episode change hides the read but keeps its single-flight slot.
        // `reloadWanted`: a load arrived meanwhile; if this read turns out to
        // belong to an earlier episode, a fresh one starts when it ends.
        case reading(
            token: UInt64, episode: UInt64, answer: AnswerState, clearsStamp: Bool,
            reloadWanted: Bool)
        case answering(WatchBlockedPrompt, token: UInt64, WatchAnswer)
    }

    enum Event: Equatable, Sendable {
        case load(stampExpired: Bool)
        case readFinished(UInt64, WatchRead<WatchBlockedPrompt?>)
        case answer(WatchAnswer)
        case answerFinished(UInt64, promptID: UUID, AnswerState, spent: Bool)
        case blockedEpisode
    }

    enum Effect: Equatable, Sendable {
        case read(UInt64)
        case answer(UInt64, promptID: UUID, WatchAnswer)
        case success
        case failure
    }

    private(set) var state: State = .resting(.idle, .idle)
    private var lastToken: UInt64 = 0
    /// A Blocked transition invalidates all reads from an earlier episode.
    private var episode: UInt64 = 0

    var prompt: WatchRead<WatchBlockedPrompt?> {
        switch state {
        case .resting(let read, _): read
        case .reading(_, let readEpisode, _, _, _): readEpisode == episode ? .loading : .idle
        case .answering(let prompt, _, _): .loaded(prompt)
        }
    }

    var answer: AnswerState {
        switch state {
        case .resting(_, let answer), .reading(_, _, let answer, _, _): answer
        case .answering: .sending
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.resting(_, let answer), .load(let expired)):
            let clearsStamp: Bool
            switch answer {
            case .done:
                guard expired else { return [] }
                clearsStamp = true
            case .sending: return []
            case .idle, .failed, .promptChanged: clearsStamp = false
            }
            lastToken += 1
            state = .reading(
                token: lastToken, episode: episode, answer: clearsStamp ? answer : .idle,
                clearsStamp: clearsStamp, reloadWanted: false)
            return [.read(lastToken)]

        case (.reading(let token, let readEpisode, let answer, let clearsStamp, _), .load):
            // Single flight: the read in progress answers this load, unless it
            // turns out to be from an earlier episode (see readFinished).
            state = .reading(
                token: token, episode: readEpisode, answer: answer, clearsStamp: clearsStamp,
                reloadWanted: true)
            return []

        case (.reading(let token, let readEpisode, let answer, let clearsStamp, let reloadWanted),
              .readFinished(let completed, let read)):
            guard token == completed else { return [] }
            guard readEpisode == episode else {
                // A stale read is dropped (B-09); a load that waited on it
                // gets a read of the current episode.
                guard reloadWanted else {
                    state = .resting(.idle, .idle)
                    return []
                }
                lastToken += 1
                state = .reading(
                    token: lastToken, episode: episode, answer: .idle, clearsStamp: false,
                    reloadWanted: false)
                return [.read(lastToken)]
            }
            let nextAnswer: AnswerState
            if clearsStamp, case .loaded(_?) = read { nextAnswer = .idle }
            else { nextAnswer = answer }
            state = .resting(read, nextAnswer)
            return []

        case (.resting(.loaded(let prompt?), let answer), .answer(let choice)):
            switch answer {
            case .sending, .done: return []
            case .idle, .failed, .promptChanged: break
            }
            switch (choice, prompt.approval) {
            case (.allow, .allow), (.deny, .allow), (.deny, .hold): break
            case (.allow, .hold), (_, .readOnly): return []
            }
            lastToken += 1
            state = .answering(prompt, token: lastToken, choice)
            return [.answer(lastToken, promptID: prompt.promptID, choice)]

        case (.answering(let prompt, let token, _),
              .answerFinished(let completed, let promptID, let answer, let spent)):
            guard token == completed, prompt.promptID == promptID else { return [] }
            state = .resting(.loaded(prompt), answer)
            var effects: [Effect] = []
            switch answer {
            case .done(.allow, _): effects = [.success]
            case .failed, .promptChanged: effects = [.failure]
            case .done(.deny, _), .idle, .sending: break
            }
            if spent {
                lastToken += 1
                state = .reading(
                    token: lastToken, episode: episode, answer: answer, clearsStamp: false,
                    reloadWanted: false)
                effects.append(.read(lastToken))
            }
            return effects

        case (.reading(let token, let readEpisode, _, _, let reloadWanted), .blockedEpisode):
            episode += 1
            state = .reading(
                token: token, episode: readEpisode, answer: .idle, clearsStamp: false,
                reloadWanted: reloadWanted)
            return []
        case (.resting, .blockedEpisode), (.answering, .blockedEpisode):
            episode += 1
            state = .resting(.idle, .idle)
            return []

        case (.resting, _), (.reading, _), (.answering, _): return []
        }
    }
}
