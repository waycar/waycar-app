import CryptoKit
import Foundation
import OSLog
import Synchronization

/// Each Agent's last transcript, kept on this device so a chat opens with its
/// bubbles before the Host answers, and so the offline reader can show an
/// Agent's conversation with no connection at all. The live read still runs
/// and reconciles; a chat's copy only spares its empty first paint.
///
/// One file per Agent launch under Application Support, excluded from backups
/// and written with complete file protection: unreadable while the device is
/// locked, in which case the chat simply starts from the Host's answer. Pane
/// and terminal ids are opaque, so paths carry only their SHA-256 digests.
///
/// A file names the key it was written for and when it was last saved or
/// confirmed current; one for a different key, another format version, or
/// bytes that no longer decode is deleted on read instead of shown.
final class ChatTranscriptCache: Sendable {
    /// One Agent launch: a pane reused by a new terminal or a relaunch with a
    /// new marker reads as a different transcript.
    struct Key: Hashable, Sendable {
        let hostID: Host.ID
        let paneID: String
        let terminalID: String
        /// `ChatModeTimestamp.string(from: marker.launchedAt)`; "" without a marker.
        let launchedAt: String
    }

    private struct MessageDTO: Codable, Equatable {
        let id: String
        let role: String
        let text: String
        let ts: String?
        let media: [MediaDTO]
        let card: ChatTranscriptCard?

        init(_ message: ChatTranscriptMessage) {
            id = message.id
            role = message.role.rawValue
            text = message.text
            ts = message.timestamp.map(ChatModeTimestamp.string(from:))
            media = message.media.map(MediaDTO.init)
            card = message.card
        }

        var message: ChatTranscriptMessage? {
            guard let role = ChatTranscriptMessage.Role(rawValue: role) else { return nil }
            let timestamp: Date?
            if let ts {
                guard let date = ChatModeTimestamp.date(from: ts) else { return nil }
                timestamp = date
            } else {
                timestamp = nil
            }
            let media = media.compactMap(\.media)
            guard media.count == self.media.count else { return nil }
            return ChatTranscriptMessage(
                id: id, role: role, text: text, timestamp: timestamp, media: media, card: card)
        }
    }

    /// One `ChatMedia`, with exactly one of `path`, `url` and `inline` set.
    private struct MediaDTO: Codable, Equatable {
        /// One inline source, in either form: the transcript-line form
        /// (`transcript`, `offset`) or the session form (`session`, and the
        /// export's harness `kind` when not opencode); the RFC 6901
        /// `pointer` names the base64 string either way.
        struct Inline: Codable, Equatable {
            let transcript: String?
            let offset: Int?
            let session: String?
            let pointer: String
            let kind: String?

            /// The source the object names, or nil when it is neither form
            /// or both.
            var source: ChatMedia.Source? {
                switch (session, transcript, offset) {
                case (let session?, nil, nil) where !session.isEmpty:
                    .sessionInline(session: session, pointer: pointer, agentKind: kind)
                case (nil, let transcript?, let offset?)
                    where !transcript.isEmpty && offset >= 0:
                    .inline(transcript: transcript, offset: offset, pointer: pointer)
                default:
                    nil
                }
            }
        }

        let id: String
        let kind: String
        let mime: String?
        let alt: String?
        let path: String?
        let url: URL?
        let inline: Inline?

        init(_ media: ChatMedia) {
            id = media.id
            kind = media.kind.rawValue
            mime = media.mime
            alt = media.alt
            var path: String?
            var url: URL?
            var inline: Inline?
            switch media.source {
            case .hostFile(let hostPath):
                path = hostPath
            case .inline(let transcript, let offset, let pointer):
                inline = Inline(
                    transcript: transcript, offset: offset, session: nil, pointer: pointer, kind: nil)
            case .sessionInline(let session, let pointer, let agentKind):
                inline = Inline(
                    transcript: nil, offset: nil, session: session, pointer: pointer, kind: agentKind)
            case .web(let webURL):
                url = webURL
            }
            self.path = path
            self.url = url
            self.inline = inline
        }

