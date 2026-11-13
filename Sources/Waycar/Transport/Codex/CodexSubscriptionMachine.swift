/// Whether this connection is subscribed to each Codex thread (CODEX-03):
/// `thread/resume` subscribes, and the subscription lasts until the
/// connection closes or Codex closes the thread. Listing a thread never
/// resumes it (X8): only a prompt, Stop's turn, a blocked thread's requests
/// or a launch need it.
///
/// Concurrent needs share one resume: its token names the Task the owner
/// keeps, and every waiter reports back with it, so a stale failure cannot
/// clear a newer resume (B-29). A thread with no entry is not subscribed.
struct CodexSubscriptionMachine: StateMachine {
    enum Subscription: Equatable, Sendable {
        /// A `thread/resume` is in flight.
        case resuming(token: UInt64)
        case subscribed
    }

    typealias State = [String: Subscription]

    enum Event: Equatable, Sendable {
        /// Something needs `thread` subscribed.
        case needed(String)
        /// A waiter's resume, `token`, answered.
        case resumed(String, token: UInt64)
        /// A waiter's resume, `token`, failed (or the transport closed).
        case resumeFailed(String, token: UInt64)
        /// `thread/start` answered: a started thread is subscribed.
        case started(String)
        /// `thread/closed`: the thread unloaded.
        case closed(String)
    }

    enum Effect: Equatable, Sendable {
        /// Send `thread/resume` for `thread` and keep its Task as `token`.
        case resume(String, token: UInt64)
        /// Wait for the resume Task kept as `token`.
        case wait(String, token: UInt64)
        /// Drop the resume Task kept for `thread`.
        case forget(String)
    }

    private(set) var state: State = [:]
    private var lastToken: UInt64 = 0

    /// Subscribed, or resuming: turn events for it are this connection's.
    func isTracked(_ thread: String) -> Bool { state[thread] != nil }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .needed(let thread):
            switch state[thread] {
            case .subscribed?:
                return []
            case .resuming(let token)?:
                return [.wait(thread, token: token)]
            case nil:
                lastToken += 1
                state[thread] = .resuming(token: lastToken)
                return [.resume(thread, token: lastToken), .wait(thread, token: lastToken)]
            }
        case .resumed(let thread, _):
            // Any answer subscribes the thread.
            state[thread] = .subscribed
            return [.forget(thread)]
        case .resumeFailed(let thread, let token):
            // Only the resume that failed is cleared: a waiter that learns of
            // an older failure late must not drop the retry that replaced it.
            guard state[thread] == .resuming(token: token) else { return [] }
            state[thread] = nil
            return [.forget(thread)]
        case .started(let thread):
            state[thread] = .subscribed
            return []
        case .closed(let thread):
            // A resume in flight keeps going, as before: its answer subscribes.
            guard state[thread] == .subscribed else { return [] }
            state[thread] = nil
            return []
        }
    }
}
