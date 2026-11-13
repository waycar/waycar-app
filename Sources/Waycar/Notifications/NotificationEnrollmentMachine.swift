import Foundation

/// Durable enrollment intent per Host. A failed registration returns to
/// waiting; only a fresh confirmed idle/unregistered read permits a retry.
struct NotificationEnrollmentMachine: StateMachine {
    enum HostState: Equatable, Sendable {
        case waiting
        case registering(UInt64)
        case complete
    }

    struct State: Equatable, Sendable {
        var hosts: [Host.ID: HostState] = [:]
    }

    enum Registration: Equatable, Sendable {
        case idleUnregistered
        case registered
        case unknownOrFailed
    }

    enum Event: Equatable, Sendable {
        case initialize(seen: Set<Host.ID>, pending: Set<Host.ID>)
        case clear
        case discover(Set<Host.ID>)
        case consider(Host.ID, Registration, liveEnabled: Bool)
        case registered(Host.ID, token: UInt64, confirmed: Bool, liveEnabled: Bool)
    }

    enum Effect: Equatable, Sendable {
        case register(Host.ID, token: UInt64)
        case enableLiveActivity(Host.ID)
        case save
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    init(seen: Set<Host.ID>, pending: Set<Host.ID>) {
        for id in seen { state.hosts[id] = .complete }
        for id in pending { state.hosts[id] = .waiting }
    }

    var seen: Set<Host.ID> { Set(state.hosts.keys) }
    var pending: Set<Host.ID> {
        Set(state.hosts.compactMap { $0.value == .complete ? nil : $0.key })
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .initialize(let seen, let pending):
            state.hosts = Dictionary(uniqueKeysWithValues: seen.map { ($0, .complete) })
            for id in pending { state.hosts[id] = .waiting }
        case .clear:
            state.hosts = [:]
        case .discover(let ids):
            let new = ids.subtracting(seen)
            for id in new { state.hosts[id] = .waiting }
            return new.isEmpty ? [] : [.save]
        case .consider(let id, let registration, let liveEnabled):
            guard state.hosts[id] == .waiting else { return [] }
            switch registration {
            case .idleUnregistered:
                lastToken &+= 1
                state.hosts[id] = .registering(lastToken)
                return [.register(id, token: lastToken)]
            case .registered:
                return complete(id, liveEnabled: liveEnabled)
            case .unknownOrFailed:
                break
            }
        case .registered(let id, let token, let confirmed, let liveEnabled):
            guard state.hosts[id] == .registering(token) else { return [] }
            guard confirmed else {
                state.hosts[id] = .waiting
                return []
            }
            return complete(id, liveEnabled: liveEnabled)
        }
        return []
    }

    private mutating func complete(_ id: Host.ID, liveEnabled: Bool) -> [Effect] {
        state.hosts[id] = .complete
        return (liveEnabled ? [] : [.enableLiveActivity(id)]) + [.save]
    }
}
