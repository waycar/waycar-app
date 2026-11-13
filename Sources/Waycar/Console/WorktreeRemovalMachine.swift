import Foundation

/// One immutable removal request, from write-boundary authorization to a
/// reply or a strictly later snapshot. Its caller-minted UUID is its token.
struct WorktreeRemovalMachine: StateMachine {
    enum State: Equatable, Sendable {
        case preparing
        case authorized(affected: Set<ConsoleAgent.ID>)
        case dispatched(affected: Set<ConsoleAgent.ID>, snapshotGeneration: UInt64)
        case unconfirmed(affected: Set<ConsoleAgent.ID>, snapshotGeneration: UInt64)
        case removed(WorktreeRemovalReceipt)
        case refused
    }

    enum Event: Equatable, Sendable {
        /// nil means the owner could not prove the exact linked checkout on
        /// this connection. Re-entry after dispatch needs no second proof.
        case authorize(WorktreeRemovalRequest, affected: Set<ConsoleAgent.ID>?)
        case dispatched(WorktreeRemovalRequest, snapshotGeneration: UInt64)
        case unconfirmed(WorktreeRemovalRequest)
        case succeeded(WorktreeRemovalRequest, snapshotGeneration: UInt64)
        case refused
        case snapshot(generation: UInt64, stillPresent: Bool)

        var request: WorktreeRemovalRequest? {
            switch self {
            case .authorize(let request, _), .dispatched(let request, _),
                 .unconfirmed(let request), .succeeded(let request, _): request
            case .refused, .snapshot: nil
            }
        }
    }

    enum Effect: Equatable, Sendable {
        case record(WorktreeRemovalReceipt, snapshotGeneration: UInt64)
        case finish
        case reject(WorktreeRemovalError)
    }

    let request: WorktreeRemovalRequest
    private(set) var state: State = .preparing

    var requiresIdentityProof: Bool {
        switch state {
        case .preparing, .authorized: true
        case .dispatched, .unconfirmed, .removed, .refused: false
        }
    }

    var isDispatched: Bool {
        if case .dispatched = state { return true }
        return false
    }

    func canReconcileSnapshot(generation: UInt64) -> Bool {
        guard case .unconfirmed(_, let dispatched) = state else { return false }
        return generation > dispatched
    }

    private var affectedAgentIDs: Set<ConsoleAgent.ID> {
        switch state {
        case .authorized(let affected), .dispatched(let affected, _), .unconfirmed(let affected, _):
            affected
        case .removed(let receipt): receipt.affectedAgentIDs
        case .preparing, .refused: []
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        if let supplied = event.request, supplied != request {
            return [.reject(.staleIdentity)]
        }
        switch (state, event) {
        case (.preparing, .authorize(_, let affected)), (.authorized, .authorize(_, let affected)):
            guard let affected else { return [.reject(.staleIdentity)] }
            state = .authorized(affected: affected)
            return []
        case (.dispatched, .authorize):
            // Transport link recovery can legitimately re-enter the same
            // write boundary. Never replace the dispatch-time affected IDs.
            return []
        case (.unconfirmed, .authorize), (.removed, .authorize), (.refused, .authorize):
            return [.reject(.staleIdentity)]
        case (.preparing, .dispatched(_, let generation)),
             (.authorized, .dispatched(_, let generation)):
            state = .dispatched(affected: affectedAgentIDs, snapshotGeneration: generation)
            return []
        case (.dispatched, .dispatched), (.unconfirmed, .dispatched),
             (.removed, .dispatched), (.refused, .dispatched):
            return []
        case (.dispatched(let affected, let generation), .unconfirmed):
            state = .unconfirmed(affected: affected, snapshotGeneration: generation)
            return []
        case (.preparing, .unconfirmed), (.authorized, .unconfirmed),
             (.unconfirmed, .unconfirmed), (.removed, .unconfirmed), (.refused, .unconfirmed):
            return [.reject(.staleIdentity)]
        case (.preparing, .succeeded(_, let generation)), (.authorized, .succeeded(_, let generation)),
             (.dispatched, .succeeded(_, let generation)), (.unconfirmed, .succeeded(_, let generation)):
            return remove(at: generation)
        case (.removed, .succeeded), (.refused, .succeeded):
            return [.reject(.staleIdentity)]
        case (.unconfirmed(_, let dispatched), .snapshot(let generation, let stillPresent)):
            guard generation > dispatched else { return [] }
            if stillPresent {
                state = .refused
                return [.finish]
            }
            return remove(at: generation)
        case (.preparing, .snapshot), (.authorized, .snapshot), (.dispatched, .snapshot),
             (.removed, .snapshot), (.refused, .snapshot):
            return []
        case (.preparing, .refused), (.authorized, .refused), (.dispatched, .refused),
             (.unconfirmed, .refused):
            state = .refused
            return [.finish]
        case (.removed, .refused), (.refused, .refused):
            return []
        }
    }

    private mutating func remove(at generation: UInt64) -> [Effect] {
        let receipt = WorktreeRemovalReceipt(request: request, affectedAgentIDs: affectedAgentIDs)
        state = .removed(receipt)
        return [.record(receipt, snapshotGeneration: generation), .finish]
    }
}
