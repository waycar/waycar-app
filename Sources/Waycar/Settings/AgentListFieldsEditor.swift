import Foundation
import Observation

/// Per-Host layout edits. The draft session (`beginEditing`, `update`,
/// `save`, `cancel`) validates a batch and writes it in one step; `commit`
/// wraps that session around a single change. `replaceWithPluginFields`
/// persists one Host independently so overlapping inline syncs do not end
/// each other's requests.
/// Hosts without a saved choice show their herdr fields, or Waycar's
/// fallback when the plugin has none or the Host runs tmux only.
@MainActor
@Observable
final class AgentListFieldsEditor {
    typealias SyncState = AgentListFieldsSyncMachine.DisplayState

    enum LayoutSource: Equatable {
        case draft, saved, plugin, pluginDefaults, loading, missing, unavailable
        /// A tmux-only Host: no herdr plugin, so Waycar's fields until the
        /// user saves their own (ADR 0026).
        case builtIn
    }

    typealias Fetch = @MainActor (Host.ID) async -> HerdrSidebarSnapshotStore.HostState?

    let layouts: AgentRowLayoutStore
    let snapshots: HerdrSidebarSnapshotStore
    private let fetch: Fetch
    /// The backends each Host runs (`ConsoleStore.presentBackends`).
    private let backends: (Host.ID) -> [HostBackend]
    private var editing = AgentListFieldsEditingMachine()
    var isEditing: Bool { editing.isEditing }
    var drafts: [Host.ID: AgentRowLayout] { editing.drafts }
    private var pluginSync = AgentListFieldsSyncMachine()
    var syncStates: [Host.ID: SyncState] { pluginSync.displays }
    var errorMessage: String? {
        get { editing.message }
        set { send(.messageChanged(newValue)) }
    }

    init(
        layouts: AgentRowLayoutStore, snapshots: HerdrSidebarSnapshotStore,
        backends: @escaping (Host.ID) -> [HostBackend] = { _ in [.herdr] },
        fetch: @escaping Fetch
    ) {
        self.layouts = layouts
        self.snapshots = snapshots
        self.backends = backends
        self.fetch = fetch
    }

    /// Whether the Host has herdr plugin fields to follow and Sync from. A
    /// tmux-only or herdr-core Host has none (`pluginRowLayout`); a Host with
    /// both herdr and tmux edits its herdr rows' fields.
    func hasPluginFields(for hostID: Host.ID) -> Bool {
        backends(hostID).contains { $0.capabilities.pluginRowLayout }
    }

    /// Whether the Host also lists tmux rows beside herdr's, which follow
    /// these fields only once they are saved.
    func listsTmuxBesidePlugin(for hostID: Host.ID) -> Bool {
        let backends = backends(hostID)
        return backends.contains { $0.capabilities.pluginRowLayout } && backends.contains(.tmux)
    }

    func listsZellijBesidePlugin(for hostID: Host.ID) -> Bool {
        let backends = backends(hostID)
        return backends.contains { $0.capabilities.pluginRowLayout } && backends.contains(.zellij)
    }

    /// The Console's layout for this Host, or its draft while editing. On a
    /// Host with both backends this is the herdr rows' layout.
    func layout(for hostID: Host.ID) -> AgentRowLayout {
        if isEditing, let draft = drafts[hostID] { return draft }
        return layouts.resolvedLayout(
            for: hostID, pluginSnapshot: snapshots.snapshot(for: hostID),
            backend: hasPluginFields(for: hostID) ? .herdr : .tmux)
    }

    func source(for hostID: Host.ID) -> LayoutSource {
        if isEditing, drafts[hostID] != nil { return .draft }
        return underlyingSource(for: hostID)
    }

    /// Saved or snapshot provenance, ignoring an in-memory draft. Never `.draft`.
    func underlyingSource(for hostID: Host.ID) -> LayoutSource {
        if layouts.hostLayouts[hostID] != nil { return .saved }
        guard hasPluginFields(for: hostID) else { return .builtIn }
        switch snapshots.states[hostID] {
        case .loading: return .loading
        case .loaded(let snapshot?): return snapshot.diagnostics.isEmpty ? .plugin : .pluginDefaults
        case .loaded(nil): return .missing
        case .unavailable, nil: return .unavailable
        }
    }

    /// Hosts whose draft would be written by Save. Compared to the optional
    /// saved layout, not to effective plugin rows: syncing a plugin copy onto
    /// a Host with no saved choice stays dirty.
    var dirtyHostIDs: Set<Host.ID> {
        Set(drafts.compactMap { hostID, layout in
            layout != layouts.hostLayouts[hostID] ? hostID : nil
        })
    }

    /// True when Save would change the persisted catalog.
    var hasUnsavedChanges: Bool {
        !dirtyHostIDs.isEmpty
    }

    func beginEditing() {
        send(.begin)
    }

    func cancel() {
        send(.cancel)
    }

    /// All changed Hosts are written in one validated step; a failed write
    /// keeps the drafts and stays in edit mode.
    func save() {
        guard isEditing else { return }
        let changes = drafts.filter { $0.value != layouts.hostLayouts[$0.key] }
            .mapValues { Optional($0) }
        send(.save(changes))
    }

    func update(_ hostID: Host.ID, _ edit: (inout AgentRowLayout) -> Void) {
        guard isEditing else { return }
        var next = layout(for: hostID)
        edit(&next)
        do {
            try next.validate()
            try next.validateForConsole()
        } catch {
            report(error)
            return
        }
        send(.edited(hostID, next))
    }

