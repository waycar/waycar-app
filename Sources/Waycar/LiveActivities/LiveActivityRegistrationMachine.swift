import Foundation

/// One Host's serial registration writer. Token intent outranks preference
/// refreshes (LA-01); failures wait for fresh work or an explicit retry.
struct LiveActivityRegistrationMachine: StateMachine {
    enum ActivityJob: Equatable, Sendable {
        case set(hex: String, startedAt: Date)
        case setPreferences
        case clear(hex: String)
    }
    enum StartJob: Equatable, Sendable {
        case set(hex: String)
        case clear
    }
    enum Job: Equatable, Sendable {
        case activity(ActivityJob)
        case start(StartJob)
    }
    struct Pending: Equatable, Sendable {
        var activity: ActivityJob?
        var start: StartJob?
    }
    enum Phase: Equatable, Sendable {
        case idle
        case writing(UInt64, Job, Pending)
        case retryPending(Pending)
    }
    struct State: Equatable, Sendable {
        var phase: Phase = .idle
        var requestedStart: StartJob?
        var writtenToken: String?
    }
    enum Event: Equatable, Sendable {
        case enqueue(ActivityJob)
        case activityToken(String, startedAt: Date)
        case clearToken
        case requestStart(StartJob)
        case finished(UInt64, succeeded: Bool)
        case retry
    }
    enum Effect: Equatable, Sendable {
        case write(UInt64, Job)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var isDirty: Bool {
        if case .retryPending = state.phase { true } else { false }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .activityToken(let hex, let startedAt):
            state.writtenToken = hex
            return enqueue(.activity(.set(hex: hex, startedAt: startedAt)))
        case .clearToken:
            guard let hex = state.writtenToken else { return [] }
            state.writtenToken = nil
            return enqueue(.activity(.clear(hex: hex)))
        case .enqueue(let job):
            return enqueue(.activity(job))
        case .requestStart(let job):
            guard state.requestedStart != job else { return [] }
            state.requestedStart = job
            return enqueue(.start(job))
        case .retry:
            guard case .retryPending(let pending) = state.phase else { return [] }
            return pump(pending)
        case .finished(let token, let succeeded):
            guard case .writing(let current, let job, var pending) = state.phase,
                current == token else { return [] }
            let superseded: Bool
            switch job {
            case .activity(let failed):
                if !succeeded, pending.activity == .setPreferences {
                    switch failed {
                    case .set, .clear: pending.activity = nil
                    case .setPreferences: break
                    }
                }
                superseded = pending.activity != nil
                if !succeeded, !superseded { pending.activity = failed }
            case .start(let failed):
                superseded = pending.start != nil
                if !succeeded, !superseded { pending.start = failed }
            }
            if succeeded || superseded { return pump(pending) }
            state.phase = .retryPending(pending)
            return []
        }
    }

    private mutating func enqueue(_ job: Job) -> [Effect] {
        var pending: Pending
        switch state.phase {
        case .idle: pending = Pending()
        case .writing(_, _, let queued), .retryPending(let queued): pending = queued
        }
        switch job {
        case .activity(let next):
            switch (pending.activity, next) {
            case (.some(.set), .setPreferences), (.some(.clear), .setPreferences): break
            case (.none, _), (.some, _): pending.activity = next
            }
        case .start(let next): pending.start = next
        }
        if case .writing(let token, let active, _) = state.phase {
            state.phase = .writing(token, active, pending)
            return []
        }
        return pump(pending)
    }

    private mutating func pump(_ queued: Pending) -> [Effect] {
        var pending = queued
        let job: Job
        if let next = pending.activity {
            pending.activity = nil
            job = .activity(next)
        } else if let next = pending.start {
            pending.start = nil
            job = .start(next)
        } else {
            state.phase = .idle
            return []
        }
        lastToken &+= 1
        state.phase = .writing(lastToken, job, pending)
        return [.write(lastToken, job)]
    }
}
