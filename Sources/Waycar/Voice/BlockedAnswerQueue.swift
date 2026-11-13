import Foundation
import Observation

/// Allow and Deny answers taken while their Host could not be reached
/// (CONTEXT.md **Queued Answer**), waiting to go out once it can. One per
/// Agent: a newer answer replaces the older. Kept in memory only and for
/// `maxAge`, so a stale approval never outlives the prompt it answered; the
/// replay itself still re-reads the screen and sends only while the same
/// prompt is on it (`BlockedPromptAnswerer.replay`).
@MainActor
@Observable
final class BlockedAnswerQueue {
    struct Entry: Equatable, Identifiable, Sendable {
        let id: UUID
        let agentID: ConsoleAgent.ID
        let pending: PendingBlockedAnswer
        let queuedAt: Date
    }

    /// How a queued answer ended.
    enum Finish: Equatable, Sendable {
        /// The keys went out.
        case sent
        /// The Agent's prompt changed first; nothing was sent.
        case promptChanged
        /// The replay failed after it may have reached the Host.
        case notConfirmed
        /// `maxAge` passed before the Host came back.
        case expired
    }

    /// How long an answer waits.
    nonisolated static let defaultMaxAge: Duration = .seconds(600)

    var entries: [ConsoleAgent.ID: Entry] { queue.entries }
    private var queue = BlockedAnswerQueueMachine()
    /// Called when an entry ends in a way the user cannot see on screen: a
    /// replay's result, or an expiry. Not for a withdrawn or superseded one.
    @ObservationIgnored var onFinished: (@MainActor (Entry, Finish) -> Void)?

    @ObservationIgnored private let maxAge: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var expiries: [UUID: Task<Void, Never>] = [:]

    init(
        maxAge: Duration = BlockedAnswerQueue.defaultMaxAge,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.maxAge = maxAge
        self.sleep = sleep
    }

    deinit {
        for task in expiries.values { task.cancel() }
    }

    func entry(for agentID: ConsoleAgent.ID) -> Entry? {
        entries[agentID]
    }

    /// Queues `pending` for `agentID`, replacing any earlier answer.
    @discardableResult
    func enqueue(
        _ pending: PendingBlockedAnswer, for agentID: ConsoleAgent.ID, now: Date = Date()
    ) -> Entry {
        let entry = Entry(id: UUID(), agentID: agentID, pending: pending, queuedAt: now)
        _ = send(.enqueue(entry))
        return entry
    }

    /// Drops the Agent's queued answer without a report: the user withdrew
    /// it, or the Agent answered otherwise.
    func withdraw(agentID: ConsoleAgent.ID) {
        _ = send(.withdraw(agentID))
    }

    /// Claims the answer immediately before dispatch. Once keys may reach
    /// the Host, only their real outcome can settle it, never an expiry.
    func beginSending(_ entry: Entry) -> Bool {
        send(.claim(entry))
    }

    /// Drops every answer for a Host that is no longer the same one.
    func withdrawAll(on hostID: Host.ID) {
        for agentID in entries.keys where agentID.hostID == hostID { withdraw(agentID: agentID) }
    }

    /// Drops answers for Hosts outside `hostIDs`.
    func retainHosts(_ hostIDs: Set<Host.ID>) {
        for agentID in entries.keys where !hostIDs.contains(agentID.hostID) {
            withdraw(agentID: agentID)
        }
    }

    /// Ends `entry` with a report, if it is still the Agent's queued answer.
    func finish(_ entry: Entry, _ outcome: Finish) {
        _ = send(.finish(entry, outcome))
    }

    /// The claim effect is synchronous with dispatch admission. Timers and
    /// reports run only after the machine has committed the new state.
    private func send(_ event: BlockedAnswerQueueMachine.Event) -> Bool {
        var claimed = false
        for effect in queue.handle(event) {
            switch effect {
            case .armExpiry(let entry):
                let wait = maxAge
                let sleep = sleep
                expiries[entry.id] = Task { [weak self] in
                    do { try await sleep(wait) } catch { return }
                    self?.finish(entry, .expired)
                }
            case .cancelExpiry(let id):
                expiries.removeValue(forKey: id)?.cancel()
            case .claimed:
                claimed = true
            case .report(let entry, let outcome):
                onFinished?(entry, outcome)
            }
        }
        return claimed
    }
}

extension BlockedAnswerQueue {
    /// What a local notification says when a queued answer ends.
    nonisolated static func notice(label: String, identity: String?, finish: Finish)
        -> (title: String, body: String)
    {
        let subject = identity.map { " · \($0)" } ?? ""
        switch finish {
        case .sent:
            return ("\(label) sent\(subject)", "Sent once the Host was back.")
        case .promptChanged:
            return (
                "\(label) not sent\(subject)",
                "The prompt changed, so nothing was sent. Review it in Waycar.")
        case .notConfirmed:
            return (
                "\(label) not confirmed\(subject)",
                "It may not have arrived. Check the Agent in Waycar.")
        case .expired:
            return (
                "\(label) not sent\(subject)",
                "The Host stayed unreachable too long. Nothing was sent.")
        }
    }
}
