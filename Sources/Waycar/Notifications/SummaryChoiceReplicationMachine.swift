import Foundation

/// Replicates the app's summary choice without overlapping per-Host writes.
/// Joining an older write gets one fresh pass, including when it failed;
/// a choice changed during a pass is likewise replayed after the pass joins.
struct SummaryChoiceReplicationMachine: StateMachine {
    enum Replica: Equatable, Sendable {
        case unconfirmed
        case confirmed(Bool)
        case writing(UInt64, choice: Bool, confirmed: Bool?)
        case retryPending(choice: Bool, confirmed: Bool?)

        var confirmedChoice: Bool? {
            switch self {
            case .unconfirmed: nil
            case .confirmed(let choice): choice
            case .writing(_, _, let confirmed), .retryPending(_, let confirmed): confirmed
            }
        }
    }
    struct Batch: Equatable, Sendable {
        let choice: Bool
        let joined: Bool
    }
    struct State: Equatable, Sendable {
        var replicas: [Host.ID: Replica] = [:]
        var batches: [UInt64: Batch] = [:]
    }
    enum Event: Equatable, Sendable {
        case catalogChanged(Set<Host.ID>)
        case apply(Bool, hosts: [Host.ID], updating: Set<Host.ID>)
        case writeFinished(Host.ID, UInt64, succeeded: Bool)
        case batchFinished(UInt64, currentChoice: Bool)
        case registrationConfirmed(Host.ID, Bool)
    }
    enum Effect: Equatable, Sendable {
        case write(Host.ID, UInt64, choice: Bool)
        case waitForWrites(batch: UInt64, writes: [UInt64])
        case reapply
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    func confirmedChoice(for host: Host.ID) -> Bool? { state.replicas[host]?.confirmedChoice }

    func inFlight(for host: Host.ID) -> UInt64? {
        if case .writing(let token, _, _) = state.replicas[host] { token } else { nil }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .catalogChanged(let hosts):
            // Match the existing store's catalog semantics: prune confirmations,
            // but keep writes joinable until they return, even if removed.
            for (host, replica) in state.replicas where !hosts.contains(host) {
                if case .writing(let token, let choice, _) = replica {
                    state.replicas[host] = .writing(token, choice: choice, confirmed: nil)
                } else {
                    state.replicas[host] = nil
                }
            }
            for host in hosts where state.replicas[host] == nil { state.replicas[host] = .unconfirmed }
            return []
        case .apply(let choice, let hosts, let updating):
            var effects: [Effect] = []
            var writes: [UInt64] = []
            var joined = false
            for host in hosts where confirmedChoice(for: host) != choice {
                if let token = inFlight(for: host) {
                    writes.append(token)
                    joined = true
                } else if !updating.contains(host) {
                    let confirmed = confirmedChoice(for: host)
                    lastToken += 1
                    state.replicas[host] = .writing(lastToken, choice: choice, confirmed: confirmed)
                    effects.append(.write(host, lastToken, choice: choice))
                    writes.append(lastToken)
                }
            }
            lastToken += 1
            state.batches[lastToken] = Batch(choice: choice, joined: joined)
            return effects + [.waitForWrites(batch: lastToken, writes: writes)]
        case .writeFinished(let host, let token, let succeeded):
            guard case .writing(let current, let choice, let confirmed) = state.replicas[host],
                current == token else { return [] }
            state.replicas[host] = succeeded ? .confirmed(choice)
                : .retryPending(choice: choice, confirmed: confirmed)
            return []
        case .batchFinished(let token, let choice):
            guard let batch = state.batches.removeValue(forKey: token) else { return [] }
            return batch.joined || batch.choice != choice ? [.reapply] : []
        case .registrationConfirmed(let host, let choice):
            if case .writing(let token, let writing, _) = state.replicas[host] {
                state.replicas[host] = .writing(token, choice: writing, confirmed: choice)
            } else {
                state.replicas[host] = .confirmed(choice)
            }
            return []
        }
    }
}
