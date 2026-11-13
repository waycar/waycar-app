#if canImport(ActivityKit)
import ActivityKit
#endif
import Foundation

/// A started (or adopted) Live Activity, identified the way ActivityKit
/// identifies it plus the Host it was requested for.
struct LiveActivityHandle: Hashable, Sendable {
    var id: String
    var hostID: UUID
}

/// ActivityKit's `ActivityState`, reduced to what the coordinator observes.
enum LiveActivityRunState: Sendable, Equatable {
    case active
    case stale
    case ended
    case dismissed
}

enum LiveActivityRequestError: Error, Sendable, Equatable {
    /// ActivityKit refused the request, or Live Activities are unavailable.
    /// Carries ActivityKit's own reason for the Settings diagnostic row.
    case requestFailed(String = "")
    /// `AgentActivityAttributes.hostID` was not a UUID string.
    case invalidHostID
}

/// Abstracts ActivityKit so `HostLiveActivityCoordinator` can be tested
/// without starting a real Live Activity. Production uses
/// `ActivityKitLiveActivityController`.
@MainActor
protocol LiveActivityControlling: AnyObject {
    var areEnabled: Bool { get }

    func request(
        attributes: AgentActivityAttributes,
        content: AgentActivityAttributes.ContentState
    ) throws -> LiveActivityHandle

    func update(id: String, content: AgentActivityAttributes.ContentState)

    func end(
        id: String,
        finalContent: AgentActivityAttributes.ContentState?,
        immediate: Bool
    )

    /// ActivityKit's current activities in its own order, oldest first. An
    /// `.ended` one is still on the Lock Screen until it is dismissed.
    func currentActivities() -> [(id: String, hostID: UUID, state: LiveActivityRunState)]

    /// Activities ActivityKit announces from now on — notably one a Host's
    /// push-to-start created, which the app did not request itself.
    func activityUpdates() -> AsyncStream<LiveActivityHandle>

    /// This install's push-to-start token for `AgentActivityAttributes`:
    /// the current token first, then each rotation.
    func pushToStartTokenUpdates() -> AsyncStream<Data>

    func pushTokenUpdates(for handle: LiveActivityHandle) -> AsyncStream<Data>

    func stateUpdates(for handle: LiveActivityHandle) -> AsyncStream<LiveActivityRunState>
}

