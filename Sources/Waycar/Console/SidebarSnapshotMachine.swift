import Foundation

/// One Host's borrowed sidebar read. The visible layout and the latest read's
/// answer deliberately differ after a connection failure. Disconnect retains
/// both; invalidation forgets them, but never reuses a read token.
struct SidebarSnapshotMachine: StateMachine {
    typealias Connection = HerdrSidebarSnapshotStore.Connection
    typealias HostState = HerdrSidebarSnapshotStore.HostState

    struct Facts: Equatable, Sendable {
        var displayed: HostState?
        var answer: HostState?
        var file: ConsoleInventoryCache.SidebarLayout?
    }
    enum State: Equatable, Sendable {
        case disconnected(Facts)
        case connected(Connection, Facts)
        case reading(Connection, token: UInt64, Facts)
    }
    enum Outcome: Equatable, Sendable {
        case loaded(Data?)
        case connectionFailed
        case failed
    }
    enum Event: Equatable, Sendable {
        case seed(ConsoleInventoryCache.SidebarLayout)
        case reconcile(Connection?)
        case refresh
        case finished(UInt64, Outcome)
        case invalidate
    }
    enum Effect: Equatable, Sendable {
        case cancel(UInt64)
        case read(UInt64)
        case publish(Facts)
        case didChange
    }

    private(set) var state: State = .disconnected(Facts())
    private var lastToken: UInt64 = 0

    var connection: Connection? {
        switch state {
        case .disconnected: nil
        case .connected(let connection, _), .reading(let connection, _, _): connection
        }
    }
    var facts: Facts {
        switch state {
        case .disconnected(let facts), .connected(_, let facts), .reading(_, _, let facts): facts
        }
    }
    var pendingToken: UInt64? {
        guard case .reading(_, let token, _) = state else { return nil }
        return token
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .seed(let file)):
            guard facts.displayed == nil else { return [] }
            var next = facts
            next.displayed = .loaded(AgentRowLayoutSnapshot.decode(file.data))
            next.file = file
            switch state {
            case .disconnected: state = .disconnected(next)
            case .connected(let connection, _): state = .connected(connection, next)
            case .reading(let connection, let token, _): state = .reading(connection, token: token, next)
            }
            return [.publish(next)]
        case (_, .invalidate):
            let cancel = pendingToken.map { [Effect.cancel($0)] } ?? []
            let next = Facts()
            state = .disconnected(next)
            return cancel + [.publish(next)]
        case (_, .reconcile(nil)):
            let cancel = pendingToken.map { [Effect.cancel($0)] } ?? []
            state = .disconnected(facts)
            return cancel
        case (_, .reconcile(let next?)):
            guard connection != next else { return [] }
            return start(next)
        case (.connected(let connection, _), .refresh), (.reading(let connection, _, _), .refresh):
            return start(connection)
        case (.reading(let connection, let current, var next), .finished(let token, let outcome)):
            guard token == current else { return [] }
            switch outcome {
            case .loaded(let data):
                next.displayed = .loaded(AgentRowLayoutSnapshot.decode(data))
                next.answer = next.displayed
                next.file = .init(data: data)
            case .connectionFailed:
                next.answer = .unavailable
                if next.displayed == nil || next.displayed == .loading { next.displayed = .unavailable }
            case .failed:
                next.displayed = .unavailable
                next.answer = .unavailable
                next.file = nil
            }
            state = .connected(connection, next)
            return [.publish(next), .didChange]
        case (.disconnected, .refresh), (.disconnected, .finished), (.connected, .finished):
            return []
        }
    }

    private mutating func start(_ connection: Connection) -> [Effect] {
        var effects = pendingToken.map { [Effect.cancel($0)] } ?? []
        var next = facts
        if next.displayed == nil {
            next.displayed = .loading
            effects.append(.publish(next))
        }
        lastToken &+= 1
        state = .reading(connection, token: lastToken, next)
        return effects + [.read(lastToken)]
    }
}
