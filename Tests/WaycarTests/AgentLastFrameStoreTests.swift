import Foundation
import Testing
import UIKit

@testable import Waycar

/// Which Agents keep a cached last frame, for how long, and what forgets it
/// (#21, #27).
@MainActor
@Suite("Agent last frame store")
struct AgentLastFrameStoreTests {
    /// Only the eight most recently captured Agents keep a frame, on disk as
    /// in memory; capturing an Agent again makes it the most recent.
    @Test func theEightMostRecentAgentsKeepTheirFrames() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LastFrameClock()
        let host = Host.fixture()
        let store = AgentLastFrameStore(directory: directory, now: { clock.now })
        let agents = (0..<10).map { Self.agent("w1:p\($0)", host: host) }
        for agent in agents.prefix(9) {
            store.record(Self.image(), size: Self.size, for: agent, host: host)
            clock.advance(1)
        }
        #expect(store.frame(for: agents[0].id, host: host) == nil, "the oldest of nine is evicted")
        #expect(agents[1..<9].allSatisfy { store.frame(for: $0.id, host: host) != nil })

        store.record(Self.image(), size: Self.size, for: agents[1], host: host)
        clock.advance(1)
        store.record(Self.image(), size: Self.size, for: agents[9], host: host)
        #expect(store.frame(for: agents[1].id, host: host) != nil, "a recapture is the most recent")
        #expect(store.frame(for: agents[2].id, host: host) == nil)

