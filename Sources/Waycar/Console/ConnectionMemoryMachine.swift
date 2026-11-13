import Foundation

/// One Host's connection-memory claim. A retained memory can read or write
/// only while its claim is current; changing targets never grants an old
/// connection ownership again. The disk envelope remains the cache's concern.
struct ConnectionMemoryMachine: StateMachine {
    struct Claim: Equatable, Sendable {
        let token: UInt64
        let target: ConsoleInventoryCache.Target
    }

    enum State: Equatable, Sendable {
        case invalidated
        case unloaded(Claim)
        case unreadable(Claim)
        /// A read of a different target answers unknown without erasing the
        /// facts already in memory. Only a changed fact replaces them.
        case current(Claim, remembered: ConsoleInventoryCache.Target, facts: ConsoleInventoryCache.ConnectionFacts)
    }

    enum Event: Equatable, Sendable {
        case claim(ConsoleInventoryCache.Target)
        case loaded(UInt64, ConsoleInventoryCache.ConnectionFacts?)
        case remember(UInt64, ConsoleInventoryCache.ConnectionFacts)
        case invalidate
    }

    enum Effect: Equatable, Sendable {
        case persist(ConsoleInventoryCache.Target, ConsoleInventoryCache.ConnectionFacts)
    }

    private(set) var state: State = .invalidated
    private var lastToken: UInt64 = 0
    var token: UInt64 { lastToken }

    var claim: Claim? {
        switch state {
        case .invalidated: nil
        case .unloaded(let claim), .unreadable(let claim), .current(let claim, _, _): claim
        }
    }

    func facts(for token: UInt64) -> ConsoleInventoryCache.ConnectionFacts? {
        guard claim?.token == token else { return ConsoleInventoryCache.ConnectionFacts() }
        switch state {
        case .current(let claim, let target, let facts):
            return claim.target == target ? facts : ConsoleInventoryCache.ConnectionFacts()
        case .invalidated, .unloaded, .unreadable: return nil
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .invalidate):
            state = .invalidated
        case (_, .claim(let target)):
            guard claim?.target != target else { return [] }
            lastToken &+= 1
            let next = Claim(token: lastToken, target: target)
            switch state {
            case .current(_, let remembered, let facts): state = .current(next, remembered: remembered, facts: facts)
            case .invalidated, .unloaded, .unreadable: state = .unloaded(next)
            }
        case (.unloaded(let claim), .loaded(let token, let facts)),
             (.unreadable(let claim), .loaded(let token, let facts)):
            guard token == claim.token else { return [] }
            state = facts.map { .current(claim, remembered: claim.target, facts: $0) } ?? .unreadable(claim)
        case (.current(let claim, _, _), .remember(let token, let facts)):
            guard token == claim.token else { return [] }
            // A different remembered target starts with no facts, even if
            // its old value happens to equal the new target's answer.
            guard self.facts(for: token) != facts else { return [] }
            state = .current(claim, remembered: claim.target, facts: facts)
            return [.persist(claim.target, facts)]
        case (.invalidated, .loaded), (.invalidated, .remember),
             (.unloaded, .remember), (.unreadable, .remember), (.current, .loaded):
            break
        }
        return []
    }
}
