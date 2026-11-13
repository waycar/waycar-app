import CryptoKit
import Foundation
import os

/// A Composer message waiting on this device for its Host (CONTEXT.md
/// **Queued Message**): what was typed, its attachments, the Agent it is for
/// and when it was sent. Persisted per Host and Agent so it outlives the app
/// process; it leaves the queue once it is delivered, fails after its
/// request was written, or the user deletes or withdraws it.
struct QueuedMessage: Codable, Sendable, Equatable, Identifiable {
    /// The Agent a message was queued for. herdr reuses pane ids and an
    /// Agent's name and terminal are no identity, so a drain checks the
    /// Agent's `agent_session` when it had one, else the pane's Agent kind.
    struct AgentIdentity: Codable, Sendable, Equatable {
        let paneID: String
        /// nil when no row listed the Agent at Send.
        let kind: String?
        /// herdr's `agent_session` value; nil when the Agent reported none.
        let session: String?

        init(paneID: String, kind: String?, session: String?) {
            self.paneID = paneID
            self.kind = kind
            self.session = session
        }

        init(_ agent: Agent) {
            self.init(paneID: agent.paneID, kind: agent.kind, session: agent.agentSession?.value)
        }

        /// Whether `current` is still the Agent this message was queued for:
        /// the same pane, and the recorded session, or without one the
        /// recorded kind. A message queued before any row listed the Agent
        /// never matches on its own: it is held until the user sends it
        /// anyway, so a reused pane cannot receive it by accident.
        func matches(_ current: AgentIdentity) -> Bool {
            guard current.paneID == paneID else { return false }
            if let session { return current.session == session }
            guard let kind else { return false }
            return current.kind == kind
        }
    }

    struct Attachment: Codable, Sendable, Equatable, Identifiable {
        enum Kind: String, Codable, Sendable {
            case image
            case file
        }

        let id: UUID
        let kind: Kind
        /// The picked file's name for a file chip; nil for an image.
        let fileName: String?
        /// The local copy in the message's directory, until it is uploaded.
        var localFileName: String?
        /// A file's extension, or an image's format (`jpeg`, `png`).
        let fileExtension: String
        let pixelWidth: Int?
        let pixelHeight: Int?
        let byteCount: Int64
        /// Where the upload put it on the Host; the prompt carries this.
        var hostPath: String?
    }

    let id: UUID
    let hostID: Host.ID
    var agent: AgentIdentity
    /// What the user typed; the prompt is this with the attachments' Host
    /// paths appended (`AgentComposerStore.prompt(text:paths:)`).
    let draftText: String
    var attachments: [Attachment]
    let createdAt: Date
    /// Set just before its prompt goes out, cleared if nothing reached the
    /// Host: a record that still has it after the app ended may have been
    /// delivered, so it is not sent again on its own.
    var promptStartedAt: Date? = nil
    /// An upload failure keeps its copies for Retry, never an automatic
    /// send after relaunch. Absent in older records means still waiting.
    var failureMessage: String? = nil
    /// The Queued Launch this message belonged to before handover. Kept
    /// across re-keying so deleting a partially handed-over launch also
    /// deletes its moved, still-unsent messages, not the real pane's Sends.
    var originLaunchID: QueuedLaunch.ID? = nil

    var agentID: ConsoleAgent.ID { ConsoleAgent.ID(hostID: hostID, paneID: agent.paneID) }

    /// Every attachment is on the Host.
    var isUploaded: Bool { attachments.allSatisfy { $0.hostPath != nil } }

    /// The delivered text, with the Host paths known so far.
    var prompt: String {
        AgentComposerStore.prompt(text: draftText, paths: attachments.compactMap(\.hostPath))
    }
}

