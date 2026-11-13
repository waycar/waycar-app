import Foundation
import Testing

@testable import Waycar

@Suite("New Agent discovery transitions")
struct AgentDiscoveryMachineTests {
    private let hostID = UUID()
    private let cached = CachedAgentKinds(kinds: [.claude], verifiedAt: Date(timeIntervalSince1970: 1))

    @Test func liveDetectionAndStaleCompletions() {
        let first = AgentDiscoveryMachine.Attempt(token: 1, hostID: hostID)
        let second = AgentDiscoveryMachine.Attempt(token: 2, hostID: hostID)
        var machine = AgentDiscoveryMachine()
        #expect(machine.handle(.begin(hostID, nil)) == [.clearSelection, .detect(first)])
        #expect(machine.state == .detecting(first))
        #expect(machine.handle(.loaded(first, [.codex])) == [
            .applyKinds([.codex], hostID, preservesLoadedPick: false)
        ])
        #expect(machine.state == .live([.codex]))
        #expect(machine.handle(.begin(hostID, cached)) == [
            .applyKinds(cached.kinds, hostID, preservesLoadedPick: true), .detect(second)
        ])
        #expect(machine.handle(.failed(first, "old")).isEmpty)
        #expect(machine.handle(.cancelled(first)).isEmpty)
        #expect(machine.handle(.loaded(first, [.omp])).isEmpty)
        #expect(machine.state == .refreshing(second, cached))
        #expect(machine.handle(.loaded(second, [.omp])) == [
            .applyKinds([.omp], hostID, preservesLoadedPick: true)
        ])
        #expect(machine.cachedKinds == nil)
    }

    @Test func cachedInventorySurvivesFailureAndCancellation() {
        let attempt = AgentDiscoveryMachine.Attempt(token: 1, hostID: hostID)
        for event in [AgentDiscoveryMachine.Event.failed(attempt, "down"), .cancelled(attempt)] {
            var machine = AgentDiscoveryMachine().after([.begin(hostID, cached)])
            #expect(machine.kinds == cached.kinds && machine.isLoaded)
            #expect(machine.handle(event).isEmpty)
            #expect(machine.state == .cached(cached))
            #expect(machine.cachedKinds?.verifiedAt == cached.verifiedAt)
        }
    }

    @Test func uncachedFailuresCancellationAndHostReset() {
        let attempt = AgentDiscoveryMachine.Attempt(token: 1, hostID: hostID)
        var machine = AgentDiscoveryMachine().after([.begin(hostID, nil)])
        #expect(machine.handle(.failed(attempt, "down")).isEmpty)
        #expect(machine.state == .failed("down"))
        machine = AgentDiscoveryMachine().after([.begin(hostID, nil), .cancelled(attempt)])
        #expect(machine.state == .idle)
        machine = AgentDiscoveryMachine().after([.begin(hostID, cached), .reset])
        #expect(machine.kinds.isEmpty && !machine.isLoaded)
        #expect(machine.handle(.loaded(attempt, [.omp])) == [
            .applyKinds([.omp], hostID, preservesLoadedPick: false)
        ])
        #expect(machine.handle(.begin(nil, nil)) == [.clearSelection])
        #expect(machine.handle(.begin(hostID, nil)) == [
            .clearSelection, .detect(.init(token: 2, hostID: hostID))
        ])
        #expect(machine.handle(.loaded(.init(token: 2, hostID: UUID()), [.omp])).isEmpty)
    }
}
