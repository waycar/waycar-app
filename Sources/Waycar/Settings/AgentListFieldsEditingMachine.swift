import Foundation

/// A draft session owns all unsaved Host layouts. Ending or restarting it
/// invalidates plugin requests; a later edit invalidates only that Host.
struct AgentListFieldsEditingMachine: StateMachine {
    enum State: Equatable, Sendable {
        case viewing(message: String?)
        case editing(drafts: [Host.ID: AgentRowLayout], message: String?)
    }
    enum Event: Equatable, Sendable {
        case begin
        case cancel
        case edited(Host.ID, AgentRowLayout)
        case syncDraft(Host.ID, AgentRowLayout?)
        case save([Host.ID: AgentRowLayout?])
        case saved
        case messageChanged(String?)
    }
    enum Effect: Equatable, Sendable {
        case invalidateAllSyncs
        case invalidateSync(Host.ID)
        case persist([Host.ID: AgentRowLayout?])
    }

    private(set) var state: State = .viewing(message: nil)

    var isEditing: Bool {
        if case .editing = state { true } else { false }
    }
    var drafts: [Host.ID: AgentRowLayout] {
        if case .editing(let drafts, _) = state { drafts } else { [:] }
    }
    var message: String? {
        switch state {
        case .viewing(let message), .editing(_, let message): message
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .begin):
            state = .editing(drafts: [:], message: nil)
            return [.invalidateAllSyncs]
        case (_, .cancel):
            state = .viewing(message: nil)
            return [.invalidateAllSyncs]
        case (.editing(var drafts, _), .edited(let host, let layout)):
            drafts[host] = layout
            state = .editing(drafts: drafts, message: nil)
            return [.invalidateSync(host)]
        case (.editing(var drafts, let message), .syncDraft(let host, let layout)):
            drafts[host] = layout
            state = .editing(drafts: drafts, message: message)
            return []
        case (.editing, .save(let changes)):
            return [.persist(changes)]
        case (.editing, .saved):
            state = .viewing(message: nil)
            return [.invalidateAllSyncs]
        case (.viewing, .messageChanged(let message)):
            state = .viewing(message: message)
            return []
        case (.editing(let drafts, _), .messageChanged(let message)):
            state = .editing(drafts: drafts, message: message)
            return []
        case (.viewing, .edited), (.viewing, .syncDraft), (.viewing, .save), (.viewing, .saved):
            return []
        }
    }
}
