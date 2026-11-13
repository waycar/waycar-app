import Foundation
import os

/// A New Agent launch as Start decided it (`StartAgentStore.submit()`):
/// everything `StartAgentStore.launch(_:)` needs, so a Queued Launch
/// (CONTEXT.md **Queued Launch**) replays what the user chose from a store
/// that never showed the form. What depends on the Host as it is at launch
/// is resolved then: a name-only New Workspace's directory (the Host's
/// home), the Chat Mode options. The name and worktree branch are pinned
/// before the first try, so every later try identifies the same launch.
struct LaunchDraft: Codable, Equatable, Sendable {
    /// The launched Agent's first message: what the user typed and the
    /// Composer Tray items, prepared into the launch's own directory
    /// (`QueuedLaunchStore.launchDirectory`) and not yet uploaded. It
    /// reaches the Agent as a Queued Message.
    struct FirstMessage: Codable, Equatable, Sendable {
        let text: String
        let attachments: [QueuedMessage.Attachment]
    }

    let id: UUID
    let hostID: Host.ID
    /// A New Workspace with an empty directory starts in the Host's home,
    /// resolved at launch. A queued draft names its backend, so its replay
    /// lands on the runtime the sheet showed.
    var dispatch: StartAgentStore.Dispatch
    /// The existing Workspace, or a Worktree's source; nil for a New
    /// Workspace.
    let workspaceID: String?
    /// The origin Agent's directory when the sheet opened from an Agent.
    let originCwd: String?
    /// The name as entered; nil falls back to the kind's default name (a
    /// shell's to herdr's tab label), resolved once into launchName.
    let name: String?
    /// A preset's suggested name the user left untouched: made unique at
    /// launch like the default.
    let suggestedName: String?
    /// The resolved name, pinned before the first try or when kept. Nil
    /// for an unnamed shell, which keeps the Host's default tab label.
    var launchName: String? = nil
    /// The typed or minted branch, pinned across stores and app launches.
    var worktreeBranch: String? = nil
    /// A kind's minted session id, reused by the command and Chat Marker
    /// when a later try recovers the Agent an earlier try started.
    var sessionPin: UUID? = nil
    /// The OpenCode 2 session id an opencode launch minted
    /// (`OpenCodeSessionID.mint()`): New Agent › OpenCode creates that
    /// session, a terminal launch opens `opencode --session <id>`. Pinned
    /// once, so every retry and replay names the same session.
    var opencodeSessionID: String? = nil
    let userArguments: [String]
    /// Whether an Agent of a Chat Mode kind starts in Chat Mode. Never for
    /// a preset.
    let chatMode: Bool
    /// A preset's first message (Help's Ask an Agent, the Keychain Fix).
    var presetFirstMessage: String?
    var firstMessage: FirstMessage?
    /// Whether a successful launch updates Last Used: not for a preset.
    let remembersLaunch: Bool
    /// New Chat's quick chat, whose Chat Mode is not the sheet's to keep.
    let isQuickChat: Bool
}

/// A New Agent Start waiting for its Host, or for a check after its answer
/// was lost (CONTEXT.md **Queued Launch**): where its replay stands, and
/// when the user pressed Start. Persisted per Host so it outlives the app;
/// it leaves the device once its Agent started, or the user deletes it.
/// `state`, `startedPaneID`, `joinedRunningAgent` and `mayHaveStarted` are
/// `QueuedLaunchMachine`'s state (`lifecycle`); the owner changes them only
/// through it.
struct QueuedLaunch: Codable, Sendable, Equatable, Identifiable {
    enum State: Codable, Sendable, Equatable {
        /// Waiting for its Host's verified connection.
        case waiting
        /// Its replay is under way. Saved before anything goes to the Host,
        /// so a record found in it when the app starts may have launched.
        case starting
        /// Legacy records only: restored as waiting with mayHaveStarted.
        case uncertain
        /// Its replay failed after it may have reached the Host; the message
        /// is user-facing. Only the user retries or deletes it.
        case failed(String)
    }

    var draft: LaunchDraft
    var state: State
    let createdAt: Date
    /// A successful start awaiting local message handover. Retry and restore
    /// finish the handover, never start that Agent a second time.
    var startedPaneID: String? = nil
    /// An adopted checkout already had an Agent: its queued messages must
    /// be held for Send Anyway, including after an interrupted handover.
    var joinedRunningAgent: Bool? = nil
    /// An earlier try may have reached the Host. The next verified
    /// connection checks the Launch Tag before starting anything missing.
    var mayHaveStarted: Bool? = nil

    var startedAgentID: ConsoleAgent.ID? {
        startedPaneID.map { ConsoleAgent.ID(hostID: hostID, paneID: $0) }
    }

    var id: UUID { draft.id }
    var hostID: Host.ID { draft.hostID }

    static func pendingAgentID(hostID: Host.ID, launchID: ID) -> ConsoleAgent.ID {
        ConsoleAgent.ID(hostID: hostID, paneID: "queued-launch:" + launchID.uuidString)
    }

