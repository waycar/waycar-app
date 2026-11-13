import Foundation
import OSLog
import Synchronization

/// Each Host's last-known Agent Inventory and sidebar layout, kept on this
/// device so a cold launch shows the Console before any Host has answered.
///
/// One file per Host and backend under Application Support (herdr's keeps
/// the `<host>.json` name it always had, tmux's is `<host>.tmux.json`), plus
/// the Host's last detected `HostBackendPresence` and when it was detected
/// (`<host>.backends.json`), so a cold launch starts the projections the Host
/// had, what its connections proved (`<host>.connection.json`: `$HOME`
/// and herdr's protocol version, #105), and the Agent kinds its last
/// detection found (`<host>.agents.json`), so New Agent offers them before
/// the Host answers. Excluded from backups. Inventory
/// files are written with complete file protection: unreadable while the
/// device is locked, in which case the Console simply starts empty. The
/// presence, connection and Agent kinds files, and the directory, are
/// protected only until first unlock: they hold no secrets, and CarPlay
/// must dial a Host while the phone is locked. Installs whose files predate that are migrated
/// once per process (`migrateProtection`). A file that exists but cannot be
/// read (locked) is never deleted nor mistaken for a missing one. The raw
/// `session.snapshot` is
/// stored rather than the projected rows, so a cached Host is projected by
/// exactly the code a live one is. Terminal screen text (including the
/// Console card snippet) is never stored here; the picture of each Agent's
/// last frame is `AgentLastFrameStore`'s.
///
/// A file names the connection target it was taken from; one written for a
/// different target, another format version, another backend, or bytes that
/// no longer decode is deleted on read instead of shown.
final class ConsoleInventoryCache: Sendable {
    /// The connection coordinates a snapshot belongs to. Editing any of them
    /// can point the Host at a different herdr, whose panes the old snapshot
    /// knows nothing about.
    struct Target: Codable, Equatable, Sendable {
        let address: String
        let port: Int
        let username: String
        let sessionName: String
        let jumpAddress: String
        let jumpPort: Int
        let jumpUsername: String

        init(_ host: Host) {
            address = host.address
            port = host.port
            username = host.username
            sessionName = host.sessionName
            jumpAddress = host.usesJumpHost ? host.jumpAddress : ""
            jumpPort = host.usesJumpHost ? host.jumpPort : 0
            jumpUsername = host.usesJumpHost ? host.resolvedJumpUsername : ""
        }
    }

    /// The plugin's sidebar layout file as last read. `data` is nil when the
    /// Host has no such file, which is itself a layout answer.
    struct SidebarLayout: Codable, Equatable, Sendable {
        let data: Data?
    }

    struct Entry: Equatable, Sendable {
        var snapshot: SessionSnapshot
        var sidebarLayout: SidebarLayout?
        /// When `snapshot` was taken live: the last time its Agents were
        /// seen running, which a Closed Session captured from them carries.
        /// Nil for a file written before this was kept.
        var verifiedAt: Date? = nil
    }

    private struct Envelope: Codable {
        let version: Int
        let hostID: UUID
        let target: Target
        let snapshot: SessionSnapshot
        let sidebarLayout: SidebarLayout?
        let verifiedAt: Date?
        /// Nil in herdr files, as in every file written before tmux support.
        let backend: HostBackend?
    }

    private struct PresenceEnvelope: Codable {
        let version: Int
        let hostID: UUID
        let target: Target
        let presence: HostBackendPresence
        /// Nil in files written before detection times were kept.
        let verifiedAt: Date?
    }

    /// The Host's last detected backends and when that detection answered.
    struct PresenceRecord: Equatable, Sendable {
        let presence: HostBackendPresence
        /// Nil when unknown, which reads as stale.
        let verifiedAt: Date?
    }

    /// What the Host's connections proved (#105, C-CACHE); see
    /// `HostConnectionMemory`.
    struct ConnectionFacts: Codable, Equatable, Sendable {
        var homeDirectory: String?
        var protocolVersion: Int?
        /// The login PATH herdr-core's lines export (`CoreLoginPath`); a
        /// file written before herdr-core reads without it.
        var loginPATH: String?
    }

