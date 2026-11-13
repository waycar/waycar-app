import Foundation
import Synchronization
import Testing

@testable import Waycar

/// The device's network path (#105, C-NET): `currentKey` follows every
/// reading, and `changes()` reports each path the device settles on.
@Suite("Network path monitor", .timeLimit(.minutes(1)))
struct NetworkPathMonitorTests {
    /// Readings the test hands the monitor.
    private final class ScriptedPathSource: NetworkPathSource {
        private let handler = Mutex<(@Sendable (NetworkPathSnapshot) -> Void)?>(nil)
        private let cancelled = Mutex(false)
        private let starts = Mutex(0)

        var isCancelled: Bool { cancelled.withLock { $0 } }
        var startCount: Int { starts.withLock { $0 } }

        func start(_ handler: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
            starts.withLock { $0 += 1 }
            self.handler.withLock { $0 = handler }
        }

        func cancel() {
            cancelled.withLock { $0 = true }
        }

        func read(_ snapshot: NetworkPathSnapshot) {
            handler.withLock { $0 }?(snapshot)
        }
    }

    /// The debounce wait, held until the test opens it; opening releases
    /// every wait, present and future, until it is closed again.
    private actor DebounceGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let resuming = waiters
            waiters.removeAll()
            for waiter in resuming { waiter.resume() }
        }

        func close() {
            isOpen = false
        }
    }

    /// Every change a subscriber reading all along has seen, in order.
    /// `changes()` keeps only the newest change nobody has read yet, so a
    /// test that reads once, late, cannot tell one change from several.
    private final class ChangeLog: Sendable {
        private let state = Mutex<[NetworkPathKey?]>([])

        var changes: [NetworkPathKey?] { state.withLock { $0 } }

        func append(_ change: NetworkPathKey?) {
            state.withLock { $0.append(change) }
        }
    }

    private static let wifiHome = NetworkPathSnapshot(
        isSatisfied: true, interface: .wifi, interfaceName: "en0", localAddress: "192.168.1.20")
    private static let wifiCafe = NetworkPathSnapshot(
        isSatisfied: true, interface: .wifi, interfaceName: "en0", localAddress: "10.0.7.33")
    private static let cellular = NetworkPathSnapshot(
        isSatisfied: true, interface: .cellular, interfaceName: "pdp_ip0",
        localAddress: "2607:fb90:1:2:3:4:5:6")
    private static let offline = NetworkPathSnapshot(
        isSatisfied: false, interface: nil, interfaceName: nil, localAddress: nil)

    private func makeMonitor() -> (NetworkPathMonitor, ScriptedPathSource, DebounceGate) {
        let source = ScriptedPathSource()
        let gate = DebounceGate()
        let monitor = NetworkPathMonitor(
            source: source, debounce: .seconds(1), sleep: { _ in await gate.wait() })
        return (monitor, source, gate)
    }

    @Test func keysNameTheInterfaceAndTheAddressesNetwork() throws {
        let home = try #require(Self.wifiHome.key)
        #expect(home.interface == .wifi)
        #expect(home.interfaceName == "en0")
        #expect(home.addressPrefix == "192.168.1")
        #expect(Self.wifiCafe.key != home)
        #expect(Self.cellular.key?.addressPrefix == "2607:fb90:1:2")
        #expect(Self.offline.key == nil)
        // Another address on the same network is the same network.
        var sameNetwork = Self.wifiHome
        sameNetwork.localAddress = "192.168.1.99"
        #expect(sameNetwork.key == home)
        #expect(NetworkPathKey.prefix(ofAddress: "not an address") == nil)
    }

    /// A burst of readings settles as one change to where it ended; the
    /// first path is the baseline, not a change.
    @Test func aBurstOfReadingsSettlesAsOneChange() async throws {
        let (monitor, source, gate) = makeMonitor()
        let log = ChangeLog()
        let changes = monitor.changes()
        let reader = Task { for await change in changes { log.append(change) } }
        monitor.start()

        source.read(Self.wifiHome)
        #expect(monitor.currentKey == Self.wifiHome.key)
        source.read(Self.offline)
        source.read(Self.cellular)
        #expect(monitor.currentKey == Self.cellular.key)
        // Nothing settles while the debounce waits, not even the path lost
        // midway.
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.changes.isEmpty)
        await gate.open()

        try await waitUntil("the burst should settle") { !log.changes.isEmpty }
        monitor.stop()
        #expect(source.isCancelled)
        await reader.value
        #expect(log.changes == [Self.cellular.key])
    }

    /// A blip that returns to the settled path reports nothing.
    @Test func aBlipBackToTheSettledPathIsNoChange() async throws {
        let (monitor, source, gate) = makeMonitor()
        let log = ChangeLog()
        let changes = monitor.changes()
        let reader = Task { for await change in changes { log.append(change) } }
        monitor.start()
        source.read(Self.wifiHome)

        source.read(Self.offline)
        source.read(Self.wifiHome)
        await gate.open()
        // The blip's debounce has ended: a subscriber reading all along
        // heard nothing.
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.changes.isEmpty)

        await gate.close()
        source.read(Self.wifiCafe)
        await gate.open()
        try await waitUntil("the café should be reported") { !log.changes.isEmpty }
        monitor.stop()
        await reader.value
        #expect(log.changes == [Self.wifiCafe.key])
    }

    @Test func losingThePathIsAChangeToNil() async throws {
        let (monitor, source, gate) = makeMonitor()
        var changes = monitor.changes().makeAsyncIterator()
        monitor.start()
        source.read(Self.wifiHome)
        source.read(Self.offline)
        await gate.open()

        #expect(await changes.next() == .some(nil))
        #expect(monitor.currentKey == nil)
        monitor.stop()
    }

    // MARK: Pinned interleavings (P3c, SSH-02)

    @Test func startIsIdempotent() {
        let (monitor, source, _) = makeMonitor()
        monitor.start()
        monitor.start()
        #expect(source.startCount == 1)
        monitor.stop()
    }

    /// A baseline subscriber that arrives before the first reading hears it
    /// when it comes, then every settled change after it.
    @Test func aBaselineSubscriberBeforeTheFirstReadingHearsItThenChanges() async throws {
        let (monitor, source, gate) = makeMonitor()
        var changes = monitor.changes(includingBaseline: true).makeAsyncIterator()
        monitor.start()
        source.read(Self.wifiHome)
        source.read(Self.wifiCafe)
        await gate.open()

        #expect(await changes.next() == .some(Self.wifiHome.key))
        #expect(await changes.next() == .some(Self.wifiCafe.key))
        monitor.stop()
        #expect(await changes.next() == nil)
    }

    /// A baseline subscriber that arrives after the first reading hears the
    /// path settled last, at once, and nothing that has not settled yet.
    @Test func aBaselineSubscriberAfterTheFirstReadingHearsTheSettledPathAtOnce() async throws {
        let (monitor, source, gate) = makeMonitor()
        monitor.start()
        source.read(Self.wifiHome)
        source.read(Self.cellular)
        let log = ChangeLog()
        let changes = monitor.changes(includingBaseline: true)
        let reader = Task { for await change in changes { log.append(change) } }

        try await waitUntil("the baseline should arrive at once") { !log.changes.isEmpty }
        #expect(log.changes == [Self.wifiHome.key])
        await gate.open()
        try await waitUntil("cellular should settle") { log.changes.count == 2 }
        monitor.stop()
        await reader.value
        #expect(log.changes == [Self.wifiHome.key, Self.cellular.key])
    }

    /// A plain stream keeps only the newest settled change nobody read yet.
    @Test func aPlainStreamKeepsTheNewestUnreadChange() async throws {
        let (monitor, source, gate) = makeMonitor()
        var changes = monitor.changes().makeAsyncIterator()
        monitor.start()
        source.read(Self.wifiHome)
        await gate.open()
        source.read(Self.wifiCafe)
        try await waitUntil("the café should settle") {
            let probe = monitor.changes(includingBaseline: true)
            var iterator = probe.makeAsyncIterator()
            return await iterator.next() == .some(Self.wifiCafe.key)
        }
        source.read(Self.cellular)
        try await waitUntil("cellular should settle") {
            let probe = monitor.changes(includingBaseline: true)
            var iterator = probe.makeAsyncIterator()
            return await iterator.next() == .some(Self.cellular.key)
        }

        #expect(await changes.next() == .some(Self.cellular.key))
        monitor.stop()
        #expect(await changes.next() == nil)
    }

    /// Settling back on the baseline after another path settled is a change.
    @Test func returningToTheBaselineAfterAChangeIsAChange() async throws {
        let (monitor, source, gate) = makeMonitor()
        let log = ChangeLog()
        let changes = monitor.changes()
        let reader = Task { for await change in changes { log.append(change) } }
        monitor.start()
        source.read(Self.wifiHome)
        await gate.open()
        source.read(Self.wifiCafe)
        try await waitUntil("the café should settle") { log.changes.count == 1 }
        source.read(Self.wifiHome)
        try await waitUntil("home should settle again") { log.changes.count == 2 }
        monitor.stop()
        await reader.value
        #expect(log.changes == [Self.wifiCafe.key, Self.wifiHome.key])
    }

    @Test func stopFinishesEveryStreamAndCancelsTheSource() async throws {
        let (monitor, source, _) = makeMonitor()
        let plain = monitor.changes()
        let baseline = monitor.changes(includingBaseline: true)
        monitor.start()
        source.read(Self.wifiHome)
        source.read(Self.wifiCafe)
        monitor.stop()

        var plainSeen: [NetworkPathKey?] = []
        for await change in plain { plainSeen.append(change) }
        var baselineSeen: [NetworkPathKey?] = []
        for await change in baseline { baselineSeen.append(change) }
        #expect(plainSeen.isEmpty)
        #expect(baselineSeen == [Self.wifiHome.key])
        #expect(source.isCancelled)
    }
}
