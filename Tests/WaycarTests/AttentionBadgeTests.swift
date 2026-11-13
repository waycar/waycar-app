import Foundation
import Testing

@testable import Waycar

/// The Attention Badge: Blocked + Done Agents summed across Hosts, from
/// per-Host counts the app (live) and the Notification Service Extension
/// (push) both write into one app-group store.
@MainActor
@Suite("Attention badge")
struct AttentionBadgeTests {
    private let hostA = Host.fixture(name: "alpha")
    private let hostB = Host.fixture(name: "bravo")
    private let hostC = Host.fixture(name: "charlie")

    private func temporaryStore() throws -> AttentionBadgeStore {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return AttentionBadgeStore(containerURL: container)
    }

    private func push(attention: Int?, at timestamp: TimeInterval = 1_753_305_600)
        -> NotificationPayload
    {
        NotificationPayload(
            paneID: "w1:p1", agentKind: "claude", status: .blocked,
            timestamp: Date(timeIntervalSince1970: timestamp), attention: attention)
    }

    private func agent(_ host: Host, _ paneID: String, _ status: AgentStatus) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID, status: status)),
            workspaceLabel: nil, repositoryCheckout: nil)
    }

    private func shell(_ host: Host, _ paneID: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(
                terminalID: "term-\(paneID)", kind: Agent.shellKind, title: "zsh",
                status: .blocked, workspaceID: "w1", tabID: "w1:t1", paneID: paneID,
                cwd: "/srv", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil)
    }

    // MARK: Store

    @Test func aPushReplacesOnlyItsHostsShareOfTheSum() throws {
        let store = try temporaryStore()

        #expect(store.badge(after: push(attention: 2), from: hostA.id) == 2)
        #expect(store.badge(after: push(attention: 3), from: hostB.id) == 5)
        #expect(store.badge(after: push(attention: 0), from: hostA.id) == 3)
        #expect(store.counts() == [hostA.id: 0, hostB.id: 3])
    }

    @Test func aPushWithoutACountLeavesTheBadgeAlone() throws {
        let store = try temporaryStore()
        _ = store.badge(after: push(attention: 2), from: hostA.id)

        #expect(store.badge(after: push(attention: nil), from: hostA.id) == nil)
        #expect(store.badge(after: push(attention: nil), from: hostB.id) == nil)
        #expect(store.counts() == [hostA.id: 2])
    }

    @Test func replaceDropsRemovedHostsAndKeepsUnknownOnes() throws {
        let store = try temporaryStore()
        _ = store.badge(after: push(attention: 1), from: hostA.id)
        _ = store.badge(after: push(attention: 2), from: hostB.id)
        _ = store.badge(after: push(attention: 4), from: hostC.id)

        let totals = store.replace([hostA.id: 0], pruningTo: [hostA.id, hostB.id])

        #expect(totals.previous == 7)
        #expect(totals.current == 2)
        #expect(store.counts() == [hostA.id: 0, hostB.id: 2])
    }

    @Test func storedCountsAreClampedAndTheSumNeverOverflows() throws {
        let store = try temporaryStore()
        let directory = try #require(store.containerURL)
            .appendingPathComponent("attention-badge", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for host in [hostA, hostB] {
            try Data(#"{"v":1,"attention":\#(Int.max)}"#.utf8)
                .write(to: directory.appendingPathComponent(host.id.uuidString + ".json"))
        }
        let cap = NotificationPayload.maximumAttention

        #expect(store.counts() == [hostA.id: cap, hostB.id: cap])
        #expect(store.badge(after: push(attention: 1), from: hostC.id) == 2 * cap + 1)
        #expect(store.replace([:], pruningTo: [hostA.id, hostB.id]).current == 2 * cap)
    }

    @Test func aRemovedHostsPushNoLongerCounts() throws {
        let store = try temporaryStore()
        _ = store.replace([hostA.id: 1], pruningTo: [hostA.id])

        // B's Notification Key outlived its removal, so its pushes still
        // decrypt; the badge must not count them.
        #expect(store.badge(after: push(attention: 4), from: hostB.id) == 1)
        #expect(store.counts() == [hostA.id: 1])
    }

    @Test func aPushOlderThanTheStoredCountIsIgnored() throws {
        let store = try temporaryStore()
        _ = store.badge(after: push(attention: 2, at: 1_753_305_610), from: hostA.id)

        // The earlier transition's push, delivered late, carries a stale count.
        #expect(store.badge(after: push(attention: 1, at: 1_753_305_600), from: hostA.id) == 2)
        #expect(store.badge(after: push(attention: 3, at: 1_753_305_620), from: hostA.id) == 3)
    }

    // MARK: Inventory

    @Test func inventoryCountsBlockedAndDonePerKnownHostWithoutShells() {
        let hostD = Host.fixture(name: "delta")
        let inventory = AttentionBadgeCoordinator.Inventory(
            agents: [
                agent(hostA, "a1", .blocked),
                agent(hostA, "a2", .done),
                agent(hostA, "a3", .working),
                agent(hostA, "a4", .idle),
                shell(hostA, "a5"),
                agent(hostB, "b1", .blocked),
                agent(hostC, "c1", .done),
            ],
            hosts: [hostA, hostB, hostC, hostD],
            hostStatuses: [hostA.id: .connected, hostB.id: .connected, hostC.id: .suspended,
                           hostD.id: .connected],
            hostsAwaitingSnapshot: [hostB.id])

        // B is still loading and C is suspended: their inventories are
        // unknown, so they contribute no live count. D is known and empty.
        #expect(inventory.known == [hostA.id: 2, hostD.id: 0])
        #expect(inventory.catalog == [hostA.id, hostB.id, hostC.id, hostD.id])
    }

    // MARK: Coordinator

    @Test func setsTheBadgeAtLaunchThenOnlyWhenTheSumMoves() throws {
        let store = try temporaryStore()
        _ = store.badge(after: push(attention: 3), from: hostB.id)
        let badge = BadgeRecorder()
        let coordinator = AttentionBadgeCoordinator(store: store, apply: badge.record)
        let catalog: Set<Host.ID> = [hostA.id, hostB.id]

        // Launch: nothing live yet, the stored sum still sets the badge.
        coordinator.inventoryDidChange(.init(known: [:], catalog: catalog))
        // A connects with one Agent needing attention; B stays unknown and
        // keeps the count its last push reported.
        coordinator.inventoryDidChange(.init(known: [hostA.id: 1], catalog: catalog))
        coordinator.inventoryDidChange(.init(known: [hostA.id: 1], catalog: catalog))
        // A push from B lands in the store; the next live change on A sums it.
        _ = store.badge(after: push(attention: 5), from: hostB.id)
        coordinator.inventoryDidChange(.init(known: [hostA.id: 0], catalog: catalog))
        // B is deleted from the catalog.
        coordinator.inventoryDidChange(.init(known: [hostA.id: 0], catalog: [hostA.id]))

        #expect(badge.values == [3, 4, 5, 0])
    }

    @Test func noHostsMeansAZeroBadge() throws {
        let store = try temporaryStore()
        _ = store.badge(after: push(attention: 2), from: hostA.id)
        let badge = BadgeRecorder()
        let coordinator = AttentionBadgeCoordinator(store: store, apply: badge.record)

        coordinator.inventoryDidChange(.init(known: [:], catalog: []))

        #expect(badge.values == [0])
        #expect(store.counts().isEmpty)
    }
}

@MainActor
private final class BadgeRecorder {
    private(set) var values: [Int] = []

    func record(_ value: Int) {
        values.append(value)
    }
}