    private struct ConnectionEnvelope: Codable {
        let version: Int
        let hostID: UUID
        let target: Target
        let facts: ConnectionFacts
    }

    private struct AgentKindsEnvelope: Codable {
        let version: Int
        let hostID: UUID
        let target: Target
        let agentKinds: CachedAgentKinds
    }

    /// One Host's `HostConnectionMemory`, bound to the connection target it
    /// was made for: facts kept for any other target read as unknown, and
    /// writes for a target the Host no longer has are dropped.
    struct ConnectionMemory: HostConnectionMemory {
        let cache: ConsoleInventoryCache
        let hostID: Host.ID
        let target: Target
        let token: UInt64

        var homeDirectory: String? {
            cache.connectionFacts(hostID: hostID, target: target, token: token).homeDirectory
        }

        func rememberHomeDirectory(_ home: String?) {
            cache.updateConnectionFacts(hostID: hostID, target: target, token: token) {
                $0.homeDirectory = home
            }
        }

        var protocolVersion: Int? {
            cache.connectionFacts(hostID: hostID, target: target, token: token).protocolVersion
        }

        func rememberProtocolVersion(_ version: Int?) {
            cache.updateConnectionFacts(hostID: hostID, target: target, token: token) {
                $0.protocolVersion = version
            }
        }

        var codexPresence: CodexPresence? {
            cache.loadPresence(hostID: hostID, target: target, discardingInvalidRecords: false)?.presence.codex
        }

        var opencodePresence: OpenCodePresence? {
            cache.loadPresence(hostID: hostID, target: target, discardingInvalidRecords: false)?.presence.opencode
        }

        var loginPATH: String? {
            cache.connectionFacts(hostID: hostID, target: target, token: token).loginPATH
        }

        func rememberLoginPATH(_ path: String?) {
            cache.updateConnectionFacts(hostID: hostID, target: target, token: token) {
                $0.loginPATH = path
            }
        }
    }

    private struct PendingWrite: Sendable {
        let ownerID: UUID
        let target: Target
        let entry: Entry
    }

    /// What reading a cache file found. `unreadable` is a file that exists
    /// but could not be read, typically its protection class while locked.
    enum ReadResult: Sendable {
        case data(Data)
        case missing
        case unreadable
    }

    /// The file operations whose outcome depends on data protection, which
    /// the simulator does not enforce; tests inject a fake.
    struct FileAccess: Sendable {
        var read: @Sendable (URL) -> ReadResult
        var write: @Sendable (Data, URL, Data.WritingOptions) throws -> Void
        var setProtection: @Sendable (FileProtectionType, URL) throws -> Void

        static let live = FileAccess(
            read: { url in
                do {
                    return .data(try Data(contentsOf: url))
                } catch {
                    return isMissingFile(error) ? .missing : .unreadable
                }
            },
            write: { data, url, options in try data.write(to: url, options: options) },
            setProtection: { protection, url in
                try FileManager.default.setAttributes(
                    [.protectionKey: protection], ofItemAtPath: url.path(percentEncoded: false))
            })

