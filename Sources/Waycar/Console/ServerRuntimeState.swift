import Foundation

/// A server chat runtime (`ServerChatBackend`) is installed independently of
/// its shared server. Only Host detail and New Agent present this state; a
/// stopped server is not a Console failure.
enum ServerRuntimeState: Equatable, Sendable {
    case notInstalled
    case needsUpdate(version: String)
    /// Detection's question about it did not answer in time: its CLI
    /// (`codex --version`) or its server's state (`daemon version`).
    case notResponding(HostDetectionProbe)
    case stopped(error: String? = nil)
    case running
    case starting

    /// Detection is a fact, not a start: only the start machine can supply
    /// `starting`, which takes precedence over even a stale stopped presence.
    init(server: ServerChatBackend, presence: HostBackendPresence?, starting: Bool, error: String?) {
        if starting {
            self = .starting
            return
        }
        let silent = presence?.unansweredProbe(of: server.backend)
        guard let found = presence.flatMap(server.presence(in:)) else {
            self = silent.map(ServerRuntimeState.notResponding) ?? .notInstalled
            return
        }
        guard found.meetsFloor else {
            self = .needsUpdate(version: found.version)
            return
        }
        if found.isRunning { self = .running }
        else if let silent { self = .notResponding(silent) }
        else { self = .stopped(error: error) }
    }

    var isAvailable: Bool {
        switch self {
        case .stopped, .running, .starting: true
        case .notInstalled, .needsUpdate, .notResponding: false
        }
    }

    var startError: String? {
        if case .stopped(let error) = self { return error }
        return nil
    }
}
