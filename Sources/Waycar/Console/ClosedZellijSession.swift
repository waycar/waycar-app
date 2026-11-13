import Foundation

/// A Host's saved Zellij layout. Kept by Zellij, never synced/expired as an Agent record.
struct ClosedZellijSession: Identifiable, Equatable {
    let hostID: Host.ID
    let hostName: String
    let session: ZellijClosedSession
    var id: String { hostID.uuidString + ":" + session.name }
    var deleteTitle: String { "Delete Zellij session “\(session.name)”?" }
    static let deleteMessage = "Its saved layout is removed from the Host."

    var terminalRow: ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: hostName,
            agent: Agent(
                terminalID: session.terminalID, kind: Agent.shellKind, title: session.name,
                status: .shellTerminal, workspaceID: ZellijPaneID.workspace(session: session.name),
                tabID: "", paneID: session.terminalID, cwd: "", revision: 0, name: session.name),
            workspaceLabel: nil, repositoryCheckout: nil, backend: .zellij)
    }
}

extension ConsoleStore {
    var closedZellijSessions: [ClosedZellijSession] {
        projections.values.filter { $0.backend == .zellij }.flatMap { projection in
            projection.closedZellijSessions.map {
                ClosedZellijSession(hostID: projection.host.id, hostName: projection.host.displayName, session: $0)
            }
        }
    }

    func refreshClosedZellijSessions() async {
        for projection in projections.values where projection.backend == .zellij && projection.status == .connected {
            try? await projection.refreshClosedZellijSessions()
        }
    }

    func deleteClosedZellijSession(_ row: ClosedZellijSession) async throws {
        guard let projection = projection(on: row.hostID, backend: .zellij) else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        try await projection.session.withTransport { try await $0.deleteZellijSession(row.session.name) }
        try await projection.refreshClosedZellijSessions()
    }
}
