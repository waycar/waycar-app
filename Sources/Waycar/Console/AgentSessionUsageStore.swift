import Foundation
import Observation

/// Follows one Agent's session file for the terminal usage strip (#325).
///
/// The file reaches tens of megabytes and only ever grows, so this keeps the
/// bytes it has already folded and reads from there: a refresh fetches the
/// appended tail instead of the whole file again. Nothing is persisted — the
/// offset and the totals live here for as long as the screen does, which is
/// enough because a reconnect re-reads from zero once.
@MainActor
@Observable
final class AgentSessionUsageStore {
    /// What the strip renders; empty until a billed entry has been folded.
    private(set) var usage = AgentSessionUsage()
    /// Whether omp shows its own `tok/s` readout (`composer.tokenRate`), read
    /// from the config beside the session file. The strip shows the rate
    /// exactly when the Agent would.
    private(set) var showsTokenRate = false
    /// The current model's context window as omp on the Host reports it,
    /// nil until asked or when omp does not know. Looked up once per model
    /// selector for the store's life; a model omp cannot size stays unsized
    /// rather than being asked about on every tick.
    private(set) var contextWindow: Int?
    @ObservationIgnored private var contextWindows: [String: Int?] = [:]

    /// `11.0%` once the window is known, `30K` until then.
    var contextText: String? { usage.contextText(window: contextWindow) }

    /// omp's config is a few hundred bytes; a file this large is not it.
    static let configBytes = 256 * 1_024

    /// How much one refresh may download. A screen opened mid-session catches
    /// up in a single pass for every realistic file, and a file larger than
    /// this finishes catching up over the following refreshes.
    static let catchUpBytes = 16 * 1_024 * 1_024
    /// One ranged read's size: small enough that folding a chunk stays
    /// imperceptible on the main actor, large enough that catching up is not
    /// thousands of round trips.
    static let chunkBytes = 512 * 1_024

    /// Which refresh owns the store, the file the offset below belongs to,
    /// the config's age and the lookup out. Read activity never observes the
    /// store, so it is excluded from observation.
    @ObservationIgnored private var follower = SessionUsageFollowMachine()
    @ObservationIgnored private var offset: UInt64 = 0
    /// Bytes after the last newline: a line is folded only once it is complete,
    /// so a refresh never parses half of a line another process is still
    /// writing.
    @ObservationIgnored private var pending = Data()
    /// Reads whatever was appended since the last refresh and folds every
    /// complete line among it. `read` is the caller's transport borrow,
    /// resolved per call so a reconnect cannot leave a stale one behind.
    ///
    /// Each refresh's token fences its awaits: `.task(id:)` cancels the
    /// previous follower on a path change but does not wait for it, and its
    /// read may still land after the new path's totals are in place. A
    /// cancelled refresh stops at its next step.
    func refresh(
        path: String,
        read: (RemoteFileRange) async throws -> RemoteFileSlice,
        resolveContextWindow: ((String) async throws -> Int?)? = nil
    ) async {
        var effects = follower.handle(.refreshed(path: path, now: .now))
        while !effects.isEmpty {
            switch effects.removeFirst() {
            case .dropTotals:
                dropTotals()
            case .showTokenRate(let shows):
                showsTokenRate = shows
            case .readConfig(let token):
                effects += await readConfig(token: token, sessionPath: path, read: read)
            case .follow(let token):
                guard !Task.isCancelled else { return }
                effects += await follow(path: path, token: token, read: read)
            case .foldChunk:
                break // Consumed by `follow`'s loop.
            case .lookUpWindow(let token):
                guard !Task.isCancelled else { return }
                guard resolveContextWindow != nil else { break }
                effects += lookUpWindow(token: token)
            case .resolve(let token, let selector):
                guard let resolveContextWindow else { break }
                let outcome: SessionUsageFollowMachine.LookupOutcome
                do {
                    let window = try await resolveContextWindow(selector)
                    outcome = Task.isCancelled ? .dropped : .answered(window)
                } catch {
                    outcome = .dropped
                }
                effects += follower.handle(.lookupEnded(token, selector: selector, outcome))
            case .rememberWindow(let selector, let window):
                contextWindows[selector] = window
                if usage.modelSelector == selector { contextWindow = window }
            }
        }
    }

