import Foundation
import Synchronization
import MoshCore
import Testing
import UIKit

@testable import Waycar

/// The standbys an app holds ahead of its attaches (#105): single use,
/// young enough for their server to still wait, and never beside an attach's
/// own bootstrap for the same target.
@MainActor
@Suite("Standby mosh store", .timeLimit(.minutes(1)))
struct StandbyMoshStoreTests {
    private let key = StandbyMoshStore.Key(
        hostID: UUID(), backend: .herdr, target: .agentPane("w1:p1"))

    /// Counts the bootstraps a store asked for.
    private final class Bootstraps: Sendable {
        private let count = Mutex(0)
        var made: Int { count.withLock { $0 } }

        func make(_ bootstrap: MoshBootstrap) -> @Sendable () async throws -> MoshBootstrap {
            { [self] in
                count.withLock { $0 += 1 }
                return bootstrap
            }
        }
    }

    @Test func aStandbyIsTakenOnce() async throws {
        let store = StandbyMoshStore()
        await store.prepare(key, origin: .speculative) { MoshFlowFixture.standbyBootstrap }?.value

        #expect(await store.take(key)?.bootstrap == MoshFlowFixture.standbyBootstrap)
        #expect(await store.take(key) == nil, "a second attach must not reuse a used server")
    }

    /// An attach reports which kind of standby it started at (#105).
    @Test(arguments: [StandbyMosh.Origin.graceExpiry, .speculative])
    func aStandbyKeepsWhyItWasStarted(origin: StandbyMosh.Origin) async throws {
        let store = StandbyMoshStore()
        await store.prepare(key, origin: origin) { MoshFlowFixture.standbyBootstrap }?.value

        #expect(await store.take(key)?.origin == origin)
    }

    /// mosh-server waits 60 s for its first client; from 50 s on the attach
    /// would race the server's exit, so the standby no longer counts.
    @Test func aStandbyPastItsUsableAgeIsIgnored() async throws {
        let clock = StandbyClock()
        let store = StandbyMoshStore(now: { clock.now })
        await store.prepare(key, origin: .graceExpiry) { MoshFlowFixture.standbyBootstrap }?.value
        clock.advance(by: .seconds(49))
        #expect(store.standby(for: key) != nil)

        clock.advance(by: .seconds(1))
        #expect(store.standby(for: key) == nil)
        #expect(await store.take(key) == nil)
    }

    /// The two never run for one target together: no standby starts while an
    /// attach bootstraps it, and an attach arriving while a standby is being
    /// made waits for it and uses it instead of bootstrapping a second server.
    @Test func aStandbyAndAnAttachBootstrapNeverRunForTheSameTarget() async throws {
        let store = StandbyMoshStore()
        let bootstraps = Bootstraps()
        #expect(await store.claimAttachBootstrap(key) == nil)
        #expect(
            store.prepare(
                key, origin: .speculative,
                bootstrap: bootstraps.make(MoshFlowFixture.standbyBootstrap)) == nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(bootstraps.made == 0)

        store.finishAttachBootstrap(key)
        let gate = ScriptedTransportCallGate()
        store.prepare(key, origin: .speculative) {
            await gate.waitUntilOpen()
            return MoshFlowFixture.standbyBootstrap
        }
        let claim = Task { await store.claimAttachBootstrap(key) }
        await gate.waitForEntry()
        await gate.open()
        #expect(await claim.value?.bootstrap == MoshFlowFixture.standbyBootstrap)
        #expect(!store.hasAttachBootstrap(on: key.hostID), "the standby served: no attach bootstrap")
    }

    /// A bootstrap that overruns its budget leaves nothing behind, and the
    /// wait for it ends at the budget.
    @Test func aStandbyBootstrapPastItsBudgetLeavesNoStandby() async throws {
        let store = StandbyMoshStore()
        let started = ContinuousClock.now
        await store.prepare(key, origin: .graceExpiry, budget: .milliseconds(100)) {
            try await Task.sleep(for: .seconds(2))
            return MoshFlowFixture.standbyBootstrap
        }?.value
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(await store.take(key) == nil)
    }
}

