import Foundation

/// One accepted usage fetch at a time, with tokened poll wakeups. Reports
/// belong to Hosts independently of the scheduler. A forgotten Host loses
/// its report and fetch ownership; a late answer cannot resurrect either.
struct AIUsagePollingMachine: StateMachine {
    struct FetchToken: Hashable, Sendable {
        let requestID: UUID
        let sequence: UInt64
    }

    struct Due: Equatable, Sendable {
        let hostID: Host.ID
        let delay: Duration
        let isFollowUp: Bool
    }

    enum State: Equatable, Sendable {
        case paused
        case waiting(Due, timer: UInt64)
        case fetching(Host.ID, token: FetchToken)
    }

    enum Outcome: Equatable, Sendable {
        case success(AIUsageReport)
        case interrupted
        case failed(String, executableMissing: Bool)
    }

    enum Event: Equatable, Sendable {
        case schedule(Due?)
        case pollElapsed(UInt64)
        case fetch(Host.ID, path: String, scheduled: Bool, requestID: UUID)
        case finished(FetchToken, Outcome, at: Date, hostIsEnabled: Bool)
        case forget(Host.ID)
    }

    enum Effect: Equatable, Sendable {
        case armPoll(UInt64, after: Duration)
        case cancelPoll(UInt64)
        case retirePoll(UInt64)
        case checkSchedule
        case fetch(Host.ID, path: String, token: FetchToken)
        case cancelFetch(FetchToken)
        case retireFetch(FetchToken)
        case redetect(Host.ID)
        case reschedule
    }

    private(set) var state: State = .paused
    private(set) var usage: [Host.ID: AIUsageHostState] = [:]
    private var serverFollowUps: [Host.ID: Date] = [:]
    private var followedUpHostIDs: Set<Host.ID> = []
    private var lastToken: UInt64 = 0

    var fetchingHostID: Host.ID? {
        if case .fetching(let host, _) = state { host } else { nil }
    }

    var fetchToken: FetchToken? {
        if case .fetching(_, let token) = state { token } else { nil }
    }

    func followUp(for hostID: Host.ID) -> Date? { serverFollowUps[hostID] }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.paused, .schedule(let due)):
            return schedule(due)
        case (.waiting(_, let timer), .schedule(let due)):
            return [.cancelPoll(timer)] + schedule(due)
        case (.waiting(_, let current), .pollElapsed(let token)):
            guard current == token else { return [] }
            state = .paused
            return [.retirePoll(token), .checkSchedule]
        case (.paused, .fetch(let hostID, let path, let scheduled, let requestID)):
            return fetch(hostID, path: path, scheduled: scheduled, requestID: requestID)
        case (.waiting(_, let timer), .fetch(let hostID, let path, let scheduled, let requestID)):
            return [.cancelPoll(timer)] + fetch(hostID, path: path, scheduled: scheduled, requestID: requestID)
        case (.fetching(let hostID, let current), .finished(let token, let outcome, let date, let enabled)):
            guard token == current else { return [] }
            state = .paused
            guard enabled else { return [.retireFetch(token), .reschedule] }
            var reportState = usage[hostID] ?? AIUsageHostState()
            reportState.lastFinishedAt = date
            var executableMissing = false
            switch outcome {
            case .success(let report):
                let dataDate = report.dataDate(finishedAt: date)
                reportState.snapshot = AIUsageSnapshot(report: report, fetchedAt: dataDate)
                if report.source == .server,
                    date.timeIntervalSince(dataDate) > AIUsagePollSchedule.serverRebuildAge,
                    followedUpHostIDs.insert(hostID).inserted
                {
                    serverFollowUps[hostID] = date.addingTimeInterval(AIUsagePollSchedule.serverFollowUpDelay)
                }
                reportState.lastFailure = report.commandError
                reportState.consecutiveFailures = report.commandError == nil ? 0 : reportState.consecutiveFailures + 1
            case .interrupted:
                break
            case .failed(let message, let missing):
                reportState.consecutiveFailures += 1
                reportState.lastFailure = message
                executableMissing = missing
            }
            usage[hostID] = reportState
            return [.retireFetch(token), executableMissing ? .redetect(hostID) : .reschedule]
        case (_, .forget(let hostID)):
            usage[hostID] = nil
            serverFollowUps[hostID] = nil
            followedUpHostIDs.remove(hostID)
            guard case .fetching(let currentHost, let token) = state, currentHost == hostID else { return [] }
            state = .paused
            return [.cancelFetch(token)]
        case (.paused, .pollElapsed), (.fetching, .pollElapsed),
             (.paused, .finished), (.waiting, .finished),
             (.fetching, .fetch), (.fetching, .schedule):
            return []
        }
    }

    private mutating func schedule(_ due: Due?) -> [Effect] {
        guard let due else {
            state = .paused
            return []
        }
        lastToken &+= 1
        state = .waiting(due, timer: lastToken)
        return [.armPoll(lastToken, after: due.delay)]
    }

    private mutating func fetch(
        _ hostID: Host.ID, path: String, scheduled: Bool, requestID: UUID
    ) -> [Effect] {
        serverFollowUps[hostID] = nil
        if scheduled { followedUpHostIDs.remove(hostID) }
        lastToken &+= 1
        let token = FetchToken(requestID: requestID, sequence: lastToken)
        state = .fetching(hostID, token: token)
        return [.fetch(hostID, path: path, token: token)]
    }
}
