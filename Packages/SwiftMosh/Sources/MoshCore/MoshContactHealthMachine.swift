import MoshTransport

/// How a mosh session's contact with its server stands: not judged (not
/// running, or suspended), healthy, stalled, or expired. The session counts
/// as heard from when it starts, and every authenticated server datagram is
/// contact. Only while the session runs is the silence judged: at
/// `stallThresholdMs` it reads stalled (patch 11), at `networkTimeoutMs` it
/// expires (patch 12, checked before the stall). Time arrives in events as
/// `MoshClientSession`'s clock reading. The connectivity the session
/// publishes is the state's; an expired session keeps the one it had until
/// its runtime stops. (Waycar patch.)
struct MoshContactHealthMachine: StateMachine {
    enum State: Equatable, Sendable {
        /// Not judged, and no connectivity: before the first start, or once
        /// the runtime stopped or suspended.
        case notRunning(lastContactMs: UInt64)
        case healthy(lastContactMs: UInt64)
        case stalled(lastContactMs: UInt64)
        /// The network timeout passed; the session is failing.
        case expired(lastContactMs: UInt64, connectivity: MoshConnectivity)
    }

    enum Event: Equatable, Sendable {
        /// The session (re)started running at `nowMs`, which counts as
        /// contact.
        case started(nowMs: UInt64)
        /// An authenticated server datagram at `nowMs`. `judged` is whether
        /// the session runs: during a shutdown it is contact, not judgment.
        case contact(nowMs: UInt64, judged: Bool)
        /// A maintenance pass of the running session at `nowMs`.
        case tick(nowMs: UInt64)
        /// The runtime stopped or suspended.
        case ended
    }

    enum Effect: Equatable, Sendable {
        /// Publish a connectivity change.
        case publish(MoshConnectivity)
        /// Fail the session with `.timeout(timeoutMs:)`.
        case expire(timeoutMs: UInt32)
    }

    private(set) var state: State = .notRunning(lastContactMs: 0)
    private let stallThresholdMs: UInt32
    private let networkTimeoutMs: UInt32

    init(stallThresholdMs: UInt32, networkTimeoutMs: UInt32) {
        self.stallThresholdMs = stallThresholdMs
        self.networkTimeoutMs = networkTimeoutMs
    }

    /// What `connectivity` and `connectivityStream()` report.
    var connectivity: MoshConnectivity? {
        switch state {
        case .notRunning: nil
        case .healthy: .connected
        case .stalled: .stalled
        case .expired(_, let connectivity): connectivity
        }
    }

    var lastContactMs: UInt64 {
        switch state {
        case .notRunning(let last), .healthy(let last), .stalled(let last), .expired(let last, _): last
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.notRunning, .started(let now)), (.healthy, .started(let now)), (.stalled, .started(let now)),
             (.expired, .started(let now)):
            return judge(lastContactMs: now, nowMs: now)

        case (.healthy, .contact(let now, true)), (.stalled, .contact(let now, true)):
            return judge(lastContactMs: now, nowMs: now)
        case (.healthy, .contact(let now, false)):
            state = .healthy(lastContactMs: now)
            return []
        case (.stalled, .contact(let now, false)):
            state = .stalled(lastContactMs: now)
            return []
        case (.notRunning, .contact(let now, _)):
            // Never judged before a start.
            state = .notRunning(lastContactMs: now)
            return []
        case (.expired(_, let connectivity), .contact(let now, _)):
            state = .expired(lastContactMs: now, connectivity: connectivity)
            return []

        case (.healthy(let last), .tick(let now)), (.stalled(let last), .tick(let now)):
            if now >= last, now - last >= UInt64(networkTimeoutMs) {
                state = .expired(lastContactMs: last, connectivity: connectivity ?? .connected)
                return [.expire(timeoutMs: networkTimeoutMs)]
            }
            return judge(lastContactMs: last, nowMs: now)
        case (.notRunning, .tick), (.expired, .tick):
            return []

        case (.notRunning, .ended), (.healthy, .ended), (.stalled, .ended), (.expired, .ended):
            state = .notRunning(lastContactMs: lastContactMs)
            return []
        }
    }

    /// The healthy or stalled state for `lastContactMs` judged at `nowMs`,
    /// publishing it when the connectivity changes.
    private mutating func judge(lastContactMs last: UInt64, nowMs now: UInt64) -> [Effect] {
        let silentMs = now >= last ? now - last : 0
        let stalled = silentMs >= UInt64(stallThresholdMs)
        let previous = connectivity
        state = stalled ? .stalled(lastContactMs: last) : .healthy(lastContactMs: last)
        let current: MoshConnectivity = stalled ? .stalled : .connected
        return current == previous ? [] : [.publish(current)]
    }
}