#if canImport(ActivityKit)
/// Production ActivityKit adapter: one `Activity<AgentActivityAttributes>`
/// per Host, started with `pushType: .token` so the plugin can push updates
/// after the app suspends, or started by the plugin through push-to-start
/// (docs/agents/live-activity-contract.md).
///
/// ActivityKit is the source of truth — this type does not cache `Activity`
/// references, so Swift 6 never treats them as MainActor-isolated bindings
/// when handing them to ActivityKit's nonisolated update/end/async APIs.
@MainActor
final class ActivityKitLiveActivityController: LiveActivityControlling {
    var areEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func request(
        attributes: AgentActivityAttributes,
        content: AgentActivityAttributes.ContentState
    ) throws -> LiveActivityHandle {
        guard let hostID = UUID(uuidString: attributes.hostID) else {
            throw LiveActivityRequestError.invalidHostID
        }
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: content, staleDate: nil),
                pushType: .token)
            return LiveActivityHandle(id: activity.id, hostID: hostID)
        } catch {
            throw LiveActivityRequestError.requestFailed(String(describing: error))
        }
    }

    func update(id: String, content: AgentActivityAttributes.ContentState) {
        Task { await Self.pushUpdate(id: id, content: content) }
    }

    func end(
        id: String,
        finalContent: AgentActivityAttributes.ContentState?,
        immediate: Bool
    ) {
        let content = finalContent.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = immediate ? .immediate : .default
        Task { await Self.pushEnd(id: id, content: content, policy: policy) }
    }

    func currentActivities() -> [(id: String, hostID: UUID, state: LiveActivityRunState)] {
        Self.systemActivities().compactMap { activity in
            guard let hostID = UUID(uuidString: activity.attributes.hostID) else { return nil }
            return (activity.id, hostID, Self.runState(activity.activityState))
        }
    }

    func activityUpdates() -> AsyncStream<LiveActivityHandle> {
        AsyncStream { continuation in
            let task = Task { await Self.forwardActivities(to: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func pushToStartTokenUpdates() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task { await Self.forwardPushToStartTokens(to: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func pushTokenUpdates(for handle: LiveActivityHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task { await Self.forwardTokens(id: handle.id, to: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stateUpdates(for handle: LiveActivityHandle) -> AsyncStream<LiveActivityRunState> {
        AsyncStream { continuation in
            let task = Task { await Self.forwardStates(id: handle.id, to: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated private static func systemActivities() -> [Activity<AgentActivityAttributes>] {
        Activity<AgentActivityAttributes>.activities
    }

    nonisolated private static func activity(id: String) -> Activity<AgentActivityAttributes>? {
        systemActivities().first { $0.id == id }
    }

    nonisolated private static func runState(_ state: ActivityState) -> LiveActivityRunState {
        switch state {
        case .active, .pending: .active
        case .stale: .stale
        case .ended: .ended
        case .dismissed: .dismissed
        @unknown default: .active
        }
    }

    nonisolated private static func pushUpdate(
        id: String, content: AgentActivityAttributes.ContentState
    ) async {
        guard let activity = activity(id: id) else { return }
        await activity.update(ActivityContent(state: content, staleDate: nil))
    }

    nonisolated private static func pushEnd(
        id: String,
        content: ActivityContent<AgentActivityAttributes.ContentState>?,
        policy: ActivityUIDismissalPolicy
    ) async {
        guard let activity = activity(id: id) else { return }
        await activity.end(content, dismissalPolicy: policy)
    }

    nonisolated private static func forwardTokens(
        id: String, to continuation: AsyncStream<Data>.Continuation
    ) async {
        guard let activity = activity(id: id) else {
            continuation.finish()
            return
        }
        for await token in activity.pushTokenUpdates {
            continuation.yield(token)
        }
        continuation.finish()
    }

    /// A push-started activity whose `hostID` is not a UUID cannot belong to
    /// any Host; it is skipped rather than surfaced.
    nonisolated private static func forwardActivities(
        to continuation: AsyncStream<LiveActivityHandle>.Continuation
    ) async {
        for await activity in Activity<AgentActivityAttributes>.activityUpdates {
            guard let hostID = UUID(uuidString: activity.attributes.hostID) else { continue }
            continuation.yield(LiveActivityHandle(id: activity.id, hostID: hostID))
        }
        continuation.finish()
    }

    nonisolated private static func forwardPushToStartTokens(
        to continuation: AsyncStream<Data>.Continuation
    ) async {
        for await token in Activity<AgentActivityAttributes>.pushToStartTokenUpdates {
            continuation.yield(token)
        }
        continuation.finish()
    }

    nonisolated private static func forwardStates(
        id: String, to continuation: AsyncStream<LiveActivityRunState>.Continuation
    ) async {
        guard let activity = activity(id: id) else {
            continuation.finish()
            return
        }
        for await state in activity.activityStateUpdates {
            continuation.yield(runState(state))
        }
        continuation.finish()
    }
}
#else
@MainActor
final class ActivityKitLiveActivityController: LiveActivityControlling {
    var areEnabled: Bool { false }

    func request(
        attributes: AgentActivityAttributes,
        content: AgentActivityAttributes.ContentState
    ) throws -> LiveActivityHandle {
        throw LiveActivityRequestError.requestFailed("ActivityKit unavailable")
    }

    func update(id: String, content: AgentActivityAttributes.ContentState) {}

    func end(
        id: String,
        finalContent: AgentActivityAttributes.ContentState?,
        immediate: Bool
    ) {}

    func currentActivities() -> [(id: String, hostID: UUID, state: LiveActivityRunState)] { [] }

    func activityUpdates() -> AsyncStream<LiveActivityHandle> {
        AsyncStream { $0.finish() }
    }

    func pushToStartTokenUpdates() -> AsyncStream<Data> {
        AsyncStream { $0.finish() }
    }

    func pushTokenUpdates(for handle: LiveActivityHandle) -> AsyncStream<Data> {
        AsyncStream { $0.finish() }
    }

    func stateUpdates(for handle: LiveActivityHandle) -> AsyncStream<LiveActivityRunState> {
        AsyncStream { $0.finish() }
    }
}
#endif
