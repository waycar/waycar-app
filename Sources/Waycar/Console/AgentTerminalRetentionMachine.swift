import Foundation

/// One cached entry is presented, retained idle with an expiry, or permanently
/// evicted. Presentation ownership can move only while idle. Timer and teardown
/// completions belong to this entry's tokens, never to a successor's lifetime.
struct AgentTerminalRetentionMachine: StateMachine {
    enum State: Equatable, Sendable {
        case presented(owner: UUID)
        case retainedIdle(owner: UUID, expiry: UInt64)
        case evicting(teardown: UInt64)
        case removed
    }

    enum Event: Equatable, Sendable {
        case claimPresentation(UUID)
        case activate(UUID)
        case release(UUID)
        case expiryElapsed(UInt64)
        case evict
        case teardownFinished(UInt64)
    }

    enum Effect: Equatable, Sendable {
        case cancelExpiry
        case scheduleExpiry(UInt64)
        case evict
        case tearDown(UInt64)
    }

    private(set) var state: State
    private var lastToken: UInt64 = 0

    init(ownerID: UUID) {
        state = .presented(owner: ownerID)
    }

    var isRetained: Bool {
        switch state {
        case .presented, .retainedIdle: true
        case .evicting, .removed: false
        }
    }

    var isVisible: Bool {
        if case .presented = state { return true }
        return false
    }

    var presentationOwnerID: UUID? {
        switch state {
        case .presented(let owner), .retainedIdle(let owner, _): owner
        case .evicting, .removed: nil
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.retainedIdle(_, let expiry), .claimPresentation(let owner)):
            state = .retainedIdle(owner: owner, expiry: expiry)
            return []
        case (.presented(let owner), .activate(let received)) where owner == received,
             (.retainedIdle(let owner, _), .activate(let received)) where owner == received:
            state = .presented(owner: owner)
            return [.cancelExpiry]
        case (.presented(let owner), .release(let received)) where owner == received,
             (.retainedIdle(let owner, _), .release(let received)) where owner == received:
            lastToken &+= 1
            state = .retainedIdle(owner: owner, expiry: lastToken)
            return [.scheduleExpiry(lastToken)]
        case (.retainedIdle(_, let expiry), .expiryElapsed(let received)) where expiry == received:
            return [.evict]
        case (.presented, .evict), (.retainedIdle, .evict):
            lastToken &+= 1
            state = .evicting(teardown: lastToken)
            return [.tearDown(lastToken)]
        case (.evicting(let teardown), .teardownFinished(let received)) where teardown == received:
            state = .removed
            return []
        case (.presented, .claimPresentation), (.presented, .activate), (.presented, .release),
             (.presented, .expiryElapsed), (.presented, .teardownFinished),
             (.retainedIdle, .activate), (.retainedIdle, .release),
             (.retainedIdle, .expiryElapsed), (.retainedIdle, .teardownFinished),
             (.evicting, _), (.removed, _):
            return []
        }
    }
}
