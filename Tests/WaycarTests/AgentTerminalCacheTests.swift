import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Retained Agent terminals")
struct AgentTerminalCacheTests {
    @Test func selectionIsLazyAndReturningKeepsTheLiveAgentPipeline() async throws {
        let (host, transport, console, agent) = try await connectedAgent()
        let cache = AgentTerminalCache()
        let owner = UUID()
        let composer = console.composerStore(for: agent)
        let first = cache.acquire(agent: agent, console: console, composer: composer, ownerID: owner)
        #expect(await transport.attachRequests.isEmpty)
        first.attach.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { await transport.hasLiveAttachSession }
        let surfaceID = first.attach.terminalID

        cache.release(first, ownerID: owner)
        #expect(await transport.hasLiveAttachSession)
        let returned = cache.acquire(agent: agent, console: console, composer: composer, ownerID: owner)
        #expect(returned === first)
        #expect(returned.attach.terminalID == surfaceID)
        #expect(await transport.attachRequests.count == 1)
        await cache.suspend()
        #expect(await transport.hasLiveAttachSession == false)
        #expect(cache.entries.isEmpty)
        console.setHosts([])
        #expect(host.id == agent.hostID)
    }

    @Test func expiryStopsAnIdleAgentWithoutClosingItsRemotePane() async throws {
        let (_, transport, console, agent) = try await connectedAgent()
        let cache = AgentTerminalCache(idleTimeout: .milliseconds(20))
        let owner = UUID()
        let entry = cache.acquire(
            agent: agent, console: console, composer: console.composerStore(for: agent), ownerID: owner)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { await transport.hasLiveAttachSession }
        cache.release(entry, ownerID: owner)
        try await waitUntil { cache.entries.isEmpty && !entry.isRetained }
        try await waitUntil { await transport.hasLiveAttachSession == false }
        #expect(await transport.closedPanes.isEmpty)
        await cache.suspend()
        console.setHosts([])
    }

    @Test func anotherWindowGetsAFreshSurfaceAndOldReleaseCannotRetireIt() async throws {
        let (_, transport, console, agent) = try await connectedAgent()
        let cache = AgentTerminalCache()
        let firstOwner = UUID()
        let secondOwner = UUID()
        let composer = console.composerStore(for: agent)
        let first = cache.acquire(agent: agent, console: console, composer: composer, ownerID: firstOwner)
        first.attach.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { await transport.hasLiveAttachSession }
        let second = cache.acquire(agent: agent, console: console, composer: composer, ownerID: secondOwner)
        #expect(first !== second)
        #expect(!first.isRetained)
        second.attach.viewDidResize(cols: 80, rows: 24)
        cache.release(first, ownerID: firstOwner)
        try await waitUntil { await transport.attachRequests.count == 2 }
        #expect(cache.entries[agent.id] === second)
        #expect(second.isRetained)
        await cache.suspend()
        console.setHosts([])
    }

    @Test func obsoleteSnapshotCannotEvictASelectedAgent() async throws {
        let (_, _, console, agent) = try await connectedAgent()
        let cache = AgentTerminalCache()
        let entry = cache.acquire(
            agent: agent, console: console, composer: console.composerStore(for: agent), ownerID: UUID())
        await cache.reconcile(hostID: agent.hostID, agents: [], isCurrent: { false })
        #expect(cache.entries[agent.id] === entry)
        await cache.reconcile(hostID: agent.hostID, agents: [])
        #expect(cache.entries.isEmpty)
        await cache.suspend()
        console.setHosts([])
    }