/// What this device learned about each Host's mosh, per network (#105).
@MainActor
@Suite("Mosh availability memory", .timeLimit(.minutes(1)))
struct MoshAvailabilityStoreTests {
    private let home = ScriptedNetworkPathSource.home.key!
    private let cafe = ScriptedNetworkPathSource.cafe.key!

    @MainActor
    private final class Calendar {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    @Test func anOutcomeAnswersOnlyForItsNetworkAndOnlyForADay() {
        let calendar = Calendar()
        let store = MoshAvailabilityStore(now: { calendar.now })
        let host = Host.fixture()
        store.record(.unavailable, for: host, network: home)

        #expect(store.outcome(for: host, network: home) == .unavailable)
        #expect(store.outcome(for: host, network: cafe) == nil, "UDP blocked here says nothing there")
        #expect(store.outcome(for: host, network: nil) == nil)

        calendar.now = calendar.now.addingTimeInterval(24 * 3600 - 1)
        #expect(store.outcome(for: host, network: home) == .unavailable)
        calendar.now = calendar.now.addingTimeInterval(1)
        #expect(store.outcome(for: host, network: home) == nil)
    }

    /// A Host whose address changed since keeps nothing learned for the old
    /// one.
    @Test func anOutcomeLearnedForAnotherTargetDoesNotAnswer() {
        let store = MoshAvailabilityStore()
        let host = Host.fixture()
        store.record(.available, for: host, network: home)
        var moved = host
        moved.address = "elsewhere.example"
        #expect(store.outcome(for: moved, network: home) == nil)
    }

    /// Kept across launches, so a cold-restored Agent rides mosh from its
    /// first attach.
    @Test func outcomesSurviveARelaunch() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let host = Host.fixture()
        MoshAvailabilityStore(fileURL: file).record(.available, for: host, network: home)

        try await pollUntil("the next launch should read the outcome back") {
            MoshAvailabilityStore(fileURL: file).outcome(for: host, network: home) == .available
        }
    }

    /// A CarPlay launch with the phone locked cannot read the `.complete`
    /// file. What it learns meanwhile is kept in memory and nothing is
    /// written over the file; once unlocked both answer.
    @Test func aLockedFileIsNeitherReadAsEmptyNorOverwritten() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let host = Host.fixture()
        MoshAvailabilityStore(fileURL: file).record(.available, for: host, network: home)
        try await pollUntil("the outcome should be written") {
            Self.contents(of: file)?.contains("\"available\"") ?? false
        }

