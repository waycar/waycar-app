import Foundation

/// What `ChatTranscriptCache` knows of each key's transcript copy: nothing
/// yet (no entry), a list held in memory (with the identity it was saved
/// under, when it was saved or confirmed, and whether its write is still
/// queued), and whether the key's file is known to be missing.
///
/// A held list is the newest: a disk read that lands after a save, or after
/// any other read filled the entry, changes nothing. Writes coalesce: a save
/// while a write is queued only replaces what that write takes. The owner
/// keeps the machine under its mutex, reads the disk and writes on its
/// serial queue, and performs removals there in order.
///
/// Kept as they were (CHAT-07): a removal while a disk read is out marks
/// the key missing, and the read that lands then still holds what it found
/// (it read before the removal's file deletion ran), beside the mark. A held
/// list answers first; the mark answers once `retainOnly` or `prune` forgets
/// the list. `retainOnly` forgets held lists of other Hosts but keeps their
/// missing marks; a pane or Host removal forgets both.
struct TranscriptCacheMachine: StateMachine {
    typealias Key = ChatTranscriptCache.Key

    struct Copy: Equatable, Sendable {
        var messages: [ChatTranscriptMessage]
        var identity: String
        var savedAt: Date
        var writeQueued: Bool
    }

    struct Entry: Equatable, Sendable {
        var held: Copy?
        /// The file was looked for and is not there: the disk is asked once.
        /// Beside a held list only after a read raced a removal.
        var missing = false

        static let missing = Entry(held: nil, missing: true)
    }

    struct State: Equatable, Sendable {
        var entries: [Key: Entry] = [:]
    }

    /// What a disk read found.
    struct Found: Equatable, Sendable {
        let messages: [ChatTranscriptMessage]
        let savedAt: Date
        let identity: String
    }

    enum Event: Equatable, Sendable {
        case diskRead(Key, Found?)
        case saved(Key, [ChatTranscriptMessage], identity: String, at: Date)
        /// A read of the Host found the held list still current.
        case confirmed(Key, identity: String, at: Date)
        /// The key's queued write runs now.
        case writeDue(Key)
        case removed(Key)
        case removedPane(Host.ID, paneID: String)
        case removedHost(Host.ID)
        case retained(Set<Host.ID>)
        /// `prune` deleted the key's file.
        case pruned(Key)
    }

    enum Effect: Equatable, Sendable {
        case scheduleWrite(Key)
        case write(Key, [ChatTranscriptMessage], savedAt: Date, identity: String)
        /// `confirmed` moved the saved time.
        case moved
        case deleteFile(Key)
        case deletePane(Host.ID, paneID: String)
        case deleteHost(Host.ID)
        case deleteHosts(except: Set<Host.ID>)
    }

    /// A list confirmed again moves its time on, and rewrites its file, only
    /// once the stored time is older than this.
    static let confirmationGranularity: TimeInterval = 60

    private(set) var state = State()

    /// The list kept for `key` as `identity` sees it: [] for a missing file
    /// or another identity's list, nil when the disk was never asked.
    func messages(for key: Key, identity: String) -> [ChatTranscriptMessage]? {
        guard let entry = state.entries[key] else { return nil }
        if let copy = entry.held { return copy.identity == identity ? copy.messages : [] }
        return entry.missing ? [] : nil
    }

    func savedAt(for key: Key) -> Date? {
        state.entries[key]?.held?.savedAt
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .diskRead(let key, let found):
            if state.entries[key]?.held != nil { return [] }
            update(key) { entry in
                if let found {
                    entry.held = Copy(
                        messages: found.messages, identity: found.identity,
                        savedAt: found.savedAt, writeQueued: false)
                } else {
                    entry.missing = true
                }
            }
            return []
        case .saved(let key, let messages, let identity, let stamp):
            if let copy = state.entries[key]?.held, copy.messages == messages,
                copy.identity == identity
            {
                return []
            }
            return stage(messages, at: stamp, for: key, identity: identity)
        case .confirmed(let key, let identity, let stamp):
            guard let copy = state.entries[key]?.held,
                stamp.timeIntervalSince(copy.savedAt) > Self.confirmationGranularity
            else { return [] }
            return [.moved] + stage(copy.messages, at: stamp, for: key, identity: identity)
        case .writeDue(let key):
            guard var copy = state.entries[key]?.held, copy.writeQueued else { return [] }
            copy.writeQueued = false
            state.entries[key]?.held = copy
            return [.write(key, copy.messages, savedAt: copy.savedAt, identity: copy.identity)]
        case .removed(let key):
            state.entries[key] = .missing
            return [.deleteFile(key)]
        case .removedPane(let hostID, let paneID):
            state.entries = state.entries.filter { $0.key.hostID != hostID || $0.key.paneID != paneID }
            return [.deletePane(hostID, paneID: paneID)]
        case .removedHost(let hostID):
            state.entries = state.entries.filter { $0.key.hostID != hostID }
            return [.deleteHost(hostID)]
        case .retained(let hostIDs):
            let dropped = state.entries.keys.filter { !hostIDs.contains($0.hostID) }
            for key in dropped {
                update(key) { $0.held = nil }
            }
            return [.deleteHosts(except: hostIDs)]
        case .pruned(let key):
            if let copy = state.entries[key]?.held, !copy.writeQueued {
                update(key) { $0.held = nil }
            }
            return []
        }
    }

    /// Changes the key's entry, dropping it once it knows nothing.
    private mutating func update(_ key: Key, _ change: (inout Entry) -> Void) {
        var entry = state.entries[key] ?? Entry()
        change(&entry)
        state.entries[key] = entry.held == nil && !entry.missing ? nil : entry
    }

    /// Holds `messages` as the key's newest list; a write is scheduled
    /// unless one is already queued, which then takes this list.
    private mutating func stage(
        _ messages: [ChatTranscriptMessage], at stamp: Date, for key: Key, identity: String
    ) -> [Effect] {
        let queued = state.entries[key]?.held?.writeQueued ?? false
        state.entries[key] = Entry(held: Copy(
            messages: messages, identity: identity, savedAt: stamp, writeQueued: true))
        return queued ? [] : [.scheduleWrite(key)]
    }
}
