import Foundation

@testable import Waycar

/// ActivityKit stand-in for `HostLiveActivityCoordinator` tests: records
/// request/update/end and lets the test push tokens, run-states, pushed
/// (push-to-start) activities, and push-to-start tokens. Activities are
/// listed oldest first, like ActivityKit.
@MainActor
final class FakeLiveActivityController: LiveActivityControlling {
    var areEnabled = true
    var requestError: (any Error)?

    private(set) var requested: [AgentActivityAttributes.ContentState] = []
    private(set) var requestedHandles: [LiveActivityHandle] = []
    private(set) var updates: [(id: String, content: AgentActivityAttributes.ContentState)] = []
    private(set) var ended: [(id: String, finalContent: AgentActivityAttributes.ContentState?, immediate: Bool)] =
        []

    private var nextID = 1
    private var records: [String: Record] = [:]
    /// Creation order, oldest first, for `currentActivities()`.
    private var order: [String] = []
    private var announcements: [AsyncStream<LiveActivityHandle>.Continuation] = []
    private var startTokenContinuations: [AsyncStream<Data>.Continuation] = []
    private var lastStartToken: Data?

    private struct Record {
        var id: String
        var hostID: UUID
        var content: AgentActivityAttributes.ContentState?
        var state: LiveActivityRunState = .active
        var lastToken: Data?
        var tokenContinuations: [AsyncStream<Data>.Continuation] = []
        var stateContinuations: [AsyncStream<LiveActivityRunState>.Continuation] = []
    }

    /// An activity ActivityKit already lists, such as one from a previous
    /// launch; `.ended` is one iOS ended (its 8-hour limit) that still
    /// shows on the Lock Screen.
    func seed(id: String, hostID: UUID, state: LiveActivityRunState = .active) {
        records[id] = Record(id: id, hostID: hostID, state: state)
        order.append(id)
    }

    /// What the Lock Screen shows: listed and not dismissed. An `.ended`
    /// activity stays until it is dismissed.
    var visibleActivityIDs: [String] {
        order.filter { records[$0].map { $0.state != .dismissed } ?? false }
    }

    /// A push-to-start created `id`: ActivityKit lists it and announces it
    /// through `activityUpdates()`.
    func announce(id: String, hostID: UUID) {
        seed(id: id, hostID: hostID)
        for continuation in announcements {
            continuation.yield(LiveActivityHandle(id: id, hostID: hostID))
        }
    }

    func emitPushToStartToken(_ data: Data) {
        lastStartToken = data
        for continuation in startTokenContinuations {
            continuation.yield(data)
        }
    }

    func emitToken(id: String, _ data: Data) {
        records[id]?.lastToken = data
        for continuation in records[id]?.tokenContinuations ?? [] {
            continuation.yield(data)
        }
    }

    /// The state changes and ActivityKit reports it; the activity stays
    /// listed, as an ended one does until it is dismissed.
    func emitState(id: String, _ state: LiveActivityRunState) {
        records[id]?.state = state
        for continuation in records[id]?.stateContinuations ?? [] {
            continuation.yield(state)
        }
    }

    /// The state changed while the app was suspended: ActivityKit lists it,
    /// the state stream has not reported it yet.
    func setStateSilently(id: String, _ state: LiveActivityRunState) {
        records[id]?.state = state
    }

    func activityID(for hostID: UUID) -> String? {
        records.values.first(where: { $0.hostID == hostID })?.id
    }

    func request(
        attributes: AgentActivityAttributes,
        content: AgentActivityAttributes.ContentState
    ) throws -> LiveActivityHandle {
        if let requestError { throw requestError }
        guard areEnabled else { throw LiveActivityRequestError.requestFailed() }
        guard let hostID = UUID(uuidString: attributes.hostID) else {
            throw LiveActivityRequestError.invalidHostID
        }
        let id = "act-\(nextID)"
        nextID += 1
        requested.append(content)
        let handle = LiveActivityHandle(id: id, hostID: hostID)
        requestedHandles.append(handle)
        records[id] = Record(id: id, hostID: hostID, content: content)
        order.append(id)
        return handle
    }

    func update(id: String, content: AgentActivityAttributes.ContentState) {
        updates.append((id, content))
        records[id]?.content = content
    }

    func end(
        id: String,
        finalContent: AgentActivityAttributes.ContentState?,
        immediate: Bool
    ) {
        ended.append((id, finalContent, immediate))
        if let record = records.removeValue(forKey: id) {
            order.removeAll { $0 == id }
            for continuation in record.tokenContinuations { continuation.finish() }
            for continuation in record.stateContinuations { continuation.finish() }
        }
    }

    func currentActivities() -> [(id: String, hostID: UUID, state: LiveActivityRunState)] {
        order.compactMap { id in records[id].map { ($0.id, $0.hostID, $0.state) } }
    }

    func activityUpdates() -> AsyncStream<LiveActivityHandle> {
        AsyncStream { continuation in
            announcements.append(continuation)
        }
    }

    /// ActivityKit yields the current push-to-start token as soon as the
    /// sequence is observed, then each rotation.
    func pushToStartTokenUpdates() -> AsyncStream<Data> {
        AsyncStream { continuation in
            startTokenContinuations.append(continuation)
            if let lastStartToken { continuation.yield(lastStartToken) }
        }
    }

    func pushTokenUpdates(for handle: LiveActivityHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            guard var record = records[handle.id] else {
                continuation.finish()
                return
            }
            record.tokenContinuations.append(continuation)
            let replay = record.lastToken
            records[handle.id] = record
            // ActivityKit yields the current token as soon as the sequence
            // is observed, then subsequent rotations.
            if let replay { continuation.yield(replay) }
        }
    }

    func stateUpdates(for handle: LiveActivityHandle) -> AsyncStream<LiveActivityRunState> {
        stream(for: handle) { $0.stateContinuations.append($1) }
    }

    private func stream<Element>(
        for handle: LiveActivityHandle,
        register: (inout Record, AsyncStream<Element>.Continuation) -> Void
    ) -> AsyncStream<Element> {
        AsyncStream { continuation in
            guard var record = records[handle.id] else {
                continuation.finish()
                return
            }
            register(&record, continuation)
            records[handle.id] = record
        }
    }
}