    func setRows(_ rows: [AgentRow], kind: String?, for hostID: Host.ID) {
        update(hostID) {
            if let kind { $0.rowsByAgent[kind] = rows }
            else { $0.rows = rows }
        }
    }

    /// One inline change, validated and persisted at once. A no-op, invalid,
    /// or unsaveable change writes nothing and returns false, keeping its
    /// message in `errorMessage` and no draft behind: the screens show what
    /// is persisted, never a change that failed to save. Inside an open draft
    /// session the change joins that session and `save` writes every dirty
    /// Host; a failed save then keeps the session, as `save` documents.
    @discardableResult
    func commit(_ hostID: Host.ID, _ edit: (inout AgentRowLayout) -> Void) -> Bool {
        let wasEditing = isEditing
        if !wasEditing { beginEditing() }
        let before = layout(for: hostID)
        update(hostID, edit)
        if errorMessage != nil {
            if !wasEditing { discardKeepingError() }
            return false
        }
        guard layout(for: hostID) != before else {
            if !wasEditing { cancel() }
            return false
        }
        save()
        if isEditing, !wasEditing {
            discardKeepingError()
            return false
        }
        return !isEditing
    }

    /// Inline Sync from plugin: fills the Host from its plugin snapshot and
    /// saves immediately. The resulting `syncStates` entry survives the save
    /// so the screen can report what happened; the next change clears it.
    func replaceWithPluginFields(_ hostID: Host.ID, hostName: String = "this Host") async {
        await syncFromPlugin(hostID, hostName: hostName, saveImmediately: true)
    }

    /// Fetches the Host's first two plugin rows, row gap, and token styles,
    /// preserving its Waycar row. A missing snapshot fills fallback fields; a failed
    /// read leaves the draft unchanged. Results are dropped once editing
    /// ended or the draft was edited since. Draft-only; the screen uses
    /// `replaceWithPluginFields`.
    ///
    /// `hostName` is only interpolated into the unread-snapshot failure copy.
    /// The one-argument call stays valid and uses "this Host".
    func syncFromPlugin(_ hostID: Host.ID, hostName: String = "this Host") async {
        await syncFromPlugin(hostID, hostName: hostName, saveImmediately: false)
    }

    private func syncFromPlugin(
        _ hostID: Host.ID, hostName: String, saveImmediately: Bool
    ) async {
        // A tmux-only Host has no plugin fields to sync from.
        guard (saveImmediately || isEditing), hasPluginFields(for: hostID) else { return }
        let effects = pluginSync.handle(.start(hostID, saveImmediately: saveImmediately))
        guard case .fetch(let request) = effects.first else { return }
        let thirdRow = AgentRowSlot.slotRows(layout(for: hostID).rows)[AgentRowSlot.herdrRowCount]
        let state = await fetch(hostID)
        let outcome: AgentListFieldsSyncMachine.Outcome
        switch state {
        case .loaded(let snapshot?):
            outcome = .replacement(snapshot.layout.withWaycarRow(thirdRow), message:
                snapshot.diagnostics.isEmpty
                    ? "Replaced with plugin fields."
                    : "herdr reported a configuration problem, so its default fields were used.")
        case .loaded(nil):
            outcome = .replacement(AgentRowLayout.waycarDefault.withWaycarRow(thirdRow), message:
                "This Host has no plugin fields snapshot, so Waycar's fallback fields were used.")
        case .unavailable:
            outcome = .failed("Couldn't reach \(hostName). Rows unchanged.")
        case .loading, nil:
            outcome = .failed("You're offline. Rows unchanged.")
        }
        sendSync(.received(hostID, request, outcome))
    }

    /// True while the saved catalog cannot be read: edits are refused until
    /// `resetSavedFields` discards it.
    var isCatalogUnreadable: Bool {
        layouts.catalogLoadError != nil
    }

    /// Discards the unreadable catalog together with any draft session, so
    /// the screens return to each Host's herdr fields.
    func resetSavedFields() {
        layouts.resetUnreadableCatalog()
        cancel()
    }

    private func discardKeepingError() {
        let message = errorMessage
        cancel()
        errorMessage = message
    }

    private func send(_ event: AgentListFieldsEditingMachine.Event) {
        for effect in editing.handle(event) {
            switch effect {
            case .invalidateAllSyncs:
                sendSync(.invalidateAll)
            case .invalidateSync(let hostID):
                sendSync(.invalidate(hostID))
            case .persist(let changes):
                do {
                    try layouts.setLayouts(changes)
                    send(.saved)
                } catch {
                    report(error)
                }
            }
        }
    }

    private func sendSync(_ event: AgentListFieldsSyncMachine.Event) {
        for effect in pluginSync.handle(event) {
            switch effect {
            case .fetch:
                break // Started and awaited by syncFromPlugin.
            case .applyLayout(let hostID, let token, let replacement, let saveImmediately):
                do {
                    if saveImmediately {
                        try layouts.setLayout(replacement, for: hostID)
                        send(.syncDraft(hostID, nil))
                    } else {
                        send(.syncDraft(hostID, replacement))
                    }
                    sendSync(.applied(hostID, token))
                } catch {
                    sendSync(.applyFailed(hostID, token, message(for: error)))
                }
            case .clearError:
                errorMessage = nil
            case .reportError(let message):
                errorMessage = message
            }
        }
    }

    private func report(_ error: any Error) {
        errorMessage = message(for: error)
    }

    private func message(for error: any Error) -> String {
        error is AgentRowLayoutStoreError
            ? AgentListFieldsCopy.unreadableCatalogEdit
            : "This layout could not be saved. Use at most 3 rows and 16 fields per row, with valid field names."
    }
}
