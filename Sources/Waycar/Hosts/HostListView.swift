import Observation
import SwiftUI

struct HostRemovalRequest: Equatable {
    let hosts: [Host]

    var title: String {
        if hosts.count == 1, let host = hosts.first {
            return "Remove \(host.displayName)?"
        }
        return "Remove \(hosts.count) Hosts?"
    }

    var actionTitle: String {
        hosts.count == 1 ? "Remove Host" : "Remove Hosts"
    }

    let message =
        "This permanently deletes the Host configuration and any saved password "
        + "from the Keychain. This cannot be undone."
}

@MainActor
@Observable
final class HostRemovalStore {
    private(set) var errorMessage: String?
    private(set) var pendingRequest: HostRemovalRequest?

    @ObservationIgnored
    private let store: HostStore

    init(store: HostStore) {
        self.store = store
    }

    func requestRemoval(_ ids: [Host.ID]) {
        let requestedIDs = Set(ids)
        let hosts = store.hosts.filter { requestedIDs.contains($0.id) }
        guard !hosts.isEmpty else { return }
        pendingRequest = HostRemovalRequest(hosts: hosts)
    }

    func cancelRemoval() {
        pendingRequest = nil
    }

    func confirmRemoval(_ request: HostRemovalRequest) {
        pendingRequest = nil
        for host in request.hosts {
            do {
                try store.remove(host.id)
            } catch {
                errorMessage = "The Host could not be removed. Its saved credentials may still be in the Keychain."
                return
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }
}

/// Host management (#14): the catalog of Hosts with add/edit/remove, each
/// row leading into that Host's onboarding checklist.
struct HostListView: View {
    let store: HostStore
    private let initialHostID: Host.ID?
    private let connectionStatuses: [Host.ID: EventsSessionStatus]
    private let standingFailures: [Host.ID: TransportError]
    private let latencies: [Host.ID: Duration]
    /// Each connected Host's live transport (mosh or SSH).
    private let moshStates: [Host.ID: ConsoleStore.MoshHostCapsuleState]
    /// Re-tests mosh on a Host and upgrades its live SSH sessions.
    private let reprobeMosh: ((Host.ID) -> Void)?
    /// Hosts whose Host-detail Reconnect request is in flight. Distinct from
    /// `EventsSessionStatus.reconnecting`.
    private let manualReconnectInFlightHostIDs: Set<Host.ID>
    private let retryConnection: (@MainActor @Sendable (Host.ID) async -> Void)?
    /// CodexBar detection for the row badge and the Host page's AI Usage
    /// settings; nil where the composition has no AI Usage.
    private let aiUsage: AIUsageStore?
    /// The Console: each Host's backends for the tmux badge, and Host
    /// detail's backend controls. nil where the composition has no Console.
    private let console: ConsoleStore?
    @State private var removal: HostRemovalStore
    @State private var addition: HostAddition?
    @State private var path: [Host.ID] = []
    /// Live latency and CPU / memory / swap while the sheet's list is on
    /// screen; nil where the composition has no Console.
    @State private var telemetry: HostLiveTelemetry?
    @Environment(\.scenePhase) private var scenePhase

    init(
        store: HostStore,
        initialHostID: Host.ID? = nil,
        connectionStatuses: [Host.ID: EventsSessionStatus] = [:],
        standingFailures: [Host.ID: TransportError] = [:],
        latencies: [Host.ID: Duration] = [:],
        moshStates: [Host.ID: ConsoleStore.MoshHostCapsuleState] = [:],
        reprobeMosh: ((Host.ID) -> Void)? = nil,
        manualReconnectInFlightHostIDs: Set<Host.ID> = [],
        retryConnection: (@MainActor @Sendable (Host.ID) async -> Void)? = nil,
        aiUsage: AIUsageStore? = nil,
        console: ConsoleStore? = nil
    ) {
        self.store = store
        self.aiUsage = aiUsage
        self.console = console
        self.initialHostID = initialHostID
        self.connectionStatuses = connectionStatuses
        self.standingFailures = standingFailures
        self.latencies = latencies
        self.moshStates = moshStates
        self.reprobeMosh = reprobeMosh
        self.manualReconnectInFlightHostIDs = manualReconnectInFlightHostIDs
        self.retryConnection = retryConnection
        _removal = State(initialValue: HostRemovalStore(store: store))
        _telemetry = State(initialValue: console.map { HostLiveTelemetry(source: $0) })
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.catalogLoadError != nil {
                    HostCatalogUnavailableView()
                } else if store.hosts.isEmpty {
                    HostSetupGuide(
                        scan: { addition = .scan },
                        addManually: { addition = .manual },
                        findComputersRow: AnyView(FindComputersSetupCard { addition = .find }))
                } else {
                    // The Console's card list: each Host is its own card on
                    // the grouped backdrop.
                    List {
                        ForEach(store.hosts) { host in
                            NavigationLink(value: host.id) {
                                HostCard(
                                    host: host,
                                    connectionStatus: connectionStatuses[host.id],
                                    standingFailure: standingFailures[host.id],
                                    latency: latencies[host.id],
                                    moshState: moshStates[host.id],
                                    resources: HostResourcePresentation(
                                        isEnabled: host.isEnabled,
                                        status: connectionStatuses[host.id],
                                        usage: telemetry?.usage[host.id]),
                                    hasCodexBar: aiUsage?.detection(for: host.id).path != nil,
                                    showsTmuxBadge: TmuxBadge.isShown(
                                        for: console?.backendPresence(on: host.id)),
                                    showsCoreBadge: CoreBadge.isShown(
                                        for: console?.resolvedBackends(on: host.id)),
                                    showsZellijBadge: ZellijBadge.isShown(
                                        for: console?.backendPresence(on: host.id)),
                                    catalog: store)
                                .modifier(AgentCardChrome(isSelected: false))
                            }
                            // No chevron outside the card: the whole card is
                            // the way in.
                            .navigationLinkIndicatorVisibility(.hidden)
                            .hoverEffect(.highlight)
                            .modifier(ConsoleCardRow())
                            // Activating the card opens the Host page;
                            // turning it on or off is a named action instead.
                            .accessibilityAction(named: host.isEnabled ? "Disable" : "Enable") {
                                store.setHostEnabled(!host.isEnabled, for: host.id)
                            }
                            // Explicit swipe actions replace `onDelete`'s, so
                            // Delete is spelled out here beside Duplicate. No
                            // destructive role: that role removes the row from
                            // the list at once, and a cancelled removal then
                            // leaves the list out of step with the catalog,
                            // crashing the next change to it.
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash") {
                                    removal.requestRemoval([host.id])
                                }
                                .tint(Brand.Colors.danger)
                                duplicateButton(for: host)
                                    .tint(Brand.Colors.accent)
                            }
                            .contextMenu {
                                duplicateButton(for: host)
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    removal.requestRemoval([host.id])
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .task(id: isSampling) {
                        guard isSampling else { return }
                        await telemetry?.run()
                    }
                }
            }
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan to Pair", systemImage: "qrcode.viewfinder") {
                        addition = .scan
                    }
                    .disabled(store.catalogLoadError != nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Add Host", systemImage: "plus") {
                        Button("Find Computers", systemImage: "wifi") { addition = .find }
                        Button("Add Manually", systemImage: "square.and.pencil") { addition = .manual }
                    }
                        .disabled(store.catalogLoadError != nil)
                }
            }
            .navigationDestination(for: Host.ID.self) { id in
                if let host = store.hosts.first(where: { $0.id == id }) {
                    // Keyed by the Host's record: editing recreates the
                    // onboarding store so checks run against fresh settings,
                    // while turning it on or off keeps the page (and any
                    // open Edit sheet and VoiceOver focus) in place.
                    HostOnboardingView(
                        host: host,
                        catalog: store,
                        connectionStatus: connectionStatuses[id],
                        standingFailure: standingFailures[id],
                        isManualReconnectInFlight: manualReconnectInFlightHostIDs.contains(id),
                        retryConnection: retryAction(for: id),
                        liveMoshState: moshStates[id],
                        reprobeLiveMosh: reprobeMosh.map { reprobe in { reprobe(id) } },
                        aiUsage: aiUsage,
                        console: console)
                        .id(host.recordForm)
                } else {
                    ContentUnavailableView("Host removed", systemImage: "server.rack")
                }
            }
            .modifier(HostAdditionSheet(store: store, addition: $addition) { id in
                path.append(id)
            })
            .quietCancelAlert(
                removal.pendingRequest?.title ?? "Remove Host?",
                isPresented: removalConfirmationPresented,
                presenting: removal.pendingRequest
            ) { request in
                Button(request.actionTitle, role: .destructive) {
                    removal.confirmRemoval(request)
                }
                Button("Cancel", role: .cancel) {
                    removal.cancelRemoval()
                }
                .tint(Brand.Colors.quietAction)
            } message: { request in
                Text(request.message)
            }
            .quietCancelAlert(
                "Could Not Remove Host",
                isPresented: Binding(
                    get: { removal.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            removal.dismissError()
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    removal.dismissError()
                }
                .tint(Brand.Colors.quietAction)
            } message: {
                Text(removal.errorMessage ?? "")
            }
            .task(id: initialHostID) {
                guard
                    path.isEmpty,
                    let initialHostID,
                    store.hosts.contains(where: { $0.id == initialHostID })
                else { return }
                path.append(initialHostID)
            }
        }
        // Sheets don't take the app root's tint; Toggles default to green.
        .tint(Brand.Colors.accent)
    }

    /// Sampling runs only while the list itself is on screen in an active
    /// app: a pushed Host page or a background app stops it.
    private var isSampling: Bool {
        scenePhase == .active && path.isEmpty
    }

    private var removalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { removal.pendingRequest != nil },
            set: { if !$0 { removal.cancelRemoval() } })
    }

    /// Opens the Add Host form prefilled from `host`, e.g. to reach the same
    /// machine at another network's address.
    private func duplicateButton(for host: Host) -> some View {
        Button("Duplicate", systemImage: "plus.square.on.square") {
            addition = .duplicate(host.recordForm)
        }
    }

    private func retryAction(
        for id: Host.ID
    ) -> (@MainActor @Sendable () async -> Void)? {
        guard let retryConnection else { return nil }
        return { await retryConnection(id) }
    }
}

