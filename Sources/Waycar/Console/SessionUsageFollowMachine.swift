/// Which refresh of the session usage strip owns `AgentSessionUsageStore`
/// (#325), the file it follows, when omp's config was read, and the one
/// model window lookup out.
///
/// A refresh mints a token and runs three steps in turn, each across an
/// await: the config read (once a minute), the tail follow, the window
/// lookup. A step's answer counts only while its token is the newest; a
/// newer refresh, on any path, makes every older answer stale. The bytes,
/// offset and totals stay in the owner: this machine says only whose they
/// are.
///
/// Kept as they were (CONSOLE-23):
/// - `cleared` drops the followed file and its config but mints no token,
///   so a refresh in flight stays current and folds its read into the
///   cleared store. The screen cancels its follower before clearing.
/// - The lookup slot holds one selector, and any lookup ending empties it,
///   so after an older refresh's lookup ends a newer one's selector can be
///   asked about twice.
struct SessionUsageFollowMachine: StateMachine {
    enum File: Equatable, Sendable {
        case none
        case following(path: String)
    }

    enum Config: Equatable, Sendable {
        case unread
        case read(at: ContinuousClock.Instant)
    }

    enum Lookup: Equatable, Sendable {
        case idle
        case resolving(selector: String)
    }

    struct State: Equatable, Sendable {
        var file: File = .none
        /// The refresh that owns the store; 0 before the first.
        var current: UInt64 = 0
        var config: Config = .unread
        var lookup: Lookup = .idle
    }

    enum LookupOutcome: Equatable, Sendable {
        /// omp's window for the selector; nil when omp cannot size it.
        case answered(Int?)
        /// Failed, or the refresh was cancelled: nothing to remember.
        case dropped
    }

    enum Event: Equatable, Sendable {
        case refreshed(path: String, now: ContinuousClock.Instant)
        /// The config step finished: `showsRate` nil when the read failed.
        case configRead(UInt64, showsRate: Bool?, now: ContinuousClock.Instant)
        /// A tail read came back; `fileExists` is false when the session
        /// file is gone.
        case chunkRead(UInt64, fileExists: Bool)
        /// The follow ended without the file vanishing: a short read, the
        /// budget spent, or a failed read.
        case followed(UInt64)
        /// The model needs a window the owner does not remember.
        case lookupNeeded(UInt64, selector: String)
        case lookupEnded(UInt64, selector: String, LookupOutcome)
        /// The screen's `clear()`.
        case cleared
    }

    enum Effect: Equatable, Sendable {
        /// Forget the followed file's totals and the rate readout.
        case dropTotals
        case showTokenRate(Bool)
        case readConfig(UInt64)
        case follow(UInt64)
        /// The tail read belongs to the current refresh: fold it.
        case foldChunk(UInt64)
        case lookUpWindow(UInt64)
        case resolve(UInt64, selector: String)
        case rememberWindow(selector: String, Int?)
    }

    /// How long a config read stays good for. The setting is toggled by hand
    /// and rarely, so a minute of lag costs nothing; re-reading on every tick
    /// would double the strip's round trips.
    static let configInterval: Duration = .seconds(60)

    private(set) var state = State()

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .refreshed(let path, let now):
            state.current &+= 1
            let token = state.current
            var effects: [Effect] = []
            if state.file != .following(path: path) {
                effects += dropFile()
                state.file = .following(path: path)
            }
            switch state.config {
            case .read(let at) where now < at.advanced(by: Self.configInterval):
                effects.append(.follow(token))
            case .read, .unread:
                effects.append(.readConfig(token))
            }
            return effects
        case .configRead(let token, let showsRate, let now):
            guard token == state.current else { return [] }
            guard let showsRate else { return [.follow(token)] }
            state.config = .read(at: now)
            return [.showTokenRate(showsRate), .follow(token)]
        case .chunkRead(let token, let fileExists):
            guard token == state.current else { return [] }
            guard fileExists else { return dropFile() + [.lookUpWindow(token)] }
            return [.foldChunk(token)]
        case .followed(let token):
            guard token == state.current else { return [] }
            return [.lookUpWindow(token)]
        case .lookupNeeded(let token, let selector):
            guard state.lookup != .resolving(selector: selector) else { return [] }
            state.lookup = .resolving(selector: selector)
            return [.resolve(token, selector: selector)]
        case .lookupEnded(let token, let selector, let outcome):
            state.lookup = .idle
            guard token == state.current, case .answered(let window) = outcome else { return [] }
            return [.rememberWindow(selector: selector, window)]
        case .cleared:
            return dropFile()
        }
    }

    private mutating func dropFile() -> [Effect] {
        state.file = .none
        state.config = .unread
        return [.dropTotals]
    }
}
