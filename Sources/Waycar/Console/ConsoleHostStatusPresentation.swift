import Foundation

/// One Console list row for a Host's connection or snapshot condition.
///
/// Quiet rows (Paused, Connecting, Loading Agents) are informational and
/// do not navigate to Host settings. Failed and reconnecting rows still do,
/// and so does a connection held for an untrusted host key: the user
/// answers it on the Host page.
///
/// A Host inside its reconnect grace (last-known rows on screen, not yet
/// verified, not yet past the threshold) shows no row for the conditions
/// that resolve themselves. A failure that needs the user — Failed, or a
/// Standing Failure carried into Connecting — shows at once.
///
/// A Host with no Waycar plugin gets a row with an Install offer (WAY-341);
/// Not now holds for 14 days (`HostToolsOffer`). An outdated plugin (#209)
/// gets a row of its own too, and so does a working Node-era plugin, with an
/// Update that moves the Host to the native tools (WAY-451). All are the
/// Host's lowest priority (`hostRows`) and offer their action in place and
/// Not now; none navigates.
///
/// A runtime installed but stopped (`TransportError.startableRuntime`,
/// #389: every Host restart stops herdr) is a normal state, not an outage:
/// its row is quiet, says what is stopped, and offers Start Herdr TUI or
/// Start Herdr Core in place, so it does not navigate either.
struct ConsoleHostStatusPresentation: Equatable, Identifiable {
    enum Severity: Equatable {
        case informational
        case warning
        case critical
    }

    let hostID: Host.ID
    let hostName: String
    let message: String
    let systemImage: String
    let severity: Severity
    let navigates: Bool
    /// A second line under `message`; only the plugin row has one.
    var detail: String?
    /// Set on one backend's failure on a dual Host (`init(host:failedScope:failure:)`):
    /// the row offers a Retry of that backend alone.
    var retryScope: ConsoleScope?
    /// The stopped runtime this row offers to start, in place of Retry; nil
    /// on every row whose failure names none.
    var startsRuntime: HostBackend?
    /// The row's `detail` is what the last start of `startsRuntime` said
    /// when it failed.
    var startFailed = false
    /// The plugin row's offer (`init(host:pluginStatus:isDismissed:)`); nil
    /// on every other row.
    var pluginOffer: PluginOffer?
    /// Set on a Host's row when its failure is a missing backend (WAY-338,
    /// `ConsoleStore.backendGapBehindFailure`): tapping it opens the install
    /// panel in a sheet, not Host settings.
    var opensBackendInstall = false

    enum PluginOffer: Equatable {
        /// The plugin is older than this build needs: Update, Not now.
        case update
        /// The Host has no plugin: Install, Not now.
        case install
        /// The plugin works but is a Node-era one (below
        /// `nativeToolsMinimumVersion`): Update, Not now. A prompt, not a need.
        case moveToNative
    }

    /// Whether this is the plugin row. It is no failure, so the Console's
    /// empty states ignore it.
    var isPluginRow: Bool { pluginOffer != nil }

    var id: String {
        hostID.uuidString + (retryScope.map { "/\($0.backend.rawValue)" } ?? "")
            + (isPluginRow ? "/waycar-plugin" : "")
    }
    var isCritical: Bool { severity == .critical }

    /// A Host's rows, most urgent first: its connection or snapshot
    /// condition, then any failed backend's, and
    /// the plugin row only while none shows. A plugin nag must never stand
    /// in for, or sit beside, a failure the user has to act on.
    static func hostRows(
        condition: Self?, backendFailures: [Self],
        pluginNotice: @autoclosure () -> Self?
    ) -> [Self] {
        let rows = (condition.map { [$0] } ?? []) + backendFailures
        guard rows.isEmpty else { return rows }
        return pluginNotice().map { [$0] } ?? []
    }