    @Test func changedRouteAllowsAgentEvictionBeforeItsViewDisappears() async throws {
        let (_, transport, console, agent) = try await connectedAgent()
        let budget = TerminalRetentionBudget(maximumPerHost: 3)
        let cache = AgentTerminalCache(budget: budget)
        let presentation = AgentPresentationProbe()
        let entry = cache.acquire(
            agent: agent, console: console, composer: console.composerStore(for: agent), ownerID: UUID(),
            isPresented: { presentation.isPresented })
        entry.attach.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { await transport.hasLiveAttachSession }
        for id in ["shell-one", "shell-two"] {
            try await budget.admit(key: .init(hostID: agent.hostID, terminalID: id), ownerID: UUID(),
                                   isVisible: { true }, onEvict: {})
        }
        presentation.isPresented = false
        try await budget.admit(key: .init(hostID: agent.hostID, terminalID: "next"), ownerID: UUID(),
                               isVisible: { true }, onEvict: {})
        #expect(!entry.isRetained)
        #expect(cache.entries.isEmpty)
        #expect(await transport.hasLiveAttachSession == false)
        await cache.suspend()
        console.setHosts([])
    }

    @Test func completingAnOldRemovalKeepsItsReplacementTeardownTracked() async throws {
        let (host, transport, console, agent) = try await connectedAgent()
        let cache = AgentTerminalCache()
        let composer = console.composerStore(for: agent)
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let first = cache.acquire(
            agent: agent, console: console, composer: composer, ownerID: UUID())
        first.attach.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { await transport.hasLiveAttachSession }
        let removing = Task { await cache.removeHost(host.id) }
        await endGate.waitForEntry()

        let replacement = cache.acquire(
            agent: agent, console: console, composer: composer, ownerID: UUID())
        let reconciling = Task { await cache.reconcile(hostID: host.id, agents: []) }
        try await waitUntil { !replacement.isRetained }
        // Inspect ownership without exposing teardown bookkeeping in the production API.
        func trackedTeardown() -> Task<Void, Never>? {
            let tasks = Mirror(reflecting: cache).children.first { $0.label == "teardowns" }?.value
                as? [ConsoleAgent.ID: Task<Void, Never>]
            return tasks?[agent.id]
        }
        let newer = try #require(trackedTeardown())
        await endGate.open()
        await removing.value
        await reconciling.value
        #expect(trackedTeardown() == newer)
        await cache.suspend()
        console.setHosts([])
    }

    @Test func suspendEndsEveryHostsTerminalsTogether() async throws {
        let hosts = [Host.fixture(), Host.fixture()]
        let transports = Dictionary(uniqueKeysWithValues: hosts.map {
            ($0.id, ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")])))
        })
        let console = ConsoleStore { host, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: {
                guard let transport = transports[host.id] else {
                    throw TransportError.sshUnreachable(detail: "unscripted host")
                }
                return transport
            }, keepalive: nil)
        }
        console.setHosts(hosts)
        await console.resume()
        try await waitUntil { console.agents.count == 2 }
        let cache = AgentTerminalCache()
        // Each teardown waits here, as ending a mosh terminal waits for a
        // Host that does not answer.
        let gate = ScriptedTransportCallGate()
        for agent in console.agents {
            let transport = try #require(transports[agent.hostID])
            await transport.gateNextAttachEnd(on: gate)
            let entry = cache.acquire(
                agent: agent, console: console, composer: console.composerStore(for: agent), ownerID: UUID())
            entry.attach.viewDidResize(cols: 80, rows: 24)
            try await waitUntil { await transport.hasLiveAttachSession }
        }

        let suspending = Task { await cache.suspend() }
        // Serially, the second teardown would start only after the first
        // ended: suspension's background time would pay for each in turn.
        let bothStarted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await gate.waitForEntry(count: 2)
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            await gate.open()
            group.cancelAll()
            return first
        }
        await suspending.value

        #expect(bothStarted, "suspension must start every Host's teardown before awaiting any")
        #expect(cache.entries.isEmpty)
        console.setHosts([])
    }

    private func connectedAgent() async throws -> (Host, ScriptedTransport, ConsoleStore, ConsoleAgent) {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let console = ConsoleStore { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        console.setHosts([host])
        await console.resume()
        try await waitUntil { console.agents.count == 1 }
        return (host, transport, console, try #require(console.agents.first))
    }
}

@MainActor
private final class AgentPresentationProbe {
    var isPresented = true
}
