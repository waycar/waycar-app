/// One message-jump run of ``TerminalMessageJumpController`` and its
/// frame waits: whether a run is in progress and was asked to stop, the
/// frame a step is waiting for, and the settle timer and the enclosing
/// task's cancel handler that race that frame.
///
/// Rules a reader needs:
/// - Each wait gets a token (the old wait id). The settle timer and the
///   enclosing-task cancel handler act only while their token is the active
///   wait, so a timer or handler from an earlier wait or run cannot time out
///   or cancel a later one (the poison-window guard).
/// - A step's frames are buffered from the moment it starts awaiting; the
///   latest paint decides the step even when an earlier one woke the waiter.
/// - A cancel wins over a frame, and is checked before the wait arms, inside
///   it, and when it returns.
/// - Only a held continuation is resumed, at most once; a resume clears the
///   active token and cancels the timer.
struct MessageJumpFrameWaitMachine: StateMachine {
    enum Result: Equatable, Sendable {
        case frame(String)
        case timedOut
        case cancelled
    }

    enum Wait: Equatable, Sendable {
        case none
        /// `token` is the active wait; `held` while its continuation waits.
        case active(token: UInt64, held: Bool)
    }

    struct State: Equatable, Sendable {
        /// Most recent viewport text, including frames delivered while idle.
        var latestFrame = ""
        var isRunning = false
        /// Set by `cancel()` or a live enclosing-task cancel; cleared when a
        /// run starts or finishes.
        var cancelRequested = false
        /// The current step accepts frame deliveries.
        var isAwaitingFrame = false
        /// Latest frame that arrived while the step awaited.
        var bufferedFrame: String?
        var wait = Wait.none
    }

    enum Event: Equatable, Sendable {
        case frameChanged(String)
        case cancel
        case start
        case finish
        case beginAwaiting
        /// `waitForFrame` entry: answer at once or arm a wait.
        case prepareWait(taskCancelled: Bool)
        /// Inside the continuation: answer at once or hold it.
        case continuationArmed(UInt64, taskCancelled: Bool)
        case timerFired(UInt64)
        /// The enclosing task's cancel handler reached the main actor.
        case enclosingCancelled(UInt64)
        /// The awaited continuation returned `result`.
        case waitReturned(UInt64, Result, taskCancelled: Bool)
    }

    enum Effect: Equatable, Sendable {
        case started
        case refused
        /// The wait's answer: return it (or resume the continuation with it).
        case answer(Result)
        /// Await a continuation for this token.
        case armWait(UInt64)
        /// Hold the continuation (a stranded one is answered cancelled first).
        case hold(UInt64)
        case cancelTimer
        case armTimer(UInt64)
        /// Resume the held continuation of `token`.
        case resume(UInt64, Result)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var latestFrame: String { state.latestFrame }
    var isRunning: Bool { state.isRunning }

    func isCancelPending(taskCancelled: Bool) -> Bool {
        state.cancelRequested || taskCancelled
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .frameChanged(let text):
            state.latestFrame = text
            guard state.isAwaitingFrame else { return [] }
            // A burst resumes the waiter on its first frame; later ones in
            // the same turn only replace the buffer, which decides the step.
            state.bufferedFrame = text
            return resumeHeld(with: .frame(text))
        case .cancel:
            state.cancelRequested = true
            return resumeHeld(with: .cancelled)
        case .start:
            guard !state.isRunning else { return [.refused] }
            state.isRunning = true
            state.cancelRequested = false
            return [.started]
        case .finish:
            state.isAwaitingFrame = false
            state.bufferedFrame = nil
            var effects: [Effect] = [.cancelTimer]
            // Drop a stranded waiter rather than resume it twice.
            if case .active(let token, true) = state.wait {
                effects.append(.resume(token, .cancelled))
            }
            state.wait = .none
            state.cancelRequested = false
            state.isRunning = false
            return effects
        case .beginAwaiting:
            state.isAwaitingFrame = true
            state.bufferedFrame = nil
            return []
        case .prepareWait(let taskCancelled):
            if isCancelPending(taskCancelled: taskCancelled) {
                state.isAwaitingFrame = false
                state.bufferedFrame = nil
                return [.answer(.cancelled)]
            }
            if let buffered = state.bufferedFrame {
                state.bufferedFrame = nil
                state.isAwaitingFrame = false
                return [.answer(.frame(buffered))]
            }
            lastToken += 1
            state.wait = .active(token: lastToken, held: false)
            return [.armWait(lastToken)]
        case .continuationArmed(let token, let taskCancelled):
            if isCancelPending(taskCancelled: taskCancelled) { return [.answer(.cancelled)] }
            if let buffered = state.bufferedFrame {
                state.bufferedFrame = nil
                return [.answer(.frame(buffered))]
            }
            state.wait = .active(token: token, held: true)
            return [.hold(token), .cancelTimer, .armTimer(token)]
        case .timerFired(let token):
            guard case .active(token, _) = state.wait else { return [] }
            return resumeHeld(with: .timedOut)
        case .enclosingCancelled(let token):
            // Ownership first: a delayed handler from a finished wait must not
            // set `cancelRequested` on a later jump.
            guard case .active(token, _) = state.wait else { return [] }
            state.cancelRequested = true
            return resumeHeld(with: .cancelled)
        case .waitReturned(let token, let result, let taskCancelled):
            let resolved: Result
            if isCancelPending(taskCancelled: taskCancelled) {
                // A cancel wins even when a frame already resumed the wait.
                resolved = .cancelled
            } else if case .frame = result {
                resolved = .frame(state.bufferedFrame ?? state.latestFrame)
            } else {
                resolved = result
            }
            state.isAwaitingFrame = false
            state.bufferedFrame = nil
            if case .active(token, _) = state.wait { state.wait = .none }
            return [.answer(resolved)]
        }
    }

    /// Resumes the held continuation at most once; nothing without one.
    private mutating func resumeHeld(with result: Result) -> [Effect] {
        guard case .active(let token, true) = state.wait else { return [] }
        state.wait = .none
        return [.cancelTimer, .resume(token, result)]
    }
}