        let lock = DeviceLock()
        let store = MoshAvailabilityStore(
            fileURL: file,
            readFile: { url in
                lock.isLocked ? .unreadable : ConsoleInventoryCache.FileAccess.live.read(url)
            })
        #expect(store.outcome(for: host, network: home) == nil)
        store.record(.unavailable, for: host, network: cafe)
        try await Task.sleep(for: .milliseconds(50))
        #expect(Self.contents(of: file)?.contains("\"unavailable\"") == false,
            "nothing is written while the file is locked")

        lock.isLocked = false
        #expect(store.outcome(for: host, network: home) == .available)
        #expect(store.outcome(for: host, network: cafe) == .unavailable)
        try await pollUntil("both outcomes should be written once unlocked") {
            Self.contents(of: file).map {
                $0.contains("\"available\"") && $0.contains("\"unavailable\"")
            } ?? false
        }
    }

    /// Hosts dropped while the file is locked stay dropped: the load once
    /// unlocked does not bring back what the file holds for them.
    @Test func hostsDroppedWhileLockedStayDroppedOnceUnlocked() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let kept = Host.fixture()
        let removed = Host.fixture()
        let forgotten = Host.fixture()
        let writer = MoshAvailabilityStore(fileURL: file)
        for host in [kept, removed, forgotten] {
            writer.record(.available, for: host, network: home)
        }
        try await pollUntil("all three outcomes should be written") {
            Self.contents(of: file).map { contents in
                [kept, removed, forgotten].allSatisfy { contents.contains($0.id.uuidString) }
            } ?? false
        }

        let lock = DeviceLock()
        let store = MoshAvailabilityStore(
            fileURL: file,
            readFile: { url in
                lock.isLocked ? .unreadable : ConsoleInventoryCache.FileAccess.live.read(url)
            })
        store.retainOnly([kept, forgotten])
        store.forget(hostID: forgotten.id)

        lock.isLocked = false
        #expect(store.outcome(for: kept, network: home) == .available)
        #expect(store.outcome(for: removed, network: home) == nil)
        #expect(store.outcome(for: forgotten, network: home) == nil)
        try await pollUntil("the file should keep only the retained Host") {
            Self.contents(of: file).map {
                $0.contains(kept.id.uuidString) && !$0.contains(removed.id.uuidString)
                    && !$0.contains(forgotten.id.uuidString)
            } ?? false
        }
    }

    /// Per-Host network history stays on this device: its directory is
    /// left out of iCloud and Finder backups, which an atomic write of the
    /// file itself could not keep.
    @Test func theFileIsLeftOutOfBackups() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = MoshAvailabilityStore(fileURL: file)
        store.record(.available, for: Host.fixture(), network: home)
        try await pollUntil("the outcome should be written") {
            FileManager.default.fileExists(atPath: file.path())
        }
        store.record(.unavailable, for: Host.fixture(), network: cafe)
        try await Task.sleep(for: .milliseconds(50))
        let values = try file.deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// The production file lives in a directory of its own, not the
    /// Application Support root that backups take.
    @Test func theProductionFileHasADirectoryOfItsOwn() throws {
        let file = try #require(MoshAvailabilityStore.applicationSupportFile())
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        #expect(file.deletingLastPathComponent().standardizedFileURL != support.standardizedFileURL)
    }

    /// A removed or re-targeted Host's coordinates leave the device.
    @Test func aForgottenOrRetargetedHostLeavesNothingOnDisk() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let host = Host.fixture(address: "old-target.example")
        let other = Host.fixture(name: "other", address: "other.example")
        let store = MoshAvailabilityStore(fileURL: file)
        store.record(.available, for: host, network: home)
        store.record(.available, for: other, network: home)

        var moved = host
        moved.address = "new-target.example"
        store.retainOnly([moved, other])
        #expect(store.outcome(for: host, network: home) == nil)
        try await pollUntil("the old target should leave the file") {
            Self.contents(of: file).map { !$0.contains("old-target.example") && $0.contains("other.example") }
                ?? false
        }

        store.forget(hostID: other.id)
        #expect(store.outcome(for: other, network: home) == nil)
        try await pollUntil("the forgotten Host should leave the file") {
            Self.contents(of: file).map { !$0.contains("other.example") } ?? false
        }
    }

    /// What expired while the app was away is dropped as the file loads,
    /// not left on disk until the next outcome.
    @Test func expiredOutcomesAreDroppedOnLoad() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let calendar = Calendar()
        let host = Host.fixture(name: "expiring", address: "expiring.example")
        MoshAvailabilityStore(fileURL: file, now: { calendar.now })
            .record(.available, for: host, network: home)
        try await pollUntil("the outcome should be written") {
            Self.contents(of: file)?.contains("expiring.example") ?? false
        }

        calendar.now = calendar.now.addingTimeInterval(MoshAvailabilityStore.freshness + 1)
        _ = MoshAvailabilityStore(fileURL: file, now: { calendar.now })
        try await pollUntil("the expired outcome should leave the file") {
            Self.contents(of: file).map { !$0.contains("expiring.example") } ?? false
        }
    }

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "mosh-availability-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "MoshAvailability.json")
    }

    private static func contents(of file: URL) -> String? {
        (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// mosh-server paints a blank screen before the Agent's (#105): only text a
/// person would see counts as content.
@Suite("Terminal visible content", .timeLimit(.minutes(1)))
struct TerminalVisibleContentTests {
    /// What one scanner says of each read in turn.
    private func scan(_ reads: [String]) -> [Bool] {
        var scanner = TerminalVisibleContentScanner()
        return reads.map { scanner.containsVisibleContent(Data($0.utf8)) }
    }

    @Test func aBlankFirstFrameIsNotContent() {
        let blank = "\u{1B}[?1049h\u{1B}[?25l\u{1B}[H\u{1B}[2J\u{1B}]0;title\u{07}\u{1B}[0m  \r\n"
        #expect(scan([blank, "\u{1B}[1;1H$ ready"]) == [false, true])
    }

    /// A sequence split between two reads never passes for text.
    @Test func aSequenceSplitAcrossReadsIsNotContent() {
        #expect(
            scan(["\u{1B}[3", "1;42m", "\u{1B}]2;win", "dow\u{1B}\\", "x"])
                == [false, false, false, false, true])
    }
}

/// The grid each layout last had, kept across launches (#105).
@MainActor
@Suite("Terminal grid size memory", .timeLimit(.minutes(1)))
struct TerminalGridSizeMemoryTests {
    private static let portrait = TerminalGridSizeMemory.Layout(
        horizontalSizeClass: 1, verticalSizeClass: 2, width: 440, height: 956, fontSize: 13)
    private static let landscape = TerminalGridSizeMemory.Layout(
        horizontalSizeClass: 2, verticalSizeClass: 1, width: 956, height: 440, fontSize: 13)

    @Test func eachLayoutRemembersItsOwnGridAcrossLaunches() throws {
        let defaults = try #require(UserDefaults(suiteName: "grid-sizes-\(UUID().uuidString)"))
        let memory = TerminalGridSizeMemory(defaults: defaults)
        #expect(memory.size(for: Self.portrait) == nil)
        memory.record(cols: 54, rows: 60, for: Self.portrait)
        #expect(memory.size(for: Self.landscape) == nil, "a rotated window fits another grid")
        memory.record(cols: 120, rows: 26, for: Self.landscape)
        #expect(memory.size(for: nil) == nil, "no window, no remembered grid")

        let relaunched = TerminalGridSizeMemory(defaults: defaults)
        #expect(relaunched.size(for: Self.landscape) == .init(cols: 120, rows: 26))
        #expect(relaunched.size(for: Self.portrait) == .init(cols: 54, rows: 60))
        #expect(relaunched.lastRecordedSize == .init(cols: 120, rows: 26))
    }

    /// The layout is the window's own: two windows of different sizes key
    /// different grids.
    @Test func aWindowsLayoutIsItsOwn() {
        let narrow = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 1024))
        let wide = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 1024))
        let memory = TerminalGridSizeMemory(
            defaults: UserDefaults(suiteName: "grid-sizes-\(UUID().uuidString)") ?? .standard)
        memory.record(cols: 40, rows: 60, for: TerminalGridSizeMemory.layout(of: narrow))
        memory.record(cols: 90, rows: 60, for: TerminalGridSizeMemory.layout(of: wide))
        #expect(memory.size(for: TerminalGridSizeMemory.layout(of: narrow)) == .init(cols: 40, rows: 60))
        #expect(memory.size(for: TerminalGridSizeMemory.layout(of: wide)) == .init(cols: 90, rows: 60))
    }
}

