import Foundation
import UserNotifications

/// Keeps the app icon's Attention Badge — Agents needing attention (Blocked
/// or Done) summed across every Host — exact while the app holds its Host
/// connections.
///
/// Each Host whose Agent Inventory is known contributes its live count; a
/// Host whose inventory is unknown (connecting, failed, suspended, awaiting
/// its first snapshot) keeps the count last stored for it, by this app or by
/// the Notification Service Extension from a push. Hosts that left the
/// catalog are dropped. The counts live in `AttentionBadgeStore`, shared with
/// the extension, so both sides sum the same numbers.
///
/// Counted from each Agent's live status, never the status a window's open
/// Agent was held under: opening a Done Agent turns it Idle on its Host,
/// which is exactly when it stops needing attention.
@MainActor
final class AttentionBadgeCoordinator {
    /// What the badge is derived from. Equatable so the app only reacts when
    /// a count or a Host's knownness actually changes.
    struct Inventory: Equatable {
        /// The attention count of every Host whose Agent Inventory is known.
        var known: [Host.ID: Int]
        /// The Host catalog; stored counts outside it are dropped.
        var catalog: Set<Host.ID>

        init(known: [Host.ID: Int], catalog: Set<Host.ID>) {
            self.known = known
            self.catalog = catalog
        }

        /// Counts Blocked and Done Agents per Host, shells excluded (they
        /// have no Agent Status), for the Hosts that are Connected with a
        /// snapshot in hand.
        init(
            agents: [ConsoleAgent], hosts: [Host],
            hostStatuses: [Host.ID: EventsSessionStatus], hostsAwaitingSnapshot: Set<Host.ID>
        ) {
            let attentionByHost = Dictionary(
                grouping: agents.filter { ConsoleStatusFilter.attention.matches($0) }, by: \.hostID)
            var known: [Host.ID: Int] = [:]
            for host in hosts
            where hostStatuses[host.id] == .connected && !hostsAwaitingSnapshot.contains(host.id) {
                known[host.id] = attentionByHost[host.id]?.count ?? 0
            }
            self.init(known: known, catalog: Set(hosts.map(\.id)))
        }
    }

    private let store: AttentionBadgeStore
    private let apply: @MainActor (Int) -> Void
    private var hasApplied = false
    private var lastInventory: Inventory?

    init(
        store: AttentionBadgeStore = AttentionBadgeStore(),
        apply: @escaping @MainActor (Int) -> Void = { count in
            UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: nil)
        }
    ) {
        self.store = store
        self.apply = apply
    }

    /// Stores the known counts and sets the badge when the stored total
    /// moved. The first call always sets it, so a badge left stale by an
    /// earlier run is corrected at launch.
    func inventoryDidChange(_ inventory: Inventory) {
        lastInventory = inventory
        let totals = store.replace(inventory.known, pruningTo: inventory.catalog)
        guard !hasApplied || totals.previous != totals.current else { return }
        hasApplied = true
        apply(totals.current)
    }

    /// A push arrived while the app is running: the extension has already
    /// stored the count it carried, which can be older than what the app
    /// knows live (the Host counted before its debounce and delivery).
    /// Re-stores the live counts over it and always sets the badge, so the
    /// app stays the one source of the foreground badge.
    func pushDidArrive() {
        guard let lastInventory else { return }
        hasApplied = true
        apply(store.replace(lastInventory.known, pruningTo: lastInventory.catalog).current)
    }
}
