import Foundation
import Synchronization
import Testing

@testable import Waycar

@Suite("Find Computers store")
@MainActor
struct FindComputersStoreTests {
    @Test func startsBonjourImmediatelyAndScansOnlyAfterATap() async {
        let browser = DiscoveryTestBrowser()
        let sweeper = DiscoveryTestSweeper()
        let store = FindComputersStore(
            browser: browser, sweeper: sweeper, localSubnet: { nil }, settleDelay: .seconds(60))
        var milestones: [Milestone] = []
        store.start { milestones.append($0) }
        defer { store.stop() }
        #expect(browser.calls == 1)
        #expect(sweeper.calls == 0)
        #expect(milestones == [.lanScanStarted])
        browser.continuation.yield(.ready)
        browser.continuation.yield(.computers([
            FoundComputer(address: "192.168.1.20", port: 22, serviceName: "Studio Mac", software: nil, source: .bonjour)
        ]))
        #expect(await waitUntil { store.hasSettled })
        #expect(milestones == [.lanScanStarted, .lanScanFound(count: 1)])

        store.scanNetwork()
        #expect(sweeper.calls == 1)
        sweeper.continuation.yield(.found(FoundComputer(
            address: "192.168.1.20", port: 22, serviceName: nil, software: "OpenSSH_test", source: .sweep)))
        sweeper.continuation.yield(.finished)
        #expect(await waitUntil { store.sweep == .finished })
        #expect(store.computers.count == 1)
        #expect(store.computers.first?.software == "OpenSSH_test")
        #expect(milestones.count == 2)
    }

    @Test func browseDenialReportsOnlyThePermissionMilestone() async {
        let browser = DiscoveryTestBrowser()
        let store = FindComputersStore(browser: browser, localSubnet: { nil })
        var milestones: [Milestone] = []
        store.start { milestones.append($0) }
        defer { store.stop() }
        browser.continuation.yield(.denied)
        #expect(await waitUntil { store.isDenied })
        #expect(milestones == [.lanScanStarted, .lanPermissionDenied])
    }
}

private final class DiscoveryTestBrowser: ComputerBrowsing, Sendable {
    let stream: AsyncStream<BrowseEvent>
    let continuation: AsyncStream<BrowseEvent>.Continuation
    private let count = Mutex(0)
    init() { (stream, continuation) = AsyncStream.makeStream() }
    var calls: Int { count.withLock { $0 } }
    func events() -> AsyncStream<BrowseEvent> {
        count.withLock { $0 += 1 }
        return stream
    }
}

private final class DiscoveryTestSweeper: NetworkSweeping, Sendable {
    let stream: AsyncStream<SweepEvent>
    let continuation: AsyncStream<SweepEvent>.Continuation
    private let count = Mutex(0)
    init() { (stream, continuation) = AsyncStream.makeStream() }
    var calls: Int { count.withLock { $0 } }
    func sweep() -> AsyncStream<SweepEvent> {
        count.withLock { $0 += 1 }
        return stream
    }
}
