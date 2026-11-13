import Foundation
import Synchronization
import Testing

@testable import Waycar

/// The on-device last-known inventory: what a cold launch may show, and what
/// it must refuse to show.
@Suite("Console inventory cache")
struct ConsoleInventoryCacheTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "console-inventory-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var entry: ConsoleInventoryCache.Entry {
        ConsoleInventoryCache.Entry(
            snapshot: .fixture(
                agents: [
                    .fixture(paneID: "w1:p1", status: .blocked, name: "reviewer"),
                    .fixture(paneID: "w2:p1", status: .working, workspaceID: "w2"),
                ],
                workspaces: [
                    .fixture(workspaceID: "w1", label: "Proj", repoName: "proj"),
                    .fixture(workspaceID: "w2", label: "Api"),
                ]),
            sidebarLayout: ConsoleInventoryCache.SidebarLayout(
                data: Data(#"{"v":1,"agent_panel_sort":"priority"}"#.utf8)),
            verifiedAt: Date(timeIntervalSince1970: 1_800_000_000.25))
    }

    @Test func aSavedEntryReadsBackForTheSameTarget() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let writer = ConsoleInventoryCache(directory: directory)
        writer.save(entry, for: host)
        writer.flush()

        // A new process has nothing pending: the answer is the file's.
        let reader = ConsoleInventoryCache(directory: directory)
        #expect(reader.load(for: host) == entry)

        var absentLayout = entry
        absentLayout.sidebarLayout = ConsoleInventoryCache.SidebarLayout(data: nil)
        writer.save(absentLayout, for: host)
        writer.flush()
        #expect(reader.load(for: host) == absentLayout)
    }

    @Test func aNewerEntryWinsOverTheOneStillQueued() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = ConsoleInventoryCache(directory: directory)
        var newer = entry
        newer.snapshot = .fixture(agents: [.fixture(paneID: "w1:p9")])
        cache.save(entry, for: host)
        cache.save(newer, for: host)
        #expect(cache.load(for: host) == newer)
        cache.flush()
        #expect(ConsoleInventoryCache(directory: directory).load(for: host) == newer)
    }

    @Test func corruptOrForeignVersionFilesAreDeletedNotShown() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = ConsoleInventoryCache(directory: directory)
        let url = cache.fileURL(for: host.id)

        cache.save(entry, for: host)
        cache.flush()
        try Data("{ not json".utf8).write(to: url)
        #expect(cache.load(for: host) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path()))

        cache.save(entry, for: host)
        cache.flush()
        var envelope = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        envelope["version"] = ConsoleInventoryCache.formatVersion + 1
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        #expect(cache.load(for: host) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path()))
    }

    @Test func aRetargetedHostCannotReadTheOldTargetsSnapshot() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = ConsoleInventoryCache(directory: directory)
        cache.save(entry, for: host)
        cache.flush()

        var renamed = host
        renamed.name = "Renamed"
        #expect(cache.load(for: renamed) == entry)

        var retargeted = host
        retargeted.sessionName = "other"
        #expect(cache.load(for: retargeted) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(for: host.id).path()))
        #expect(cache.load(for: host) == nil)
    }

    @Test func removalAndCatalogPruningDeleteFiles() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = Host.fixture()
        let removed = Host.fixture()
        let orphan = Host.fixture()
        let cache = ConsoleInventoryCache(directory: directory)
        for host in [kept, removed, orphan] { cache.save(entry, for: host) }
        cache.flush()

        cache.remove(removed.id)
        cache.retainOnly([kept.id, removed.id])
        cache.flush()

        #expect(cache.load(for: kept) == entry)
        #expect(cache.load(for: removed) == nil)
        #expect(cache.load(for: orphan) == nil)
        #expect(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path()))
                == ["\(kept.id.uuidString).json"])
    }

    @Test func anObsoleteWriterCannotConsumeAReplacementAfterRemoval() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blocksMigration = Mutex(true)
        let access = ConsoleInventoryCache.FileAccess(
            read: ConsoleInventoryCache.FileAccess.live.read,
            write: ConsoleInventoryCache.FileAccess.live.write,
            setProtection: { _, _ in
                let blocks = blocksMigration.withLock { flag in
                    defer { flag = false }
                    return flag
                }
                if blocks {
                    entered.signal()
                    release.wait()
                }
            })
        let cache = ConsoleInventoryCache(directory: directory, fileAccess: access)
        // Initial protection migration holds the serial disk queue ahead of W1, D and W2.
        #expect(entered.wait(timeout: .now() + 5) == .success)
        let host = Host.fixture()
        var replacement = entry
        replacement.snapshot = .fixture(agents: [.fixture(paneID: "w1:p9")])
        cache.save(entry, for: host)
        cache.remove(host.id, backend: .herdr)
        cache.save(replacement, for: host)
        release.signal()
        cache.flush()
        #expect(ConsoleInventoryCache(directory: directory).load(for: host) == replacement)
    }

    @Test func aRemovalCancelsAWriteStillQueued() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = ConsoleInventoryCache(directory: directory)
        cache.save(entry, for: host)
        cache.remove(host.id)
        cache.flush()
        #expect(cache.load(for: host) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(for: host.id).path()))
    }

    private var tmuxEntry: ConsoleInventoryCache.Entry {
        ConsoleInventoryCache.Entry(
            snapshot: .fixture(
                agents: [.fixture(paneID: "tmux:%1", workspaceID: "tmux:$1")],
                workspaces: [.fixture(workspaceID: "tmux:$1", label: "work")]),
            sidebarLayout: nil,
            verifiedAt: Date(timeIntervalSince1970: 1_800_000_100))
    }

    private func fileNames() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? [])
    }

    @Test func eachBackendRoundTripsThroughItsOwnFile() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let writer = ConsoleInventoryCache(directory: directory)
        writer.save(entry, for: host, backend: .herdr)
        writer.save(tmuxEntry, for: host, backend: .tmux)
        writer.flush()

        #expect(writer.fileURL(for: host.id, backend: .herdr)
            != writer.fileURL(for: host.id, backend: .tmux))
        let reader = ConsoleInventoryCache(directory: directory)
        #expect(reader.load(for: host, backend: .herdr) == entry)
        #expect(reader.load(for: host, backend: .tmux) == tmuxEntry)
        #expect(fileNames().count == 2)
    }

    /// herdr keeps the bare file name every older build wrote; tmux and
    /// herdr-core each get a suffix, so switching the herdr runtime ends one
    /// scope's cache without touching the other's.
    @Test func coreHasItsOwnSuffixAndNeverSharesAFileWithHerdrOrTmux() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = ConsoleInventoryCache(directory: directory)
        let id = host.id.uuidString
        #expect(cache.fileURL(for: host.id, backend: .herdr).lastPathComponent == "\(id).json")
        #expect(cache.fileURL(for: host.id, backend: .core).lastPathComponent == "\(id).core.json")
        #expect(cache.fileURL(for: host.id, backend: .tmux).lastPathComponent == "\(id).tmux.json")

        let coreEntry = ConsoleInventoryCache.Entry(
            snapshot: .fixture(
                agents: [.fixture(paneID: "hc:t7", workspaceID: "core:/srv")],
                workspaces: [.fixture(workspaceID: "core:/srv", label: "srv")]),
            sidebarLayout: nil,
            verifiedAt: Date(timeIntervalSince1970: 1_800_000_200))
        cache.save(entry, for: host, backend: .herdr)
        cache.save(coreEntry, for: host, backend: .core)
        cache.flush()

        let reader = ConsoleInventoryCache(directory: directory)
        #expect(reader.load(for: host, backend: .core) == coreEntry)
        #expect(reader.load(for: host, backend: .herdr) == entry)
        #expect(fileNames().count == 2)

        // Ending the core scope deletes its file and nothing else.
        cache.remove(host.id, backend: .core)
        cache.flush()
        #expect(reader.load(for: host, backend: .core) == nil)
        #expect(reader.load(for: host, backend: .herdr) == entry)
    }

    @Test func herdrOnlyReplacementUsesCachedCodexWithoutProbingAndFollowsPresenceUpdates() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let codex = CodexPresence(version: "0.167.1", path: "/home/u/.nvm/bin/codex")
        var presence = HostBackendPresence(herdr: true, tmuxVersion: nil, codex: codex)
        let cache = ConsoleInventoryCache(directory: directory)
        cache.savePresence(.init(presence: presence, verifiedAt: Date()), for: host)
        cache.flush()
        // A replacement herdr-only connection skips fresh backend detection.
        let replacement = ConsoleInventoryCache(directory: directory).connectionMemory(for: host)
        let probes = Mutex(0)
        let params = try await WaycarSSHTransport.agentStartParams(
            .init(kind: "codex", name: "c"), paneID: "pane", codexSupportsNoDaemon: {
                await AgentLaunchBuilder.codexSupportsNoDaemon(presence: replacement.codexPresence) {
                    probes.withLock { $0 += 1 }
                    return false // bare SSH cannot find this nvm installation
                }
            })
        #expect(params.args == ["--no-daemon"])
        #expect(probes.withLock { $0 } == 0)
        var running = codex
        running.socketPath = "/tmp/codex.sock"
        presence.codex = running
        cache.savePresence(.init(presence: presence, verifiedAt: Date()), for: host)
        cache.flush()
        #expect(replacement.codexPresence == running)
        presence.codex = codex
        cache.savePresence(.init(presence: presence, verifiedAt: Date()), for: host)
        cache.flush()
        #expect(replacement.codexPresence == codex)
        presence.codex = nil
        cache.savePresence(.init(presence: presence, verifiedAt: Date()), for: host)
        cache.flush()
        #expect(replacement.codexPresence == nil)
        var retargeted = host
        retargeted.address = "elsewhere.example"
        presence.codex = running
        cache.savePresence(.init(presence: presence, verifiedAt: Date()), for: retargeted)
        cache.flush()
        #expect(replacement.codexPresence == nil)
        #expect(cache.loadPresence(for: retargeted)?.presence.codex == running)
    }

    @Test func presenceRoundTripsAndIsDiscardedWhenTheTargetChanges() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let record = ConsoleInventoryCache.PresenceRecord(
            presence: HostBackendPresence(herdr: true, tmuxVersion: "3.4"),
            verifiedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let cache = ConsoleInventoryCache(directory: directory)
        cache.savePresence(record, for: host)
        cache.flush()

        #expect(ConsoleInventoryCache(directory: directory).loadPresence(for: host) == record)

        var retargeted = host
        retargeted.address = "elsewhere.example"
        #expect(cache.loadPresence(for: retargeted) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.presenceFileURL(for: host.id).path()))
        #expect(cache.loadPresence(for: host) == nil)
    }

    /// The Agent kinds New Agent offers before the Host answers: kept per
    /// connection target, across processes, and forgotten with the Host.
    @Test func agentKindsRoundTripAndAreDiscardedWhenTheTargetChanges() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let kinds = CachedAgentKinds(
            kinds: [.claude, .codex], verifiedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let cache = ConsoleInventoryCache(directory: directory)
        cache.saveAgentKinds(kinds, for: host)
        cache.flush()

        #expect(
            cache.agentKindsFileURL(for: host.id).lastPathComponent
                == "\(host.id.uuidString).agents.json")
        #expect(ConsoleInventoryCache(directory: directory).loadAgentKinds(for: host) == kinds)

        var retargeted = host
        retargeted.username = "someone-else"
        #expect(cache.loadAgentKinds(for: retargeted) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.agentKindsFileURL(for: host.id).path()))
        #expect(cache.loadAgentKinds(for: host) == nil)

        cache.saveAgentKinds(kinds, for: host)
        cache.remove(host.id)
        cache.flush()
        #expect(cache.loadAgentKinds(for: host) == nil)
        #expect(fileNames().isEmpty)
    }

    /// A presence file written before detection times were kept still
    /// reads, as stale (#105).
    @Test func aPresenceFileWithoutADetectionTimeReadsWithNone() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = ConsoleInventoryCache(directory: directory)
        cache.savePresence(
            .init(presence: .herdrOnly, verifiedAt: Date(timeIntervalSince1970: 1)), for: host)
        cache.flush()
        let url = cache.presenceFileURL(for: host.id)
        var envelope = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        envelope["verifiedAt"] = nil
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)

        #expect(cache.loadPresence(for: host) == .init(presence: .herdrOnly, verifiedAt: nil))
    }

    /// What a Host's connections proved (#105): kept per connection target,
    /// across processes, and forgotten with the Host.
    @Test func connectionFactsRoundTripPerTargetAndLeaveWithTheHost() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let writer = ConsoleInventoryCache(directory: directory)
        let memory = writer.connectionMemory(for: host)
        #expect(memory.homeDirectory == nil)
        #expect(memory.protocolVersion == nil)
        memory.rememberHomeDirectory("/home/dev")
        memory.rememberProtocolVersion(22)
        writer.flush()

        let reader = ConsoleInventoryCache(directory: directory)
        #expect(reader.connectionMemory(for: host).homeDirectory == "/home/dev")
        #expect(reader.connectionMemory(for: host).protocolVersion == 22)

        var retargeted = host
        retargeted.port = 2222
        #expect(reader.connectionMemory(for: retargeted).homeDirectory == nil)
        // A nil forgets the one fact and keeps the other.
        reader.connectionMemory(for: host).rememberHomeDirectory(nil)
        reader.flush()
        let third = ConsoleInventoryCache(directory: directory)
        #expect(third.connectionMemory(for: host).homeDirectory == nil)
        #expect(third.connectionMemory(for: host).protocolVersion == 22)

        third.remove(host.id)
        third.flush()
        #expect(third.connectionMemory(for: host).protocolVersion == nil)
        #expect(!FileManager.default.fileExists(
            atPath: third.connectionFileURL(for: host.id).path()))
    }

    @Test func removingTmuxDeletesOnlyTheTmuxFile() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = ConsoleInventoryCache(directory: directory)
        cache.save(entry, for: host, backend: .herdr)
        cache.save(tmuxEntry, for: host, backend: .tmux)
        cache.savePresence(.init(presence: .herdrOnly, verifiedAt: nil), for: host)
        cache.flush()

        cache.remove(host.id, backend: .tmux)
        cache.flush()

        #expect(cache.load(for: host, backend: .tmux) == nil)
        #expect(cache.load(for: host, backend: .herdr) == entry)
        #expect(cache.loadPresence(for: host) != nil)
        #expect(!FileManager.default.fileExists(
            atPath: cache.fileURL(for: host.id, backend: .tmux).path()))
    }

    @Test func retainOnlyKeepsEveryKindOfFileForKeptHostsAndNoneForOthers() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = Host.fixture()
        let dropped = Host.fixture()
        let presence = ConsoleInventoryCache.PresenceRecord(
            presence: HostBackendPresence(herdr: true, tmuxVersion: "3.4"), verifiedAt: nil)
        let cache = ConsoleInventoryCache(directory: directory)
        let kinds = CachedAgentKinds(kinds: [.claude], verifiedAt: Date(timeIntervalSince1970: 1))
        for host in [kept, dropped] {
            cache.save(entry, for: host, backend: .herdr)
            cache.save(tmuxEntry, for: host, backend: .tmux)
            cache.savePresence(presence, for: host)
            cache.connectionMemory(for: host).rememberProtocolVersion(22)
            cache.saveAgentKinds(kinds, for: host)
        }
        cache.flush()

        cache.retainOnly([kept.id])
        cache.flush()

        #expect(fileNames() == [
            cache.fileURL(for: kept.id, backend: .herdr).lastPathComponent,
            cache.fileURL(for: kept.id, backend: .tmux).lastPathComponent,
            cache.presenceFileURL(for: kept.id).lastPathComponent,
            cache.connectionFileURL(for: kept.id).lastPathComponent,
            cache.agentKindsFileURL(for: kept.id).lastPathComponent,
        ])
        #expect(cache.loadAgentKinds(for: kept) == kinds)
        #expect(cache.loadAgentKinds(for: dropped) == nil)
        #expect(cache.load(for: kept, backend: .tmux) == tmuxEntry)
        #expect(cache.loadPresence(for: kept) == presence)
        #expect(cache.load(for: dropped, backend: .herdr) == nil)
        #expect(cache.load(for: dropped, backend: .tmux) == nil)
        #expect(cache.loadPresence(for: dropped) == nil)
        #expect(cache.connectionMemory(for: dropped).protocolVersion == nil)
        #expect(cache.connectionMemory(for: kept).protocolVersion == 22)
    }

    /// Presence and connection files must be readable while the phone is
    /// locked (CarPlay dials then); existing installs are migrated.
    @Test func migrationMovesOnlyPresenceAndConnectionFilesAndRetriesAfterAFailure() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let names = ["\(id).json", "\(id).tmux.json", "\(id).backends.json", "\(id).connection.json"]
        for name in names {
            try Data("{}".utf8).write(to: directory.appending(path: name))
        }
        let fake = FakeFileAccess()
        fake.failProtection.withLock { $0 = true }
        let cache = ConsoleInventoryCache(directory: directory, fileAccess: fake.access)
        cache.flush()
        #expect(fake.protectionCalls.withLock { $0.count } == 3)

        fake.failProtection.withLock { $0 = false }
        fake.protectionCalls.withLock { $0 = [] }
        cache.savePresence(.init(presence: .herdrOnly, verifiedAt: nil), for: Host.fixture())
        cache.flush()
        let calls = fake.protectionCalls.withLock { $0 }
        #expect(calls.allSatisfy { $0.protection == .completeUntilFirstUserAuthentication })
        #expect(Set(calls.map { $0.url.lastPathComponent }) == [
            directory.lastPathComponent, "\(id).backends.json", "\(id).connection.json",
        ])

        // Succeeded once: later writes do not migrate again.
        fake.protectionCalls.withLock { $0 = [] }
        cache.savePresence(.init(presence: .herdrOnly, verifiedAt: nil), for: Host.fixture())
        cache.flush()
        #expect(fake.protectionCalls.withLock { $0.isEmpty })
    }

    @Test func presenceAndConnectionWritesAreReadableAfterFirstUnlockInventoryIsNot() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let fake = FakeFileAccess()
        let cache = ConsoleInventoryCache(directory: directory, fileAccess: fake.access)
        cache.savePresence(.init(presence: .herdrOnly, verifiedAt: nil), for: host)
        cache.connectionMemory(for: host).rememberProtocolVersion(22)
        cache.save(entry, for: host)
        cache.flush()

        let writes = fake.writes.withLock { $0 }
        func options(_ url: URL) -> Data.WritingOptions? {
            writes.last { $0.url == url }?.options
        }
        let untilFirstAuth = Data.WritingOptions.completeFileProtectionUntilFirstUserAuthentication
        #expect(options(cache.presenceFileURL(for: host.id))?.contains(untilFirstAuth) == true)
        #expect(options(cache.connectionFileURL(for: host.id))?.contains(untilFirstAuth) == true)
        #expect(options(cache.fileURL(for: host.id))?.contains(.completeFileProtection) == true)
    }

    /// A locked connection file is not a missing one: its facts must not be
    /// cached empty, deleted, or written over with a partial update.
    @Test func anUnreadableConnectionFileIsNeitherCachedEmptyNorClobbered() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let writer = ConsoleInventoryCache(directory: directory)
        writer.connectionMemory(for: host).rememberHomeDirectory("/home/dev")
        writer.connectionMemory(for: host).rememberProtocolVersion(22)
        writer.flush()
        let url = writer.connectionFileURL(for: host.id)
        let original = try Data(contentsOf: url)

        let fake = FakeFileAccess()
        fake.unreadable.withLock { $0 = [url] }
        let cache = ConsoleInventoryCache(directory: directory, fileAccess: fake.access)
        let memory = cache.connectionMemory(for: host)
        #expect(memory.homeDirectory == nil)
        #expect(memory.protocolVersion == nil)
        memory.rememberHomeDirectory("/home/other")
        cache.flush()
        #expect(try Data(contentsOf: url) == original)

        fake.unreadable.withLock { $0 = [] }
        #expect(memory.homeDirectory == "/home/dev")
        #expect(memory.protocolVersion == 22)
    }

    @Test func anUnreadablePresenceOrInventoryFileIsKept() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let writer = ConsoleInventoryCache(directory: directory)
        let record = ConsoleInventoryCache.PresenceRecord(presence: .herdrOnly, verifiedAt: nil)
        writer.savePresence(record, for: host)
        writer.save(entry, for: host)
        writer.flush()

        let fake = FakeFileAccess()
        fake.unreadable.withLock {
            $0 = [writer.presenceFileURL(for: host.id), writer.fileURL(for: host.id)]
        }
        let cache = ConsoleInventoryCache(directory: directory, fileAccess: fake.access)
        #expect(cache.loadPresence(for: host) == nil)
        #expect(cache.load(for: host) == nil)
        cache.flush()

        fake.unreadable.withLock { $0 = [] }
        #expect(cache.loadPresence(for: host) == record)
        #expect(cache.load(for: host) == entry)
    }
}