/// A network path change gives every running mosh session a fresh UDP flow
/// at once (#105).
@MainActor
@Suite("Mosh session registry", .timeLimit(.minutes(1)))
struct MoshSessionRegistryTests {
    private final class Rebinder: MoshTransportRebinding {
        private let count = Mutex(0)
        var rebinds: Int { count.withLock { $0 } }
        func rebindTransport() async { count.withLock { $0 += 1 } }
    }

    @MainActor
    private final class Changes {
        var keys: [NetworkPathKey?] = []
    }

    @Test func aPathChangeRebindsEveryRunningSession() async throws {
        let path = ScriptedNetworkPathSource()
        let registry = MoshSessionRegistry()
        let fastPath = MoshFastPath(networkPath: path.monitor(), sessions: registry)
        let running = Rebinder()
        let ended = Rebinder()
        _ = registry.register(running)
        registry.unregister(registry.register(ended))
        let changes = Changes()
        fastPath.networkDidChange = { changes.keys.append($0) }
        fastPath.start()

        path.read(ScriptedNetworkPathSource.home)
        try await Task.sleep(for: .milliseconds(50))
        #expect(running.rebinds == 0, "the first reading is the baseline, not a change")

        path.read(ScriptedNetworkPathSource.cafe)
        try await pollUntil("the running session should rebind") { running.rebinds == 1 }
        #expect(ended.rebinds == 0)
        #expect(changes.keys == [ScriptedNetworkPathSource.cafe.key])
    }

