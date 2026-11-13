import Foundation
import Synchronization
import Testing

@testable import Waycar

@Suite("Find Computers store")
@MainActor
struct FindComputersStoreTests {
    @Test func oneStartBrowsesAndChecksEveryAddress() async throws {
        let browser = DiscoveryTestBrowser()
        let sweeper = DiscoveryTestSweeper()
        let store = FindComputersStore(
            browser: browser, sweeper: sweeper, localSubnet: { nil }, settleDelay: .seconds(60),
            isAppActive: { true })
        var milestones: [Milestone] = []
        store.start { milestones.append($0) }
        defer { store.stop() }
        #expect(browser.calls == 1)
        #expect(sweeper.calls == 1)
        #expect(milestones == [.lanScanStarted])
        browser.continuation.yield(.ready)
        browser.continuation.yield(.computers([
            FoundComputer(address: "192.168.1.20", port: 22, serviceName: "Studio Mac", software: nil, source: .bonjour)
        ]))
        try await waitUntil { store.hasSettled }
        sweeper.continuation.yield(.found(FoundComputer(
            address: "192.168.1.20", port: 22, serviceName: nil, software: "OpenSSH_test", source: .sweep)))
        sweeper.continuation.yield(.finished)
        try await waitUntil { store.sweep == .finished }
        #expect(store.computers.count == 1)
        #expect(store.computers.first?.software == "OpenSSH_test")
        #expect(milestones == [.lanScanStarted, .lanScanFound(count: 1)])
    }

    /// While iOS's Local Network prompt is up the app is inactive, and what a
    /// search sees then says nothing about the network: no milestone goes out.
    @Test func milestonesWaitForAnActiveApp() async throws {
        let browser = DiscoveryTestBrowser()
        let store = FindComputersStore(
            browser: browser, sweeper: DiscoveryTestSweeper(), localSubnet: { nil },
            isAppActive: { false })
        var milestones: [Milestone] = []
        store.start { milestones.append($0) }
        defer { store.stop() }
        browser.continuation.yield(.denied)
        try await waitUntil { store.isDenied }
        #expect(milestones.isEmpty)
    }

    @Test func browseDenialReportsOnlyThePermissionMilestone() async throws {
        let browser = DiscoveryTestBrowser()
        let store = FindComputersStore(
            browser: browser, sweeper: DiscoveryTestSweeper(), localSubnet: { nil },
            isAppActive: { true })
        var milestones: [Milestone] = []
        store.start { milestones.append($0) }
        defer { store.stop() }
        browser.continuation.yield(.denied)
        try await waitUntil { store.isDenied }
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
