import Foundation

/// Keeps the transcripts of the Agents that finished most recently on this
/// device, read while the app is open with a connection, so the offline
/// reader has something to show on a train. The Agents the user opens are
/// saved by their own terminal screens; this covers the ones they have not
/// opened lately.
///
/// Bounded on purpose: at most `limit` Agents, one read at a time (the Host's
/// requests share one SSH connection), none of an Agent whose copy is fresh
/// or that was read (or failed) within `staleAfter`, none of a Host whose
/// plugin cannot read transcripts until `staleAfter` passes, and nothing
/// while the app is not active. After a pass that left nothing to read it
/// looks again in `staleAfter`.
@MainActor
final class ChatTranscriptPrefetcher {
    static let limit = 8
    static let staleAfter: Duration = .seconds(TranscriptPrefetchMachine.cooldown)

    /// What the Console tells the prefetcher; closures, so tests run it
    /// against fakes.
    struct Source {
        /// The app is in the foreground.
        var isActive: @MainActor () -> Bool
        var agents: @MainActor () -> [ConsoleAgent]
        /// Whether a read of this Agent's transcript can be tried now: its
        /// rows are verified, its Host's markers are settled (the key of a
        /// chat's copy depends on them) and its kind has a reader.
        var canRead: @MainActor (ConsoleAgent) -> Bool
        /// When the copy kept for the Agent was last saved or confirmed.
        var savedAt: @MainActor (ConsoleAgent) -> Date?
        /// Reads the transcript from the Host and keeps it.
        var fetch: @MainActor (ConsoleAgent) async throws -> Void
        var now: @MainActor () -> Date
        var sleep: @Sendable (Duration) async throws -> Void
    }

    private let source: Source
    private var machine = TranscriptPrefetchMachine()
    private var tasks: [UInt64: Task<Void, Never>] = [:]

    init(source: Source) {
        self.source = source
    }

    /// The Console's state moved: starts a pass when something is due. A
    /// pass already running looks again after each read.
    func update() {
        guard source.isActive() else {
            cancel()
            return
        }
        guard !machine.isRunning else { return }
        let hasDue = nextDue() != nil
        let now = source.now()
        perform(machine.handle(.update(
            active: true, hasDue: hasDue, now: now,
            nextWake: hasDue ? nil : nextWake(now: now))))
    }

    /// Stops at once: the app left the foreground or a Host went away.
    func cancel() {
        perform(machine.handle(.cancel))
    }

    /// The `limit` most recently finished Agents the Console can read now,
    /// newest first, with Hosts and backends taking turns so one busy Host
    /// does not use every place. Recency is the Host's own change counter
    /// (`stateChangeSeq`), which only compares within one Host and backend.
    static func newestFinished(
        _ agents: [ConsoleAgent], limit: Int = ChatTranscriptPrefetcher.limit,
        where canRead: @MainActor (ConsoleAgent) -> Bool
    ) -> [ConsoleAgent] {
        struct Group: Hashable {
            let hostID: Host.ID
            let backend: HostBackend
        }
        let finished = agents.filter {
            !$0.isShell && ($0.agent.status == .done || $0.agent.status == .idle) && canRead($0)
        }
        var groups: [Group: [ConsoleAgent]] = [:]
        for agent in finished {
            groups[Group(hostID: agent.hostID, backend: agent.backend), default: []].append(agent)
        }
        let ordered = groups.keys.sorted {
            let lhs = groups[$0]?.first?.hostName ?? ""
            let rhs = groups[$1]?.first?.hostName ?? ""
            if lhs != rhs { return lhs < rhs }
            if $0.hostID != $1.hostID { return $0.hostID.uuidString < $1.hostID.uuidString }
            return $0.backend.rawValue < $1.backend.rawValue
        }
        let ranked: [[ConsoleAgent]] = ordered.map { group in
            (groups[group] ?? []).sorted { lhs, rhs in
                let lhsSequence = lhs.agent.stateChangeSeq ?? 0
                let rhsSequence = rhs.agent.stateChangeSeq ?? 0
                if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
                let lhsOrder = lhs.snapshotOrder ?? Int.max
                let rhsOrder = rhs.snapshotOrder ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.agent.paneID < rhs.agent.paneID
            }
        }
        var picked: [ConsoleAgent] = []
        var rank = 0
        while picked.count < limit {
            let row = ranked.compactMap { rank < $0.count ? $0[rank] : nil }
            if row.isEmpty { break }
            picked += row.prefix(limit - picked.count)
            rank += 1
        }
        return picked
    }

    private func nextDue() -> ConsoleAgent? {
        let now = source.now()
        return Self.newestFinished(source.agents(), where: source.canRead).first { agent in
            guard machine.canTry(agent.id, now: now) else { return false }
            guard let saved = source.savedAt(agent) else { return true }
            return now.timeIntervalSince(saved) >= TranscriptPrefetchMachine.cooldown
        }
    }

    private func nextWake(now: Date) -> Date? {
        let candidates = Self.newestFinished(source.agents(), where: source.canRead).map {
            TranscriptPrefetchMachine.Candidate(id: $0.id, savedAt: source.savedAt($0))
        }
        return machine.nextWake(for: candidates, now: now)
    }

    private func run(_ token: UInt64) async {
        while !Task.isCancelled, machine.ownsPass(token), source.isActive() {
            guard let agent = nextDue() else { break }
            _ = machine.handle(.attempted(token, agent.id, now: source.now()))
            do {
                try await source.fetch(agent)
            } catch is CancellationError {
                break
            } catch {
                // Silent: no plugin or an unwritten transcript is no news.
                // The machine rejects a cancelled pass before changing cooldowns.
                if Self.cannotReadTranscripts(error) {
                    _ = machine.handle(.unreadable(token, agent.hostID, now: source.now()))
                }
            }
        }
        tasks[token] = nil
        guard machine.ownsPass(token) else { return }
        let active = !Task.isCancelled && source.isActive()
        let now = source.now()
        perform(machine.handle(.ended(token, active: active, now: now, nextWake: active ? nextWake(now: now) : nil)))
    }

    private func perform(_ effects: [TranscriptPrefetchMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .cancel(let token):
                tasks.removeValue(forKey: token)?.cancel()
            case .run(let token):
                tasks[token] = Task { [weak self] in await self?.run(token) }
            case .sleep(let token, let delay):
                let sleep = source.sleep
                tasks[token] = Task { [weak self] in
                    do { try await sleep(delay) } catch { return }
                    guard !Task.isCancelled, let self else { return }
                    tasks[token] = nil
                    perform(machine.handle(.woke(token)))
                }
            case .update:
                update()
            }
        }
    }

    /// The Host's side lacks the reader: no Agent of it can be read until
    /// the plugin changes.
    private static func cannotReadTranscripts(_ error: any Error) -> Bool {
        (error as? NotificationRegistrationError) == .pluginNotInstalled
            || (error as? ChatTranscriptError) == .readerUnavailable
    }
}
