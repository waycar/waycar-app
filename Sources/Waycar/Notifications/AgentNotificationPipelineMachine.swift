import Foundation

/// Anti-flap and voice deferral per Agent. Presentation gates arrive at fire
/// time; timer tokens, push timestamps and status revalidation reject stale work.
struct AgentNotificationPipelineMachine: StateMachine {
    struct Summary: Equatable, Sendable {
        let status: AgentStatus
        let body: String
    }
    struct Observation: Equatable, Sendable {
        let status: AgentStatus
        let changedAt: Date
        var summary: Summary?
    }
    struct Candidate: Equatable, Sendable {
        var banner: AgentNotificationBanner
        let sound: Bool
    }
    enum AgentState: Equatable, Sendable {
        /// A summary can precede even the first live inventory.
        case unseen(Summary)
        case baseline(Observation)
        case holding(Observation, token: UInt64, banner: AgentNotificationBanner)
        case deferred(Observation, Candidate, announced: Bool)
        case announced(Observation)

        var observation: Observation? {
            switch self {
            case .unseen: nil
            case .baseline(let value), .holding(let value, _, _),
                 .deferred(let value, _, _), .announced(let value): value
            }
        }
        var summary: Summary? {
            switch self {
            case .unseen(let summary): summary
            case .baseline, .holding, .deferred, .announced: observation?.summary
            }
        }
        var wasAnnounced: Bool {
            switch self {
            case .announced: true
            case .deferred(_, _, let announced): announced
            case .unseen, .baseline, .holding: false
            }
        }
        var hold: UInt64? {
            if case .holding(_, let token, _) = self { token } else { nil }
        }
        func withSummary(_ summary: Summary) -> Self {
            guard var value = observation else { return .unseen(summary) }
            value.summary = summary
            switch self {
            case .unseen: return .unseen(summary)
            case .baseline: return .baseline(value)
            case .holding(_, let token, let banner): return .holding(value, token: token, banner: banner)
            case .deferred(_, let candidate, let announced): return .deferred(value, candidate, announced: announced)
            case .announced: return .announced(value)
            }
        }
    }
    enum Replay: Equatable, Sendable { case idle, waiting(UInt64) }
    struct State: Equatable, Sendable {
        var agents: [ConsoleAgent.ID: AgentState] = [:]
        var replay: Replay = .idle
    }
    enum Gate: Equatable, Sendable { case suppressed, voiceQuiet, disabled, allowed }
    enum Event: Equatable, Sendable {
        case observed(AgentNotificationBanner, at: Date)
        case removed(ConsoleAgent.ID)
        case push(AgentNotificationBanner, timestamp: Date, showing: AgentNotificationBanner?, gate: Gate)
        case holdElapsed(ConsoleAgent.ID, UInt64, Gate)
        case replayElapsed(UInt64, gates: [ConsoleAgent.ID: Gate])
    }
    enum Effect: Equatable, Sendable {
        case armHold(ConsoleAgent.ID, UInt64)
        case cancelHold(ConsoleAgent.ID, UInt64)
        case show(AgentNotificationBanner, sound: Bool)
        case armReplay(UInt64)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var knownIDs: Set<ConsoleAgent.ID> {
        Set(state.agents.compactMap { $0.value.observation == nil ? nil : $0.key })
    }
    var deferred: [ConsoleAgent.ID: AgentNotificationTarget] {
        state.agents.compactMapValues {
            if case .deferred(_, let item, _) = $0 { item.banner.target } else { nil }
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .removed(let id):
            let old = state.agents.removeValue(forKey: id)
            return old?.hold.map { [.cancelHold(id, $0)] } ?? []
        case .observed(let banner, let now):
            let id = banner.target.agentID
            let old = state.agents[id]
            guard old?.observation?.status != banner.status else { return [] }
            let summary = old?.summary.flatMap { $0.status == banner.status ? $0 : nil }
            let observation = Observation(status: banner.status, changedAt: now, summary: summary)
            var effects = old?.hold.map { [Effect.cancelHold(id, $0)] } ?? []
            if old?.observation != nil, banner.status == .blocked || banner.status == .done {
                lastToken &+= 1
                state.agents[id] = .holding(observation, token: lastToken, banner: banner)
                effects.append(.armHold(id, lastToken))
            } else {
                state.agents[id] = .baseline(observation)
            }
            return effects
        case .push(let banner, let timestamp, let showing, let gate):
            let id = banner.target.agentID
            let old = state.agents[id]
            if let observation = old?.observation,
                observation.status != banner.status, timestamp < observation.changedAt { return [] }
            let next = old?.withSummary(Summary(status: banner.status, body: banner.alert.body))
                ?? .unseen(Summary(status: banner.status, body: banner.alert.body))
            state.agents[id] = next
            guard next.observation?.status == banner.status else { return [] }
            if let showing, showing.target == banner.target, showing.status == banner.status {
                return [.show(AgentNotificationBanner(
                    target: banner.target, status: banner.status,
                    alert: AgentNotificationAlert(title: showing.alert.title, body: banner.alert.body)), sound: false)]
            }
            guard next.hold == nil else { return [] }
            return announce(id, candidate: Candidate(banner: banner, sound: !next.wasAnnounced), gate: gate)
        case .holdElapsed(let id, let token, let gate):
            guard case .holding(let observation, let current, var banner) = state.agents[id],
                current == token else { return [] }
            if let summary = observation.summary, summary.status == banner.status {
                banner = AgentNotificationBanner(
                    target: banner.target, status: banner.status,
                    alert: AgentNotificationAlert(title: banner.alert.title, body: summary.body))
            }
            state.agents[id] = .baseline(observation)
            return announce(id, candidate: Candidate(banner: banner, sound: true), gate: gate)
        case .replayElapsed(let token, let gates):
            guard state.replay == .waiting(token) else { return [] }
            state.replay = .idle
            var effects: [Effect] = []
            for (id, gate) in gates where gate != .voiceQuiet {
                guard case .deferred(let observation, let candidate, let announced) = state.agents[id] else { continue }
                // Remove before re-applying every gate, including suppression.
                state.agents[id] = announced ? .announced(observation) : .baseline(observation)
                guard observation.status == candidate.banner.status else { continue }
                effects += announce(id, candidate: Candidate(
                    banner: candidate.banner, sound: candidate.sound && !announced), gate: gate)
            }
            if !deferred.isEmpty { effects += scheduleReplay() }
            return effects
        }
    }

    private mutating func scheduleReplay() -> [Effect] {
        guard state.replay == .idle else { return [] }
        lastToken &+= 1
        state.replay = .waiting(lastToken)
        return [.armReplay(lastToken)]
    }

    private mutating func announce(_ id: ConsoleAgent.ID, candidate: Candidate, gate: Gate) -> [Effect] {
        guard let current = state.agents[id], let observation = current.observation else { return [] }
        switch gate {
        case .suppressed:
            return []
        case .voiceQuiet:
            state.agents[id] = .deferred(observation, candidate, announced: current.wasAnnounced)
            return scheduleReplay()
        case .disabled:
            state.agents[id] = current.wasAnnounced ? .announced(observation) : .baseline(observation)
            return []
        case .allowed:
            state.agents[id] = .announced(observation)
            return [.show(candidate.banner, sound: candidate.sound)]
        }
    }
}
