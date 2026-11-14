/// The message-jump wiring's session (``AgentMessageJumpWiring``): which
/// Attach session it serves, the jump Task bound to it, and the transcript
/// read that feeds its index.
///
/// Rules a reader needs:
/// - A reset advances the session generation and the jump epoch; anything
///   minted before it (a jump not yet entered, a jump's end, a read in
///   flight, a snapshot held for a walk) is dropped.
/// - A jump body runs only when its Task passes the entry check: not
///   cancelled, same session, latest epoch. Until it does, the jump it
///   replaced stays the running one (shown, and holding transcript reads).
///   Only the latest jump's end clears the running jump and applies a held
///   snapshot.
/// - One transcript read at a time: a refresh while one runs asks for one
///   more after it (`stale`). A read that lands during a walk is delivered
///   at once but reaches the jump index only when the walk ends, so the walk
///   never learns new messages under it.
struct MessageJumpSessionMachine: StateMachine {
    enum Jump: Equatable, Sendable {
        case idle
        /// The jump Task for `epoch` exists and has not passed its entry
        /// check; the jump it replaced, if one ran, is still the running one.
        case scheduled(epoch: UInt64, previous: AttachRunningJump?)
        case running(epoch: UInt64, AttachRunningJump)
    }

    enum Read: Equatable, Sendable {
        case idle
        /// A read for this session runs under `token`; `stale` asks for one
        /// more after it.
        case reading(token: UInt64, stale: Bool)
    }

    struct State: Equatable, Sendable {
        var generation: UInt64 = 0
        var epoch: UInt64 = 0
        var jump = Jump.idle
        var read = Read.idle
        var held: ChatTranscriptSnapshot?
    }

    enum Event: Equatable, Sendable {
        case jumpRequested
        case jumpEntered(epoch: UInt64, generation: UInt64, taskCancelled: Bool, AttachRunningJump)
        case jumpEnded(epoch: UInt64)
        case refreshRequested
        case readFinished(UInt64, ChatTranscriptSnapshot?)
        case reset
    }

    enum Effect: Equatable, Sendable {
        /// Cancel the jump Task in hand and start one for `epoch`, bound to
        /// the `generation` session.
        case startJump(epoch: UInt64, generation: UInt64)
        case runBody
        case clearJumpTask
        /// Cancel the jump Task in hand and drop it.
        case cancelJumpTask
        case publishRunning(AttachRunningJump?)
        case publishGeneration(UInt64)
        /// The reset's own owner-side steps: reach, scroll run, controller.
        case resetSessionState
        case startRead(UInt64)
        /// The read in hand finished: drop its Task.
        case clearRead
        case cancelRead
        case indexTranscript(ChatTranscriptSnapshot)
        case deliverTranscript(ChatTranscriptSnapshot)
        case resetIndex
    }

    private(set) var state = State()
    private let jumpUsesTranscript: Bool
    private var lastReadToken: UInt64 = 0

    init(jumpUsesTranscript: Bool) {
        self.jumpUsesTranscript = jumpUsesTranscript
    }

    var runningJump: AttachRunningJump? {
        switch state.jump {
        case .idle: nil
        case .scheduled(_, let previous): previous
        case .running(_, let jump): jump
        }
    }

    var hasJumpTask: Bool { state.jump != .idle }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .jumpRequested:
            state.epoch &+= 1
            state.jump = .scheduled(epoch: state.epoch, previous: runningJump)
            return [.startJump(epoch: state.epoch, generation: state.generation)]
        case .jumpEntered(let epoch, let generation, let taskCancelled, let jump):
            guard !taskCancelled, generation == state.generation, epoch == state.epoch else { return [] }
            state.jump = .running(epoch: epoch, jump)
            return [.publishRunning(jump), .runBody]
        case .jumpEnded(let epoch):
            guard epoch == state.epoch else { return [] }
            state.jump = .idle
            var effects: [Effect] = [.clearJumpTask, .publishRunning(nil)]
            if let held = state.held {
                state.held = nil
                effects.append(.indexTranscript(held))
            }
            return effects
        case .refreshRequested:
            switch state.read {
            case .idle:
                return startRead()
            case .reading(let token, _):
                state.read = .reading(token: token, stale: true)
                return []
            }
        case .readFinished(let token, let snapshot):
            // A reset has dropped this read and may have started another.
            guard case .reading(token, let stale) = state.read else { return [] }
            state.read = .idle
            var effects: [Effect] = [.clearRead]
            if let snapshot {
                if jumpUsesTranscript {
                    if runningJump == nil {
                        effects.append(.indexTranscript(snapshot))
                    } else {
                        state.held = snapshot
                    }
                }
                effects.append(.deliverTranscript(snapshot))
            }
            if stale { effects += startRead() }
            return effects
        case .reset:
            state.jump = .idle
            state.epoch &+= 1
            state.generation &+= 1
            state.read = .idle
            state.held = nil
            return [
                .cancelJumpTask, .publishGeneration(state.generation), .publishRunning(nil),
                .resetSessionState, .cancelRead, .resetIndex,
            ]
        }
    }

    private mutating func startRead() -> [Effect] {
        lastReadToken += 1
        state.read = .reading(token: lastReadToken, stale: false)
        return [.startRead(lastReadToken)]
    }
}