    /// Which offer a Host's plugin gets, if any: Update below this build's
    /// minimum, Install when there is none, and move-to-native for a current
    /// plugin still below `nativeToolsMinimumVersion` (a Node-era one). A
    /// plugin whose version cannot be read, or that is already native, gets
    /// none. Only the first two are needs; the third is a prompt, so it must
    /// never stand in for a feature gate (`WaycarPluginRequirement.status`).
    static func pluginOffer(
        pluginStatus: WaycarPluginStatus, nativeToolsStatus: WaycarPluginStatus
    ) -> PluginOffer? {
        switch pluginStatus {
        case .outdated: .update
        case .notInstalled: .install
        case .current:
            if case .outdated = nativeToolsStatus { .moveToNative } else { nil }
        case .unknown: nil
        }
    }

    /// The plugin row: a plugin below this build's minimum, none at all, or a
    /// Node-era one (`nativeToolsStatus`), unless the user answered it
    /// (`isDismissed`: Not now for that minimum, or the Install and
    /// move-to-native offers' 14 days or switched-off reminder). Current and
    /// unknown plugins show nothing.
    init?(
        host: Host, pluginStatus: WaycarPluginStatus,
        nativeToolsStatus: WaycarPluginStatus = .unknown, isDismissed: Bool
    ) {
        guard !isDismissed else { return nil }
        hostID = host.id
        hostName = host.displayName
        severity = .warning
        navigates = false
        switch Self.pluginOffer(pluginStatus: pluginStatus, nativeToolsStatus: nativeToolsStatus) {
        case .update?:
            guard case .outdated(let installed, let required) = pluginStatus else { return nil }
            message = "\(host.displayName): Waycar plugin \(installed) is out of date"
            detail = "This app needs \(required)."
            systemImage = "arrow.down.circle"
            pluginOffer = .update
        case .install?:
            message = "Install Waycar Host Tools on \(host.displayName)"
            detail = "Adds notifications, Live Activities, chat replies and tmux Agent status."
            systemImage = "wrench.and.screwdriver"
            pluginOffer = .install
        case .moveToNative?:
            message = "\(host.displayName): Update Waycar to stop needing Node"
            detail = "The new Waycar tools run without Node. Your own Node stays as it is."
            systemImage = "arrow.triangle.2.circlepath"
            pluginOffer = .moveToNative
        case nil:
            return nil
        }
    }

    /// The Host's plugin row with the user's answers applied: an outdated
    /// plugin hides after Not now at this build's minimum
    /// (`WaycarPluginNoticeDismissals`); the Install offer and the
    /// move-to-native prompt hide by the Host's `HostToolsOffer` record, the
    /// latter keyed to `nativeToolsMinimumVersion`. With no offer record
    /// (previews) those two are never offered.
    @MainActor
    static func pluginRow(
        host: Host, pluginStatus: WaycarPluginStatus, nativeToolsStatus: WaycarPluginStatus,
        noticeDismissals: WaycarPluginNoticeDismissals, hostToolsOffer: HostToolsOffer?,
        now: Date = Date()
    ) -> Self? {
        let isDismissed =
            switch pluginOffer(pluginStatus: pluginStatus, nativeToolsStatus: nativeToolsStatus) {
            case .install?: hostToolsOffer?.isHidden(host.id, now: now) ?? true
            case .moveToNative?: hostToolsOffer?.isNativeToolsPromptHidden(host.id, now: now) ?? true
            case .update?, nil: noticeDismissals.isDismissed(host.id)
            }
        return Self(
            host: host, pluginStatus: pluginStatus, nativeToolsStatus: nativeToolsStatus,
            isDismissed: isDismissed)
    }

    /// One backend's failure on a dual Host whose status presents the other
    /// backend (design §2 scenario 11): the row names the backend, carries
    /// the failure's full presentation, and retries that backend.
    ///
    /// A stopped runtime's row starts it instead (`startsRuntime`). Its
    /// message already names the runtime, so it reads like the Host's own.
    init(
        host: Host, failedScope: ConsoleScope, failure: TransportError,
        startErrors: [HostBackend: String] = [:]
    ) {
        hostID = host.id
        hostName = host.displayName
        (message, systemImage, severity, navigates) = Self.failed(
            failure,
            hostName: failure.startableRuntime == nil
                ? "\(failedScope.backend.displayName) on \(host.displayName)" : host.displayName)
        retryScope = failedScope
        offerStart(for: failure, startErrors: startErrors)
    }