/// Data protection as a device enforces it, which the simulator does not:
/// chosen files read as locked, and protection changes and write options
/// are recorded. Reads and writes otherwise reach the disk.
private final class FakeFileAccess: Sendable {
    struct ProtectionCall: Sendable {
        let protection: FileProtectionType
        let url: URL
    }

    struct Write: Sendable {
        let url: URL
        let options: Data.WritingOptions
    }

    let unreadable = Mutex<Set<URL>>([])
    let failProtection = Mutex(false)
    let protectionCalls = Mutex<[ProtectionCall]>([])
    let writes = Mutex<[Write]>([])

    var access: ConsoleInventoryCache.FileAccess {
        ConsoleInventoryCache.FileAccess(
            read: { [self] url in
                if unreadable.withLock({ $0.contains(url) }) { return .unreadable }
                return ConsoleInventoryCache.FileAccess.live.read(url)
            },
            write: { [self] data, url, options in
                writes.withLock { $0.append(Write(url: url, options: options)) }
                try data.write(to: url, options: .atomic)
            },
            setProtection: { [self] protection, url in
                protectionCalls.withLock { $0.append(ProtectionCall(protection: protection, url: url)) }
                if failProtection.withLock({ $0 }) {
                    throw CocoaError(.fileWriteNoPermission)
                }
            })
    }
}