        private static func isMissingFile(_ error: any Error) -> Bool {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
                nsError.code == CocoaError.fileReadNoSuchFile.rawValue
                    || nsError.code == CocoaError.fileNoSuchFile.rawValue
            {
                return true
            }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) { return true }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)
            }
            return false
        }
    }

    static let formatVersion = 1
    /// Presence and connection files: readable after first unlock.
    private static let lockedReadableWrite: Data.WritingOptions = [
        .atomic, .completeFileProtectionUntilFirstUserAuthentication,
    ]

    let directory: URL
    private let fileAccess: FileAccess
    private let queue = DispatchQueue(label: "com.otreva.waycar.console-inventory-cache")
    private let pending = Mutex<[ConsoleScope: PendingWrite]>([:])
    /// Connection facts as last read or written, so the SSH layer asks
    /// memory, not the disk, on every connection.
    private let connectionFacts = Mutex<[Host.ID: ConnectionMemoryMachine]>([:])
    private let preparedDirectory = Mutex(false)
    /// Whether `migrateProtection` has succeeded in this process.
    private let migratedProtection = Mutex(false)
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "ConsoleInventoryCache")

    convenience init(directory: URL) {
        self.init(directory: directory, fileAccess: .live)
    }

    init(directory: URL, fileAccess: FileAccess) {
        self.directory = directory
        self.fileAccess = fileAccess
        queue.async { [self] in migrateProtection() }
    }

    /// The production location, or nil when Application Support cannot be
    /// resolved — the Console then runs without a cache.
    static func applicationSupport() -> ConsoleInventoryCache? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        else { return nil }
        return ConsoleInventoryCache(
            directory: base.appending(path: "ConsoleInventory", directoryHint: .isDirectory))
    }

    /// The Host backend's cached entry, or nil when there is none it can
    /// use. A write still waiting for the disk is newer than the file, so it
    /// answers first.
    func load(for host: Host, backend: HostBackend = .herdr) -> Entry? {
        let target = Target(host)
        let scope = ConsoleScope(hostID: host.id, backend: backend)
        if let write = pending.withLock({ $0[scope] }) {
            return write.target == target ? write.entry : nil
        }
        return queue.sync { read(scope: scope, target: target) }
    }

    /// Coalesced: while a write for the Host backend is queued, a newer
    /// entry replaces it instead of queueing another. Encoding and I/O stay
    /// off the caller.
    func save(_ entry: Entry, for host: Host, backend: HostBackend = .herdr) {
        let target = Target(host)
        let scope = ConsoleScope(hostID: host.id, backend: backend)
        let ownerID = pending.withLock { pending -> UUID? in
            let queuedOwner = pending[scope]?.ownerID
            let ownerID = queuedOwner ?? UUID()
            pending[scope] = PendingWrite(ownerID: ownerID, target: target, entry: entry)
            return queuedOwner == nil ? ownerID : nil
        }
        guard let ownerID else { return }
        queue.async { [self] in
            // A removal may have invalidated this writer and queued another.
            let write = pending.withLock { pending -> PendingWrite? in
                guard pending[scope]?.ownerID == ownerID else { return nil }
                return pending.removeValue(forKey: scope)
            }
            guard let write else { return }
            persist(write, scope: scope)
        }
    }

    /// Forgets everything kept for the Host: every backend's inventory, its
    /// presence, and its connection facts.
    func remove(_ hostID: Host.ID) {
        for backend in HostBackend.allCases {
            remove(hostID, backend: backend)
        }
        connectionFacts.withLock { machines in
            _ = machines[hostID]?.handle(.invalidate)
        }
        let urls = [
            presenceFileURL(for: hostID), connectionFileURL(for: hostID),
            agentKindsFileURL(for: hostID),
        ]
        queue.async {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Forgets one backend's inventory: its projection ended because the
    /// backend is gone or hidden.
    func remove(_ hostID: Host.ID, backend: HostBackend) {
        let scope = ConsoleScope(hostID: hostID, backend: backend)
        pending.withLock { _ = $0.removeValue(forKey: scope) }
        let url = fileURL(for: hostID, backend: backend)
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The Host's last detected backends, or nil when none was kept for its
    /// current connection target.
    func loadPresence(for host: Host) -> PresenceRecord? {
        loadPresence(hostID: host.id, target: Target(host))
    }

    private func loadPresence(
        hostID: Host.ID, target: Target, discardingInvalidRecords: Bool = true
    ) -> PresenceRecord? {
        let url = presenceFileURL(for: hostID)
        return queue.sync {
            let data: Data
            switch fileAccess.read(url) {
            case .data(let read): data = read
            // A locked file is kept: it is still the Host's answer once unlocked.
            case .missing, .unreadable: return nil
            }
            guard
                let envelope = try? JSONDecoder().decode(PresenceEnvelope.self, from: data),
                envelope.version == Self.formatVersion,
                envelope.hostID == hostID,
                envelope.target == target
            else {
                // A memory retained by an old connection must not delete the
                // presence a newer target has since saved for this Host.
                if discardingInvalidRecords { try? FileManager.default.removeItem(at: url) }
                return nil
            }
            return PresenceRecord(presence: envelope.presence, verifiedAt: envelope.verifiedAt)
        }
    }

    func savePresence(_ record: PresenceRecord, for host: Host) {
        let envelope = PresenceEnvelope(
            version: Self.formatVersion, hostID: host.id, target: Target(host),
            presence: record.presence, verifiedAt: record.verifiedAt)
        let url = presenceFileURL(for: host.id)
        queue.async { [self] in
            do {
                try prepareDirectory()
                migrateProtection()
                let data = try JSONEncoder().encode(envelope)
                try fileAccess.write(data, url, Self.lockedReadableWrite)
            } catch {
                Self.log.debug("Backend presence write skipped: \(error.localizedDescription)")
            }
        }
    }

    /// The Agent kinds the Host's last detection found, or nil when none
    /// were kept for its current connection target.
    func loadAgentKinds(for host: Host) -> CachedAgentKinds? {
        let url = agentKindsFileURL(for: host.id)
        let target = Target(host)
        let hostID = host.id
        return queue.sync {
            let data: Data
            switch fileAccess.read(url) {
            case .data(let read): data = read
            // A locked file is kept: it is still the Host's answer once unlocked.
            case .missing, .unreadable: return nil
            }
            guard
                let envelope = try? JSONDecoder().decode(AgentKindsEnvelope.self, from: data),
                envelope.version == Self.formatVersion,
                envelope.hostID == hostID,
                envelope.target == target
            else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return envelope.agentKinds
        }
    }

    func saveAgentKinds(_ agentKinds: CachedAgentKinds, for host: Host) {
        let envelope = AgentKindsEnvelope(
            version: Self.formatVersion, hostID: host.id, target: Target(host),
            agentKinds: agentKinds)
        let url = agentKindsFileURL(for: host.id)
        queue.async { [self] in
            do {
                try prepareDirectory()
                migrateProtection()
                let data = try JSONEncoder().encode(envelope)
                try fileAccess.write(data, url, Self.lockedReadableWrite)
            } catch {
                Self.log.debug("Agent kinds write skipped: \(error.localizedDescription)")
            }
        }
    }

    /// Obtaining a memory claims the Host's current target. A retained memory
    /// from a prior target cannot take that claim back by writing late.
    func connectionMemory(for host: Host) -> ConnectionMemory {
        let target = Target(host)
        let token = connectionFacts.withLock { machines in
            _ = machines[host.id, default: ConnectionMemoryMachine()].handle(.claim(target))
            return machines[host.id]?.token ?? 0
        }
        return ConnectionMemory(cache: self, hostID: host.id, target: target, token: token)
    }

    private func connectionFacts(hostID: Host.ID, target: Target, token: UInt64) -> ConnectionFacts {
        loadConnectionFacts(hostID: hostID, target: target, token: token) ?? ConnectionFacts()
    }

    /// The loaded fast path takes only the mutex. An unreadable file is
    /// retried, never cached as empty or overwritten with a partial fact.
    private func loadConnectionFacts(hostID: Host.ID, target: Target, token: UInt64) -> ConnectionFacts? {
        guard let machine = connectionFacts.withLock({ $0[hostID] }),
            machine.claim?.token == token, machine.claim?.target == target
        else { return ConnectionFacts() }
        if let facts = machine.facts(for: token) { return facts }
        let url = connectionFileURL(for: hostID)
        return queue.sync { () -> ConnectionFacts? in
            let read = fileAccess.read(url)
            return connectionFacts.withLock { machines -> ConnectionFacts? in
                guard let current = machines[hostID], current.claim?.token == token else {
                    return ConnectionFacts()
                }
                // A concurrent update is newer than the disk read.
                if let facts = current.facts(for: token) { return facts }
                let facts: ConnectionFacts?
                switch read {
                case .unreadable: facts = nil
                case .missing: facts = ConnectionFacts()
                case .data(let data):
                    if let envelope = try? JSONDecoder().decode(ConnectionEnvelope.self, from: data),
                        envelope.version == Self.formatVersion, envelope.hostID == hostID, envelope.target == target
                    {
                        facts = envelope.facts
                    } else {
                        try? FileManager.default.removeItem(at: url)
                        facts = ConnectionFacts()
                    }
                }
                _ = machines[hostID]?.handle(.loaded(token, facts))
                return facts
            }
        }
    }

    private func updateConnectionFacts(
        hostID: Host.ID, target: Target, token: UInt64, _ update: (inout ConnectionFacts) -> Void
    ) {
        guard var facts = loadConnectionFacts(hostID: hostID, target: target, token: token) else {
            Self.log.debug("Connection facts update skipped: the kept file is unreadable")
            return
        }
        let before = facts
        update(&facts)
        guard facts != before else { return }
        connectionFacts.withLock { machines in
            for effect in machines[hostID]?.handle(.remember(token, facts)) ?? [] {
                switch effect {
                case .persist(let target, let facts):
                    let envelope = ConnectionEnvelope(
                        version: Self.formatVersion, hostID: hostID, target: target, facts: facts)
                    // Encoding and I/O stay off the caller.
                    queue.async { [self] in
                        do {
                            try prepareDirectory()
                            migrateProtection()
                            let data = try JSONEncoder().encode(envelope)
                            try fileAccess.write(data, connectionFileURL(for: hostID), Self.lockedReadableWrite)
                        } catch {
                            Self.log.debug("Connection facts write skipped: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    /// Deletes every Host's files but these, including Hosts removed from the
    /// catalog while this device was not running.
    func retainOnly(_ hostIDs: Set<Host.ID>) {
        pending.withLock { $0 = $0.filter { hostIDs.contains($0.key.hostID) } }
        connectionFacts.withLock { machines in
            for id in machines.keys where !hostIDs.contains(id) {
                _ = machines[id]?.handle(.invalidate)
            }
        }
        let directory = directory
        queue.async {
            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
            else { return }
            for file in files {
                // `<host>.json`, `<host>.tmux.json`, `<host>.backends.json`,
                // `<host>.connection.json`, `<host>.agents.json`.
                let stem = file.lastPathComponent.split(separator: ".").first.map(String.init)
                let id = stem.flatMap(UUID.init(uuidString:))
                if let id, hostIDs.contains(id) { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Waits for every write and removal queued so far.
    func flush() {
        queue.sync {}
    }

    func fileURL(for hostID: Host.ID, backend: HostBackend = .herdr) -> URL {
        let name =
            switch backend {
            case .herdr: "\(hostID.uuidString).json"
            case .core: "\(hostID.uuidString).core.json"
            case .tmux: "\(hostID.uuidString).tmux.json"
            case .zellij: "\(hostID.uuidString).zellij.json"
            case .ultimate: "\(hostID.uuidString).ultimate.json"
            case .codex: "\(hostID.uuidString).codex.json"
            case .opencode: "\(hostID.uuidString).opencode.json"
            }
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    func presenceFileURL(for hostID: Host.ID) -> URL {
        directory.appending(path: "\(hostID.uuidString).backends.json", directoryHint: .notDirectory)
    }

    func connectionFileURL(for hostID: Host.ID) -> URL {
        directory.appending(path: "\(hostID.uuidString).connection.json", directoryHint: .notDirectory)
    }

    func agentKindsFileURL(for hostID: Host.ID) -> URL {
        directory.appending(path: "\(hostID.uuidString).agents.json", directoryHint: .notDirectory)
    }

    private func read(scope: ConsoleScope, target: Target) -> Entry? {
        let url = fileURL(for: scope.hostID, backend: scope.backend)
        let data: Data
        switch fileAccess.read(url) {
        case .data(let read): data = read
        // Missing or locked both start empty; a locked file is kept.
        case .missing, .unreadable: return nil
        }
        guard
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.version == Self.formatVersion,
            envelope.hostID == scope.hostID,
            envelope.target == target,
            (envelope.backend ?? .herdr) == scope.backend
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Entry(
            snapshot: envelope.snapshot, sidebarLayout: envelope.sidebarLayout,
            verifiedAt: envelope.verifiedAt)
    }

    private func persist(_ write: PendingWrite, scope: ConsoleScope) {
        do {
            try prepareDirectory()
            migrateProtection()
            let envelope = Envelope(
                version: Self.formatVersion, hostID: scope.hostID, target: write.target,
                snapshot: write.entry.snapshot, sidebarLayout: write.entry.sidebarLayout,
                verifiedAt: write.entry.verifiedAt,
                backend: scope.backend == .herdr ? nil : scope.backend)
            let data = try JSONEncoder().encode(envelope)
            try fileAccess.write(
                data, fileURL(for: scope.hostID, backend: scope.backend),
                [.atomic, .completeFileProtection])
        } catch {
            // Expected while the device is locked; the next snapshot retries.
            Self.log.debug("Inventory cache write skipped: \(error.localizedDescription)")
        }
    }

    private func prepareDirectory() throws {
        guard !preparedDirectory.withLock({ $0 }) else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
        preparedDirectory.withLock { $0 = true }
    }

    /// Moves the directory and every presence and connection file written
    /// under complete protection to protection until first unlock. Writes
    /// happen only when facts change, so without this an existing install's
    /// files would stay unreadable while locked forever. Changing the class
    /// needs the old key, so it fails while locked; it is retried on the
    /// next write until it succeeds once. Inventory files are left alone.
    /// Runs on `queue`.
    private func migrateProtection() {
        guard !migratedProtection.withLock({ $0 }) else { return }
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            // Nothing to migrate; `prepareDirectory` creates it with the new class.
            migratedProtection.withLock { $0 = true }
            return
        }
        let protection = FileProtectionType.completeUntilFirstUserAuthentication
        var succeeded = true
        do {
            try fileAccess.setProtection(protection, directory)
        } catch {
            succeeded = false
            Self.log.debug("Cache directory protection migration failed: \(error.localizedDescription)")
        }
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".connection.json") || name.hasSuffix(".backends.json") else { continue }
            do {
                try fileAccess.setProtection(protection, file)
            } catch {
                succeeded = false
                Self.log.debug("Cache file protection migration failed: \(error.localizedDescription)")
            }
        }
        if succeeded { migratedProtection.withLock { $0 = true } }
    }
}

/// A Host's installed Agent kinds as its last successful detection found
/// them (`ConsoleStore.availableAgentKinds(on:)`), and when.
struct CachedAgentKinds: Codable, Equatable, Sendable {
    let kinds: [SupportedAgentKind]
    let verifiedAt: Date
}

extension ConsoleInventoryCache.Entry {
    /// Pane geometry is not part of the Console projection, so it is not kept.
    init(
        liveSnapshot snapshot: SessionSnapshot,
        sidebarLayout: ConsoleInventoryCache.SidebarLayout?,
        verifiedAt: Date?
    ) {
        self.init(
            snapshot: SessionSnapshot(
                agents: snapshot.agents, layouts: [], panes: snapshot.panes,
                protocolVersion: snapshot.protocolVersion, tabs: snapshot.tabs,
                version: snapshot.version, workspaces: snapshot.workspaces,
                focusedPaneID: snapshot.focusedPaneID, focusedTabID: snapshot.focusedTabID,
                focusedWorkspaceID: snapshot.focusedWorkspaceID),
            sidebarLayout: sidebarLayout,
            verifiedAt: verifiedAt)
    }
}
