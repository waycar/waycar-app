/// The structured requests (approvals, questions) each Codex thread waits on
/// (CODEX-06). Codex sends one as a server request; a resume replays the ones
/// still pending (X13), so a request with an id already listed replaces it.
/// It leaves when the user's answer is written, when `serverRequest/resolved`
/// says it was answered elsewhere (first answer wins, X14), when the thread
/// stops being Blocked, or when it closes.
///
/// An answer is written once and never replayed: a cancelled or failed write
/// leaves the request listed for the user to answer again.
struct CodexApprovalMachine: StateMachine {
    struct Request: Equatable, Sendable {
        let id: CodexRPCID
        let request: AgentPendingRequest
    }

    /// Each thread's waiting requests in arrival order; none is no entry.
    typealias State = [String: [Request]]

    enum Event: Equatable, Sendable {
        case asked(String, Request)
        /// The user's answer to `id` was written.
        case answered(String, CodexRPCID)
        /// `serverRequest/resolved` with this request id.
        case resolvedElsewhere(String, JSONValue)
        /// The thread stopped being Blocked, or closed.
        case dropped(String)
    }

    enum Effect: Equatable, Sendable {
        case publish
    }

    private(set) var state: State = [:]

    func requests(_ thread: String) -> [AgentPendingRequest] {
        state[thread, default: []].map(\.request)
    }

    func request(_ thread: String, shownAs id: String) -> Request? {
        state[thread]?.first { $0.request.id == id }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .asked(let thread, let request):
            state[thread, default: []].removeAll { $0.id == request.id }
            state[thread, default: []].append(request)
            return [.publish]
        case .answered(let thread, let id):
            state[thread]?.removeAll { $0.id == id }
            return [.publish]
        case .resolvedElsewhere(let thread, let id):
            let before = state[thread]?.count
            // Codex's per-connection counter ids are assumed below 2^53.
            state[thread]?.removeAll { $0.id.matches(id) }
            return before == state[thread]?.count ? [] : [.publish]
        case .dropped(let thread):
            state[thread] = nil
            return []
        }
    }
}

extension CodexRPCID {
    /// The id as the Console shows and answers it.
    var displayString: String {
        switch self {
        case .integer(let value): String(value)
        case .string(let value): value
        }
    }

    /// Whether a JSON id (`serverRequest/resolved`'s `requestId`) names this one.
    func matches(_ value: JSONValue) -> Bool {
        switch (self, value) {
        case (.integer(let id), .number(let number)): Double(id) == number
        case (.string(let id), .string(let string)): id == string
        default: false
        }
    }
}
