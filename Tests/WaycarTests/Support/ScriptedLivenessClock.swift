import Foundation
import Synchronization

@testable import Waycar

/// A scripted `LivenessClock` (#105): `now` moves only when the test
/// advances it, so every measured round trip is zero and the derived
/// deadlines sit at their floors (2 s deadline, 200 ms hedge delay). Every
/// sleep lasts until the test fires sleeps of its duration.
final class ScriptedLivenessClock: Sendable {
    private struct Sleeper {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: ContinuousClock.Instant
        var sleepers: [Sleeper] = []
    }

    private let state: Mutex<State>

    init(now: ContinuousClock.Instant = .now) {
        state = Mutex(State(now: now))
    }

    var clock: LivenessClock {
        LivenessClock(now: { self.now }, sleep: { try await self.sleep(for: $0) })
    }

    var now: ContinuousClock.Instant {
        state.withLock { $0.now }
    }

    func advance(by duration: Duration) {
        state.withLock { $0.now = $0.now.advanced(by: duration) }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state in
                    guard !Task.isCancelled else { return true }
                    state.sleepers.append(
                        Sleeper(id: id, duration: duration, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Whether a sleep of `duration` is pending, or starts within `timeout`.
    func waitForSleep(_ duration: Duration, timeout: Duration = .waitCeiling) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isSleeping(duration) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return isSleeping(duration)
    }

    func isSleeping(_ duration: Duration) -> Bool {
        state.withLock { $0.sleepers.contains { $0.duration == duration } }
    }

    /// Ends every pending sleep of `duration`; returns how many there were.
    @discardableResult
    func fire(_ duration: Duration) -> Int {
        let fired = state.withLock { state -> [Sleeper] in
            let matching = state.sleepers.filter { $0.duration == duration }
            state.sleepers.removeAll { $0.duration == duration }
            return matching
        }
        for sleeper in fired { sleeper.continuation.resume() }
        return fired.count
    }
}