    static func launchID(forPendingAgent id: ConsoleAgent.ID) -> ID? {
        let prefix = "queued-launch:"
        guard id.paneID.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(id.paneID.dropFirst(prefix.count)))
    }

    var pendingAgentID: ConsoleAgent.ID {
        Self.pendingAgentID(hostID: hostID, launchID: id)
    }

    /// A second stable message id, distinct from the launch id its typed
    /// First Message uses. Migration can repeat either write without duplicates.
    var presetMessageID: UUID {
        var uuid = id.uuid
        uuid.15 ^= 1
        return UUID(uuid: uuid)
    }

    var pendingIdentity: QueuedMessage.AgentIdentity? {
        guard case .agent(let kind) = draft.dispatch.launch else { return nil }
        return QueuedMessage.AgentIdentity(
            paneID: pendingAgentID.paneID, kind: kind.rawValue, session: nil)
    }
}

/// Queued Launches on this device, one directory per launch under
/// `<root>/<Host id>/<launch id>/`: `launch.json` and the first message's
/// attachment copies. A launch that starts at once prepares its copies in
/// the same place and removes them when it ends. Application Support, never
/// the temporary directory or Caches, so the system does not purge a launch
/// waiting for its Host; excluded from backup. Writes are synchronous and
/// atomic, as `QueuedMessageStore`'s: a launch must be on disk before the
/// sheet dismisses.
final class QueuedLaunchStore: Sendable {
    let directory: URL
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "QueuedLaunchStore")
    private static let recordName = "launch.json"

    init(directory: URL) {
        self.directory = directory
    }

    /// `<Application Support>/QueuedLaunches`, or nil when Application
    /// Support cannot be resolved.
    static func applicationSupport() -> QueuedLaunchStore? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        else { return nil }
        return QueuedLaunchStore(
            directory: base.appending(path: "QueuedLaunches", directoryHint: .isDirectory))
    }

    /// The Host's Queued Launches, oldest first. A directory with no record
    /// (copies a launch left when the app ended), or whose record does not
    /// decode or belongs to another Host, is deleted; one whose record
    /// cannot be read right now (protected data unavailable) is kept.
    func launches(on hostID: Host.ID) -> [QueuedLaunch] {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: hostDirectory(hostID), includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return [] }
        var found: [QueuedLaunch] = []
        let decoder = JSONDecoder()
        for entry in entries {
            let record = entry.appending(path: Self.recordName, directoryHint: .notDirectory)
            guard manager.fileExists(atPath: record.path) else {
                try? manager.removeItem(at: entry)
                continue
            }
            guard let data = try? Data(contentsOf: record) else { continue }
            guard let launch = try? decoder.decode(QueuedLaunch.self, from: data),
                launch.hostID == hostID
            else {
                try? manager.removeItem(at: entry)
                continue
            }
            found.append(launch)
        }
        return found.sorted { $0.createdAt < $1.createdAt }
    }

    /// Writes `launch`'s record into its directory, creating it. Throws when
    /// the record is not durably on disk.
    func save(_ launch: QueuedLaunch) throws {
        do {
            let folder = try preparedDirectory(hostID: launch.hostID, launchID: launch.id)
            let data = try JSONEncoder().encode(launch)
            try data.write(
                to: folder.appending(path: Self.recordName, directoryHint: .notDirectory),
                options: [.atomic, .completeFileProtection])
        } catch {
            Self.log.error("Queued Launch save failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Deletes `launch`'s directory: its record and attachment copies.
    func remove(_ launch: QueuedLaunch) {
        remove(hostID: launch.hostID, launchID: launch.id)
    }

    /// Deletes `launch`'s record only. Its attachment copies stay until the
    /// app next reads the Host's launches, which deletes a directory with
    /// no record.
    func removeRecord(_ launch: QueuedLaunch) {
        try? FileManager.default.removeItem(
            at: launchDirectory(hostID: launch.hostID, launchID: launch.id)
                .appending(path: Self.recordName, directoryHint: .notDirectory))
    }

    /// Deletes one launch's directory.
    func remove(hostID: Host.ID, launchID: UUID) {
        try? FileManager.default.removeItem(at: launchDirectory(hostID: hostID, launchID: launchID))
    }

    /// Deletes every launch of one Host, e.g. after its target changed.
    func remove(hostID: Host.ID) {
        try? FileManager.default.removeItem(at: hostDirectory(hostID))
    }

    /// Deletes every Host's launches but these.
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

    /// Where a launch's record and attachment copies live, created on demand.
    func preparedDirectory(hostID: Host.ID, launchID: UUID) throws -> URL {
        let folder = launchDirectory(hostID: hostID, launchID: launchID)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = directory
        try? root.setResourceValues(values)
        return folder
    }

    func launchDirectory(hostID: Host.ID, launchID: UUID) -> URL {
        hostDirectory(hostID).appending(path: launchID.uuidString, directoryHint: .isDirectory)
    }

    private func hostDirectory(_ hostID: Host.ID) -> URL {
        directory.appending(path: hostID.uuidString, directoryHint: .isDirectory)
    }
}
