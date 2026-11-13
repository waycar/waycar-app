import Foundation
import Observation

/// Read-only snapshots borrowed from the Console's existing connections.
/// A Host's layout outlives its connection: disconnect stops reading, not
/// displaying the last layout (including one seeded from the inventory cache).
@MainActor
@Observable
final class HerdrSidebarSnapshotStore {
    enum HostState: Equatable, Sendable {
        case loading
        case loaded(AgentRowLayoutSnapshot?)
        case unavailable
    }

    struct Connection: Equatable, Sendable {
        let generation: UInt64
        let revision: UInt64
    }

    /// Output projections only. Keeping the visible dictionary separate from
    /// read bookkeeping avoids invalidating every Console row on each read.
    private(set) var states: [Host.ID: HostState] = [:]
    @ObservationIgnored private(set) var layoutFiles: [Host.ID: ConsoleInventoryCache.SidebarLayout] = [:]
    @ObservationIgnored private var reads: [Host.ID: SidebarSnapshotMachine] = [:]
    @ObservationIgnored private var tasks: [Host.ID: [UInt64: Task<Void, Never>]] = [:]

    func snapshot(for hostID: Host.ID) -> AgentRowLayoutSnapshot? {
        guard case .loaded(let snapshot) = states[hostID] else { return nil }
        return snapshot
    }

    func seed(_ hostID: Host.ID, layout: ConsoleInventoryCache.SidebarLayout) {
        for effect in reads[hostID, default: SidebarSnapshotMachine()].handle(.seed(layout)) {
            if case .publish(let facts) = effect { apply(facts, to: hostID) }
        }
    }

    /// Only connected, snapshot-ready Hosts can borrow a transport. Revision
    /// changes replace a read even when the connection generation is unchanged.
    func reconcile(
        _ next: [Host.ID: Connection],
        transports: any NotificationTransportProvider,
        didChange: @escaping @MainActor @Sendable () -> Void
    ) {
        for id in Array(reads.keys) where next[id] == nil && reads[id]?.connection != nil {
            disconnect(id)
        }
        for (id, connection) in next {
            send(.reconcile(connection), to: id, transports: transports, didChange: didChange)
        }
    }

    func invalidate(_ hostID: Host.ID) {
        let effects = reads[hostID, default: SidebarSnapshotMachine()].handle(.invalidate)
        for effect in effects {
            switch effect {
            case .cancel(let token): tasks[hostID]?.removeValue(forKey: token)?.cancel()
            case .publish(let facts): apply(facts, to: hostID)
            case .read, .didChange: break
            }
        }
        tasks[hostID] = nil
    }

    private func disconnect(_ hostID: Host.ID) {
        let effects = reads[hostID]?.handle(.reconcile(nil)) ?? []
        for effect in effects {
            if case .cancel(let token) = effect { tasks[hostID]?.removeValue(forKey: token)?.cancel() }
        }
        tasks[hostID] = nil
    }

    func refresh(
        transports: any NotificationTransportProvider,
        didChange: @escaping @MainActor @Sendable () -> Void
    ) async {
        for id in Array(reads.keys) where reads[id]?.connection != nil {
            send(.refresh, to: id, transports: transports, didChange: didChange)
        }
        await waitForPendingReads()
    }

    /// Returns the read's own answer, not the retained layout. A superseded
    /// refresh follows the replacement read, as before.
    func refresh(
        _ hostID: Host.ID,
        transports: any NotificationTransportProvider,
        didChange: @escaping @MainActor @Sendable () -> Void
    ) async -> HostState? {
        guard reads[hostID]?.connection != nil else { return nil }
        send(.refresh, to: hostID, transports: transports, didChange: didChange)
        while let task = tasks[hostID]?.values.first { await task.value }
        return reads[hostID]?.facts.answer ?? states[hostID]
    }

    func waitForPendingReads() async {
        while !tasks.isEmpty {
            let pending = tasks.values.flatMap { $0.values }
            for task in pending { await task.value }
        }
    }

    private func apply(_ facts: SidebarSnapshotMachine.Facts, to id: Host.ID) {
        // Even an equal subscript write notifies Observation. Same-layout
        // refreshes must remain invisible to the Console and terminal switcher.
        if states[id] != facts.displayed { states[id] = facts.displayed }
        layoutFiles[id] = facts.file
    }

    private func send(
        _ event: SidebarSnapshotMachine.Event,
        to id: Host.ID,
        transports: any NotificationTransportProvider,
        didChange: @escaping @MainActor @Sendable () -> Void
    ) {
        for effect in reads[id, default: SidebarSnapshotMachine()].handle(event) {
            switch effect {
            case .cancel(let token):
                tasks[id]?.removeValue(forKey: token)?.cancel()
                if tasks[id]?.isEmpty == true { tasks[id] = nil }
            case .publish(let facts):
                apply(facts, to: id)
            case .didChange:
                didChange()
            case .read(let token):
                tasks[id, default: [:]][token] = Task { [weak self] in
                    let outcome: SidebarSnapshotMachine.Outcome
                    do {
                        outcome = .loaded(try await transports.readHerdrSidebarLayout(for: id))
                    } catch is TransportError {
                        outcome = .connectionFailed
                    } catch {
                        outcome = .failed
                    }
                    guard let self, !Task.isCancelled else { return }
                    tasks[id]?.removeValue(forKey: token)
                    if tasks[id]?.isEmpty == true { tasks[id] = nil }
                    send(.finished(token, outcome), to: id, transports: transports, didChange: didChange)
                }
            }
        }
    }
}
