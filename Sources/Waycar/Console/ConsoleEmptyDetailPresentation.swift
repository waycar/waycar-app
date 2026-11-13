import SwiftUI

struct ConsoleEmptyDetailPresentation: Equatable {
    enum Action: String, CaseIterable, Identifiable {
        case showAgents, newAgent, hosts

        var id: Self { self }
        var title: String {
            switch self {
            case .showAgents: "Show Agents"
            case .newAgent: "New Agent"
            case .hosts: "Hosts"
            }
        }
        var systemImage: String {
            switch self {
            case .showAgents: "sidebar.left"
            case .newAgent: "plus"
            case .hosts: "server.rack"
            }
        }
        var shortcutHint: String? {
            switch self {
            case .showAgents: nil
            case .newAgent: "⌘N"
            case .hosts: "⌘⇧H"
            }
        }
    }

    let title = "No Agent Selected"
    let systemImage = "rectangle.on.rectangle"
    let message: String
    let actions: [Action]

    /// With no Host, the detail shows `HostSetupGuide` instead. With Hosts
    /// but none enabled there is nowhere to start an Agent and nothing to
    /// choose, so the detail says why and leads with Hosts, the only place
    /// the user can fix it; New Agent is not offered.
    init(showsAgentsAction: Bool = true, hostCount: Int = 1, enabledHostCount: Int = 1) {
        if enabledHostCount == 0 {
            message = ConsoleAgentsSurface.allHostsDisabledMessage(hostCount: hostCount)
            actions = showsAgentsAction ? [.hosts, .showAgents] : [.hosts]
        } else {
            message = "Choose an Agent or start a new one to view its live terminal."
            actions = showsAgentsAction ? [.showAgents, .newAgent, .hosts] : [.newAgent, .hosts]
        }
    }
}

struct ConsoleEmptyDetailView: View {
    let presentation: ConsoleEmptyDetailPresentation
    let perform: (ConsoleEmptyDetailPresentation.Action) -> Void

    var body: some View {
        ContentUnavailableView {
            Label(presentation.title, systemImage: presentation.systemImage)
        } description: {
            Text(presentation.message)
        } actions: {
            ForEach(presentation.actions) { action in
                Button {
                    perform(action)
                } label: {
                    HStack {
                        Label(action.title, systemImage: action.systemImage)
                        if let hint = action.shortcutHint {
                            Text(hint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .hoverEffect(.highlight)
            }
        }
    }
}
