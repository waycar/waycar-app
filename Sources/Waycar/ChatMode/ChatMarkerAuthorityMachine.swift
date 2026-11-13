import Foundation

/// One pane's marker: the Host is authoritative except during a local write's
/// grace period, or while an explicitly retired launch still needs deletion.
struct ChatMarkerAuthorityMachine: StateMachine {
    enum State: Equatable, Sendable {
        case absent
        case local(ChatModeMarker, recordedAt: Date)
        case confirmed(ChatModeMarker)
        case retired(launchedAt: Date)
    }

    enum Event: Equatable, Sendable {
        case record(ChatModeMarker, now: Date)
        case reported(ChatModeMarker?, now: Date)
        case retire
        case session(ChatModeMarker.Session, now: Date)
        case follow(Agent, now: Date)
    }

    enum Effect: Equatable, Sendable {
        case changed(revision: Bool)
        case rewrite(ChatModeMarker)
        case delete
    }

    private(set) var state: State
    static let localRecordGrace: TimeInterval = 120

    init(state: State = .absent) { self.state = state }

    var marker: ChatModeMarker? {
        switch state {
        case .local(let marker, _), .confirmed(let marker): marker
        case .absent, .retired: nil
        }
    }

    var recordedAt: Date? {
        if case .local(_, let stamp) = state { return stamp }
        return nil
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .record(let marker, let now)):
            state = .local(marker, recordedAt: now)
            return [.changed(revision: true)]
        case (.local(let local, let stamp), .reported(let hostCopy, let now))
            where now.timeIntervalSince(stamp) < Self.localRecordGrace
                && !Self.supersedes(hostCopy, local: local):
            return [.rewrite(local)]
        case (.retired(let launch), .reported(let hostCopy?, _))
            where hostCopy.launchedAt.timeIntervalSince(launch) < 0.001:
            return [.delete]
        case (_, .reported(let hostCopy, _)):
            let next: State = hostCopy.map { .confirmed($0) } ?? .absent
            guard state != next else { return [] }
            let revises = marker != hostCopy || recordedAt != nil
            state = next
            return [.changed(revision: revises)]
        case (.local(let marker, _), .retire), (.confirmed(let marker), .retire):
            state = .retired(launchedAt: marker.launchedAt)
            return [.changed(revision: true)]
        case (.local(let marker, _), .session(let session, let now)),
             (.confirmed(let marker), .session(let session, let now)):
            state = .local(Self.updating(marker, terminalID: marker.terminalID, session: session), recordedAt: now)
            return [.changed(revision: true)]
        case (.local(let marker, _), .follow(let agent, let now)),
             (.confirmed(let marker), .follow(let agent, let now)):
            guard marker.applies(to: agent) else { return [] }
            let terminalID = marker.terminalID == nil ? nil : agent.terminalID
            let session: ChatModeMarker.Session?
            if let live = agent.agentSession, !live.value.isEmpty {
                session = .init(kind: live.kind.rawValue, value: live.value)
            } else {
                session = marker.session
            }
            guard terminalID != marker.terminalID || session != marker.session else { return [] }
            state = .local(Self.updating(marker, terminalID: terminalID, session: session), recordedAt: now)
            return [.changed(revision: true)]
        case (.absent, .retire), (.absent, .session), (.absent, .follow),
             (.retired, .retire), (.retired, .session), (.retired, .follow):
            return []
        }
    }

    private static func supersedes(_ hostCopy: ChatModeMarker?, local: ChatModeMarker) -> Bool {
        guard let hostCopy else { return false }
        let offset = hostCopy.launchedAt.timeIntervalSince(local.launchedAt)
        guard abs(offset) < 0.001 else { return offset > 0 }
        return (hostCopy.session != nil || local.session == nil)
            && (local.terminalID == nil || hostCopy.terminalID == local.terminalID)
    }

    private static func updating(
        _ marker: ChatModeMarker, terminalID: String?, session: ChatModeMarker.Session?
    ) -> ChatModeMarker {
        ChatModeMarker(
            v: marker.v, paneID: marker.paneID, terminalID: terminalID, kind: marker.kind,
            cwd: marker.cwd, session: session, prompt: marker.prompt,
            chatMode: marker.chatMode, launchedAt: marker.launchedAt)
    }
}
