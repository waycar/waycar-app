import Foundation

/// One phone activity lease shared by requests and the reachable watch.
/// Expiration invalidates every owner before replying, then releases the app.
struct WatchActivityLeaseMachine: StateMachine {
    enum State: Equatable, Sendable {
        case released
        case held(generation: Int, owners: Set<UUID>, reachable: Bool)
    }

    enum Event: Sendable {
        case acquire(UUID)
        case release(UUID)
        case reachability(Bool)
        case expired(Int)
    }

    enum Effect: Equatable, Sendable {
        case begin(Int)
        case startPublishing
        case expireReplies
        case release
    }

    private(set) var state: State = .released
    private var generation = 0

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.released, .acquire(let owner)):
            generation += 1
            state = .held(generation: generation, owners: [owner], reachable: false)
            return [.begin(generation)]
        case (.released, .reachability(true)):
            generation += 1
            state = .held(generation: generation, owners: [], reachable: true)
            return [.begin(generation), .startPublishing]
        case (.held(let generation, var owners, let reachable), .acquire(let owner)):
            owners.insert(owner)
            state = .held(generation: generation, owners: owners, reachable: reachable)
            return []
        case (.held(let generation, var owners, let reachable), .release(let owner)):
            guard owners.remove(owner) != nil else { return [] }
            if owners.isEmpty && !reachable {
                state = .released
                return [.release]
            }
            state = .held(generation: generation, owners: owners, reachable: reachable)
            return []
        case (.held(let generation, let owners, let reachable), .reachability(let next)):
            guard next != reachable else { return [] }
            if !next && owners.isEmpty {
                state = .released
                return [.release]
            }
            state = .held(generation: generation, owners: owners, reachable: next)
            return next ? [.startPublishing] : []
        case (.held(let generation, _, _), .expired(let token)):
            guard generation == token else { return [] }
            state = .released
            return [.expireReplies, .release]
        case (.released, .release), (.released, .reachability(false)), (.released, .expired):
            return []
        }
    }
}
