import Foundation

/// Joins a voice envelope and its independently transferred file in either
/// order. Tasks, files and activity holds are performed/kept by the bridge.
struct WatchRecordingRendezvousMachine: StateMachine {
    enum Record: Equatable, Sendable {
        case fileWaiting(url: URL, arrived: Date, expiry: UInt64)
        case messageWaiting(agentID: ConsoleAgent.ID, messageToken: UInt64, wait: UInt64)
        case expired
    }

    struct State: Equatable, Sendable {
        var records: [UUID: Record] = [:]
        var expiredOrder: [UUID] = []
    }

    enum Event: Sendable {
        case message(UUID, ConsoleAgent.ID, token: UInt64)
        /// Admission comes from the message ledger; a waiting envelope takes
        /// precedence over it, while other processing/final ids reject copies.
        case file(UUID, URL, arrived: Date, acceptUnclaimed: Bool)
        case waitExpired(UUID, token: UInt64)
        case fileExpired(UUID, token: UInt64)
        case sweep(cutoff: Date)
    }

    enum Effect: Equatable, Sendable {
        case waitForFile(UUID, token: UInt64)
        case armExpiry(UUID, token: UInt64)
        case cancelTimer(UInt64)
        case delete(URL)
        case transcribe(UUID, URL, ConsoleAgent.ID, messageToken: UInt64, waiting: UInt64?)
        case missing(UUID, messageToken: UInt64, waiting: UInt64?)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0
    let memoryLimit: Int

    init(memoryLimit: Int = 64) { self.memoryLimit = memoryLimit }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .message(let id, let agent, let token):
            switch state.records[id] {
            case .fileWaiting(let url, _, let expiry):
                state.records[id] = nil
                return [.cancelTimer(expiry), .transcribe(id, url, agent, messageToken: token, waiting: nil)]
            case .expired:
                state.records[id] = nil
                state.expiredOrder.removeAll { $0 == id }
                return [.missing(id, messageToken: token, waiting: nil)]
            case .messageWaiting: return []
            case nil:
                lastToken += 1
                state.records[id] = .messageWaiting(agentID: agent, messageToken: token, wait: lastToken)
                return [.waitForFile(id, token: lastToken)]
            }
        case .file(let id, let url, let arrived, let accept):
            if case .messageWaiting(let agent, let messageToken, let wait) = state.records[id] {
                state.records[id] = nil
                return [.cancelTimer(wait), .transcribe(id, url, agent, messageToken: messageToken, waiting: wait)]
            }
            guard accept else { return [.delete(url)] }
            var effects: [Effect] = []
            if case .fileWaiting(let old, _, let expiry) = state.records[id] {
                effects = [.cancelTimer(expiry), .delete(old)]
            }
            state.expiredOrder.removeAll { $0 == id }
            lastToken += 1
            state.records[id] = .fileWaiting(url: url, arrived: arrived, expiry: lastToken)
            return effects + [.armExpiry(id, token: lastToken)]
        case .waitExpired(let id, let token):
            guard case .messageWaiting(_, let messageToken, let wait) = state.records[id], wait == token else { return [] }
            state.records[id] = nil
            return [.cancelTimer(wait), .missing(id, messageToken: messageToken, waiting: wait)]
        case .fileExpired(let id, let token):
            return expire(id, token: token)
        case .sweep(let cutoff):
            let expired = state.records.compactMap { id, record -> (UUID, UInt64)? in
                if case .fileWaiting(_, let arrived, let token) = record, arrived <= cutoff { return (id, token) }
                return nil
            }
            return expired.flatMap { expire($0.0, token: $0.1) }
        }
    }

    private mutating func expire(_ id: UUID, token: UInt64) -> [Effect] {
        guard case .fileWaiting(let url, _, let current) = state.records[id], current == token else { return [] }
        state.records[id] = .expired
        state.expiredOrder.append(id)
        if state.expiredOrder.count > memoryLimit {
            state.records[state.expiredOrder.removeFirst()] = nil
        }
        return [.cancelTimer(token), .delete(url)]
    }
}