/// Queued Messages on this device, one directory per message under
/// `<root>/<Host id>/<pane digest>/<message id>/`: `message.json` and the
/// message's attachment copies. Application Support, never the temporary
/// directory or Caches, so the system does not purge a message waiting for
/// its Host; excluded from backup. Writes are synchronous and atomic: a
/// message must be on disk before Send returns, or an app kill right after
/// it would lose what the user just sent.
final class QueuedMessageStore: Sendable {
    let directory: URL
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "QueuedMessageStore")
    private static let recordName = "message.json"

    init(directory: URL) {
        self.directory = directory
    }

    /// `<Application Support>/QueuedMessages`, or nil when Application
    /// Support cannot be resolved.
    static func applicationSupport() -> QueuedMessageStore? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        else { return nil }
        return QueuedMessageStore(
            directory: base.appending(path: "QueuedMessages", directoryHint: .isDirectory))
    }

    /// The Host's Queued Messages, oldest first. A directory whose record
    /// does not decode, or belongs to another Host, is deleted with its
    /// files; one whose record cannot be read right now (protected data
    /// unavailable, I/O error) is skipped and kept.
    func messages(on hostID: Host.ID) -> [QueuedMessage] {
        let manager = FileManager.default
        let host = hostDirectory(hostID)
        guard
            let panes = try? manager.contentsOfDirectory(
                at: host, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var found: [QueuedMessage] = []
        let decoder = JSONDecoder()
        for pane in panes {
            guard
                let entries = try? manager.contentsOfDirectory(
                    at: pane, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for entry in entries {
                let record = entry.appending(path: Self.recordName, directoryHint: .notDirectory)
                guard let data = try? Data(contentsOf: record) else { continue }
                guard let message = try? decoder.decode(QueuedMessage.self, from: data),
                    message.hostID == hostID
                else {
                    try? manager.removeItem(at: entry)
                    continue
                }
                // A handover may have ended after the atomic record write
                // but before the directory rename. The identity is the
                // durable destination; finish that rename before using it.
                guard (try? relocate(message, from: entry)) != nil else { continue }
                found.append(message)
            }
        }
        // A repaired directory can also appear in a later pane listing
        // during this scan. One record id is still only one message.
        return Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Writes `message`'s record into its directory, creating it. Throws
    /// when the record is not durably on disk.
    func save(_ message: QueuedMessage) throws {
        do {
            let folder = try preparedDirectory(for: message)
            let data = try JSONEncoder().encode(message)
            try data.write(
                to: folder.appending(path: Self.recordName, directoryHint: .notDirectory),
                options: [.atomic, .completeFileProtection])
        } catch {
            Self.log.error("Queued Message save failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Hands a pending message to the Agent a launch started, preserving
    /// its id, order, prompt marker and attachment copies. Write the new
    /// identity atomically in the old directory first: a process ending
    /// before the atomic rename is recovered by `messages(on:)`.
    func rekey(
        _ message: QueuedMessage, to agent: QueuedMessage.AgentIdentity,
        from launchID: QueuedLaunch.ID
    ) throws -> QueuedMessage {
        var moved = message
        moved.agent = agent
        moved.originLaunchID = launchID
        let source = messageDirectory(for: message)
        let data = try JSONEncoder().encode(moved)
        try data.write(
            to: source.appending(path: Self.recordName, directoryHint: .notDirectory),
            options: [.atomic, .completeFileProtection])
        try relocate(moved, from: source)
        return moved
    }

    private func relocate(_ message: QueuedMessage, from source: URL) throws {
        let destination = messageDirectory(for: message)
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// Whether a pane still holds records, including ones that could not
    /// be read or whose interrupted rename could not finish. Handover must
    /// not remove the launch while any such record is left behind.
    func hasMessages(for id: ConsoleAgent.ID) -> Bool {
        let pane = hostDirectory(id.hostID)
            .appending(path: Self.digest(id.paneID), directoryHint: .isDirectory)
        let manager = FileManager.default
        guard manager.fileExists(atPath: pane.path) else { return false }
        guard let entries = try? manager.contentsOfDirectory(
            at: pane, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return true }
        return entries.contains {
            manager.fileExists(atPath: $0.appending(path: Self.recordName).path)
        }
    }

    /// Deletes `message`'s directory: its record and attachment copies.
    func remove(_ message: QueuedMessage) {
        try? FileManager.default.removeItem(at: messageDirectory(for: message))
    }

    /// Deletes a pending Composer's entire queue, including unreadable
    /// records and attachment preparation left without a record.
    func remove(agentID: ConsoleAgent.ID) {
        try? FileManager.default.removeItem(at: hostDirectory(agentID.hostID)
            .appending(path: Self.digest(agentID.paneID), directoryHint: .isDirectory))
    }

    /// Deletes every message of one Host, e.g. after its target changed.
    func remove(hostID: Host.ID) {
        try? FileManager.default.removeItem(at: hostDirectory(hostID))
    }

    /// Deletes every Host's messages but these.
    func retainOnly(_ hostIDs: Set<Host.ID>) {
        let manager = FileManager.default
        guard
            let hosts = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return }
        for host in hosts {
            if let id = UUID(uuidString: host.lastPathComponent), hostIDs.contains(id) { continue }
            try? manager.removeItem(at: host)
        }
    }

    /// Where `message`'s record and attachment copies live, created on demand.
    func preparedDirectory(for message: QueuedMessage) throws -> URL {
        let folder = messageDirectory(for: message)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = directory
        try? root.setResourceValues(values)
        return folder
    }

    /// The local copy of `attachment`, if it still has one on disk.
    func fileURL(of attachment: QueuedMessage.Attachment, in message: QueuedMessage) -> URL? {
        guard let name = attachment.localFileName else { return nil }
        let url = messageDirectory(for: message).appending(path: name, directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func messageDirectory(for message: QueuedMessage) -> URL {
        hostDirectory(message.hostID)
            .appending(path: Self.digest(message.agent.paneID), directoryHint: .isDirectory)
            .appending(path: message.id.uuidString, directoryHint: .isDirectory)
    }

    private func hostDirectory(_ hostID: Host.ID) -> URL {
        directory.appending(path: hostID.uuidString, directoryHint: .isDirectory)
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension QueuedMessage.Attachment {
    /// Prepares a Composer Tray source into `directory` exactly as staging
    /// would (`ImagePreparer`, `FilePreparer`), so the copy is the bytes the
    /// upload sends, protected and named at random.
    static func prepare(
        _ source: ComposerStagingStore.Source, into directory: URL
    ) async throws -> QueuedMessage.Attachment {
        switch source {
        case .photo(let selection):
            let image = try await ImagePreparer(directory: directory).prepare(selection)
            return QueuedMessage.Attachment(
                id: UUID(), kind: .image, fileName: nil,
                localFileName: image.fileURL.lastPathComponent,
                fileExtension: image.format.rawValue,
                pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight,
                byteCount: image.byteCount, hostPath: nil)
        case .file(let url):
            let file = try await FilePreparer(directory: directory).prepare(url)
            return QueuedMessage.Attachment(
                id: UUID(), kind: .file, fileName: url.lastPathComponent,
                localFileName: file.fileURL.lastPathComponent,
                fileExtension: file.fileExtension,
                pixelWidth: nil, pixelHeight: nil,
                byteCount: file.byteCount, hostPath: nil)
        }
    }

    /// Uploads the local copy at `fileURL` through the Host's stagers and
    /// returns its Host path.
    static func upload(
        _ attachment: QueuedMessage.Attachment, from fileURL: URL,
        stageImage: ImageStager, stageFile: FileStager
    ) async throws -> String {
        let reporter = AttachmentStageProgressReporter { _ in }
        switch attachment.kind {
        case .image:
            guard let format = PreparedImageFormat(rawValue: attachment.fileExtension),
                let width = attachment.pixelWidth, let height = attachment.pixelHeight
            else { throw AttachmentStagingError.invalidPreparedSource }
            let image = PreparedImage(
                fileURL: fileURL, format: format, pixelWidth: width, pixelHeight: height,
                byteCount: attachment.byteCount)
            return try await stageImage(image, reporter).path
        case .file:
            let file = PreparedFile(
                fileURL: fileURL, fileExtension: attachment.fileExtension,
                byteCount: attachment.byteCount)
            return try await stageFile(file, reporter).path
        }
    }
}
