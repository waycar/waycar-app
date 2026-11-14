import Foundation

/// The last-frame cache's index (``AgentLastFrameStore``): which Agents keep
/// a frame, most recently captured first, and whether the protected index on
/// disk has been read yet.
///
/// Rules a reader needs:
/// - Until the index loads (it exists but is unreadable while the device is
///   locked), nothing is written or deleted on disk: removals apply to the
///   frames in memory and are remembered for the disk's (`pending`). The
///   first load merges: frames recorded meanwhile win, remembered removals
///   and the last host catalog apply to the disk's, expired ones drop, then
///   files no entry names are swept.
/// - A capture's JPEG is encoded on the disk queue after the main actor has
///   moved on; its completion is kept only while that file still holds the
///   raw capture (`unencoded`), so a discarded or replaced frame never comes
///   back. A file name is new per capture, so it is the completion's token.
/// - Every change once loaded queues the index as it stands, in order.
struct AgentLastFrameIndexMachine: StateMachine {
    typealias Entry = AgentLastFrameStore.Entry
    typealias Target = ConsoleInventoryCache.Target

    enum Load: Equatable, Sendable {
        /// The index has not been read: removals meanwhile wait for the
        /// disk's frames.
        case pending(discards: Set<ConsoleAgent.ID>, retentions: [ConsoleScope: Set<ConsoleAgent.ID>])
        case loaded
    }

    struct State: Equatable, Sendable {
        var load = Load.pending(discards: [], retentions: [:])
        /// Most recent first.
        var entries: [Entry] = []
        /// The catalog `retainHosts` last asked for, applied once a deferred
        /// load lands.
        var retainedTargets: [Host.ID: Target]?
        /// Files whose pixels are still the raw capture.
        var unencoded: Set<String> = []
    }

    enum IndexRead: Equatable, Sendable {
        /// The index exists but cannot be read (locked).
        case unreadable
        /// The index's entries: none when it is missing or undecodable.
        case entries([Entry])
    }

    enum Removal: Equatable, Sendable {
        case agent(ConsoleAgent.ID)
        /// Hosts not in the catalog, or whose connection target changed.
        case hostsOutside([Host.ID: Target])
        /// Agents a verified scope no longer lists.
        case unlisted(Set<ConsoleAgent.ID>, verifiedScopes: Set<ConsoleScope>)
    }

    enum Event: Equatable, Sendable {
        /// A memory-only cache: nothing on disk to wait for.
        case memoryOnly
        case indexRead(IndexRead, now: Date)
        case record(Entry, now: Date)
        case remove(Removal)
        /// Remembers a discard for the disk's frames while pending.
        case deferDiscard(ConsoleAgent.ID)
        /// Remembers a verified scope's listing for the disk's frames while
        /// pending.
        case deferRetention(Set<ConsoleAgent.ID>, verifiedScopes: Set<ConsoleScope>)
        case setRetainedTargets([Host.ID: Target])
        /// The JPEG for `file` was written (or failed to encode: no event).
        case encoded(file: String)
    }

    enum Effect: Equatable, Sendable {
        /// Forget these files' pixels.
        case dropPixels([String])
        /// Queue on the disk queue, in order: encode and write `encode`'s
        /// capture, remove `removedFiles`, write `index`.
        case persist(index: [Entry], removedFiles: [String], encode: String?)
        /// Queue the first load's sweep of files outside `keep`, and the
        /// merged index when it differs from the disk's.
        case sweep(keep: Set<String>, index: [Entry], rewritesIndex: Bool)
        /// Keep the encoded JPEG for `file` in place of its raw capture.
        case storeEncoded(String)
    }

    private(set) var state = State()

    var isLoaded: Bool { state.load == .loaded }
    var entries: [Entry] { state.entries }

    static func isFresh(_ entry: Entry, now: Date) -> Bool {
        now.timeIntervalSince(entry.capturedAt) <= AgentLastFrameStore.maxAge
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state.load, event) {
        case (.pending, .memoryOnly):
            state.load = .loaded
            return []
        case (.loaded, .memoryOnly):
            return []
        case (.pending, .indexRead(.unreadable, _)):
            return []
        case (.pending(let discards, let retentions), .indexRead(.entries(let loaded), let now)):
            state.load = .loaded
            let recorded = Set(state.entries.map(\.agentID))
            var merged = state.entries + loaded.filter {
                !recorded.contains($0.agentID) && !discards.contains($0.agentID)
                    && (retentions[$0.scope]?.contains($0.agentID) ?? true)
            }
            if let targets = state.retainedTargets {
                merged.removeAll { targets[$0.hostID] != $0.target }
            }
            state.entries = Array(merged.filter { Self.isFresh($0, now: now) }
                .sorted { $0.capturedAt > $1.capturedAt }
                .prefix(AgentLastFrameStore.capacity))
            let keep = Set(state.entries.map(\.file))
            return [.sweep(keep: keep, index: state.entries, rewritesIndex: state.entries != loaded)]
        case (.loaded, .indexRead):
            return []
        case (_, .record(let entry, let now)):
            let replaced = { (old: Entry) in old.agentID == entry.agentID || !Self.isFresh(old, now: now) }
            var removed = state.entries.filter(replaced)
            state.entries.removeAll(where: replaced)
            state.entries.insert(entry, at: 0)
            if state.entries.count > AgentLastFrameStore.capacity {
                removed += state.entries[AgentLastFrameStore.capacity...]
                state.entries.removeLast(state.entries.count - AgentLastFrameStore.capacity)
            }
            let files = removed.map(\.file)
            state.unencoded.insert(entry.file)
            state.unencoded.subtract(files)
            return [.dropPixels(files)] + persist(removed: files, encode: entry.file)
        case (_, .remove(let removal)):
            let matches = { (entry: Entry) in Self.matches(entry, removal) }
            let removed = state.entries.filter(matches)
            guard !removed.isEmpty else { return [] }
            state.entries.removeAll(where: matches)
            let files = removed.map(\.file)
            state.unencoded.subtract(files)
            return [.dropPixels(files)] + persist(removed: files, encode: nil)
        case (.pending(var discards, let retentions), .deferDiscard(let agent)):
            discards.insert(agent)
            state.load = .pending(discards: discards, retentions: retentions)
            return []
        case (.pending(let discards, var retentions), .deferRetention(let listed, let scopes)):
            for scope in scopes {
                // Once pruned, an old frame cannot return in a later inventory.
                retentions[scope] = retentions[scope].map { $0.intersection(listed) } ?? listed
            }
            state.load = .pending(discards: discards, retentions: retentions)
            return []
        case (.loaded, .deferDiscard), (.loaded, .deferRetention):
            return []
        case (_, .setRetainedTargets(let targets)):
            state.retainedTargets = targets
            return []
        case (_, .encoded(let file)):
            guard state.unencoded.remove(file) != nil else { return [] }
            return [.storeEncoded(file)]
        }
    }

    /// Before the index loads, the disk holds entries memory doesn't:
    /// writing the index then would drop them.
    private func persist(removed files: [String], encode: String?) -> [Effect] {
        guard isLoaded else { return [] }
        return [.persist(index: state.entries, removedFiles: files, encode: encode)]
    }

    private static func matches(_ entry: Entry, _ removal: Removal) -> Bool {
        switch removal {
        case .agent(let agent):
            entry.agentID == agent
        case .hostsOutside(let targets):
            targets[entry.hostID] != entry.target
        case .unlisted(let listed, let scopes):
            scopes.contains(entry.scope) && !listed.contains(entry.agentID)
        }
    }
}
