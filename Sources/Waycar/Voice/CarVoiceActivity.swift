import Foundation
import os

/// What the CarPlay voice is doing, for the notification paths: an Agent
/// Notification's sound over a spoken reply takes the audio session and cuts
/// the reply (ADR 0008 amendment), so quieted pushes present without sound
/// or banner. Written on the main actor by the voice, read on
/// `UNUserNotificationCenter`'s callback queue.
final class CarVoiceActivity: Sendable {
    struct State: Equatable, Sendable {
        /// The longest the car's speaking or listening quiets every Agent: a
        /// line whose engine never reports an end must not hold every push
        /// silent for the rest of the drive.
        static let maxQuiet: TimeInterval = 90

        /// The Agent of the open conversation or Blocked turn.
        var agent: ConsoleAgent.ID?
        /// Lines being spoken and listens running; each counts while active.
        var speaking = 0
        var listening = 0
        /// When the car last went from idle to speaking or listening.
        var busySince: Date?

        /// Whether the car is speaking or listening, within `maxQuiet`.
        func isBusy(now: Date = Date()) -> Bool {
            guard speaking > 0 || listening > 0 else { return false }
            guard let busySince else { return true }
            return now.timeIntervalSince(busySince) < Self.maxQuiet
        }

        /// Whether a notification for `target` presents quietly (no banner,
        /// no sound): every Agent's while the car speaks or listens, the
        /// turn's own Agent's for the whole turn (its reply's Done would
        /// land on its own reply).
        func quiets(_ target: AgentNotificationTarget?, now: Date = Date()) -> Bool {
            if isBusy(now: now) { return true }
            guard let agent, let target else { return false }
            return target.agentID == agent
        }
    }

    /// A Blocked push from another Agent that arrived while the car spoke or
    /// listened: the driver must still hear about it, after the current line.
    struct PendingAnnouncement: Equatable, Sendable {
        let target: AgentNotificationTarget
        let alert: AgentNotificationAlert
    }

    static let shared = CarVoiceActivity()

    private struct Storage {
        var state = State()
        var pending: [PendingAnnouncement] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: Storage())

    var state: State { lock.withLock { $0.state } }

    func setAgent(_ agent: ConsoleAgent.ID?) {
        lock.withLock { $0.state.agent = agent }
    }

    func beginSpeaking() { lock.withLock { Self.begin(&$0.state, \.speaking) } }
    func endSpeaking() { lock.withLock { Self.end(&$0.state, \.speaking) } }
    func beginListening() { lock.withLock { Self.begin(&$0.state, \.listening) } }
    func endListening() { lock.withLock { Self.end(&$0.state, \.listening) } }

    /// Queues a Blocked push for the car to announce once its line ends;
    /// one per Agent, the latest wins.
    func enqueue(_ announcement: PendingAnnouncement) {
        lock.withLock { storage in
            storage.pending.removeAll { $0.target == announcement.target }
            storage.pending.append(announcement)
        }
    }

    /// Hands over and clears the queued announcements, oldest first. The car
    /// coordinator drains this when a turn gives its audio back.
    func drainPending() -> [PendingAnnouncement] {
        lock.withLock { storage in
            defer { storage.pending.removeAll() }
            return storage.pending
        }
    }

    private static func begin(_ state: inout State, _ counter: WritableKeyPath<State, Int>) {
        if state.speaking == 0, state.listening == 0 { state.busySince = Date() }
        state[keyPath: counter] += 1
    }

    private static func end(_ state: inout State, _ counter: WritableKeyPath<State, Int>) {
        assert(state[keyPath: counter] > 0, "CarVoiceActivity end without a matching begin")
        state[keyPath: counter] = max(0, state[keyPath: counter] - 1)
        if state.speaking == 0, state.listening == 0 { state.busySince = nil }
    }
}
