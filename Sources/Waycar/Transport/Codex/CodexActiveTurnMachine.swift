/// Which turn runs in each Codex thread, for Send's `turn/steer` and Stop's
/// `turn/interrupt` (CODEX-05). The known turn comes from a subscribed
/// thread's `turn/started`, or from a newest-turn read while the thread is
/// active; a thread going inactive or closing, its known turn completing,
/// or a steer refused for a turn proven ended forgets it.
///
/// Each read has a token of its own and answers its own caller with its own
/// result, as before, unless a broadcast arrived while it was out: a
/// tracked `turn/started` names the newer turn, and the thread going
/// inactive, closing or seeing the read's turn complete means no turn runs
/// (B-30). A known turn alone never stands in for a read's answer, since
/// another read may have cached it. A thread that knows no turn and has no
/// read out keeps no entry, as `thread/closed` and every forgetting removed
/// it before the conversion.
struct CodexActiveTurnMachine: StateMachine {
    /// What a read still out has heard since it started.
    enum Read: Equatable, Sendable {
        /// Nothing but these turns completing.
        case open(completed: Set<String>)
        /// A tracked `turn/started` (with no id: no turn).
        case started(String?)
        /// No turn runs any more.
        case ended
    }

    struct Thread: Equatable, Sendable {
        /// The turn Send steers and Stop interrupts without reading.
        var known: String?
        /// Reads still out, by token.
        var reads: [UInt64: Read] = [:]
    }

    typealias State = [String: Thread]

    enum Event: Equatable, Sendable {
        /// Send or Stop needs the thread's turn; `active` is its broadcast status.
        case needed(String, active: Bool)
        /// The read `token` found this running turn, or none.
        case lookedUp(String, token: UInt64, running: String?)
        /// The read `token` threw (refused, timed out, malformed, cancelled):
        /// it answers no caller and is no longer out.
        case lookupFailed(String, token: UInt64)
        /// `turn/started`; `tracked` while this connection subscribes.
        case started(String, turn: String?, tracked: Bool)
        case completed(String, turn: String?)
        /// Not active any more, closed, or a steer refused for an ended turn.
        case ended(String)

        var thread: String {
            switch self {
            case .needed(let thread, _), .lookedUp(let thread, _, _), .lookupFailed(let thread, _),
                 .started(let thread, _, _), .completed(let thread, _), .ended(let thread):
                thread
            }
        }
    }

    enum Effect: Equatable, Sendable {
        case use(String?)
        case lookUp(token: UInt64)
    }

    private(set) var state: State = [:]
    private var lastToken: UInt64 = 0

    /// A thread keeps an entry only while it knows a turn or a read is out,
    /// so a closed or idle thread leaves nothing behind.
    mutating func handle(_ event: Event) -> [Effect] {
        let subject = event.thread
        defer { if state[subject]?.known == nil, state[subject]?.reads.isEmpty == true { state[subject] = nil } }
        switch event {
        case .needed(let thread, let active):
            if let known = state[thread]?.known { return [.use(known)] }
            guard active else { return [.use(nil)] }
            lastToken += 1
            state[thread, default: Thread()].reads[lastToken] = .open(completed: [])
            return [.lookUp(token: lastToken)]
        case .lookedUp(let thread, let token, let running):
            guard let read = state[thread]?.reads.removeValue(forKey: token) else { return [.use(nil)] }
            switch read {
            case .open(let completed):
                guard let running, !completed.contains(running) else { return [.use(nil)] }
                state[thread, default: Thread()].known = running
                return [.use(running)]
            case .started(let turn):
                return [.use(turn)]
            case .ended:
                return [.use(nil)]
            }
        case .lookupFailed(let thread, let token):
            state[thread]?.reads[token] = nil
            return []
        case .started(let thread, let turn, let tracked):
            guard tracked else { return [] }
            state[thread, default: Thread()].known = turn
            hear(.started(turn), in: thread)
            return []
        case .completed(let thread, let turn):
            if let turn, state[thread]?.known == turn { state[thread]?.known = nil }
            for (token, read) in state[thread]?.reads ?? [:] {
                switch read {
                case .open(let completed):
                    if let turn { state[thread]?.reads[token] = .open(completed: completed.union([turn])) }
                case .started(let started?) where started == turn:
                    state[thread]?.reads[token] = .ended
                case .started, .ended:
                    break
                }
            }
            return []
        case .ended(let thread):
            state[thread]?.known = nil
            hear(.ended, in: thread)
            return []
        }
    }

    /// Every read still out for `thread` hears `broadcast`, the newest word.
    private mutating func hear(_ broadcast: Read, in thread: String) {
        guard let tokens = state[thread]?.reads.keys else { return }
        for token in tokens { state[thread]?.reads[token] = broadcast }
    }
}
