import Foundation

/// `UltimateTransport` across its projects: whether it is in service, lost
/// (every project failed its first retry, so `EventsSession` replaces it and
/// the connector re-discovers current locks), distrusted or closed; whether
/// an event stream runs; and which projects are online.
///
/// The epoch is ULT-01's guard: subscribing and ending a stream advance it,
/// so a one-shot snapshot read that waited across either is superseded, and
/// a pump's reports carry the epoch of the stream that started it.
struct UltimateTransportMachine: StateMachine {
    enum Lifecycle: Equatable, Sendable {
        case inService
        case lost
        case distrusted
        case closed
    }

    struct State: Equatable, Sendable {
        var lifecycle: Lifecycle = .inService
        /// Whether a stream (pumps and its continuation) runs.
        var streaming = false
        var epoch: UInt64 = 0
        var online: Set<String> = []
        /// Projects whose stream failed again after a retry, this stream.
        var failedAfterRetry: Set<String> = []
    }

    enum Event: Equatable, Sendable {
        /// A one-shot read started at `epoch` listed `instance` (or failed to).
        case snapshotRead(epoch: UInt64, instance: String, listed: Bool)
        /// No project answered a ping; with no stream, every project is
        /// forgotten.
        case pingFailed
        /// `subscribeToEvents` on a transport in service with no stream.
        case subscribe
        /// A pump of the stream at `stream` published `instance`'s inventory.
        case published(stream: UInt64, instance: String)
        /// A pump of the stream at `stream` counted `instance`'s questions.
        case questionsCounted(stream: UInt64, instance: String)
        /// `instance`'s stream at `stream` failed; `afterRetry` once it had
        /// failed before since it last published. `projects` is how many
        /// the transport has.
        case instanceFailed(stream: UInt64, instance: String, afterRetry: Bool, projects: Int)
        /// The stream at `stream` ends: its consumer ended it, its subscribe
        /// failed, or the transport ended.
        case endStream(stream: UInt64)
        case distrust
        case close
        /// A failed open: closed, the hold stays the caller's.
        case abandon
    }

    enum Effect: Equatable, Sendable {
        /// The read is older than a stream: return the current snapshot.
        case superseded
        /// Keep the one-shot read's conversations and concluded list.
        case keepListing(instance: String)
        /// Drop the project's conversations and concluded list.
        case dropListing(instance: String)
        /// Drop every project's conversations (questions and concluded stay).
        case forgetConversations
        /// Keep the pump's inventory, and say so when it changed.
        case keepPublished(instance: String)
        /// Keep the pump's question counts, and say so when they changed.
        case keepQuestions(instance: String)
        /// Drop everything known of the project, and say so when it had
        /// conversations.
        case forgetProject(instance: String)
        /// Start the pumps of the stream at `stream`.
        case startPumps(stream: UInt64)
        /// The pump may retry.
        case retry
        /// Finish the stream with this failure first (the transport is lost).
        case failStream(TransportError)
        /// Cancel the pumps and finish the stream cleanly.
        case endStream
        case release
    }

    static let offline = TransportError.channelFailed(detail: "Every Ultimate project is offline.")

    private(set) var state = State()

    init() {}

    /// Why nothing may use the transport now; nil while in service.
    var refusal: TransportError? {
        switch state.lifecycle {
        case .inService: nil
        case .lost: Self.offline
        case .distrusted, .closed: .cancelled
        }
    }

    var isClosed: Bool { state.lifecycle == .closed }

    /// Whether the stream at `stream` is the one running.
    func isCurrent(stream: UInt64) -> Bool {
        state.streaming && state.epoch == stream
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .snapshotRead(let epoch, let instance, let listed):
            guard epoch == state.epoch else { return [.superseded] }
            if listed {
                state.online.insert(instance)
                return [.keepListing(instance: instance)]
            }
            state.online.remove(instance)
            return [.dropListing(instance: instance)]
        case .pingFailed:
            guard !state.streaming else { return [] }
            state.online.removeAll()
            return [.forgetConversations]
        case .subscribe:
            guard state.lifecycle == .inService, !state.streaming else { return [] }
            state.failedAfterRetry.removeAll()
            state.epoch &+= 1
            state.streaming = true
            return [.startPumps(stream: state.epoch)]
        case .published(let stream, let instance):
            guard isCurrent(stream: stream) else { return [] }
            state.online.insert(instance)
            state.failedAfterRetry.remove(instance)
            return [.keepPublished(instance: instance)]
        case .questionsCounted(let stream, let instance):
            guard isCurrent(stream: stream) else { return [] }
            return [.keepQuestions(instance: instance)]
        case .instanceFailed(let stream, let instance, let afterRetry, let projects):
            guard isCurrent(stream: stream) else { return [] }
            state.online.remove(instance)
            if afterRetry { state.failedAfterRetry.insert(instance) }
            guard state.online.isEmpty, state.failedAfterRetry.count == projects else {
                return [.forgetProject(instance: instance), .retry]
            }
            state.lifecycle = .lost
            return [.forgetProject(instance: instance), .failStream(Self.offline)] + end()
        case .endStream(let stream):
            guard stream == state.epoch else { return [] }
            return end()
        case .distrust:
            guard state.lifecycle != .closed else { return [] }
            state.lifecycle = .distrusted
            return end()
        case .close:
            guard state.lifecycle != .closed else { return [] }
            state.lifecycle = .closed
            return end() + [.release]
        case .abandon:
            state.lifecycle = .closed
            return []
        }
    }

    /// Ends whatever stream runs and supersedes reads in flight.
    private mutating func end() -> [Effect] {
        state.epoch &+= 1
        state.streaming = false
        return [.endStream]
    }
}