        var media: ChatMedia? {
            guard let kind = ChatMedia.Kind(rawValue: kind) else { return nil }
            let source: ChatMedia.Source
            switch (path, url, inline) {
            case (let path?, nil, nil): source = .hostFile(path: path)
            case (nil, let url?, nil): source = .web(url)
            case (nil, nil, let inline?):
                guard let inlineSource = inline.source else { return nil }
                source = inlineSource
            default: return nil
            }
            return ChatMedia(id: id, kind: kind, mime: mime, source: source, alt: alt)
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let savedAt: String
        let hostID: UUID
        let paneID: String
        let terminalID: String
        let launchedAt: String
        /// Which Agent in that terminal the list belongs to (`identity` of
        /// `save`); absent in a file written without one, which reads as "".
        let identity: String?
        let messages: [MessageDTO]
    }

    /// 3 adds rich cards; a file of any other version is deleted on read.
    static let formatVersion = 3
    static let maxMessages = 300
    static let maxBytes = 2_000_000
    /// Room left in `maxBytes` for the envelope's own fields.
    private static let envelopeAllowance = 4_096
    let directory: URL
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.otreva.waycar.chat-transcript-cache")
    /// Each key's copy (`TranscriptCacheMachine`): what memory holds, what
    /// it knows is missing, and which writes are queued.
    private let state = Mutex(TranscriptCacheMachine())
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "ChatTranscriptCache")

