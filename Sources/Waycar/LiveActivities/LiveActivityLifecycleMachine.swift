import Foundation

/// Lifecycle facts for each computer's Live Activity. A dismissal retains
/// its applied desire (LA-02), unlike expiry or a failed request. Session
/// identities reject old state streams; retired activities cannot be adopted.
struct LiveActivityLifecycleMachine: StateMachine {
    struct Live: Equatable, Sendable {
        let id: String
        var applied: AgentActivityDesire?
    }
    enum Phase: Equatable, Sendable {
        case idle
        case active(Live)
        case awaitingSnapshot(Live)
        case dismissed(AgentActivityDesire?)
        case startFailed(AgentActivityDesire?)

        var live: Live? {
            switch self {
            case .active(let live), .awaitingSnapshot(let live): live
            case .idle, .dismissed, .startFailed: nil
            }
        }
        var applied: AgentActivityDesire? {
            switch self {
            case .active(let live), .awaitingSnapshot(let live): live.applied
            case .dismissed(let desire), .startFailed(let desire): desire
            case .idle: nil
            }
        }
        func applying(_ desire: AgentActivityDesire?) -> Self {
            switch self {
            case .active(let live): .active(Live(id: live.id, applied: desire))
            case .awaitingSnapshot(let live): .awaitingSnapshot(Live(id: live.id, applied: desire))
            case .dismissed: .dismissed(desire)
            case .startFailed: .startFailed(desire)
            case .idle: .dismissed(desire)
            }
        }
    }
    enum Settle: Equatable, Sendable { case idle, waiting(UInt64) }
    struct HostState: Equatable, Sendable {
        var phase: Phase = .idle
        var settle: Settle = .idle
    }
    struct SystemActivity: Equatable, Sendable {
        let id: String
        let hostID: Host.ID
        let state: LiveActivityRunState
    }
    struct State: Equatable, Sendable {
        var isStarted = false
        var hosts: [Host.ID: HostState] = [:]
        var retiredIDs: Set<String> = []
        var newest: [Host.ID: String] = [:]
    }
    enum Event: Equatable, Sendable {
        case start
        case schedule(Host.ID)
        case cancelSettle(Host.ID)
        case settleElapsed(Host.ID, UInt64)
        case begin(LiveActivityHandle, awaitingSnapshot: Bool)
        case applied(Host.ID, AgentActivityDesire?)
        case startFailed(Host.ID)
        case forgetFailure(Host.ID)
        case hold(Host.ID)
        case releaseHold(Host.ID)
        case drop(Host.ID, end: Bool)
        case end(Host.ID)
        case expire(Host.ID)
        case activityState(LiveActivityHandle, LiveActivityRunState)
        case retire(String)
        case inventory([SystemActivity], known: Set<Host.ID>, only: Host.ID?)
    }
    enum Effect: Equatable, Sendable {
        case armSettle(Host.ID, UInt64)
        case cancelSettle(UInt64)
        case apply(Host.ID)
        case watch(LiveActivityHandle)
        case cancelWatch(String)
        case endActivity(String)
        case clearToken(Host.ID)
        case schedule(Host.ID)
    }
    struct Session: Equatable, Sendable {
        let id: String
        let awaitingFirstSnapshot: Bool
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var sessions: [Host.ID: Session] {
        state.hosts.compactMapValues {
            switch $0.phase {
            case .active(let live): Session(id: live.id, awaitingFirstSnapshot: false)
            case .awaitingSnapshot(let live): Session(id: live.id, awaitingFirstSnapshot: true)
            case .idle, .dismissed, .startFailed: nil
            }
        }
    }
    var applied: [Host.ID: AgentActivityDesire] { state.hosts.compactMapValues { $0.phase.applied } }
    var failedStarts: Set<Host.ID> {
        Set(state.hosts.compactMap {
            if case .startFailed = $0.value.phase { $0.key } else { nil }
        })
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .start:
            state.isStarted = true
        case .schedule(let host):
            var effects = cancelSettle(host)
            lastToken &+= 1
            state.hosts[host, default: HostState()].settle = .waiting(lastToken)
            effects.append(.armSettle(host, lastToken))
            return effects
        case .cancelSettle(let host):
            return cancelSettle(host)
        case .settleElapsed(let host, let token):
            guard state.hosts[host]?.settle == .waiting(token) else { return [] }
            state.hosts[host]?.settle = .idle
            return [.apply(host)]
        case .begin(let handle, let awaitingSnapshot):
            let live = Live(id: handle.id, applied: state.hosts[handle.hostID]?.phase.applied)
            state.hosts[handle.hostID, default: HostState()].phase = awaitingSnapshot
                ? .awaitingSnapshot(live) : .active(live)
            return [.watch(handle)]
        case .applied(let host, let desire):
            let phase = state.hosts[host]?.phase ?? .idle
            state.hosts[host, default: HostState()].phase = phase.applying(desire)
        case .startFailed(let host):
            let applied = state.hosts[host]?.phase.applied
            state.hosts[host, default: HostState()].phase = .startFailed(applied)
        case .forgetFailure(let host):
            if case .startFailed(let applied) = state.hosts[host]?.phase {
                state.hosts[host]?.phase = applied.map { .dismissed($0) } ?? .idle
            }
        case .hold(let host):
            if case .active(let live) = state.hosts[host]?.phase {
                state.hosts[host]?.phase = .awaitingSnapshot(live)
            }
        case .releaseHold(let host):
            if case .awaitingSnapshot(let live) = state.hosts[host]?.phase {
                state.hosts[host]?.phase = .active(live)
            }
        case .drop(let host, let end):
            return drop(host, end: end)
        case .end(let host):
            let effects = drop(host, end: true)
            state.hosts[host, default: HostState()].phase = .idle
            return effects + [.clearToken(host)]
        case .expire(let host):
            return expire(host)
        case .activityState(let handle, let runState):
            guard state.hosts[handle.hostID]?.phase.live?.id == handle.id else { return [] }
            switch runState {
            case .dismissed:
                return drop(handle.hostID, end: false) + [.clearToken(handle.hostID)]
            case .ended:
                return expire(handle.hostID)
            case .active, .stale:
                break
            }
        case .retire(let id):
            state.retiredIDs.insert(id)
            return [.endActivity(id)]
        case .inventory(let inventory, let known, let only):
            let current = inventory.filter { $0.state != .dismissed }
            state.retiredIDs.formIntersection(current.map(\.id))
            state.newest = [:]
            var effects: [Effect] = []
            for activity in current {
                if let only, activity.hostID != only { continue }
                guard known.contains(activity.hostID), activity.state != .ended,
                    !state.retiredIDs.contains(activity.id) else {
                    state.retiredIDs.insert(activity.id)
                    effects.append(.endActivity(activity.id))
                    continue
                }
                if let older = state.newest[activity.hostID] {
                    state.retiredIDs.insert(older)
                    effects.append(.endActivity(older))
                }
                state.newest[activity.hostID] = activity.id
            }
            return effects
        }
        return []
    }

    private mutating func cancelSettle(_ host: Host.ID) -> [Effect] {
        guard case .waiting(let token) = state.hosts[host]?.settle else { return [] }
        state.hosts[host]?.settle = .idle
        return [.cancelSettle(token)]
    }

    private mutating func drop(_ host: Host.ID, end: Bool) -> [Effect] {
        guard let live = state.hosts[host]?.phase.live else { return [] }
        state.hosts[host]?.phase = .dismissed(live.applied)
        state.retiredIDs.insert(live.id)
        return [.cancelWatch(live.id)] + (end ? [.endActivity(live.id)] : [])
    }

    private mutating func expire(_ host: Host.ID) -> [Effect] {
        let effects = drop(host, end: true)
        let phase = state.hosts[host]?.phase ?? .idle
        state.hosts[host, default: HostState()].phase = phase.applying(nil)
        return effects + [.clearToken(host), .schedule(host)]
    }
}
