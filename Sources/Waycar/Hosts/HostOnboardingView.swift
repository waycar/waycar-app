import SwiftUI

/// Per-Host onboarding (#14): the preflight checklist with fix-it hints,
/// plus the TOFU fingerprint confirmation. Checks run automatically on
/// arrival; the goal is zero to green checkmarks without desktop docs.
struct HostOnboardingView: View {
    /// The Host as the catalog has it now. The page is keyed by its record
    /// form, so this is fresh when only enablement changes while `store.host`
    /// is not; every enablement-sensitive read uses this one.
    let host: Host
    /// The Host catalog, for the Edit sheet.
    let catalog: HostStore
    let connectionStatus: EventsSessionStatus?
    let standingFailure: TransportError?
    /// True while Console is serving a Host-detail Reconnect press (the
    /// retry call plus the 1.2 s visual-feedback hold). Distinct from
    /// `EventsSessionStatus.reconnecting`.
    let isManualReconnectInFlight: Bool
    let retryConnection: (@MainActor @Sendable () async -> Void)?
    /// The Console's live transport for this Host; nil while disconnected.
    let liveMoshState: ConsoleStore.MoshHostCapsuleState?
    /// Re-tests mosh on the live connection and upgrades its SSH sessions.
    let reprobeLiveMosh: (() -> Void)?
    /// AI Usage settings and CodexBar detection; nil hides the section.
    let aiUsage: AIUsageStore?
    /// The Console, for a Host running both backends: Show tmux sessions and
    /// the New Agent default. nil hides those controls.
    let console: ConsoleStore?
    @State private var store: HostOnboardingStore
    @State private var isEditing = false
    @State private var isConfirmingHostKeyReplacement = false
    /// True while a Reconnect press waits on this page's preflight for a
    /// host-key decision, before the Console retry starts.
    @State private var isRerunningChecks = false
    @State private var sessionSelectionError: String?
    @State private var didCopyInstallCommand = false
    /// Whether the checks already ran since the Host was last turned on.
    @State private var checksRanWhileEnabled = false
    /// Progressive disclosure: the Preflight and Status Hooks sections show
    /// one summary row until expanded. A blocking result expands itself;
    /// green and yellow start collapsed.
    @State private var isPreflightExpanded = false
    @State private var isStatusHooksExpanded = false
    /// The plugin update sheet's run, while it is presented from this page.
    @State private var pluginUpdate: WaycarPluginUpdateStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.waycarPluginUpdateActivity) private var pluginUpdateActivity
    @Environment(\.pluginUpdateRunningChange) private var pluginUpdateRunningChange
    @Environment(\.hostToolsOffer) private var hostToolsOffer

    init(
        host: Host,
        catalog: HostStore,
        connectionStatus: EventsSessionStatus? = nil,
        standingFailure: TransportError? = nil,
        isManualReconnectInFlight: Bool = false,
        retryConnection: (@MainActor @Sendable () async -> Void)? = nil,
        liveMoshState: ConsoleStore.MoshHostCapsuleState? = nil,
        reprobeLiveMosh: (() -> Void)? = nil,
        aiUsage: AIUsageStore? = nil,
        console: ConsoleStore? = nil,
        store: HostOnboardingStore? = nil
    ) {
        self.aiUsage = aiUsage
        self.console = console
        self.liveMoshState = liveMoshState
        self.reprobeLiveMosh = reprobeLiveMosh
        self.catalog = catalog
        self.connectionStatus = connectionStatus
        self.standingFailure = standingFailure
        self.isManualReconnectInFlight = isManualReconnectInFlight
        self.retryConnection = retryConnection
        self.host = host
        // `store` is a seam for tests and previews; the app lets the page
        // build its own.
        _store = State(
            initialValue: store
                ?? HostOnboardingStore(
                    host: host, knownPresence: console?.backendPresence(on: host.id)))
    }

    var body: some View {
        List {
            Section {
                HostEnabledToggle(host: host, catalog: catalog)
            } footer: {
                Text("Waycar never connects to a disabled Host. Its settings stay saved.")
            }

            Section {
                LabeledContent("Address", value: addressLine)
                LabeledContent("Session", value: sessionLine)
                LabeledContent(
                    "Auth",
                    value: authenticationLabel)
            }

            if host.isEnabled {
                liveSections
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: host.isEnabled)
        .navigationTitle(store.host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { HelpLink(.hostPage) }
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            HostFormView(store: catalog, editing: host)
        }
        .alert(
            "Trust this Host?",
            isPresented: fingerprintAlertPresented,
            presenting: store.pendingFingerprint
        ) { _ in
            Button("Trust") { store.confirmFingerprint(trusted: true) }
            Button("Don't Trust", role: .cancel) { store.confirmFingerprint(trusted: false) }
                .tint(Brand.Colors.quietAction)
        } message: { candidate in
            Text(
                "First connection to \(candidate.host):\(String(candidate.port)).\n\n"
                    + "Key fingerprint:\n\(candidate.fingerprint.displayString)\n\n"
                    + "Verify it matches the Host's key before trusting.")
        }
        .quietCancelDialog(
            "Replace the trusted Host key?",
            isPresented: hostKeyReplacementPresented,
            titleVisibility: .visible
        ) {
            Button("Trust New Key", role: .destructive) {
                Task { await store.trustPresentedHostKey() }
            }
            Button("Cancel", role: .cancel) {}
                .tint(Brand.Colors.quietAction)
        } message: {
            if let replacement = store.pendingHostKeyReplacement {
                Text(
                    "Trusted: \(replacement.known.displayString)\n\n"
                        + "Presented: \(replacement.presented.displayString)\n\n"
                        + "A changed key can indicate a reinstalled Host or an attack.")
            }
        }
        .quietCancelAlert(
            "Could Not Select Session",
            isPresented: Binding(
                get: { sessionSelectionError != nil },
                set: { if !$0 { sessionSelectionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
                .tint(Brand.Colors.quietAction)
        } message: {
            Text(sessionSelectionError ?? "")
        }
        .task(id: host.isEnabled) {
            // A Disabled Host is never contacted, not even by this page.
            // The page is keyed by the Host's record, so it survives an
            // enablement change: turning the Host off cancels the run this
            // task started (the id changes) and, through the store, stops a
            // run a button started at its host-key prompt; turning it on runs
            // the checks as arriving here does. The flag keeps a re-appearing
            // page from running them again.
            store.setHostEnabled(host.isEnabled)
            guard host.isEnabled else {
                isConfirmingHostKeyReplacement = false
                checksRanWhileEnabled = false
                return
            }
            // A run cancelled by turning the Host off may still be unwinding
            // (`runChecks` ignores a second call while one runs). Wait for it,
            // or its "cancelled" report would stay on the enabled page. The
            // id changing again cancels the wait.
            do {
                while store.phase == .running {
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                return
            }
            guard !checksRanWhileEnabled else { return }
            checksRanWhileEnabled = true
            await store.runChecks()
        }
        .onDisappear {
            // A run a button started (Reconnect, Run Checks Again, Test Mosh
            // Support, Trust New Key) is not cancelled with the page, unlike
            // the `.task` run, and its prompt would wait for an answer nobody
            // can give, holding its connection open. Decline it.
            store.confirmFingerprint(trusted: false)
        }
        .onChange(of: store.report) { _, report in
            // The Console waits for a key that was never trusted and connects
            // on its own once it is. Only a changed key stops it for good.
            // Once this page's preflight passes, the user has settled that
            // key, so reconnect for them instead of leaving the page red
            // until they tap Reconnect. A Reconnect press already retries
            // after its own preflight.
            guard report?.isFullyPassed == true,
                connectionPresentation.reconnectNeedsHostKeyDecision,
                !isReconnecting,
                let retryConnection
            else { return }
            Task { @MainActor in
                await retryConnection()
            }
        }
        .onChange(of: store.primaryBackend) { _, _ in
            // Picking the other herdr runtime changes whose checklist this
            // page shows: run it, rather than leave the old runtime's result
            // under the new one's name.
            guard host.isEnabled, checksRanWhileEnabled else { return }
            Task { @MainActor in await store.runChecks() }
        }
        .onChange(of: preflightSummary.severity, initial: true) { _, severity in
            // A blocking failure is what the user came to see; soft states
            // stay collapsed.
            if severity == .blocking { isPreflightExpanded = true }
        }
        .onChange(of: statusHooksSummary?.severity, initial: true) { _, severity in
            if severity == .blocking { isStatusHooksExpanded = true }
        }
        .onChange(of: store.presence) { _, presence in
            // Opening Host detail refreshes what the Console knows, so a
            // manual update on the Host clears its outdated-plugin prompts.
            guard let presence, presence.waycarPlugin != nil else { return }
            console?.recordDetectedPresence(presence, on: host.id)
        }
        .sheet(item: $pluginUpdate) { pluginUpdate in
            WaycarPluginUpdateSheet(store: pluginUpdate)
        }
        .onChange(of: pluginUpdate?.isRunning == true) { _, isRunning in
            pluginUpdateRunningChange?(isRunning)
        }
        .onDisappear { pluginUpdateRunningChange?(false) }
    }

    /// Everything that contacts the Host or reports on a live connection;
    /// a Disabled Host shows only its toggle and configuration.
    private var liveSections: some View {
        Group {
            let runtimeStart = self.runtimeStart
            if !runtimeStart.offers.isEmpty {
                runtimeStartSection(runtimeStart)
            } else if retryConnection != nil {
                Section {
                    Button {
                        retry()
                    } label: {
                        ZStack(alignment: .leading) {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                                .opacity(isReconnecting ? 0 : 1)
                            HStack {
                                ProgressView()
                                Text("Connecting…")
                            }
                            .opacity(isReconnecting ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.smooth(duration: 0.25), value: isReconnecting)
                    }
                    .disabled(isReconnecting)
                } footer: {
                    if let footerMessage = connectionPresentation.footerMessage {
                        Text(footerMessage)
                            .foregroundStyle(.red)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(
                    .smooth(duration: 0.25),
                    value: connectionPresentation.connectionErrorMessage)
            }

            if let console {
                ForEach(ServerChatBackend.allCases, id: \.self) { server in
                    HostServerRuntimeSection(
                        server: server, state: console.serverRuntimeState(server, on: host.id)
                    ) {
                        start(server.backend)
                    }
                }
                HostUnansweredProbesSection(
                    probes: console.backendPresence(on: host.id)?.unansweredProbes ?? [])
            }

            Section {
                SectionSummaryRow(
                    title: "Preflight", summary: preflightSummary,
                    isExpanded: $isPreflightExpanded)
                if isPreflightExpanded {
                    ForEach(PreflightCheck.checks(for: checklistBackend), id: \.self) { check in
                        PreflightCheckRow(check: check, status: status(for: check))
                    }
                }
            } header: {
                HStack {
                    Text("Preflight")
                    if store.phase == .running {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.leading, 4)
                    }
                }
            } footer: {
                // The protocol notice is advisory and the checks still pass:
                // a Host newer than this build is usable, just not fully known.
                if let versionLine = HostOnboardingVersionLine.text(
                    serverInfo: store.serverInfo, presence: store.presence,
                    backends: store.resolvedBackends)
                {
                    Text(versionLine)
                }
            }

            statusHooksSection

            waycarPluginSection

            backendPreferencesSection

            Section {
                if let liveMoshState {
                    HStack {
                        Text("Current Connection")
                        Spacer()
                        MoshTransportBadge(state: liveMoshState)
                    }
                    if let reprobeLiveMosh {
                        Button(action: reprobeLiveMosh) {
                            Label("Retest and Upgrade Sessions", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(liveMoshState == .testing)
                    }
                }
                moshSupportRow
                Button {
                    Task { await store.runMoshSupportCheck() }
                } label: {
                    Label("Test Mosh Support", systemImage: "bolt.horizontal")
                }
                .disabled(store.moshSupport == .testing)
            } header: {
                Text("Mosh")
            } footer: {
                Text(
                    "Runs a real mosh handshake against this Host. Agent sessions "
                        + "ride mosh when it passes, and fall back to SSH whenever "
                        + "mosh fails.")
            }

            if let aiUsage {
                AIUsageHostSettingsSection(store: aiUsage, hostID: store.host.id)
            }

            availableSessionsSection

            Section {
                Button {
                    Task { await store.runChecks() }
                } label: {
                    Label("Run Checks Again", systemImage: "arrow.clockwise")
                }
                .disabled(store.phase == .running)
            }

            if store.pendingHostKeyReplacement != nil {
                Section {
                    Button("Trust New Host Key", systemImage: "key.horizontal", role: .destructive) {
                        isConfirmingHostKeyReplacement = true
                    }
                } footer: {
                    Text("Only continue after verifying the new fingerprint with the Host owner.")
                }
            }
        }
    }

    /// A runtime installed but stopped (#389) is a normal state, so the
    /// connection card offers its Start in place of Reconnect, which could
    /// not help, and says what is stopped in the quiet footer style.
    private func runtimeStartSection(
        _ runtimeStart: HostOnboardingRuntimeStartPresentation
    ) -> some View {
        Section {
            ForEach(runtimeStart.offers) { offer in
                Button {
                    start(offer.runtime)
                } label: {
                    ZStack(alignment: .leading) {
                        Label(offer.title, systemImage: "power")
                            .opacity(offer.isStarting ? 0 : 1)
                        HStack {
                            ProgressView()
                            Text("Starting…")
                        }
                        .opacity(offer.isStarting ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.smooth(duration: 0.25), value: offer.isStarting)
                }
                .disabled(offer.isStarting)
                .accessibilityLabel(
                    offer.isStarting ? "Starting \(offer.runtime.displayName)" : offer.title)
            }
        } footer: {
            if let footerMessage = runtimeStart.footerMessage {
                Text(footerMessage)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.25), value: runtimeStart.footerMessage)
    }

    /// What the Console and this page's last checks say is stopped.
    private var runtimeStart: HostOnboardingRuntimeStartPresentation {
        guard let console else { return HostOnboardingRuntimeStartPresentation() }
        let hostID = host.id
        var runtimes: [HostBackend: HostOnboardingRuntimeStartPresentation.Runtime] = [:]
        for runtime in HostOnboardingRuntimeStartPresentation.startable {
            let scope = ConsoleScope(hostID: hostID, backend: runtime)
            runtimes[runtime] = .init(
                failure: console.scopeFailure(scope),
                isConnected: console.scopeStatuses[scope] == .connected,
                isStarting: console.isStarting(runtime, on: hostID),
                startError: console.startError(runtime, on: hostID))
        }
        return HostOnboardingRuntimeStartPresentation(runtimes: runtimes, report: store.report)
    }

    /// Starts the runtime through the Console, the only place that starts
    /// one, then runs this page's checks again so they show it running.
    private func start(_ runtime: HostBackend) {
        guard let console else { return }
        let hostID = host.id
        Task { @MainActor in
            if await console.startRuntime(runtime, on: hostID) {
                await store.runChecks()
            }
        }
    }

    private var authenticationLabel: String {
        switch store.host.authMethod {
        case .deviceKey: "Device Key"
        case .rsaKey: "RSA Key"
        case .password: "Password"
        }
    }

    /// Presentation tracks the pending candidate; dismissal is decided by
    /// the buttons (or a cancelled run, or the Host turning off), never by
    /// the binding, so a dismiss-then-answer race cannot double-resolve the
    /// decision. A Disabled Host never shows it: trusting would dial it.
    private var fingerprintAlertPresented: Binding<Bool> {
        Binding(
            get: { host.isEnabled && store.pendingFingerprint != nil },
            set: { _ in })
    }

    /// Trust New Key reruns the checks, so a Disabled Host never shows it.
    private var hostKeyReplacementPresented: Binding<Bool> {
        Binding(
            get: { host.isEnabled && isConfirmingHostKeyReplacement },
            set: { isConfirmingHostKeyReplacement = $0 })
    }

    private var addressLine: String {
        "\(store.host.username)@\(store.host.address):\(String(store.host.port))"
    }

    private var sessionLine: String {
        if case .namedSession(let name) = store.host.socketLocation {
            return name
        }
        return "default"
    }

    /// Reconnect first reruns this page's preflight when the Console needs a
    /// host-key decision (its connection never prompts, so only the preflight
    /// can ask "Trust this Host?" or offer Trust New Host Key), and only then
    /// waits for it: the Console retry connects with whatever the user
    /// decided. A failed last run is rerun alongside the retry instead, so
    /// its failure is not left on the page after a Reconnect that worked.
    private func retry() {
        guard !isManualReconnectInFlight, !isRerunningChecks, let retryConnection else { return }
        let needsHostKeyDecision = connectionPresentation.reconnectNeedsHostKeyDecision
        if !needsHostKeyDecision, store.report?.isFullyPassed == false {
            Task { @MainActor in await store.runChecks() }
        }
        Task { @MainActor in
            if needsHostKeyDecision {
                isRerunningChecks = true
                await store.runChecks()
                isRerunningChecks = false
            }
            await retryConnection()
        }
    }

    private var isReconnecting: Bool {
        isManualReconnectInFlight || isRerunningChecks
    }

    private var connectionPresentation: HostOnboardingConnectionPresentation {
        HostOnboardingConnectionPresentation(
            status: connectionStatus,
            standingFailure: standingFailure,
            connectedBackends: console?.connectedSecondaryBackends(on: store.host.id) ?? [],
            isManualReconnectInFlight: isManualReconnectInFlight)
    }

    private func status(for check: PreflightCheck) -> PreflightCheckStatus? {
        store.report?[check]
    }

    /// The checklist on screen: the last run's backend, else the one the
    /// next run dials.
    private var checklistBackend: HostBackend {
        store.report?.backend ?? store.primaryBackend
    }

    /// Hosts with tmux or herdr-core: Waycar's agent status hooks per agent
    /// CLI, with the fix for whatever is missing.
    @ViewBuilder
    private var statusHooksSection: some View {
        if let hooks = store.statusHooks {
            Section {
                if let summary = statusHooksSummary {
                    SectionSummaryRow(
                        title: "Status Hooks", summary: summary,
                        isExpanded: $isStatusHooksExpanded)
                }
                if isStatusHooksExpanded {
                    statusHooksDetails(hooks)
                }
            } header: {
                Text("Status Hooks")
            } footer: {
                Text(
                    store.hasTmux
                        ? "Status hooks let tmux Agents report Working, Blocked and Done. "
                            + "Agents without them show Unknown."
                        : "Status hooks let Waycar notify you when a herdr-core Agent is Blocked "
                            + "or Done, and find its chat. herdr-core reports Agent status itself.")
            }
        }
    }

    /// The section's full rows, unchanged, shown when expanded.
    @ViewBuilder
    private func statusHooksDetails(_ hooks: StatusHooksState) -> some View {
        Group {
                switch hooks {
                case .reported(let report):
                    ForEach(report.agents, id: \.agent) { agent in
                        LabeledContent(
                            StatusHooksState.displayName(ofAgent: agent.agent),
                            value: agent.installed
                                ? "Installed"
                                : agent.detected == false ? "Not installed" : "Hooks missing")
                    }
                    if !hooks.missingAgents.isEmpty {
                        Button {
                            Task { await store.installStatusHooks() }
                        } label: {
                            if store.isInstallingStatusHooks {
                                HStack {
                                    ProgressView()
                                    Text("Installing…")
                                }
                            } else {
                                Label("Install Status Hooks", systemImage: "arrow.down.circle")
                            }
                        }
                        .disabled(store.isInstallingStatusHooks)
                    }
                    if hooks.needsCodexReview {
                        Label(StatusHooksState.codexReviewNote, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .hostToolsMissing:
                    Text(
                        store.hasTmux
                            ? "Waycar's host tools are not installed, so tmux Agents show Unknown. "
                                + "Run this on the Host to install them with the status hooks:"
                            : "Waycar's host tools are not installed, so herdr-core Agents send no "
                                + "notifications and show no chat. "
                                + "Run this on the Host to install them with the status hooks:")
                    Text(WaycarPluginRequirement.installCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = WaycarPluginRequirement.installCommand
                        didCopyInstallCommand = true
                    } label: {
                        Label(
                            didCopyInstallCommand ? "Copied" : "Copy Install Command",
                            systemImage: didCopyInstallCommand ? "checkmark" : "doc.on.doc")
                    }
                case .unreadable(let detail):
                    Label(
                        "Could not read the status hooks. (\(detail))",
                        systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let installError = store.statusHooksInstallError {
                    Text(installError)
                        .font(.footnote)
                        .foregroundStyle(Brand.Colors.danger)
                }
        }
    }

    /// The Preflight section's one-row roll-up.
    private var preflightSummary: HostSectionSummary {
        .preflight(report: store.report)
    }

    /// The Status Hooks section's roll-up; nil while the Host has no hooks
    /// section at all.
    private var statusHooksSummary: HostSectionSummary? {
        guard let hooks = store.statusHooks else { return nil }
        return .statusHooks(hooks, installError: store.statusHooksInstallError)
    }

    /// What this page and the Console know of the Waycar plugin: the fresh
    /// detection once the checks ran, else the Console's last one.
    private var waycarPluginDetection: WaycarPluginDetection? {
        store.presence?.waycarPlugin ?? console?.backendPresence(on: host.id)?.waycarPlugin
    }

    /// The Host's backends for its plugin's minimum, from the same place as
    /// `waycarPluginDetection`: a core Host read from the Console's presence
    /// must still be measured against the core mode's plugin.
    private var waycarPluginBackends: [HostBackend] {
        store.resolvedBackends ?? console?.resolvedBackends(on: host.id) ?? []
    }

    /// The installed Waycar plugin against this build's minimum, with the
    /// one-tap update when it is too old (#209), and offered quietly when
    /// only a newer plugin than the Host's exists.
    @ViewBuilder
    private var waycarPluginSection: some View {
        let detection = waycarPluginDetection
        let status = WaycarPluginRequirement.status(of: detection, backends: waycarPluginBackends)
        let nativeStatus = WaycarPluginRequirement.nativeToolsStatus(of: detection)
        if detection != nil {
            Section {
                switch status {
                case .current(let version):
                    LabeledContent("Version", value: version)
                    if case .outdated = nativeStatus {
                        LabeledContent("Status", value: "Update available")
                        Label(
                            "This version needs Node on the Host. The new Waycar tools don't.",
                            systemImage: "arrow.triangle.2.circlepath")
                        pluginUpdateButton(detection: detection)
                        if let hostToolsOffer {
                            Toggle(
                                "Remind me about this update",
                                isOn: Binding(
                                    get: { hostToolsOffer.reminds(host.id) },
                                    set: { hostToolsOffer.setReminds($0, for: host.id) }))
                        }
                    } else if let latest = WaycarPluginRequirement.availableUpdate(for: detection) {
                        LabeledContent("Status", value: "\(latest) available")
                        pluginUpdateButton(detection: detection)
                    } else {
                        LabeledContent("Status", value: "Up to date")
                    }
                case .outdated(let installed, let required):
                    LabeledContent("Version", value: installed)
                    Label("Update needed: this app needs \(required).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Brand.Colors.warn)
                    pluginUpdateButton(detection: detection)
                case .notInstalled:
                    LabeledContent("Status", value: "Not installed")
                    if let hostToolsOffer {
                        Toggle(
                            "Remind me to install Host Tools",
                            isOn: Binding(
                                get: { hostToolsOffer.reminds(host.id) },
                                set: { hostToolsOffer.setReminds($0, for: host.id) }))
                    }
                    if store.statusHooks != .hostToolsMissing {
                        // The Status hooks section already offers the command
                        // on a tmux Host without the Host tools.
                        Text(WaycarPluginRequirement.installCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = WaycarPluginRequirement.installCommand
                            didCopyInstallCommand = true
                        } label: {
                            Label(
                                didCopyInstallCommand ? "Copied" : "Copy Install Command",
                                systemImage: didCopyInstallCommand ? "checkmark" : "doc.on.doc")
                        }
                    }
                case .unknown:
                    LabeledContent("Version", value: "Unknown")
                }
            } header: {
                Text("Waycar plugin")
            } footer: {
                if status == .notInstalled, hostToolsOffer != nil {
                    Text("Off hides the install offer on this Host's Console row.")
                } else if case .current = status, case .outdated = nativeStatus, hostToolsOffer != nil {
                    Text("Off hides this update prompt on this Host's Console row.")
                }
            }
        }
    }

    /// Opens the update sheet; off while an update already runs on this Host.
    private func pluginUpdateButton(detection: WaycarPluginDetection?) -> some View {
        let isRunning = pluginUpdateActivity?.runningHosts.contains(host.id) == true
        return Button {
            presentPluginUpdate(detection: detection)
        } label: {
            Label("Update Waycar on this Host…", systemImage: "arrow.down.circle")
        }
        .disabled(isRunning)
        .accessibilityHint(isRunning ? "An update is already running on this Host" : "")
    }

    private func presentPluginUpdate(detection: WaycarPluginDetection?) {
        let hostID = host.id
        let console = console
        let store = store
        pluginUpdate = WaycarPluginUpdateStore(
            host: host, detection: detection, backends: waycarPluginBackends,
            onUpdated: { presence in
                console?.waycarPluginUpdated(on: hostID, presence: presence)
                Task { await store.runChecks() }
            },
            activity: pluginUpdateActivity)
    }

    /// A Host with two backends to choose between (`HostBackendsSection`).
    @ViewBuilder
    private var backendPreferencesSection: some View {
        if let console {
            HostBackendsSection(store: store, console: console)
        }
    }

    /// Tap-to-test row for the mosh handshake proof on this Host.
    @ViewBuilder
    private var moshSupportRow: some View {
        switch store.moshSupport {
        case .idle:
            Label(
                "Not tested — sessions use SSH until mosh passes the handshake",
                systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Running mosh handshake…")
            }
        case .available:
            Label("Mosh supported — agent sessions ride mosh UDP", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Mosh handshake failed — sessions will use SSH",
                    systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var availableSessionsSection: some View {
        if !store.availableSessions.isEmpty || store.sessionDiscoveryError != nil {
            Section {
                ForEach(store.availableSessions, id: \.name) { session in
                    Button {
                        select(session)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(session.name)
                                Text(session.isRunning ? "Running" : "Stopped")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isSelected(session) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(isSelected(session) || (!session.isDefault && !session.isRunning))
                }
                if let error = store.sessionDiscoveryError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Available Sessions")
            } footer: {
                Text("Stopped named sessions must be started on the Host before selection.")
            }
        }
    }

    private func isSelected(_ session: HerdrSession) -> Bool {
        session.isDefault ? store.host.sessionName.isEmpty : store.host.sessionName == session.name
    }

    private func select(_ session: HerdrSession) {
        do {
            try store.selectSession(session, in: catalog)
        } catch {
            sessionSelectionError = "The selected session could not be saved."
        }
    }
}

/// Host detail footer copy, derived from Host Connection Status.
///
/// Automatic recovery shows the Explanation only — Summary and Detail, no
/// Recovery Suggestion. A stopped Host shows the whole presentation. See
/// Transport Error Presentation in `CONTEXT.md`.
///
/// `isManualReconnectInFlight` is a Console-owned Reconnect press (the
/// retry call plus its 1.2 s hold), not `EventsSessionStatus.reconnecting`.
/// A press hides the footer for both arms — recorded, not endorsed, in #160.
/// The animation value stays `connectionErrorMessage` so a press does not
/// drive the footer's 0.25 s transition.
struct HostOnboardingConnectionPresentation: Equatable {
    /// Status-derived footer text. The footer animation observes this; a
    /// manual Reconnect request does not change it.
    let connectionErrorMessage: String?
    let footerMessage: String?
    /// The Console stopped on a host key it may not decide about itself — an
    /// untrusted key or a changed one. Its connection never prompts, so
    /// Reconnect must first run this page's preflight, which asks.
    let reconnectNeedsHostKeyDecision: Bool

    init(
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        connectedBackends: [HostBackend] = [],
        isManualReconnectInFlight: Bool
    ) {
        let connectedMessage = HostBackend.connectedSentence(connectedBackends)
        let failure: TransportError?
        switch status {
        case .connecting:
            failure = standingFailure
            connectionErrorMessage = standingFailure.map { $0.presentation.message + connectedMessage }
        case .reconnecting(_, _, let reconnectFailure):
            failure = reconnectFailure
            connectionErrorMessage = reconnectFailure.presentation.explanation
        case .failed(let stoppedFailure):
            failure = stoppedFailure
            connectionErrorMessage = stoppedFailure.presentation.message + connectedMessage
        case .connected, .suspended, .ended, nil:
            failure = nil
            connectionErrorMessage = nil
        }
        footerMessage = isManualReconnectInFlight ? nil : connectionErrorMessage
        reconnectNeedsHostKeyDecision = failure?.needsHostKeyDecision ?? false
    }
}

/// The Host page's Start for runtimes installed but not running (#389).
///
/// The Console's account of each runtime wins: a scope failing with an error
/// that names the runtime (`TransportError.startableRuntime`) offers its
/// Start, any other failure or a live connection offers none. Only when the
/// Console has nothing to say (no projection, or one connecting afresh) does
/// this page's own preflight decide, so a stale run cannot offer a Start
/// for a runtime that serves. A start in flight keeps its offer, and hides
/// its footer line, as a Reconnect press hides the connection footer.
struct HostOnboardingRuntimeStartPresentation: Equatable {
    /// The runtimes a Start exists for, in the order the card lists them.
    static let startable: [HostBackend] = [.herdr, .core]

    /// What the Console knows of one runtime on the Host.
    struct Runtime: Equatable {
        /// Its scope's failure (`ConsoleStore.scopeFailure`).
        var failure: TransportError?
        var isConnected = false
        var isStarting = false
        /// What its last failed start said (`ConsoleStore.startError`).
        var startError: String?
    }

    struct Offer: Equatable, Identifiable {
        let runtime: HostBackend
        let isStarting: Bool
        var id: HostBackend { runtime }
        var title: String { runtime.startActionTitle }
    }

    /// One per stopped runtime; empty keeps the card's Reconnect.
    let offers: [Offer]
    /// What is stopped, or what its last start said, a line per runtime.
    let footerMessage: String?

    init(runtimes: [HostBackend: Runtime] = [:], report: PreflightReport? = nil) {
        var offers: [Offer] = []
        var lines: [String] = []
        for runtime in Self.startable {
            let state = runtimes[runtime] ?? Runtime()
            let consoleSaysStopped = state.failure?.startableRuntime == runtime
            let pageSaysStopped =
                state.failure == nil && !state.isConnected
                && report?.stoppedRuntime == runtime
            guard state.isStarting || consoleSaysStopped || pageSaysStopped else { continue }
            offers.append(Offer(runtime: runtime, isStarting: state.isStarting))
            guard !state.isStarting else { continue }
            if let error = state.startError {
                lines.append(error)
            } else if consoleSaysStopped, let failure = state.failure {
                lines.append(failure.presentation.message)
            } else {
                lines.append("\(runtime.displayName) is not running on this Host.")
            }
        }
        self.offers = offers
        footerMessage = lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// A server chat runtime's Host-only server row (Codex server), beside the
/// explicit herdr starts. Not installed stays quiet: it is optional, never
/// an install prompt here.
struct HostServerRuntimeSection: View {
    let server: ServerChatBackend
    let state: ServerRuntimeState
    let start: () -> Void

    var body: some View {
        let name = server.backend.displayName
        switch state {
        case .notInstalled:
            EmptyView()
        case .needsUpdate:
            Section {
                Text("Update \(name) to use it here")
                    .foregroundStyle(.secondary)
            } header: { Text(name) }
        case .notResponding(let probe):
            Section {
                HostUnansweredProbeText(probe: probe)
            } header: { Text(name) }
        case .running:
            Section {
                Label("\(server.serverName) running", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } header: { Text(name) }
        case .stopped, .starting:
            Section {
                if case .stopped = state {
                    Text("\(server.serverName) not running")
                        .foregroundStyle(.secondary)
                }
                Button(action: start) {
                    ZStack(alignment: .leading) {
                        Label("Start \(server.serverName)", systemImage: "power")
                            .opacity(state == .starting ? 0 : 1)
                        HStack {
                            ProgressView()
                            Text("Starting…")
                        }
                        .opacity(state == .starting ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(state == .starting)
                .accessibilityLabel(
                    state == .starting ? "Starting \(server.serverName)" : "Start \(server.serverName)")
            } header: {
                Text(name)
            } footer: {
                if let error = state.startError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .animation(.smooth(duration: 0.25), value: state)
        }
    }
}

/// Host detail's word on the terminal runtimes whose detection program did
/// not answer (server chat runtimes say it in `HostServerRuntimeSection`),
/// one section per runtime, so a wedged CLI never reads as "not installed".
struct HostUnansweredProbesSection: View {
    let probes: [HostDetectionProbe]

    var body: some View {
        let terminal = probes.filter { !$0.backend.isServerChat }
        let backends = HostBackend.allCases.filter { backend in terminal.contains { $0.backend == backend } }
        ForEach(backends, id: \.self) { backend in
            Section {
                ForEach(terminal.filter { $0.backend == backend }, id: \.self) { probe in
                    HostUnansweredProbeText(probe: probe)
                }
            } header: { Text(backend.displayName) }
        }
    }
}

/// "Codex didn't respond (`codex --version` timed out)", the command in
/// monospace.
struct HostUnansweredProbeText: View {
    let probe: HostDetectionProbe

    var body: some View {
        Text("\(probe.subject) didn't respond (\(Text(probe.command).monospaced()) timed out)")
            .foregroundStyle(.secondary)
            .accessibilityLabel(probe.message)
    }
}

/// The Preflight footer's version line: herdr's version and protocol as
/// before tmux support, "tmux 3.4" for tmux, and both lines on a Host that
/// runs both. nil until something reported a version.
enum HostOnboardingVersionLine {
    /// `backends` is what the Host's pick resolved to (`HostOnboardingStore.resolvedBackends`);
    /// without it the Host's presence decides, with no pick.
    static func text(
        serverInfo: ServerInfo?, presence: HostBackendPresence?, backends: [HostBackend]? = nil
    ) -> String? {
        let resolved = backends ?? presence?.backends ?? []
        var lines: [String] = []
        if let info = serverInfo, info.backend == .herdr {
            lines.append(herdrLine(info))
        }
        if resolved.contains(.core), let core = presence?.core {
            lines.append("Herdr Core \(core.version)")
        }
        if let info = serverInfo, info.backend == .tmux {
            lines.append("tmux \(info.version)")
        } else if let presence, resolved.contains(where: \.fillsHerdrSlot),
            resolved.contains(.tmux), let version = presence.tmuxVersion
        {
            lines.append("tmux \(version)")
        }
        if resolved.contains(.zellij), let zellij = presence?.zellij {
            lines.append("Zellij \(zellij.version)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func herdrLine(_ info: ServerInfo) -> String {
        info.exceedsGeneratedProtocol
            ? "Herdr TUI \(info.version) · protocol \(info.protocolVersion) — "
                + "newer than this app was built against, so features added "
                + "after protocol \(WaycarSSHTransport.generatedProtocolVersion) "
                + "may be unavailable."
            : "Herdr TUI \(info.version) · protocol \(info.protocolVersion)"
    }
}

/// The collapsed face of a Host detail section: one status icon, the state
/// line, and a chevron. Tapping toggles the full rows below it.
private struct SectionSummaryRow: View {
    /// Section name, for accessibility ("Preflight: all 5 checks passed").
    let title: String
    let summary: HostSectionSummary
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if reduceMotion {
                isExpanded.toggle()
            } else {
                withAnimation(.snappy) { isExpanded.toggle() }
            }
        } label: {
            HStack {
                icon
                Text(summary.detail)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(summary.detail)")
        .accessibilityHint(isExpanded ? "Collapses the details" : "Expands the details")
    }

    @ViewBuilder
    private var icon: some View {
        switch summary.severity {
        case .pending:
            ProgressView()
                .controlSize(.small)
        case .neutral:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .allPassed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Brand.Colors.warn)
        case .blocking:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .stopped:
            Image(systemName: "power.circle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PreflightCheckRow: View {
    let check: PreflightCheck
    /// nil while no report exists yet (first run still in flight).
    let status: PreflightCheckStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                statusIcon
                Text(check.title)
            }
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// A failed check's fix-it, or a soft check's warning.
    private var hint: String? {
        switch status {
        case .failed(let hint), .warning(let hint), .stopped(let hint): hint
        case .passed, .blocked, nil: nil
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .blocked:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Brand.Colors.warn)
        case .stopped:
            Image(systemName: "power.circle")
                .foregroundStyle(.secondary)
        case nil:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        }
    }
}

extension EnvironmentValues {
    /// Reports whether a plugin update started from this Host detail is
    /// running, so the window presenting it can keep it up over a deep link.
    @Entry var pluginUpdateRunningChange: (@MainActor (Bool) -> Void)? = nil
}