        await store.settle()
        let reopened = AgentLastFrameStore(directory: directory, now: { clock.now })
        let kept = Set([1] + Array(3...9)).map { agents[$0].id }
        #expect(Set(reopened.cachedEntries.map(\.agentID)) == Set(kept))
        #expect(kept.allSatisfy { reopened.frame(for: $0, host: host) != nil })
        await reopened.settle()
        #expect(try Self.images(in: directory).count == AgentLastFrameStore.capacity,
            "evicted and replaced frames leave no file behind")
    }

    /// A frame is offered for a day after its capture and never after, in this
    /// launch or a later one.
    @Test func aFrameOlderThanADayIsNeitherShownNorKept() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LastFrameClock()
        let host = Host.fixture()
        let first = Self.agent("w1:p1", host: host)
        let second = Self.agent("w1:p2", host: host)
        let store = AgentLastFrameStore(directory: directory, now: { clock.now })
        store.record(Self.image(), size: Self.size, for: first, host: host)
        clock.advance(10)
        store.record(Self.image(), size: Self.size, for: second, host: host)

        clock.advance(AgentLastFrameStore.maxAge - 10)
        #expect(store.frame(for: first.id, host: host) != nil, "a day old is still offered")
        clock.advance(1)
        #expect(store.frame(for: first.id, host: host) == nil)
        #expect(store.cachedEntries.map(\.agentID) == [second.id])

        await store.settle()
        clock.advance(10)
        let reopened = AgentLastFrameStore(directory: directory, now: { clock.now })
        #expect(reopened.frame(for: second.id, host: host) == nil)
        #expect(reopened.cachedEntries.isEmpty)
        await reopened.settle()
        #expect(try Self.images(in: directory).isEmpty)
    }

    /// A frame captured in one launch is offered in the next, at the size it
    /// was taken at.
    @Test func aFrameSurvivesAColdLaunch() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let agent = Self.agent("w1:p1", host: host)
        let store = AgentLastFrameStore(directory: directory)
        store.record(Self.image(), size: Self.size, for: agent, host: host)
        await store.settle()

        let reopened = AgentLastFrameStore(directory: directory)
        let frame = try #require(reopened.frame(for: agent.id, host: host))
        #expect(frame.size == Self.size)
        #expect(frame.image.size.width > 0)
    }

    /// A discarded frame is gone from disk too, and other Agents keep theirs.
    @Test func aDiscardedFrameIsGoneForGood() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let ended = Self.agent("w1:p1", host: host)
        let other = Self.agent("w1:p2", host: host)
        let store = AgentLastFrameStore(directory: directory)
        store.record(Self.image(), size: Self.size, for: ended, host: host)
        store.record(Self.image(), size: Self.size, for: other, host: host)
        store.discard(ended.id)
        #expect(store.frame(for: ended.id, host: host) == nil)
        await store.settle()

        let reopened = AgentLastFrameStore(directory: directory)
        #expect(reopened.frame(for: ended.id, host: host) == nil)
        #expect(reopened.frame(for: other.id, host: host) != nil)
        #expect(try Self.images(in: directory).count == 1)
    }

    /// A CarPlay launch can start the app with the phone locked, where the
    /// `.complete` index cannot be read. That is no empty cache: no frame is
    /// swept, nothing is written, and once the device unlocks the frames
    /// are all there.
    @Test func aLockedIndexIsNeitherSweptNorOverwritten() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let agents = (0..<3).map { Self.agent("w1:p\($0)", host: host) }
        let writer = AgentLastFrameStore(directory: directory)
        for agent in agents {
            writer.record(Self.image(), size: Self.size, for: agent, host: host)
        }
        await writer.settle()

        let lock = DeviceLock()
        let store = AgentLastFrameStore(
            directory: directory,
            readIndex: { url in
                lock.isLocked ? .unreadable : ConsoleInventoryCache.FileAccess.live.read(url)
            })
        store.retainHosts([host])
        store.retainAgents([], verifiedScopes: [])
        #expect(store.cachedEntries.isEmpty)
        await store.settle()
        #expect(try Self.images(in: directory).count == 3, "a locked read sweeps nothing")

        lock.isLocked = false
        #expect(Set(store.cachedEntries.map(\.agentID)) == Set(agents.map(\.id)))
        #expect(store.frame(for: agents[0].id, host: host) != nil)
        await store.settle()
        #expect(try Self.images(in: directory).count == 3)
    }

    @Test func paneRemovalsWhileLockedApplyWhenTheIndexLoads() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let agents = (0..<3).map { Self.agent("w1:p\($0)", host: host) }
        let writer = AgentLastFrameStore(directory: directory)
        for agent in agents {
            writer.record(Self.image(), size: Self.size, for: agent, host: host)
        }
        await writer.settle()
        let original = try Data(contentsOf: directory.appending(path: "index.json"))
        let lock = DeviceLock()
        let store = AgentLastFrameStore(
            directory: directory,
            readIndex: { url in
                lock.isLocked ? .unreadable : ConsoleInventoryCache.FileAccess.live.read(url)
            })
        store.retainAgents(
            Set(agents.prefix(2).map(\.id)),
            verifiedScopes: [ConsoleScope(hostID: host.id, backend: .herdr)])
        store.discard(agents[0].id)
        await store.settle()
        #expect(try Data(contentsOf: directory.appending(path: "index.json")) == original)
        #expect(try Self.images(in: directory).count == 3)

        lock.isLocked = false
        #expect(store.cachedEntries.map(\.agentID) == [agents[1].id])
        #expect(store.frame(for: agents[0].id, host: host) == nil)
        #expect(store.frame(for: agents[2].id, host: host) == nil)
        await store.settle()
        let reopened = AgentLastFrameStore(directory: directory)
        #expect(reopened.cachedEntries.map(\.agentID) == [agents[1].id])
        await reopened.settle()
        #expect(try Self.images(in: directory).count == 1)
    }

    /// A removed Host takes its frames along; so does one whose connection
    /// target changed, which may now reach another herdr.
    @Test func aRemovedOrRetargetedHostLosesItsFrames() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = Host.fixture(name: "kept")
        let renamed = Host.fixture(name: "before")
        let retargeted = Host.fixture()
        let removed = Host.fixture()
        let store = AgentLastFrameStore(directory: directory)
        for host in [kept, renamed, retargeted, removed] {
            store.record(Self.image(), size: Self.size, for: Self.agent("w1:p1", host: host), host: host)
        }
        var renamedNow = renamed
        renamedNow.name = "after"
        var retargetedNow = retargeted
        retargetedNow.address = "elsewhere.example"
        store.retainHosts([kept, renamedNow, retargetedNow])
        #expect(Set(store.cachedEntries.map(\.hostID)) == [kept.id, renamed.id])

        let stale = Host.fixture(id: kept.id, address: "moved.example")
        #expect(store.frame(for: Self.agent("w1:p1", host: kept).id, host: stale) == nil,
            "a frame taken on another target is never shown")
        #expect(Set(store.cachedEntries.map(\.hostID)) == [renamed.id])
        await store.settle()
        #expect(AgentLastFrameStore(directory: directory).cachedEntries.map(\.hostID) == [renamed.id])
    }

    /// A pane a verified snapshot no longer lists is gone; one missing only
    /// from last-known (unverified) rows may still come back.
    @Test func aGonePaneLosesItsFrameOnceItsHostIsVerified() async throws {
        let first = Host.fixture()
        let second = Host.fixture()
        let listed = Self.agent("w1:p1", host: first)
        let gone = Self.agent("w1:p2", host: first)
        let unverified = Self.agent("w1:p3", host: second)
        let store = AgentLastFrameStore(directory: nil)
        store.record(Self.image(), size: Self.size, for: listed, host: first)
        store.record(Self.image(), size: Self.size, for: gone, host: first)
        store.record(Self.image(), size: Self.size, for: unverified, host: second)

        store.retainAgents([listed.id], verifiedScopes: [])
        #expect(store.cachedEntries.count == 3, "nothing is verified yet")
        store.retainAgents(
            [listed.id], verifiedScopes: [ConsoleScope(hostID: first.id, backend: .herdr)])
        #expect(Set(store.cachedEntries.map(\.agentID)) == [listed.id, unverified.id])
    }

    // MARK: Fixtures

    static let size = CGSize(width: 402, height: 600)

    static func agent(_ pane: String, host: Host) -> ConsoleAgent {
        AgentSurfaceReplacementTests.makeAgent(pane: pane, host: host.id)
    }

    static func image() -> CGImage {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 40, height: 60),
            format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }())
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
            UIColor.green.setFill()
            context.fill(CGRect(x: 4, y: 50, width: 20, height: 6))
        }
        guard let cgImage = image.cgImage else { preconditionFailure("renderer made no bitmap") }
        return cgImage
    }

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "agent-last-frames-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func images(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".jpg") }
    }
}

@MainActor
private final class LastFrameClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Whether a test's protected files read as locked; read from the disk
/// queue, so it is lock-guarded.
final class DeviceLock: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = true

    var isLocked: Bool {
        get { lock.withLock { locked } }
        set { lock.withLock { locked = newValue } }
    }
}