    /// A Host with no usable backend (WAY-338, `ConsoleStore.backendGapBehindFailure`):
    /// the install panel's title and "Tap to set up.", whichever
    /// `TransportError` the Host's own backend reported (herdr's socket not
    /// found, say). Tapping opens the panel.
    init(host: Host, backendGap gap: HostBackendGap) {
        hostID = host.id
        hostName = host.displayName
        message = "\(host.displayName): \(gap.title). \(HostBackendGap.tapToSetUp)"
        systemImage = "exclamationmark.triangle.fill"
        severity = .warning
        navigates = true
        opensBackendInstall = true
    }

    init?(
        host: Host,
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        connectedBackends: [HostBackend] = [],
        isAwaitingSnapshot: Bool = false,
        isWithinReconnectGrace: Bool = false,
        trustHold: HostKeyTrustHold? = nil,
        startErrors: [HostBackend: String] = [:],
        syncError: String?
    ) {
        hostID = host.id
        hostName = host.displayName
        if isWithinReconnectGrace {
            switch status {
            case .failed:
                break
            case .connecting where standingFailure != nil || trustHold != nil:
                break
            case .reconnecting where trustHold != nil:
                break
            default:
                return nil
            }
        }
        // A hold means the latest dial reached the Host and waits on the
        // user, so it outranks the failure of an earlier dial.
        let isDialing = switch status {
        case .connecting, .reconnecting: true
        default: false
        }
        if let trustHold, isDialing {
            message = switch trustHold {
            case .host: "Waiting for you to trust \(host.displayName)'s host key"
            case .jumpHost:
                "Waiting for you to trust the Jump Host's host key for \(host.displayName)"
            }
            systemImage = "lock.shield"
            severity = .informational
            navigates = true
            return
        }
        switch status {
        case .suspended:
            message = "Connection to \(host.displayName) is paused."
            systemImage = "pause.circle"
            severity = .informational
            navigates = false
        case .connecting:
            if let standingFailure {
                (message, systemImage, severity, navigates) = Self.failed(
                    standingFailure, hostName: host.displayName, connectedBackends: connectedBackends)
                offerStart(for: standingFailure, startErrors: startErrors)
            } else {
                message = "Connecting to \(host.displayName)…"
                systemImage = "dot.radiowaves.left.and.right"
                severity = .informational
                navigates = false
            }
        case .reconnecting(_, _, let failure):
            message = "Reconnecting to \(host.displayName): \(failure.presentation.summary)"
            systemImage = "wifi.exclamationmark"
            severity = .warning
            navigates = true
        case .failed(let failure):
            (message, systemImage, severity, navigates) = Self.failed(
                failure, hostName: host.displayName, connectedBackends: connectedBackends)
            offerStart(for: failure, startErrors: startErrors)
        case .connected:
            if let syncError {
                (message, systemImage, severity, navigates) = Self.syncError(
                    syncError, hostName: host.displayName)
            } else if isAwaitingSnapshot {
                message = "Loading Agents from \(host.displayName)…"
                systemImage = "hourglass"
                severity = .informational
                navigates = false
            } else {
                return nil
            }
        case .ended, nil:
            if let syncError {
                (message, systemImage, severity, navigates) = Self.syncError(
                    syncError, hostName: host.displayName)
            } else {
                return nil
            }
        }
    }

    /// A stopped runtime's row offers its Start; its detail is the last
    /// failed start's words, else the failure's own suggestion.
    private mutating func offerStart(
        for failure: TransportError, startErrors: [HostBackend: String]
    ) {
        guard let runtime = failure.startableRuntime else { return }
        startsRuntime = runtime
        if let error = startErrors[runtime] {
            detail = error
            startFailed = true
        } else {
            detail = failure.presentation.recoverySuggestion
        }
    }

