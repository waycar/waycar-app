import Foundation
import Testing

@testable import Waycar

@Suite("Last frame index machine")
struct AgentLastFrameIndexMachineTests {
    private typealias Machine = AgentLastFrameIndexMachine
    private typealias Entry = AgentLastFrameStore.Entry

    private let host = Host.fixture()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ pane: String, host: Host? = nil, age: TimeInterval = 0, file: String? = nil) -> Entry {
        let host = host ?? self.host
        return Entry(
            hostID: host.id, paneID: pane, backend: .herdr, target: ConsoleInventoryCache.Target(host),
            width: 10, height: 10, capturedAt: now.addingTimeInterval(-age), file: file ?? "\(pane).jpg")
    }

    private var scope: ConsoleScope { ConsoleScope(hostID: host.id, backend: .herdr) }

    @Test func aMemoryOnlyCacheLoadsAtOnceAndPersistsEveryChange() {
        var machine = Machine()
        #expect(machine.handle(.memoryOnly).isEmpty)
        #expect(machine.isLoaded)
        let first = entry("p1")
        #expect(machine.handle(.record(first, now: now)) == [
            .dropPixels([]), .persist(index: [first], removedFiles: [], encode: "p1.jpg"),
        ])
        #expect(machine.handle(.remove(.agent(first.agentID))) == [
            .dropPixels(["p1.jpg"]), .persist(index: [], removedFiles: ["p1.jpg"], encode: nil),
        ])
        #expect(machine.handle(.remove(.agent(first.agentID))).isEmpty)
    }

    @Test func anUnreadableIndexKeepsEverythingPendingAndWritesNothing() {
        var machine = Machine()
        #expect(machine.handle(.indexRead(.unreadable, now: now)).isEmpty)
        #expect(!machine.isLoaded)
        let fresh = entry("p1")
        #expect(machine.handle(.record(fresh, now: now)) == [.dropPixels([])])
        #expect(machine.handle(.remove(.agent(fresh.agentID))) == [.dropPixels(["p1.jpg"])])
        #expect(machine.entries.isEmpty)
    }

    @Test func theFirstLoadMergesRecordedFramesRemembersRemovalsAndSweeps() {
        let recorded = entry("p1", file: "new.jpg")
        let diskCopy = entry("p1", age: 60, file: "old.jpg")
        let discarded = entry("p2", age: 30)
        let unlisted = entry("p3", age: 20)
        let listed = entry("p4", age: 10)
        let expired = entry("p5", age: AgentLastFrameStore.maxAge + 1)
        var machine = Machine().after([
            .indexRead(.unreadable, now: now), .record(recorded, now: now),
            .deferDiscard(discarded.agentID),
            .deferRetention([recorded.agentID, listed.agentID, discarded.agentID], verifiedScopes: [scope]),
        ])
        let loaded = [diskCopy, discarded, unlisted, listed, expired]
        #expect(machine.handle(.indexRead(.entries(loaded), now: now)) == [
            .sweep(keep: ["new.jpg", "p4.jpg"], index: [recorded, listed], rewritesIndex: true),
        ])
        #expect(machine.entries == [recorded, listed])
        #expect(machine.handle(.indexRead(.entries(loaded), now: now)).isEmpty)
        #expect(machine.handle(.deferDiscard(listed.agentID)).isEmpty)
        #expect(machine.state.load == .loaded)
    }

    @Test func retentionsWhilePendingOnlyNarrow() {
        let a = entry("a")
        let b = entry("b")
        var machine = Machine().after([
            .deferRetention([a.agentID, b.agentID], verifiedScopes: [scope]),
            .deferRetention([b.agentID], verifiedScopes: [scope]),
            .deferRetention([a.agentID, b.agentID], verifiedScopes: [scope]),
        ])
        _ = machine.handle(.indexRead(.entries([a, b]), now: now))
        #expect(machine.entries == [b])
    }

    @Test func theCatalogAskedForBeforeTheLoadAppliesToTheDisksFrames() {
        let other = Host.fixture()
        let kept = entry("p1")
        let gone = entry("p1", host: other)
        var machine = Machine().after([
            .indexRead(.unreadable, now: now),
            .setRetainedTargets([host.id: ConsoleInventoryCache.Target(host)]),
        ])
        #expect(machine.handle(.indexRead(.entries([kept, gone]), now: now)) == [
            .sweep(keep: ["p1.jpg"], index: [kept], rewritesIndex: true),
        ])
        #expect(machine.handle(.remove(.hostsOutside([host.id: ConsoleInventoryCache.Target(host)]))).isEmpty)
    }

    @Test func anUnchangedLoadDoesNotRewriteTheIndex() {
        let a = entry("a")
        var machine = Machine()
        #expect(machine.handle(.indexRead(.entries([a]), now: now)) == [
            .sweep(keep: ["a.jpg"], index: [a], rewritesIndex: false),
        ])
    }

    @Test func aRecordReplacesItsAgentDropsExpiredFramesAndKeepsTheCapacity() {
        let old = entry("p0", age: AgentLastFrameStore.maxAge + 1, file: "expired.jpg")
        var machine = Machine().after([.memoryOnly])
        _ = machine.handle(.indexRead(.entries([]), now: now))
        _ = machine.handle(.record(old, now: old.capturedAt))
        let panes = (1...AgentLastFrameStore.capacity).map { entry("p\($0)", age: TimeInterval(-$0)) }
        var effects: [Machine.Effect] = []
        for pane in panes { effects = machine.handle(.record(pane, now: now)) }
        #expect(machine.entries.count == AgentLastFrameStore.capacity)
        #expect(!machine.entries.contains(old))
        let again = entry("p3", file: "again.jpg")
        effects = machine.handle(.record(again, now: now))
        #expect(effects.first == .dropPixels(["p3.jpg"]))
        #expect(machine.entries.first == again)
        let overflow = entry("p9", file: "p9.jpg")
        effects = machine.handle(.record(overflow, now: now))
        #expect(effects.first == .dropPixels(["p1.jpg"]))
        #expect(machine.entries.count == AgentLastFrameStore.capacity)
    }

    @Test func anEncodingIsKeptOnlyWhileItsCaptureStays() {
        let first = entry("p1", file: "one.jpg")
        let replacement = entry("p1", file: "two.jpg")
        let discarded = entry("p2", file: "three.jpg")
        var machine = Machine().after([
            .memoryOnly, .record(first, now: now), .record(replacement, now: now),
            .record(discarded, now: now), .remove(.agent(discarded.agentID)),
        ])
        #expect(machine.handle(.encoded(file: "one.jpg")).isEmpty)
        #expect(machine.handle(.encoded(file: "three.jpg")).isEmpty)
        #expect(machine.handle(.encoded(file: "two.jpg")) == [.storeEncoded("two.jpg")])
        #expect(machine.handle(.encoded(file: "two.jpg")).isEmpty)
    }

    @Test func removalsMatchTheirKind() {
        let other = Host.fixture()
        let listed = entry("p1")
        let unlisted = entry("p2")
        let elsewhere = entry("p3", host: other)
        var machine = Machine().after([
            .memoryOnly, .record(elsewhere, now: now), .record(unlisted, now: now), .record(listed, now: now),
        ])
        _ = machine.handle(.remove(.unlisted([listed.agentID], verifiedScopes: [scope])))
        #expect(machine.entries == [listed, elsewhere])
        _ = machine.handle(.remove(.hostsOutside([host.id: ConsoleInventoryCache.Target(host)])))
        #expect(machine.entries == [listed])
    }
}
