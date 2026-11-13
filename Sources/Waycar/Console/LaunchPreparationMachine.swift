import Foundation

/// The editable form becomes a Host-bound launch before attachment preparation
/// suspends. Home lookup deliberately precedes that snapshot, so a changed kind
/// is still selected after the lookup, but never another Host's Workspace.
struct LaunchPreparationMachine: StateMachine {
    struct Target: Equatable, Sendable {
        let hostID: Host.ID
        let workspaceID: String?
        let dispatch: StartAgentStore.Dispatch
        let queuedBackend: HostBackend?
    }

    enum State: Equatable, Sendable {
        case editing
        case assembling(UInt64, Host.ID)
        case resolvingHome(UInt64, Host.ID)
        case preparing(UInt64, Target)
        case prepared(UInt64, LaunchDraft)
    }

    enum Event: Equatable, Sendable {
        case begin(Host.ID)
        case resolvingHome(UInt64)
        case homeResolved(UInt64, applies: Bool)
        case preparing(UInt64, Target)
        case prepared(UInt64, LaunchDraft)
        case finish(UInt64)
    }

    enum Effect: Equatable, Sendable {
        case assemble(UInt64)
        case useDraft(LaunchDraft)
    }

    private(set) var state: State = .editing
    private var lastToken: UInt64 = 0

    var isPreparing: Bool { token != nil }

    private var token: UInt64? {
        switch state {
        case .editing: nil
        case .assembling(let token, _), .resolvingHome(let token, _),
            .preparing(let token, _), .prepared(let token, _): token
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.editing, .begin(let hostID)):
            lastToken += 1
            state = .assembling(lastToken, hostID)
            return [.assemble(lastToken)]
        case (.assembling(let current, let hostID), .resolvingHome(let token)) where current == token:
            state = .resolvingHome(token, hostID)
            return []
        case (.resolvingHome(let current, let hostID), .homeResolved(let token, let applies))
            where current == token:
            state = applies ? .assembling(token, hostID) : .editing
            return applies ? [.assemble(token)] : []
        case (.assembling(let current, let hostID), .preparing(let token, let target))
            where current == token && hostID == target.hostID:
            state = .preparing(token, target)
            return []
        case (.preparing(let current, let target), .prepared(let token, let draft))
            where current == token && target.hostID == draft.hostID
                && target.workspaceID == draft.workspaceID && target.dispatch == draft.dispatch:
            state = .prepared(token, draft)
            return [.useDraft(draft)]
        case (_, .finish(let token)) where self.token == token:
            state = .editing
            return []
        case (.editing, _), (.assembling, _), (.resolvingHome, _), (.preparing, _), (.prepared, _):
            return []
        }
    }
}