/// The saved Host catalog could not be read. Nothing offers to add a Host
/// here: saving one would risk the preserved original.
struct HostCatalogUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Hosts Unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(
                "The saved Host catalog could not be read. Its original data was preserved; "
                    + "reinstalling or adding a Host would risk losing it.")
        }
    }
}

/// The status chip on a Host card. Chips render Host Connection Status, never
/// a Transport Error Presentation — even on `.failed`, where they say
/// "Unavailable". See Transport Error Presentation in `CONTEXT.md`. A
/// runtime installed but stopped (`TransportError.startableRuntime`, #389)
/// is a normal state, not an outage: "Not running", in the quiet tone.
struct HostConnectionPresentation: Equatable {
    enum Tone: Equatable {
        case connected
        case pending
        case warning
        case unavailable
    }

    let title: String
    let accessibilityLabel: String
    let tone: Tone

    init(
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        latency: Duration?
    ) {
        let failure: TransportError? =
            switch status {
            case .failed(let error): error
            case .connecting: standingFailure
            default: nil
            }
        if let runtime = failure?.startableRuntime {
            title = "Not running"
            accessibilityLabel = "\(runtime.displayName) is not running"
            tone = .pending
            return
        }
        switch status {
        case .connected:
            if let latency {
                let formattedLatency = HostLatencyFormatting.formatted(latency)
                title = formattedLatency
                accessibilityLabel = "Connected, latency \(formattedLatency)"
            } else {
                title = "Measuring…"
                accessibilityLabel = "Connected, measuring latency"
            }
            tone = .connected
        case .reconnecting:
            title = "Reconnecting…"
            accessibilityLabel = "Reconnecting"
            tone = .warning
        case .connecting:
            if standingFailure != nil {
                title = "Unavailable"
                accessibilityLabel = "Unavailable"
                tone = .unavailable
            } else {
                title = "Connecting…"
                accessibilityLabel = "Connecting"
                tone = .pending
            }
        case .failed, .ended:
            title = "Unavailable"
            accessibilityLabel = "Unavailable"
            tone = .unavailable
        case .suspended:
            title = "Paused"
            accessibilityLabel = "Connection paused"
            tone = .pending
        case nil:
            title = "Connecting…"
            accessibilityLabel = "Connecting"
            tone = .pending
        }
    }
}

#Preview {
    HostListView(store: HostStore(secrets: PreviewSecretStore()))
}

/// Keeps previews out of the real Keychain.
private final class PreviewSecretStore: SecretStore {
    func read(account: String) throws -> Data? { nil }
    func readAll() throws -> [String: Data] { [:] }
    func write(_ secret: Data, account: String) throws {}
    func removeSecret(account: String) throws {}
}
