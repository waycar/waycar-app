import Foundation

/// Effective app activity: the last foreground source leaving starts one
/// grant-backed grace period. Timer suspension keeps the grant for teardown;
/// expiration returns it before publishing suspension. Every phone return
/// emits activation, even while another source holds the app active.
struct AppActivityMachine: StateMachine {
    enum State: Equatable, Sendable {
        case foreground(Set<AppActivitySource>)
        case grace(startedAt: ContinuousClock.Instant, grant: UInt64)
        case suspending(startedAt: ContinuousClock.Instant, grant: UInt64)
        case suspended(startedAt: ContinuousClock.Instant)
    }

    enum Event: Equatable, Sendable {
        case becameActive(AppActivitySource, now: ContinuousClock.Instant)
        case enteredBackground(AppActivitySource, now: ContinuousClock.Instant)
        case grantRefused(UInt64)
        case grantExpired(UInt64)
        case graceElapsed(UInt64)
        case teardownFinished
    }

    enum Effect: Equatable, Sendable {
        case beginGrace(UInt64)
        case cancelGrace(UInt64)
        case releaseGrant(UInt64)
        case activated(absence: Duration?, crossedGrace: Bool, at: ContinuousClock.Instant)
        case suspended
    }

    private(set) var state: State = .foreground([])
    private(set) var activationCount: UInt64 = 0
    private(set) var lastAbsenceMayHaveSuspended = false
    private(set) var lastAbsenceDuration: Duration?
    private var lastGrant: UInt64 = 0
    let gracePeriod: Duration

    init(gracePeriod: Duration) {
        self.gracePeriod = gracePeriod
    }

    var phase: AppActivityPhase {
        switch state {
        case .foreground, .grace: .active
        case .suspending, .suspended: .suspended
        }
    }

    var hasBackgroundTimeForTeardown: Bool {
        if case .suspending = state { true } else { false }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.foreground(var sources), .becameActive(let source, let now)):
            let heldByAnother = !sources.subtracting([source]).isEmpty
            sources.insert(source)
            state = .foreground(sources)
            guard source == .phone || !heldByAnother else { return [] }
            return activate(absence: nil, observedSuspension: false, at: now)
        case (.grace(let started, let grant), .becameActive(let source, let now)):
            state = .foreground([source])
            return [.cancelGrace(grant), .releaseGrant(grant)]
                + activate(absence: now - started, observedSuspension: false, at: now)
        case (.suspending(let started, let grant), .becameActive(let source, let now)):
            state = .foreground([source])
            return [.cancelGrace(grant), .releaseGrant(grant)]
                + activate(absence: now - started, observedSuspension: true, at: now)
        case (.suspended(let started), .becameActive(let source, let now)):
            state = .foreground([source])
            return activate(absence: now - started, observedSuspension: true, at: now)
        case (.foreground(var sources), .enteredBackground(let source, let now)):
            sources.remove(source)
            guard sources.isEmpty else {
                state = .foreground(sources)
                return []
            }
            lastGrant &+= 1
            state = .grace(startedAt: now, grant: lastGrant)
            return [.beginGrace(lastGrant)]
        case (.grace(let started, let current), .graceElapsed(let token)):
            guard token == current else { return [] }
            state = .suspending(startedAt: started, grant: current)
            return [.cancelGrace(current), .suspended]
        case (.grace(let started, let current), .grantRefused(let token)):
            guard token == current else { return [] }
            state = .suspended(startedAt: started)
            return [.cancelGrace(current), .suspended]
        case (.grace(let started, let current), .grantExpired(let token)):
            guard token == current else { return [] }
            state = .suspended(startedAt: started)
            return [.cancelGrace(current), .releaseGrant(current), .suspended]
        case (.suspending(let started, let current), .grantExpired(let token)):
            guard token == current else { return [] }
            state = .suspended(startedAt: started)
            return [.cancelGrace(current), .releaseGrant(current)]
        case (.suspending(let started, let grant), .teardownFinished):
            state = .suspended(startedAt: started)
            return [.releaseGrant(grant)]
        case (.foreground, .grantRefused), (.foreground, .grantExpired),
             (.foreground, .graceElapsed), (.foreground, .teardownFinished),
             (.grace, .enteredBackground), (.grace, .teardownFinished),
             (.suspending, .enteredBackground), (.suspending, .grantRefused),
             (.suspending, .graceElapsed), (.suspended, .enteredBackground),
             (.suspended, .grantRefused), (.suspended, .grantExpired),
             (.suspended, .graceElapsed), (.suspended, .teardownFinished):
            return []
        }
    }

    private mutating func activate(
        absence: Duration?, observedSuspension: Bool, at now: ContinuousClock.Instant
    ) -> [Effect] {
        lastAbsenceDuration = absence
        lastAbsenceMayHaveSuspended = observedSuspension || absence.map { $0 >= gracePeriod } == true
        activationCount &+= 1
        return [.activated(absence: absence, crossedGrace: lastAbsenceMayHaveSuspended, at: now)]
    }
}
