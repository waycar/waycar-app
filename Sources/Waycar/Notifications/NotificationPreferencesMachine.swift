import Foundation

/// Confirmed per-Host preferences. Busy phases own their operation token;
/// recovery keeps the failed write's token through the mandatory reread.
struct NotificationPreferencesMachine: StateMachine {
    typealias Settings = NotificationPreferencesStore.HostSettings
    typealias Display = NotificationPreferencesStore.HostState

    enum Phase: Equatable, Sendable {
        case unread
        case loading(UInt64)
        case unavailable(String)
        case idle(Settings)
        case updating(UInt64, Settings)
        case recoveringAfterPartialWrite(UInt64, Settings, String)
        case failed(String, Settings)

        var display: Display? {
            switch self {
            case .unread: nil
            case .loading: .loading
            case .unavailable(let message): .unavailable(message: message)
            case .idle(let settings): .idle(settings)
            case .updating(_, let settings), .recoveringAfterPartialWrite(_, let settings, _):
                .updating(settings)
            case .failed(let message, let settings): .failed(message: message, settings: settings)
            }
        }
    }

    struct State: Equatable, Sendable {
        var hosts: [Host.ID: Phase] = [:]
    }
    enum Event: Equatable, Sendable {
        case hostsChanged(Set<Host.ID>)
        case load(Host.ID, hasDeviceToken: Bool)
        case loaded(Host.ID, UInt64, Settings, needsRegistration: Bool)
        case loadFailed(Host.ID, UInt64, String)
        case write(Host.ID, Settings, hasDeviceToken: Bool)
        case written(Host.ID, UInt64, Settings, summaryChoice: Bool?)
        case writeFailed(Host.ID, UInt64, String)
        case recovered(Host.ID, UInt64, Settings)
        case recoveryFailed(Host.ID, UInt64)
    }
    enum Effect: Equatable, Sendable {
        case read(UInt64)
        case write(UInt64)
        case reregister(Settings)
        case reread(UInt64)
        case writeCompleted(summaryChoice: Bool?)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0
    private let waitingForPush = "Waiting for push registration on this device."

    var displays: [Host.ID: Display] { state.hosts.compactMapValues(\.display) }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .hostsChanged(let hosts):
            state.hosts = state.hosts.filter { hosts.contains($0.key) }
            for host in hosts where state.hosts[host] == nil { state.hosts[host] = .unread }
            return []
        case .load(let host, let hasToken):
            guard let phase = state.hosts[host] else { return [] }
            switch phase {
            case .updating, .recoveringAfterPartialWrite: return []
            case .unread, .loading, .unavailable, .idle, .failed:
                guard hasToken else {
                    state.hosts[host] = .unavailable(waitingForPush)
                    return []
                }
                lastToken += 1
                state.hosts[host] = .loading(lastToken)
                return [.read(lastToken)]
            }
        case .loaded(let host, let token, let settings, let needsRegistration):
            guard case .loading(let current) = state.hosts[host], current == token else { return [] }
            state.hosts[host] = .idle(settings)
            return needsRegistration ? [.reregister(settings)] : []
        case .loadFailed(let host, let token, let message):
            guard case .loading(let current) = state.hosts[host], current == token else { return [] }
            state.hosts[host] = .unavailable(message)
            return []
        case .write(let host, let settings, let hasToken):
            guard hasToken else {
                state.hosts[host] = .unavailable(waitingForPush)
                return []
            }
            lastToken += 1
            state.hosts[host] = .updating(lastToken, settings)
            return [.write(lastToken)]
        case .written(let host, let token, let settings, let choice):
            guard case .updating(let current, _) = state.hosts[host], current == token else { return [] }
            state.hosts[host] = .idle(settings)
            return [.writeCompleted(summaryChoice: choice)]
        case .writeFailed(let host, let token, let message):
            guard case .updating(let current, let settings) = state.hosts[host], current == token else { return [] }
            state.hosts[host] = .recoveringAfterPartialWrite(token, settings, message)
            return [.reread(token)]
        case .recovered(let host, let token, let settings):
            guard case .recoveringAfterPartialWrite(let current, _, let message) = state.hosts[host],
                current == token else { return [] }
            state.hosts[host] = .failed(message, settings)
            return [.writeCompleted(summaryChoice: nil)]
        case .recoveryFailed(let host, let token):
            guard case .recoveringAfterPartialWrite(let current, _, let message) = state.hosts[host],
                current == token else { return [] }
            state.hosts[host] = .unavailable(message)
            return [.writeCompleted(summaryChoice: nil)]
        }
    }
}