    private static func failed(
        _ failure: TransportError, hostName: String, connectedBackends: [HostBackend] = []
    ) -> (String, String, Severity, Bool) {
        if failure.startableRuntime != nil {
            return stopped(failure, hostName: hostName, connectedBackends: connectedBackends)
        }
        return (
            "\(hostName): \(failure.presentation.message)"
                + HostBackend.connectedSentence(connectedBackends),
            failure.isHostKeySecurityFailure
                ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill",
            failure.isHostKeySecurityFailure ? .critical : .warning,
            true
        )
    }

    /// A stopped runtime: what is stopped, quietly. Its suggestion goes in
    /// the detail line (`offerStart`), and the row's Start stands in for
    /// navigating.
    private static func stopped(
        _ failure: TransportError, hostName: String, connectedBackends: [HostBackend] = []
    ) -> (String, String, Severity, Bool) {
        (
            "\(hostName): \(failure.presentation.explanation)"
                + HostBackend.connectedSentence(connectedBackends),
            "power.circle",
            .informational,
            false
        )
    }

    private static func syncError(
        _ syncError: String, hostName: String
    ) -> (String, String, Severity, Bool) {
        (
            "\(hostName): \(syncError)",
            "arrow.trianglehead.2.clockwise",
            .warning,
            true
        )
    }
}

/// Which Console agents surface to show for a catalog and inventory.
///
/// "No Agents" is a known-empty snapshot, not an unknown inventory. Connecting,
/// reconnecting, paused, failed, and Connected-awaiting-snapshot all produce
/// condition rows, so those states take `.rows` rather than the empty claim.
/// The one quiet case, a Host inside its reconnect grace, has a last-known
/// inventory, so an empty claim there is that inventory's own answer.
enum ConsoleAgentsSurface: Equatable {
    case noHosts
    case noAgents
    case noAgentsOnHost(String)
    /// A Status pill other than All (Closed included) matched nothing in the
    /// current scope.
    case noAgentsWithStatus(ConsoleStatusFilter)
    case noSearchResults
    /// Hosts exist but every one is a Disabled Host: nothing can list until
    /// one is turned on, whatever the search or Status pill says.
    case allHostsDisabled(hostCount: Int)
    case rows

    /// `enabledHostCount` defaults to `hostCount` (every Host enabled).
    init(
        hostCount: Int,
        enabledHostCount: Int? = nil,
        filteredHostName: String?,
        filteredAgentCount: Int,
        visibleIssueCount: Int,
        statusFilter: ConsoleStatusFilter = .all,
        searchQuery: String = ""
    ) {
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hostCount == 0 {
            self = .noHosts
        } else if (enabledHostCount ?? hostCount) == 0 {
            self = .allHostsDisabled(hostCount: hostCount)
        } else if filteredAgentCount == 0 && visibleIssueCount == 0 {
            if isSearching {
                self = .noSearchResults
            } else if statusFilter != .all {
                self = .noAgentsWithStatus(statusFilter)
            } else if let filteredHostName {
                self = .noAgentsOnHost(filteredHostName)
            } else {
                self = .noAgents
            }
        } else {
            self = .rows
        }
    }

    /// The one explanation for "every Host is disabled", shared by the list
    /// empty state and the iPad empty detail so the two never disagree.
    static func allHostsDisabledMessage(hostCount: Int) -> String {
        hostCount == 1
            ? "Your Host is disabled. Turn it on in Hosts."
            : "Your Hosts are disabled. Turn one on in Hosts."
    }
}

extension HostBackend {
    /// The one-tap start of this runtime where it is installed but stopped
    /// (#389): "Start Herdr TUI", "Start Herdr Core". The Console row and the
    /// Host page use the same words.
    var startActionTitle: String { "Start \(displayName)" }
}
