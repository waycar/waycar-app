import Foundation
import Testing

@testable import Waycar

/// `HostLiveTelemetry`, the Hosts sheet's sampler, against a scripted source.
@MainActor
@Suite("Host live telemetry", .timeLimit(.minutes(1)))
struct HostLiveTelemetryTests {
    private let hostA = UUID()
    private let hostB = UUID()

    @Test func samplesEachConnectedHostEveryRound() async throws {
        let source = FakeTelemetrySource(connected: [hostA])
        let telemetry = HostLiveTelemetry(source: source, interval: .milliseconds(20))
        let run = Task { await telemetry.run() }
        defer { run.cancel() }

        try await waitUntil("the connected Host should be sampled twice") {
            source.answered[hostA, default: 0] >= 2
        }
        #expect(telemetry.usage[hostA] != nil)
        #expect(source.calls(.latency, on: hostA) >= 2)
    }

    @Test func theFirstSampleDoesNotWaitAnInterval() async throws {
        let source = FakeTelemetrySource(connected: [hostA])
        let telemetry = HostLiveTelemetry(source: source, interval: .seconds(60))
        let run = Task { await telemetry.run() }
        defer { run.cancel() }

        try await waitUntil("the first sample should land at once") {
            telemetry.usage[hostA] != nil
        }
    }