    /// A real session joins once its client starts and leaves when its run
    /// ends — here a server that never answers.
    @Test func aRunningMoshSessionLeavesTheRegistryWhenItEnds() async throws {
        let registry = MoshSessionRegistry()
        let session = MoshAttachSession.make(
            bootstrap: MoshBootstrap(host: "127.0.0.1", udpPort: "9", key: "MDEyMzQ1Njc4OWFiY2RlZg"),
            cols: 80, rows: 24, firstContactTimeout: .seconds(1), registry: registry)
        try await pollUntil("the started client should join") { registry.count == 1 }
        do {
            for try await _ in session.output {}
        } catch {}
        try await pollUntil("the ended session should leave") { registry.count == 0 }
        await session.end()
    }
}

/// A returning mosh session is asked whether its server is still there
/// (#105). mosh-server 1.4.0 acks a client state with nothing new only at
/// its 3 s ACK_INTERVAL, so the check has to send one it acks at once.
@MainActor
@Suite("Mosh server contact", .timeLimit(.minutes(1)))
struct MoshServerContactTests {
    /// A server as mosh-server 1.4.0 answers: a prompted ack 100 ms after
    /// a state with something in it, none at all while it is gone.
    private actor Server: MoshServerContactSource {
        let isAlive: Bool
        private(set) var connectivity: MoshConnectivity? = .stalled
        private var listeners: [AsyncStream<MoshConnectivity>.Continuation] = []
        private(set) var prompts = 0

        init(isAlive: Bool) {
            self.isAlive = isAlive
        }

        func connectivityStream() -> AsyncStream<MoshConnectivity> {
            let (stream, continuation) = AsyncStream.makeStream(of: MoshConnectivity.self)
            if let connectivity { continuation.yield(connectivity) }
            listeners.append(continuation)
            return stream
        }

        func elicitServerReply() -> Bool {
            prompts += 1
            if isAlive {
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    await self.ack()
                }
            }
            return true
        }

        private func ack() {
            connectivity = .connected
            for listener in listeners { listener.yield(.connected) }
        }
    }

    /// An idle, healthy server is heard within the return's window: the
    /// session is kept, not abandoned for a replacement.
    @Test func anIdleHealthyServerIsHeardWithinTheWindow() async {
        let server = Server(isAlive: true)
        let heard = await MoshAttachSession.awaitServerContact(
            of: server, within: AgentAttachStore.moshContactWindow)
        #expect(heard)
        #expect(await server.prompts == 1)
    }

    /// A server that is gone stays silent: the session is abandoned.
    @Test func aDeadServerIsNotHeard() async {
        let server = Server(isAlive: false)
        let heard = await MoshAttachSession.awaitServerContact(
            of: server, within: AgentAttachStore.moshContactWindow)
        #expect(!heard)
    }

    /// One lost idle ack (a 6 s gap at the 3 s cadence) must not read as a
    /// stall: the threshold sits above two acks, as mosh's `server_late`.
    @Test func theStallThresholdOutlastsALostIdleAck() {
        #expect(MoshAttachSession.stallThresholdMs > 2 * MoshAttachSession.serverAckIntervalMs)
        #expect(MoshAttachSession.stallThresholdMs < MoshAttachSession.networkTimeoutMs)
    }
}
