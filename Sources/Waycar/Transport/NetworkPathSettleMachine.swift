import Foundation

/// How `NetworkPathMonitor` turns path readings into settled changes (#105,
/// C-NET): the first reading is the baseline; every later one arms a debounce
/// under a fresh token, replacing the one before, and only the debounce of
/// the latest reading settles it (B-26). A settled path is reported only when
/// it differs from the last one reported, so a blip back to it is no change.
///
/// The source is started once. Stopping cancels the debounce and the source
/// and finishes the streams, and leaves the readings where they were, as the
/// monitor always did.
struct NetworkPathSettleMachine: StateMachine {
    enum Reading: Equatable, Sendable {
        /// Nothing read yet: the first reading is the baseline.
        case awaitingBaseline
        /// `key` was reported last (or was the baseline), and the latest
        /// reading names it.
        case settled(NetworkPathKey?)
        /// The latest reading, `current`, waits out the debounce under
        /// `token`; `settled` was reported last.
        case debouncing(settled: NetworkPathKey?, current: NetworkPathKey?, token: UInt64)
    }

    struct State: Equatable, Sendable {
        var isStarted = false
        var reading: Reading = .awaitingBaseline
    }

    enum Event: Equatable, Sendable {
        case start
        case read(NetworkPathKey?)
        /// The debounce armed under `token` ran out.
        case debounceElapsed(token: UInt64)
        case stop
    }

    enum Effect: Equatable, Sendable {
        case startSource
        /// The baseline, for the streams that asked for it before it came.
        case reportBaseline(NetworkPathKey?)
        /// Arm a debounce under `token`, cancelling the one before.
        case armDebounce(token: UInt64)
        /// A settled change, for every stream.
        case reportChange(NetworkPathKey?)
        case cancelDebounce
        case cancelSource
        case finishStreams
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    init() {}

    /// The latest reading's key; nil before the first reading.
    var currentKey: NetworkPathKey? {
        switch state.reading {
        case .awaitingBaseline: nil
        case .settled(let key): key
        case .debouncing(_, let current, _): current
        }
    }

    /// The key reported last (the baseline before any change); `.none`
    /// before the first reading.
    var settledKey: NetworkPathKey?? {
        switch state.reading {
        case .awaitingBaseline: .none
        case .settled(let key): .some(key)
        case .debouncing(let settled, _, _): .some(settled)
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state.reading, event) {
        case (_, .start):
            guard !state.isStarted else { return [] }
            state.isStarted = true
            return [.startSource]

        case (.awaitingBaseline, .read(let key)):
            // Every reading takes a token, the baseline's included, so no
            // debounce armed before it can settle after it.
            lastToken += 1
            state.reading = .settled(key)
            return [.reportBaseline(key)]
        case (.settled(let settled), .read(let key)),
            (.debouncing(let settled, _, _), .read(let key)):
            lastToken += 1
            state.reading = .debouncing(settled: settled, current: key, token: lastToken)
            return [.armDebounce(token: lastToken)]

        case (.debouncing(let settled, let current, let armed), .debounceElapsed(let token))
        where armed == token:
            state.reading = .settled(current)
            return settled == current ? [] : [.reportChange(current)]
        case (.awaitingBaseline, .debounceElapsed), (.settled, .debounceElapsed),
            (.debouncing, .debounceElapsed):
            // A debounce a newer reading replaced (B-26).
            return []

        case (_, .stop):
            return [.cancelDebounce, .cancelSource, .finishStreams]
        }
    }
}