    init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// `<Application Support>/ChatTranscripts`, or nil when Application
    /// Support cannot be resolved — chats then open without a local copy.
    static func applicationSupport() -> ChatTranscriptCache? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        else { return nil }
        return ChatTranscriptCache(
            directory: base.appending(path: "ChatTranscripts", directoryHint: .isDirectory))
    }

    /// Newest first: a pending write, then the in-memory copy, then the file. [] when none.
    /// Memory answers first, a key known to have no file included; only a key
    /// not seen before reads the disk, once, through the write queue (so it
    /// sees removals in order, and waits at most for one write in flight).
    ///
    /// `identity` names the Agent asking: a list saved under another one is
    /// not that Agent's, however alike the key, and reads as none. The key
    /// already names a pane's terminal and a chat's launch; for an Agent a
    /// terminal can run in turn (herdr resumes or replaces one keeping pane
    /// and terminal ids), the caller's identity tells them apart. "" is no
    /// identity beyond the key (a chat's launch).
    func messages(for key: Key, identity: String = "") -> [ChatTranscriptMessage] {
        if let known = state.withLock({ $0.messages(for: key, identity: identity) }) {
            return known
        }
        let read = queue.sync(execute: { self.read(key) })
        return state.withLock { machine in
            // A save that landed while the file was read is newer.
            _ = machine.handle(.diskRead(key, read.map {
                TranscriptCacheMachine.Found(
                    messages: $0.messages, savedAt: $0.savedAt, identity: $0.identity)
            }))
            return machine.messages(for: key, identity: identity) ?? []
        }
    }

    /// When the list kept for `key` under `identity` was last saved or
    /// confirmed current by a read of the Host; nil when none is kept.
    func savedAt(for key: Key, identity: String = "") -> Date? {
        guard !messages(for: key, identity: identity).isEmpty else { return nil }
        return state.withLock { $0.savedAt(for: key) }
    }

    /// Keeps the newest `maxMessages`, then drops the oldest until it encodes in `maxBytes`.
    /// A list equal to the one already held for the key under the same
    /// `identity` writes nothing; a list held under another identity is
    /// replaced, never merged into (the caller merges against what
    /// `messages(for:identity:)` showed it, which is none for another's).
    /// Coalesced: while a write for the key is queued, a newer list replaces
    /// it. Trimming, encoding and I/O stay off the caller; the copy held in
    /// memory is the caller's list itself.
    func save(_ messages: [ChatTranscriptMessage], for key: Key, identity: String = "") {
        let stamp = now()
        perform(state.withLock {
            $0.handle(.saved(key, messages, identity: identity, at: stamp))
        })
    }

    /// Moves the saved time of the list kept for `key` under `identity` to
    /// now: a read of the Host just found it still current. Does nothing
    /// where none is kept (or only under another identity), or where the
    /// stored time is within `TranscriptCacheMachine.confirmationGranularity`,
    /// so a read every few seconds costs no writes. Whether the time moved.
    @discardableResult
    func confirm(_ key: Key, identity: String = "") -> Bool {
        guard !messages(for: key, identity: identity).isEmpty else { return false }
        let stamp = now()
        let effects = state.withLock { $0.handle(.confirmed(key, identity: identity, at: stamp)) }
        perform(effects)
        return effects.contains(.moved)
    }

    /// Performs the machine's effects outside the lock: writes and removals
    /// go to the serial queue in the order asked for.
    private func perform(_ effects: [TranscriptCacheMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .scheduleWrite(let key):
                scheduleWrite(for: key)
            case .write, .moved:
                break // `writeDue` and `confirm` consume these.
            case .deleteFile(let key):
                let url = fileURL(for: key)
                queue.async {
                    try? FileManager.default.removeItem(at: url)
                }
            case .deletePane(let hostID, let paneID):
                let url = paneDirectory(hostID: hostID, paneID: paneID)
                queue.async {
                    try? FileManager.default.removeItem(at: url)
                }
            case .deleteHost(let hostID):
                let url = hostDirectory(hostID)
                queue.async {
                    try? FileManager.default.removeItem(at: url)
                }
            case .deleteHosts(let hostIDs):
                let directory = directory
                queue.async {
                    guard
                        let hosts = try? FileManager.default.contentsOfDirectory(
                            at: directory, includingPropertiesForKeys: nil)
                    else { return }
                    for host in hosts {
                        if let id = UUID(uuidString: host.lastPathComponent), hostIDs.contains(id) {
                            continue
                        }
                        try? FileManager.default.removeItem(at: host)
                    }
                }
            }
        }
    }

    private func scheduleWrite(for key: Key) {
        queue.async { [self] in
            for case .write(let written, let messages, let savedAt, let identity)
                in state.withLock({ $0.handle(.writeDue(key)) })
            {
                persist(Self.trim(messages), savedAt: savedAt, identity: identity, for: written)
            }
        }
    }

    /// Forgets the list kept for `key`, on disk and in memory.
    func remove(_ key: Key) {
        perform(state.withLock { $0.handle(.removed(key)) })
    }

    /// Forgets every key of that pane, on disk and in memory.
    func remove(hostID: Host.ID, paneID: String) {
        perform(state.withLock { $0.handle(.removedPane(hostID, paneID: paneID)) })
    }

    /// Forgets every key of that Host, on disk and in memory.
    func remove(hostID: Host.ID) {
        perform(state.withLock { $0.handle(.removedHost(hostID)) })
    }

    /// Deletes every Host's files but these, including Hosts removed from the
    /// catalog while this device was not running.
    func retainOnly(_ hostIDs: Set<Host.ID>) {
        perform(state.withLock { $0.handle(.retained(hostIDs)) })
    }

    /// Deletes files saved more than `age` before `now()`, and any that no
    /// longer decode. Held copies of deleted files are forgotten too.
    func prune(olderThan age: Duration) {
        let cutoff = now().addingTimeInterval(-Self.seconds(age))
        queue.async { [self] in
            let manager = FileManager.default
            guard
                let enumerator = manager.enumerator(
                    at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            else { return }
            for case let url as URL in enumerator where url.pathExtension == "json" {
                // Locked device: leave the file for a later launch.
                guard let data = try? Data(contentsOf: url) else { continue }
                guard
                    let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                    envelope.version == Self.formatVersion,
                    let savedAt = ChatModeTimestamp.date(from: envelope.savedAt)
                else {
                    try? manager.removeItem(at: url)
                    continue
                }
                guard savedAt < cutoff else { continue }
                try? manager.removeItem(at: url)
                let key = Key(
                    hostID: envelope.hostID, paneID: envelope.paneID,
                    terminalID: envelope.terminalID, launchedAt: envelope.launchedAt)
                state.withLock { _ = $0.handle(.pruned(key)) }
            }
        }
    }

    /// Waits for every write and removal queued so far.
    func flush() {
        queue.sync {}
    }

    func fileURL(for key: Key) -> URL {
        paneDirectory(hostID: key.hostID, paneID: key.paneID)
            .appending(
                path: "\(Self.digest(key.terminalID + "\n" + key.launchedAt)).json",
                directoryHint: .notDirectory)
    }

    private func hostDirectory(_ hostID: Host.ID) -> URL {
        directory.appending(path: hostID.uuidString, directoryHint: .isDirectory)
    }

    private func paneDirectory(hostID: Host.ID, paneID: String) -> URL {
        hostDirectory(hostID).appending(path: Self.digest(paneID), directoryHint: .isDirectory)
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// The newest `maxMessages`, then the oldest dropped until the list fits
    /// `maxBytes` with room for the envelope.
    private static func trim(_ messages: [ChatTranscriptMessage]) -> [ChatTranscriptMessage] {
        let newest = Array(messages.suffix(maxMessages))
        let encoder = JSONEncoder()
        let sizes = newest.map { (try? encoder.encode(MessageDTO($0)).count) ?? 0 }
        // Each element after the first adds a comma.
        var total = sizes.reduce(0, +) + max(sizes.count - 1, 0)
        let budget = maxBytes - envelopeAllowance
        var drop = 0
        while drop < sizes.count, total > budget {
            total -= sizes[drop] + 1
            drop += 1
        }
        return Array(newest.dropFirst(drop))
    }

    private func read(_ key: Key) -> (messages: [ChatTranscriptMessage], savedAt: Date, identity: String)? {
        let url = fileURL(for: key)
        // A missing file and a locked device read the same: start empty.
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.version == Self.formatVersion,
            envelope.hostID == key.hostID,
            envelope.paneID == key.paneID,
            envelope.terminalID == key.terminalID,
            envelope.launchedAt == key.launchedAt,
            let savedAt = ChatModeTimestamp.date(from: envelope.savedAt)
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let messages = envelope.messages.compactMap(\.message)
        guard messages.count == envelope.messages.count else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return (messages, savedAt, envelope.identity ?? "")
    }

    private func persist(
        _ messages: [ChatTranscriptMessage], savedAt: Date, identity: String, for key: Key
    ) {
        do {
            let url = fileURL(for: key)
            try prepareDirectory(url.deletingLastPathComponent())
            let envelope = Envelope(
                version: Self.formatVersion, savedAt: ChatModeTimestamp.string(from: savedAt),
                hostID: key.hostID, paneID: key.paneID, terminalID: key.terminalID,
                launchedAt: key.launchedAt, identity: identity, messages: messages.map(MessageDTO.init))
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            // Expected while the device is locked; the next change retries.
            Self.log.debug("Chat transcript cache write skipped: \(error.localizedDescription)")
        }
    }

    /// Creates the pane's directory, and marks the root excluded from backup
    /// (which covers everything beneath it).
    private func prepareDirectory(_ paneDirectory: URL) throws {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        if !manager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: attributes)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = directory
        try root.setResourceValues(values)
        try manager.createDirectory(
            at: paneDirectory, withIntermediateDirectories: true, attributes: attributes)
    }
}
