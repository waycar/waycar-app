/// Each listed OpenCode session's activity (OPENCODE-04): a turn running
/// (Working), or resting with its last result, which is Done until it is
/// seen. `idle` is when the last turn ended and `viewed` when its result was
/// last seen, both OpenCode's epoch milliseconds (O10); a pending request
/// makes a session Blocked whatever it is doing (the owner knows those).
///
/// A re-list replaces everything with the server's own times (O14); the
/// events keep it current between re-lists, stamping `idle` where the server
/// writes one: at the end event's time, except for an interruption with
/// reason `shutdown` (a rejected permission, O17), which writes none and so
/// leaves no unseen result (B-38).
struct OpenCodeActivityMachine: StateMachine {
    struct Times: Equatable, Sendable {
        var idle: Double?
        var viewed: Double?
    }

    enum Activity: Equatable, Sendable {
        case working(Times)
        case resting(Times)
    }

    /// Listed top-level sessions only.
    typealias State = [String: Activity]

    enum Event: Equatable, Sendable {
        /// The whole list, as a re-list read it, and which of them run.
        case relisted([String: Times], running: Set<String>)
        /// A session joined the list (created, unarchived, launched).
        case listed(String, Times)
        /// Archived or deleted.
        case unlisted(String)
        /// `session.execution.started`.
        case started(String)
        /// `session.execution.succeeded`, `.failed` or `.interrupted` at `at`,
        /// with the interruption's `reason` if any.
        case ended(String, at: Double, reason: String?)
        /// `session.viewed`.
        case viewed(String, idle: Double)
        /// The user opened the session.
        case viewRequested(String)
        /// `POST /view` for `idle` answered.
        case viewPosted(String, idle: Double)
    }

    enum Effect: Equatable, Sendable {
        case publish
        /// Mark the result at `idle` seen on the server.
        case postView(idle: Double)
    }

    private(set) var state: State = [:]

    /// The interruption reason of a turn that wrote no `idle` (O17).
    static let noResult = "shutdown"

    func isRunning(_ id: String) -> Bool {
        if case .working? = state[id] { return true }
        return false
    }

    /// Pending requests win, then a running turn; an idle newer than the
    /// last view is an unseen result.
    func status(_ id: String, blocked: Bool) -> AgentStatus? {
        guard let activity = state[id] else { return nil }
        if blocked { return .blocked }
        switch activity {
        case .working: return .working
        case .resting(let times):
            if let idle = times.idle, idle > (times.viewed ?? 0) { return .done }
            return .idle
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .relisted(let listed, let running):
            state = listed.reduce(into: [:]) { state, entry in
                state[entry.key] = running.contains(entry.key) ? .working(entry.value) : .resting(entry.value)
            }
            return []
        case .listed(let id, let times):
            state[id] = .resting(times)
            return []
        case .unlisted(let id):
            state[id] = nil
            return []
        case .started(let id):
            guard case .resting(let times)? = state[id] else { return [] }
            state[id] = .working(times)
            return [.publish]
        case .ended(let id, let at, let reason):
            guard let activity = state[id] else { return [] }
            state[id] = .resting(reason == Self.noResult ? activity.times
                : Times(idle: at, viewed: activity.times.viewed))
            return [.publish]
        case .viewed(let id, let idle):
            guard let activity = state[id] else { return [] }
            state[id] = activity.with(viewed: idle)
            return [.publish]
        case .viewRequested(let id):
            guard let times = state[id]?.times, let idle = times.idle, idle > (times.viewed ?? 0) else { return [] }
            return [.postView(idle: idle)]
        case .viewPosted(let id, let idle):
            if let viewed = state[id]?.times.viewed, viewed >= idle { return [] }
            if let activity = state[id] { state[id] = activity.with(viewed: idle) }
            return [.publish]
        }
    }
}

private extension OpenCodeActivityMachine.Activity {
    var times: OpenCodeActivityMachine.Times {
        switch self {
        case .working(let times), .resting(let times): times
        }
    }

    func with(viewed: Double) -> Self {
        var times = times
        times.viewed = viewed
        switch self {
        case .working: return .working(times)
        case .resting: return .resting(times)
        }
    }
}
