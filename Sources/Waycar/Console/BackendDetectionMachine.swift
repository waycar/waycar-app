import Foundation

/// A Host's cached detection and connect work share the same settle gate.
/// Deferred requests may arrive during a detection; they remain pending until
/// it ends (a successful answer supersedes them). Nothing here starts a service.
struct BackendDetectionMachine: StateMachine {
    struct Cache: Equatable, Sendable {
        let presence: HostBackendPresence
        let verifiedAt: Date?
    }

    struct Facts: Equatable, Sendable {
        var cache: Cache?
        var missing: Set<HostBackend> = []
        var probeGenerations: [ServerChatBackend: UInt64] = [:]
        var deferredScopes: Set<HostBackend> = []
    }

    struct Request: Equatable, Sendable {
        /// Empty means unconditional detection; nonempty earns an exec only
        /// if one of these installed/stopped servers answers its cheap probe.
        var stoppedServers: Set<ServerChatBackend> = []
    }

    enum State: Equatable, Sendable {
        case idle(Facts)
        case waiting(Facts, Request)
        case detecting(Facts, token: UInt64, pending: Request?)
    }

    enum Event: Sendable {
        case seed(Cache)
        case request(now: Date)
        case deferDetection
        case finished(UInt64, presence: HostBackendPresence?, sameHost: Bool, now: Date)
        case recorded(HostBackendPresence, now: Date)
        case cancelDetection
        case hostChanged(keepsTarget: Bool)
        case suspend
        case missing(HostBackend, Bool, enabled: Bool)
        case scopeDeferred(HostBackend)
        case scopeEnded(HostBackend)
        case settled(resumable: Set<HostBackend>, detectionReady: Bool, enabled: Bool)
        case primaryVerified(UInt64, now: Date)
    }

    enum Effect: Equatable, Sendable {
        case detect(UInt64, stoppedServers: Set<ServerChatBackend>)
        case cancel(UInt64)
        case release(UInt64)
        case apply(Cache)
        case resume(HostBackend)
    }

    static let freshness: TimeInterval = 6 * 3600
    private(set) var state: State = .idle(Facts())
    private var lastToken: UInt64 = 0

    var facts: Facts {
        switch state {
        case .idle(let facts), .waiting(let facts, _), .detecting(let facts, _, _): facts
        }
    }

    var presence: HostBackendPresence? { facts.cache?.presence }

    private var pending: Request? {
        switch state {
        case .idle: nil
        case .waiting(_, let request), .detecting(_, _, let request?): request
        case .detecting(_, _, nil): nil
        }
    }

    private mutating func update(_ facts: Facts, pending: Request?) {
        switch state {
        case .idle, .waiting:
            state = pending.map { .waiting(facts, $0) } ?? .idle(facts)
        case .detecting(_, let token, _):
            state = .detecting(facts, token: token, pending: pending)
        }
    }

    private var stoppedServers: [ServerChatBackend] {
        guard let presence else { return [] }
        return ServerChatBackend.allCases.filter {
            $0.presence(in: presence).map { $0.meetsFloor && !$0.isRunning } ?? false
        }
    }

    private mutating func request(now: Date) {
        if let cache = facts.cache, let verifiedAt = cache.verifiedAt,
            now.timeIntervalSince(verifiedAt) < Self.freshness,
            !Self.pluginNeedsRecheck(cache.presence), cache.presence.ultimate != nil,
            ServerChatBackend.allCases.allSatisfy({ $0.wasProbed(in: cache.presence) })
        {
            guard !stoppedServers.isEmpty else { return }
            var request = pending ?? Request()
            request.stoppedServers.formUnion(stoppedServers)
            update(facts, pending: request)
        } else {
            update(facts, pending: Request())
        }
    }

    private static func pluginNeedsRecheck(_ presence: HostBackendPresence) -> Bool {
        guard let plugin = presence.waycarPlugin else { return true }
        switch WaycarPluginRequirement.status(of: plugin, backends: presence.backends) {
        case .outdated, .notInstalled: return true
        case .current, .unknown: return false
        }
    }

    private mutating func begin(enabled: Bool, stoppedServers: Set<ServerChatBackend>) -> [Effect] {
        switch state {
        case .detecting: return []
        case .idle, .waiting:
            let facts = facts
            guard enabled else {
                state = .idle(facts)
                return []
            }
            lastToken += 1
            state = .detecting(facts, token: lastToken, pending: nil)
            return [.detect(lastToken, stoppedServers: stoppedServers)]
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .seed(let cache)):
            guard facts.cache == nil else { return [] }
            var facts = facts
            facts.cache = cache
            update(facts, pending: pending)
            return []
        case (_, .request(let now)):
            request(now: now)
            return []
        case (_, .deferDetection):
            update(facts, pending: pending ?? Request())
            return []
        case (.detecting(let facts, let token, let pending),
              .finished(let received, let presence, let sameHost, let now)) where token == received:
            state = pending.map { .waiting(facts, $0) } ?? .idle(facts)
            guard sameHost, let presence else { return [.release(token)] }
            return [.release(token)] + handle(.recorded(presence, now: now))
        case (.idle, .finished), (.waiting, .finished), (.detecting, .finished):
            return []
        case (_, .recorded(let presence, let now)):
            var effects: [Effect] = []
            if case .detecting(_, let token, _) = state { effects.append(.cancel(token)) }
            var facts = facts
            let cache = Cache(presence: presence, verifiedAt: now)
            facts.cache = cache
            state = .idle(facts)
            return effects + [.apply(cache)]
        case (_, .cancelDetection):
            guard case .detecting(let facts, let token, let pending) = state else { return [] }
            state = pending.map { .waiting(facts, $0) } ?? .idle(facts)
            return [.cancel(token)]
        case (_, .hostChanged(let keepsTarget)):
            let effects: [Effect]
            if case .detecting(_, let token, _) = state { effects = [.cancel(token)] }
            else { effects = [] }
            state = .idle(Facts(cache: keepsTarget ? facts.cache : nil))
            return effects
        case (_, .suspend):
            var facts = facts
            facts.deferredScopes.removeAll()
            update(facts, pending: nil)
            return []
        case (_, .missing(let backend, let missing, let enabled)):
            var facts = facts
            if missing {
                guard facts.missing.insert(backend).inserted else { return [] }
                update(facts, pending: pending)
                return begin(enabled: enabled, stoppedServers: [])
            }
            facts.missing.remove(backend)
            update(facts, pending: pending)
            return []
        case (_, .scopeDeferred(let backend)):
            var facts = facts
            facts.deferredScopes.insert(backend)
            update(facts, pending: pending)
            return []
        case (_, .scopeEnded(let backend)):
            var facts = facts
            facts.deferredScopes.remove(backend)
            facts.missing.remove(backend)
            update(facts, pending: pending)
            return []
        case (_, .settled(let resumable, let detectionReady, let enabled)):
            var facts = facts
            let resuming = facts.deferredScopes.intersection(resumable)
            facts.deferredScopes.subtract(resuming)
            update(facts, pending: pending)
            let effects = HostBackend.allCases.filter { resuming.contains($0) }.map(Effect.resume)
            guard detectionReady, let pending else { return effects }
            return effects + begin(enabled: enabled, stoppedServers: pending.stoppedServers)
        case (_, .primaryVerified(let generation, let now)):
            var facts = facts
            var asks = false
            for server in stoppedServers where facts.probeGenerations[server] != generation {
                facts.probeGenerations[server] = generation
                asks = true
            }
            update(facts, pending: pending)
            if asks { request(now: now) }
            return []
        }
    }
}
