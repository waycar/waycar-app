/// Per-Host FIFO for notify.json read/modify/write operations (CS-03).
/// Enqueued Tasks await their predecessor; completion releases only its token.
/// The automatic core default is claimed once, and becomes eligible again only
/// after its failed attempt. Explicit visibility writes never claim that default.
struct NotificationVisibilityWriteMachine: StateMachine {
    enum Write: Equatable, Sendable {
        case tmux(Bool)
        case zellij(Bool)
        case core(Bool)
        /// Reads the visibility preference when its turn actually starts.
        case coreDefault
    }

    enum CoreDefault: Equatable, Sendable {
        case needed
        case pending(UInt64)
        case settled
    }

    enum State: Equatable, Sendable {
        case idle(CoreDefault)
        case writing(tokens: [UInt64], coreDefault: CoreDefault)
    }

    enum Event: Equatable, Sendable {
        case enqueue(Write)
        case finished(UInt64, succeeded: Bool)
    }

    enum Effect: Equatable, Sendable {
        case enqueue(UInt64, after: UInt64?, Write)
        case release(UInt64)
    }

    private(set) var state: State = .idle(.needed)
    private var lastToken: UInt64 = 0

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle(let coreDefault), .enqueue(let write)):
            return enqueue(write, after: [], coreDefault: coreDefault)
        case (.writing(let tokens, let coreDefault), .enqueue(let write)):
            return enqueue(write, after: tokens, coreDefault: coreDefault)
        case (.writing(let tokens, var coreDefault), .finished(let token, let succeeded))
            where tokens.first == token:
            if coreDefault == .pending(token) {
                coreDefault = succeeded ? .settled : .needed
            }
            let remaining = Array(tokens.dropFirst())
            state = remaining.isEmpty ? .idle(coreDefault)
                : .writing(tokens: remaining, coreDefault: coreDefault)
            return [.release(token)]
        case (.idle, .finished), (.writing, .finished):
            return []
        }
    }

    private mutating func enqueue(
        _ write: Write, after tokens: [UInt64], coreDefault: CoreDefault
    ) -> [Effect] {
        if write == .coreDefault, coreDefault != .needed { return [] }
        lastToken += 1
        state = .writing(
            tokens: tokens + [lastToken],
            coreDefault: write == .coreDefault ? .pending(lastToken) : coreDefault)
        return [.enqueue(lastToken, after: tokens.last, write)]
    }
}
