import Foundation

@testable import Waycar

extension ClosedSession {
    static func fixture(
        hostID: Host.ID = UUID(),
        hostName: String = "alpha",
        kind: SupportedAgentKind = .claude,
        agentName: String? = nil,
        title: String? = "Task",
        cwd: String = "/work/project",
        workspaceID: String? = "w1",
        workspaceLabel: String? = "Project",
        tabLabel: String? = nil,
        session: SessionReference? = nil,
        terminalID: String = "term",
        lastSeenRunningAt: Date? = nil,
        closedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        backend: HostBackend = .herdr
    ) -> ClosedSession {
        ClosedSession(
            id: recordID(hostID: hostID, kind: kind, session: session, terminalID: terminalID),
            hostID: hostID, hostName: hostName, kind: kind, agentName: agentName, title: title,
            cwd: cwd, workspaceID: workspaceID, workspaceLabel: workspaceLabel,
            tabLabel: tabLabel, session: session,
            lastSeenRunningAt: lastSeenRunningAt ?? closedAt, closedAt: closedAt, backend: backend)
    }
}

/// A clock a test moves by hand, for Closed Session capture and expiry.
@MainActor
final class ManualClock {
    var now: Date

    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

/// A throwaway directory for a `ClosedSessionsStore`'s file, so a relaunch
/// reads what the last store wrote.
func makeClosedSessionsDirectory() -> (URL, cleanup: () -> Void) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "closed-sessions-\(UUID().uuidString)", directoryHint: .isDirectory)
    return (directory, { try? FileManager.default.removeItem(at: directory) })
}
