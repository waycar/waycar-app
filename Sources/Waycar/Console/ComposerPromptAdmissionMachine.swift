import Foundation

/// The bounded registration/input hold around agent.prompt. A refusal is
/// never permission to type into an Attach. Time and live Agent checks arrive
/// as events so a late retry cannot cross Blocked or identity replacement.
struct ComposerPromptAdmissionMachine: StateMachine {
    enum Refusal: Equatable, Sendable { case response, blocked, agentChanged }
    enum State: Equatable, Sendable {
        case idle
        case attempting(UInt64, deadline: ContinuousClock.Instant)
        case waitingForRegistration(UInt64, deadline: ContinuousClock.Instant)
        case waitingForInput(UInt64, deadline: ContinuousClock.Instant)
        case accepted
        case refused(Refusal)
        case cancelled
    }
    enum Response: Equatable, Sendable {
        case accepted
        case registration(stillLaunching: Bool)
        case inputHold(opensAt: ContinuousClock.Instant)
        /// Includes sign-in, trust and every non-registration transport error.
        case refusal
    }
    enum Event: Sendable {
        case begin(now: ContinuousClock.Instant, budget: Duration)
        case response(UInt64, Response, now: ContinuousClock.Instant, blocked: Bool)
        case retryElapsed(UInt64, blocked: Bool, stillAddressed: Bool)
        case cancelled(UInt64)
    }
    enum Effect: Equatable, Sendable {
        case attempt(UInt64)
        case wait(UInt64, after: Duration)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0
    let retryDelay: Duration
    let queued: Bool

    init(retryDelay: Duration, queued: Bool) {
        self.retryDelay = retryDelay
        self.queued = queued
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .begin(let now, let budget)):
            return attempt(deadline: now + budget)
        case (.attempting(let token, _), .response(let id, .accepted, _, _)) where token == id:
            state = .accepted
            return []
        case (.attempting(let token, _), .response(let id, .refusal, _, _)) where token == id:
            state = .refused(.response)
            return []
        case (.attempting(let token, let deadline), .response(let id, .registration(let launching), let now, let blocked))
            where token == id:
            guard !queued || launching else {
                state = .refused(.response)
                return []
            }
            return wait(deadline: deadline, now: now, blocked: blocked, input: false)
        case (.attempting(let token, let deadline), .response(let id, .inputHold(let opensAt), let now, let blocked))
            where token == id:
            return wait(deadline: max(deadline, opensAt + retryDelay * 2), now: now, blocked: blocked, input: true)
        case (.waitingForRegistration(let token, let deadline), .retryElapsed(let id, let blocked, let addressed)) where token == id,
             (.waitingForInput(let token, let deadline), .retryElapsed(let id, let blocked, let addressed)) where token == id:
            // Blocked outranks identity replacement, as the old post-sleep check did.
            if blocked { state = .refused(.blocked); return [] }
            if !addressed { state = .refused(.agentChanged); return [] }
            return attempt(deadline: deadline)
        case (.waitingForRegistration(let token, _), .cancelled(let id)) where token == id,
             (.waitingForInput(let token, _), .cancelled(let id)) where token == id,
             (.attempting(let token, _), .cancelled(let id)) where token == id:
            state = .cancelled
            return []
        case (.idle, _), (.attempting, _), (.waitingForRegistration, _), (.waitingForInput, _),
             (.accepted, _), (.refused, _), (.cancelled, _):
            return []
        }
    }

    private mutating func attempt(deadline: ContinuousClock.Instant) -> [Effect] {
        lastToken &+= 1
        state = .attempting(lastToken, deadline: deadline)
        return [.attempt(lastToken)]
    }
    private mutating func wait(
        deadline: ContinuousClock.Instant, now: ContinuousClock.Instant, blocked: Bool, input: Bool
    ) -> [Effect] {
        guard !blocked, now + retryDelay < deadline else {
            state = .refused(blocked ? .blocked : .response)
            return []
        }
        lastToken &+= 1
        state = input ? .waitingForInput(lastToken, deadline: deadline) : .waitingForRegistration(lastToken, deadline: deadline)
        return [.wait(lastToken, after: retryDelay)]
    }
}
