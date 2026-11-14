/// A tmux pane's copy-mode scroll path (``TmuxPaneHistory``): one request
/// in flight at a time with the rows and reads that pile up behind it, and
/// the leave that ends copy mode for input or for the Attach's departure.
///
/// Rules a reader needs:
/// - The pump runs one loop per token; each turn takes everything pending
///   as one request. A failed request drops what is pending and ends the
///   loop; the next scroll starts a new one.
/// - A leave rejects scrolls and reads from the moment it is asked for. Its
///   own first step drops what is pending (rows never sent), it then waits
///   for the request in flight, and only then leaves copy mode, and only
///   when the view is in it (a departure: only copy mode this history's own
///   scroll entered). A failed leave still reads live.
/// - A leave asked for while one runs joins it; afterwards only input's
///   leave goes again, when the view is still in copy mode.
struct PaneHistoryScrollMachine: StateMachine {
    enum Request: Equatable, Sendable {
        /// Between requests: the loop is about to look at what is pending.
        case none
        /// A bare position read.
        case reading
        /// A scroll that moves the view.
        case moving
    }

    enum Pump: Equatable, Sendable {
        case idle
        /// The owner's pump loop for `token` runs.
        case running(token: UInt64, request: Request)
    }

    enum Leave: Equatable, Sendable {
        case none
        /// The owner's leave for `token` runs; scrolls and reads are refused.
        case leaving(token: UInt64, onlyIfEntered: Bool)
    }

    struct State: Equatable, Sendable {
        /// Where the pane's view was last seen; nil until the first answer.
        var position: PaneHistoryPosition?
        /// This history's own scroll took the view into copy mode and no
        /// answer since has seen it leave.
        var enteredHistory = false
        /// Rows asked for and not yet sent; positive toward older content.
        var pendingRows = 0
        /// A position read was asked for and not yet sent.
        var wantsRefresh = false
        var pump = Pump.idle
        var leave = Leave.none
    }

    enum Event: Equatable, Sendable {
        case scroll(towardOlderContent: Bool, rows: Int)
        case refresh
        /// The pump loop's head: send what is pending, or end.
        case pumpNext(UInt64)
        /// The request's answer; nil when it failed.
        case answered(UInt64, PaneHistoryScroll?)
        case leaveRequested(onlyIfEntered: Bool)
        /// The leave's own first step.
        case leaveStarted(UInt64)
        /// The leave waited out the pump.
        case pumpDrained(UInt64)
        /// The leave's copy-mode exit returned, whether or not it succeeded.
        case copyModeLeft(UInt64)
        case leaveEnded(UInt64)
        /// A leave that joined a running one saw it end.
        case joinedLeaveEnded(onlyIfEntered: Bool)
    }

    enum Effect: Equatable, Sendable {
        case startPump(UInt64)
        case request(UInt64, towardOlderContent: Bool, rows: Int)
        case pumpEnded(UInt64)
        case startLeave(UInt64, onlyIfEntered: Bool)
        /// Wait for the running leave, then report `joinedLeaveEnded`.
        case joinLeave
        case leaveCopyMode(UInt64)
        /// The joined leave ended with the view still in copy mode: input
        /// leaves again.
        case leaveAgain
        /// The observable position changed.
        case publishPosition(PaneHistoryPosition?)
        /// ``isAvailable`` changed.
        case availabilityChanged
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var position: PaneHistoryPosition? { state.position }
    var enteredHistory: Bool { state.enteredHistory }
    var isLeaving: Bool { state.leave != .none }

    /// The request in flight moves the view.
    var isMoving: Bool {
        if case .running(_, .moving) = state.pump { return true }
        return false
    }

    var isAvailable: Bool { Self.isAvailable(state.position) }

    /// The view is above live output, or a scroll that may take it there is
    /// in flight or queued, or a leave runs.
    var holdsInput: Bool {
        state.position == .inHistory || isMoving || state.pendingRows != 0 || isLeaving
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .scroll(let towardOlderContent, let rows):
            guard rows > 0, state.leave == .none else { return [] }
            state.pendingRows += towardOlderContent ? rows : -rows
            return startPumpIfIdle()
        case .refresh:
            guard state.leave == .none else { return [] }
            state.wantsRefresh = true
            return startPumpIfIdle()
        case .pumpNext(let token):
            guard state.pump == .running(token: token, request: .none) else { return [] }
            guard state.pendingRows != 0 || state.wantsRefresh else {
                state.pump = .idle
                return [.pumpEnded(token)]
            }
            let rows = state.pendingRows
            state.pendingRows = 0
            state.wantsRefresh = false
            state.pump = .running(token: token, request: rows != 0 ? .moving : .reading)
            return [.request(token, towardOlderContent: rows > 0, rows: abs(rows))]
        case .answered(let token, let answer):
            guard case .running(token, let request) = state.pump, request != .none else { return [] }
            guard let answer else {
                state.pendingRows = 0
                state.wantsRefresh = false
                state.pump = .idle
                return [.pumpEnded(token)]
            }
            state.pump = .running(token: token, request: .none)
            let effects = update(answer.position)
            if answer.enteredHistory { state.enteredHistory = true }
            return effects
        case .leaveRequested(let onlyIfEntered):
            guard state.leave == .none else { return [.joinLeave] }
            let token = nextToken()
            state.leave = .leaving(token: token, onlyIfEntered: onlyIfEntered)
            return [.startLeave(token, onlyIfEntered: onlyIfEntered)]
        case .leaveStarted(let token):
            guard case .leaving(token, _) = state.leave else { return [] }
            state.pendingRows = 0
            state.wantsRefresh = false
            return []
        case .pumpDrained(let token):
            guard case .leaving(token, let onlyIfEntered) = state.leave,
                state.position == .inHistory, !onlyIfEntered || state.enteredHistory
            else { return [] }
            return [.leaveCopyMode(token)]
        case .copyModeLeft(let token):
            guard case .leaving(token, _) = state.leave else { return [] }
            return update(.live)
        case .leaveEnded(let token):
            guard case .leaving(token, _) = state.leave else { return [] }
            state.leave = .none
            return []
        case .joinedLeaveEnded(let onlyIfEntered):
            // A departure that kept someone else's copy mode does not stand
            // in for input's leave.
            guard !onlyIfEntered, state.position == .inHistory else { return [] }
            return [.leaveAgain]
        }
    }

    private mutating func startPumpIfIdle() -> [Effect] {
        guard state.pump == .idle else { return [] }
        let token = nextToken()
        state.pump = .running(token: token, request: .none)
        return [.startPump(token)]
    }

    private mutating func update(_ next: PaneHistoryPosition) -> [Effect] {
        let wasAvailable = isAvailable
        if next != .inHistory { state.enteredHistory = false }
        var effects: [Effect] = []
        if state.position != next {
            state.position = next
            effects.append(.publishPosition(next))
        }
        if isAvailable != wasAvailable { effects.append(.availabilityChanged) }
        return effects
    }

    private static func isAvailable(_ position: PaneHistoryPosition?) -> Bool {
        position == .live || position == .inHistory
    }

    private mutating func nextToken() -> UInt64 {
        lastToken += 1
        return lastToken
    }
}