    @Test func pingsBeforeTheResourceCommand() async throws {
        let source = FakeTelemetrySource(connected: [hostA])
        source.hold(.latency, on: hostA)
        let telemetry = HostLiveTelemetry(source: source, interval: .seconds(60))
        let run = Task { await telemetry.run() }
        defer { run.cancel() }

        try await waitUntil("the ping should be in flight") {
            source.calls(.latency, on: hostA) == 1
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(source.calls(.resource, on: hostA) == 0)

        source.release(.latency, on: hostA)
        try await waitUntil("the resource command follows the ping") {
            source.calls(.resource, on: hostA) == 1
        }
        #expect(source.log.filter { $0.host == hostA }.map(\.call) == [.latency, .resource])
    }

    /// A `.connected` Host's ping is unproved during every pane-subscription
    /// reinstall: the exec is skipped, but the line keeps its last numbers.
    @Test func anUnprovedPingSkipsTheCommandAndKeepsTheLine() async throws {
        let source = FakeTelemetrySource(connected: [hostA])
        let telemetry = HostLiveTelemetry(source: source, interval: .milliseconds(20))
        let run = Task { await telemetry.run() }
        defer { run.cancel() }

        try await waitUntil("the Host should have a sample") { telemetry.usage[hostA] != nil }
        source.proves[hostA] = false
        let kept = telemetry.usage[hostA]
        let commands = source.calls(.resource, on: hostA)
        let pings = source.calls(.latency, on: hostA)
        try await waitUntil("pings keep going") {
            source.calls(.latency, on: hostA) >= pings + 3
        }
        #expect(source.calls(.resource, on: hostA) == commands)
        #expect(telemetry.usage[hostA] == kept)
    }

    @Test func aPingAnsweringAfterTheRunEndedRunsNoCommand() async throws {
        let source = FakeTelemetrySource(connected: [hostA])
        source.hold(.latency, on: hostA)
        let telemetry = HostLiveTelemetry(source: source, interval: .seconds(60))
        let run = Task { await telemetry.run() }

        try await waitUntil("the ping should be in flight") {
            source.calls(.latency, on: hostA) == 1
        }
        run.cancel()
        await run.value
        source.release(.latency, on: hostA)
        for _ in 0..<20 { await Task.yield() }
        #expect(source.calls(.resource, on: hostA) == 0)
    }

    /// No further round runs here (60 s interval), so only the check after
    /// the exec keeps a Host that disconnected meanwhile off the line.
    @Test func aSampleForAHostThatDisconnectedMeanwhileNeverLands() async throws {
        let source = FakeTelemetrySource(connected: [hostA, hostB])
        source.hold(.resource, on: hostB)
        let telemetry = HostLiveTelemetry(source: source, interval: .seconds(60))
        let run = Task { await telemetry.run() }
        defer { run.cancel() }

        try await waitUntil("A answers while B's sample is held") {
            telemetry.usage[hostA] != nil && source.calls(.resource, on: hostB) == 1
        }
        source.connected = [hostA]
        source.release(.resource, on: hostB)
        try await waitUntil("B's held sample answers") { source.answered[hostB] == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(telemetry.usage[hostB] == nil)
        #expect(telemetry.usage[hostA] != nil)
    }

    @Test func aTransientFailureClearsTheLineButKeepsAsking() async throws {
        let source = FakeTelemetrySource(connected: [hostA])
        let telemetry = HostLiveTelemetry(source: source, interval: .milliseconds(20))
        let run = Task { await telemetry.run() }
        defer { run.cancel() }

        try await waitUntil("the Host should have a sample") { telemetry.usage[hostA] != nil }
        source.failures[hostA] = TransportError.timedOut
        try await waitUntil("a failed sample clears the line") { telemetry.usage[hostA] == nil }
        let commands = source.calls(.resource, on: hostA)
        try await waitUntil("the Host keeps being asked") {
            source.calls(.resource, on: hostA) >= commands + 2
        }
        source.failures[hostA] = nil
        try await waitUntil("the line comes back once samples answer") {
            telemetry.usage[hostA] != nil
        }
    }

    @Test func anUnsupportedHostIsClearedAndNotAskedAgain() async throws {
        let source = FakeTelemetrySource(connected: [hostA])
        let telemetry = HostLiveTelemetry(source: source, interval: .milliseconds(20))
        let run = Task { await telemetry.run() }
        defer { run.cancel() }

        try await waitUntil("the Host should have a sample") { telemetry.usage[hostA] != nil }
        source.failures[hostA] = HostResourceUsage.Unsupported()
        try await waitUntil("an unsupported answer clears the line") {
            telemetry.usage[hostA] == nil
        }
        let commands = source.calls(.resource, on: hostA)
        let pings = source.calls(.latency, on: hostA)
        try await waitUntil("latency keeps being sampled") {
            source.calls(.latency, on: hostA) >= pings + 3
        }
        #expect(source.calls(.resource, on: hostA) == commands)
        #expect(telemetry.usage[hostA] == nil)
    }

    @Test func dropsAHostThatDisconnects() async throws {
        let source = FakeTelemetrySource(connected: [hostA, hostB])
        let telemetry = HostLiveTelemetry(source: source, interval: .milliseconds(20))
        let run = Task { await telemetry.run() }
        defer { run.cancel() }

        try await waitUntil("both Hosts should have a sample") { telemetry.usage.count == 2 }
        source.connected = [hostA]
        try await waitUntil("the disconnected Host's sample should be dropped") {
            telemetry.usage[hostB] == nil
        }
        #expect(telemetry.usage[hostA] != nil)
    }

    @Test func clearsEverySampleWhenCancelled() async throws {
        let source = FakeTelemetrySource(connected: [hostA])
        let telemetry = HostLiveTelemetry(source: source, interval: .milliseconds(20))
        let run = Task { await telemetry.run() }

        try await waitUntil("the Host should have a sample") { telemetry.usage[hostA] != nil }
        run.cancel()
        await run.value
        #expect(telemetry.usage.isEmpty)
    }

    @Test func aSampleAnsweringAfterTheRunEndedNeverLands() async throws {
        let source = FakeTelemetrySource(connected: [hostA])
        source.hold(.resource, on: hostA)
        let telemetry = HostLiveTelemetry(source: source, interval: .milliseconds(20))
        let run = Task { await telemetry.run() }

        try await waitUntil("the sample should be in flight") {
            source.calls(.resource, on: hostA) == 1
        }
        run.cancel()
        await run.value
        source.release(.resource, on: hostA)
        try await waitUntil("the held sample answers") { source.answered[hostA] == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(telemetry.usage.isEmpty)
    }

    @Test func dismissalNeverCancelsASampleInFlight() async throws {
        let source = FakeTelemetrySource(connected: [hostA])
        source.hold(.resource, on: hostA)
        let telemetry = HostLiveTelemetry(source: source, interval: .milliseconds(20))
        let run = Task { await telemetry.run() }

        try await waitUntil("the sample should be in flight") {
            source.calls(.resource, on: hostA) == 1
        }
        run.cancel()
        await run.value
        source.release(.resource, on: hostA)
        try await waitUntil("the held sample answers") { source.answered[hostA] == 1 }
        #expect(source.cancellationSeenInHeldCalls == [false])
    }

    @Test func aRestartedRunOwnsTheSamples() async throws {
        let source = FakeTelemetrySource(connected: [hostA, hostB])
        source.hold(.resource, on: hostA)
        let telemetry = HostLiveTelemetry(source: source, interval: .seconds(60))
        let first = Task { await telemetry.run() }

        try await waitUntil("the first run samples B and holds A") {
            telemetry.usage[hostB] != nil && source.calls(.resource, on: hostA) == 1
        }
        let second = Task { await telemetry.run() }
        try await waitUntil("the second run samples B again at once") {
            source.answered[hostB] == 2
        }
        first.cancel()
        await first.value
        #expect(telemetry.usage[hostB] != nil, "the old run's exit must not clear the new run's")

        source.release(.resource, on: hostA)
        try await waitUntil("the old run's held sample answers") { source.answered[hostA] == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(telemetry.usage[hostA] == nil, "the old run's late answer must not land")
        #expect(telemetry.usage[hostB] != nil)

        second.cancel()
        await second.value
        #expect(telemetry.usage.isEmpty)
    }

    @Test func aHeldHostDoesNotStallTheOthers() async throws {
        let source = FakeTelemetrySource(connected: [hostA, hostB])
        source.hold(.resource, on: hostA)
        let telemetry = HostLiveTelemetry(source: source, interval: .milliseconds(20))
        let run = Task { await telemetry.run() }
        defer { run.cancel() }

        try await waitUntil("B keeps advancing while A is held") {
            source.answered[hostB, default: 0] >= 3
        }
        #expect(source.calls(.resource, on: hostA) == 1)
        source.release(.resource, on: hostA)
    }

    @Test func neverOverlapsSamplesOnOneHost() async throws {
        let source = FakeTelemetrySource(connected: [hostA])
        source.hold(.resource, on: hostA)
        let telemetry = HostLiveTelemetry(source: source, interval: .milliseconds(10))
        let run = Task { await telemetry.run() }
        defer { run.cancel() }

        try await waitUntil("the first sample should be in flight") {
            source.calls(.resource, on: hostA) == 1
        }
        let rounds = source.connectedReads
        try await waitUntil("several scheduling rounds pass while the sample is held") {
            source.connectedReads >= rounds + 5
        }
        #expect(source.calls(.resource, on: hostA) == 1)
        #expect(source.calls(.latency, on: hostA) == 1)

        source.release(.resource, on: hostA)
        try await waitUntil("sampling resumes once the held sample answers") {
            source.calls(.resource, on: hostA) >= 2
        }
        #expect(source.maxConcurrent == 1)
    }
}

/// Scripts the Console's side of sampling: which Hosts are connected,
/// whether each ping proves its Host, which commands fail, and which calls
/// to hold. Every resource answer differs, so a test can tell samples apart.
@MainActor
private final class FakeTelemetrySource: HostLiveTelemetrySource {
    enum Call: Equatable { case latency, resource }

    private struct Key: Hashable {
        let host: Host.ID
        let isLatency: Bool
        init(_ call: Call, _ host: Host.ID) {
            self.host = host
            isLatency = call == .latency
        }
    }

    var connected: Set<Host.ID>
    /// Whether each Host's ping proves its connection; true by default.
    var proves: [Host.ID: Bool] = [:]
    /// What each Host's resource command throws, if anything.
    var failures: [Host.ID: any Error] = [:]
    private(set) var log: [(host: Host.ID, call: Call)] = []
    /// Resource calls that answered (successfully or not), per Host.
    private(set) var answered: [Host.ID: Int] = [:]
    /// Reads of `connectedHostIDs`: one per scheduling round, plus one per
    /// resource sample that answers.
    private(set) var connectedReads = 0
    private(set) var maxConcurrent = 0
    /// `Task.isCancelled` inside each held call once it was released.
    private(set) var cancellationSeenInHeldCalls: [Bool] = []
    private var concurrent: [Host.ID: Int] = [:]
    private var holds: Set<Key> = []
    private var held: [Key: [CheckedContinuation<Void, Never>]] = [:]

    init(connected: Set<Host.ID>) {
        self.connected = connected
    }

    var connectedHostIDs: Set<Host.ID> {
        connectedReads += 1
        return connected
    }

    func calls(_ call: Call, on host: Host.ID) -> Int {
        log.filter { $0.host == host && $0.call == call }.count
    }

    func hold(_ call: Call, on host: Host.ID) {
        holds.insert(Key(call, host))
    }

    func release(_ call: Call, on host: Host.ID) {
        let key = Key(call, host)
        holds.remove(key)
        let resuming = held.removeValue(forKey: key) ?? []
        resuming.forEach { $0.resume() }
    }

    func sampleLatency(on hostID: Host.ID) async -> Bool {
        log.append((hostID, .latency))
        await waitIfHeld(Key(.latency, hostID))
        return proves[hostID] ?? true
    }

    func hostResourceUsage(on hostID: Host.ID) async throws -> HostResourceUsage {
        log.append((hostID, .resource))
        let number = calls(.resource, on: hostID)
        concurrent[hostID, default: 0] += 1
        maxConcurrent = max(maxConcurrent, concurrent[hostID, default: 0])
        defer {
            concurrent[hostID, default: 0] -= 1
            answered[hostID, default: 0] += 1
        }
        await waitIfHeld(Key(.resource, hostID))
        if let failure = failures[hostID] { throw failure }
        return HostResourceUsage(cpu: Double(number) / 100, memory: 0.4, swap: nil)
    }

    private func waitIfHeld(_ key: Key) async {
        guard holds.contains(key) else { return }
        await withCheckedContinuation { held[key, default: []].append($0) }
        cancellationSeenInHeldCalls.append(Task.isCancelled)
    }
}
