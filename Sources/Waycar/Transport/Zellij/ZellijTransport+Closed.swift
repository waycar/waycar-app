import Foundation

extension ZellijTransport {
    func closedZellijSessions(refreshAge: Bool) async throws -> [ZellijClosedSession] {
        try ensureOpen()
        if refreshAge {
            let listing = try await exec(commands.listSessions(), allowsNoSessions: true)
            let closed = ZellijClosedSession.listing(listing)
            closedSessionAges = Dictionary(closed.compactMap { row in row.age.map { (row.name, $0) } },
                uniquingKeysWith: { first, _ in first })
            return closed
        }
        return frame.closedSessions.map { ZellijClosedSession(name: $0.name, age: closedSessionAges[$0.name]) }
    }

    func deleteZellijSession(_ name: String) async throws {
        guard ZellijPaneID.isSessionName(name) else {
            throw HerdrAPIError(code: "invalid_session", message: "Invalid Zellij session name")
        }
        // Recheck at the destructive boundary: a desk may have resumed it since the list opened.
        let listing = try await exec(commands.listSessions(), allowsNoSessions: true)
        guard ZellijSessionRecord.listing(listing).contains(where: { $0.name == name && $0.closed }) else {
            throw HerdrAPIError(code: "session_not_closed", message: "This Zellij session is no longer closed")
        }
        try await exec(commands.deleteSession(name: name))
        closedSessionAges[name] = nil
    }
}