    /// Reads the appended tail and folds its complete lines; what the
    /// refresh does next.
    private func follow(
        path: String,
        token: UInt64,
        read: (RemoteFileRange) async throws -> RemoteFileSlice
    ) async -> [SessionUsageFollowMachine.Effect] {
        var budget = Self.catchUpBytes
        while budget > 0 {
            let maxBytes = min(budget, Self.chunkBytes)
            let slice: RemoteFileSlice
            do {
                slice = try await read(
                    RemoteFileRange(path: path, offset: offset, maxBytes: maxBytes))
            } catch {
                // A failed read says nothing about the file: keep the totals
                // and the offset, and try again on the next refresh.
                return ended(token)
            }
            // A newer refresh owns the store now — another path, or the same
            // one re-followed. These bytes belong to the read that was current
            // when they were asked for, not to whatever is followed now.
            guard !Task.isCancelled else { return [] }
            let effects = follower.handle(.chunkRead(token, fileExists: slice.length != nil))
            guard effects.first == .foldChunk(token), let length = slice.length else {
                // Stale, or the session file is gone: its figures were never
                // Waycar's to invent, so the strip goes back to showing nothing.
                return effects
            }
            if length < offset {
                // The path now holds a shorter file than the one the offset
                // addresses — replaced or rotated. Start over from its head,
                // still following it: dropping the path too would make the
                // next refresh start over a second time.
                restart()
                continue
            }
            offset += UInt64(slice.data.count)
            budget -= slice.data.count
            pending.append(slice.data)
            foldCompleteLines()
            // A short read is the end of the file: stop here instead of issuing
            // another round trip that could only return nothing.
            if slice.data.count < maxBytes { return ended(token) }
        }
        return ended(token)
    }

    private func ended(_ token: UInt64) -> [SessionUsageFollowMachine.Effect] {
        Task.isCancelled ? [] : follower.handle(.followed(token))
    }

    /// Drops the followed file and its totals. The screen calls this when the
    /// focused Agent has no session path, so a previous Agent's figures cannot
    /// outlive the switch.
    func clear() {
        for effect in follower.handle(.cleared) {
            if case .dropTotals = effect { dropTotals() }
        }
    }

    private func dropTotals() {
        showsTokenRate = false
        restart()
    }

    /// Asks the Host once per model. A failed lookup is not remembered, so
    /// the next refresh asks again; an answer of "unknown" is, so a model omp
    /// cannot size is not asked about every five seconds.
    private func lookUpWindow(token: UInt64) -> [SessionUsageFollowMachine.Effect] {
        guard let selector = usage.modelSelector else {
            contextWindow = nil
            return []
        }
        if let known = contextWindows[selector] {
            contextWindow = known
            return []
        }
        return follower.handle(.lookupNeeded(token, selector: selector))
    }

    /// Reads omp's config once a minute. A failed read keeps the last answer;
    /// an absent config, or a session stored where no config sits beside it,
    /// means the readout is off.
    private func readConfig(
        token: UInt64,
        sessionPath: String,
        read: (RemoteFileRange) async throws -> RemoteFileSlice
    ) async -> [SessionUsageFollowMachine.Effect] {
        guard let configPath = AgentSessionConfig.configPath(forSessionFile: sessionPath) else {
            return follower.handle(.configRead(token, showsRate: false, now: .now))
        }
        let slice: RemoteFileSlice
        do {
            slice = try await read(
                RemoteFileRange(path: configPath, offset: 0, maxBytes: Self.configBytes))
        } catch {
            return Task.isCancelled ? [] : follower.handle(.configRead(token, showsRate: nil, now: .now))
        }
        guard !Task.isCancelled else { return [] }
        let shows = slice.length != nil && AgentSessionConfig.showsTokenRate(in: slice.data)
        return follower.handle(.configRead(token, showsRate: shows, now: .now))
    }

    /// Forgets what was read of the followed file, keeping the path.
    private func restart() {
        offset = 0
        pending = Data()
        usage = AgentSessionUsage()
        contextWindow = nil
    }

    private func foldCompleteLines() {
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty {
                usage.fold(line: Data(line))
            }
            pending.removeSubrange(pending.startIndex...newline)
        }
    }
}
