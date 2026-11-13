import Observation
import SwiftUI

/// Drives one "Update Waycar on this Host" run (#209): consent, the
/// installer over SSH with its progress, then a fresh detection so the
/// result says whether the Host now meets this build's minimum.
@MainActor
@Observable
final class WaycarPluginUpdateStore {
    enum Phase: Equatable, Sendable {
        /// Waiting for the user's consent.
        case confirm
        /// The installer runs; the latest line it printed, if any yet.
        case running(latestLine: String?)
        /// The installer finished. `stillOutdated`: the fresh detection is
        /// still below the minimum (waycar.dev served an older plugin).
        case succeeded(WaycarPluginUpdateResult, stillOutdated: Bool)
        /// The run failed; `lastLine` is the installer's last output, if any
        /// and not already part of `message`. `keptVersion` is set when a
        /// fresh detection found the Host's previous version still installed,
        /// so the failure left the old install in place.
        case failed(message: String, lastLine: String?, keptVersion: String?)
    }

    private var machine = WaycarPluginUpdateMachine()
    var phase: Phase { machine.phase }
    /// Off runs the installer with `--no-hooks`: no agent hook or
    /// opencode/kilo extension refresh.
    var refreshHooks = true

    let host: Host

    @ObservationIgnored private let detection: WaycarPluginDetection?
    /// The Host's backends under its runtime pick: a Host that uses
    /// herdr-core needs the core mode's plugin (`coreMinimumVersion`).
    @ObservationIgnored private let backends: [HostBackend]
    @ObservationIgnored private let connector: any TransportConnector
    @ObservationIgnored private let credentials: HostCredentialsProvider
    @ObservationIgnored private let onUpdated: @MainActor (HostBackendPresence?) -> Void
    /// The app-wide record of running updates; keeps two sheets from
    /// running the installer on one Host at once.
    @ObservationIgnored private let activity: WaycarPluginUpdateActivity?
    /// The run in flight. Dismissing the sheet does not cancel it: the remote
    /// installer keeps going either way, and the Console should still learn
    /// the outcome.
    @ObservationIgnored private var tasks: [UInt64: Task<Void, Never>] = [:]

    init(
        host: Host,
        detection: WaycarPluginDetection?,
        backends: [HostBackend] = [],
        connector: any TransportConnector = SSHTransportConnector(),
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        onUpdated: @escaping @MainActor (HostBackendPresence?) -> Void,
        activity: WaycarPluginUpdateActivity? = nil
    ) {
        self.activity = activity
        self.host = host
        self.detection = detection
        self.backends = backends
        self.connector = connector
        self.credentials = credentials
        self.onUpdated = onUpdated
    }

    /// Includes verification and callback delivery, until this run releases
    /// its app-wide Host lock.
    var isRunning: Bool { machine.isRunning }

    /// The installer mode the Host already uses; nil lets install.sh choose.
    var mode: WaycarPluginInstall.Mode? {
        guard case .installed(let install) = detection else { return nil }
        return install.mode
    }

    /// The Host's install is the Host Tools alone (tmux or herdr-core): there
    /// is no herdr plugin to replace, and no herdr sidebar helper to restart.
    var isToolsOnly: Bool { mode == .tmux || mode == .core }

    /// The Host has no Waycar plugin yet (WAY-341): the sheet says Install,
    /// not Update, and promises no replacement.
    var isInstall: Bool { detection == .notInstalled }

    /// The request the current choices make.
    var request: WaycarPluginUpdateRequest {
        WaycarPluginUpdateRequest(mode: mode, refreshHooks: refreshHooks)
    }

    /// The herdr plugin root the installer will unlink and replace with its
    /// own copy: a linked plugin outside `~/.local/share/waycar/plugin`.
    /// Nil when the Host uses tmux, the root is unknown, or it is already
    /// the installer's own.
    var replacedRoot: String? {
        guard case .installed(let install) = detection, install.mode == .herdr,
            let root = install.root, !root.isEmpty,
            !root.contains("/.local/share/waycar/plugin")
        else { return nil }
        return root
    }

    /// The Host runs a Node-era plugin (below `nativeToolsMinimumVersion`),
    /// so this run moves it to the native tools (WAY-451): the sheet says
    /// what that changes, and a fresh detection must reach the native
    /// minimum. A Host with no plugin, a native one, or a version that
    /// cannot be read is not a move.
    var movesToNative: Bool {
        if case .outdated = WaycarPluginRequirement.nativeToolsStatus(of: detection) { return true }
        return false
    }

    /// The version a finished run must reach: this build's minimum for the
    /// Host's backends, and for a move off Node at least the native minimum.
    var requiredVersion: String {
        let minimum = WaycarPluginRequirement.minimumVersion(for: backends)
        guard movesToNative else { return minimum }
        let native = WaycarPluginRequirement.nativeToolsMinimumVersion
        return WaycarPluginRequirement.compare(minimum, native) == .orderedDescending ? minimum : native
    }

    /// Starts (or retries) the update. Ignored while a run is in flight.
    func start() {
        // Acquisition is synchronous, as before: a second window sees the
        // Host lock immediately, before the install Task starts.
        guard case .acquire(let token)? = machine.handle(.start).first else { return }
        let effects = machine.handle(.acquired(token, activity?.begin(host.id) ?? true))
        guard !effects.isEmpty else { return }
        let hostID = host.id
        tasks[token] = Task { [weak self, activity] in
            guard let self else {
                activity?.end(hostID)
                return
            }
            await self.perform(effects)
        }
    }

    private func perform(
        _ effects: [WaycarPluginUpdateMachine.Effect], settings: SSHTransportSettings? = nil
    ) async {
        for effect in effects {
            switch effect {
            case .acquire(let token):
                await perform(machine.handle(.acquired(token, activity?.begin(host.id) ?? true)))
            case .install(let token):
                await install(token)
            case .verify(let token, let result):
                guard let settings else { preconditionFailure("Verification needs install settings") }
                await verify(result, token: token, settings: settings)
            case .notify(let presence):
                onUpdated(presence)
            case .release(let token):
                // Only the matching run's completion can emit this effect.
                activity?.end(host.id)
                tasks[token] = nil
                _ = machine.handle(.released(token))
            }
        }
    }

    private func install(_ token: UInt64) async {
        let resolved: SSHCredentials
        do {
            resolved = try credentials.credentials(for: host)
        } catch {
            await perform(machine.handle(.credentialsFailed(token, Self.message(for: error))))
            return
        }
        // The Host is already trusted for its Console connection; never
        // prompt for a first-connect key from inside this sheet.
        let settings = HostOnboardingStore.probeSettings(
            host: host, credentials: resolved,
            knownHosts: UserDefaultsKnownHostsStore.shared
        ) { _ in false }
        let request = self.request

        // A stream keeps the installer's lines in order on the main actor.
        let (lines, sink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        let follower = Task { [weak self] in
            for await line in lines {
                if let self { _ = self.machine.handle(.output(token, line)) }
            }
        }
        defer { follower.cancel() }

        let result: Result<WaycarPluginUpdateResult, WaycarPluginUpdateMachine.Failure>
        do {
            result = .success(try await connector.updateWaycarPlugin(
                settings: settings, request: request,
                progress: { line in sink.yield(line) }))
        } catch {
            result = .failure(.init(
                message: Self.message(for: error), includesLastLine: error is WaycarPluginUpdate.Failure))
        }
        sink.finish()
        await follower.value
        await perform(machine.handle(.installerEnded(token, result)), settings: settings)
    }

    private func verify(
        _ result: WaycarPluginUpdateMachine.Verification, token: UInt64, settings: SSHTransportSettings
    ) async {
        switch result {
        case .installed:
            let presence = try? await connector.detectBackends(settings: settings)
            await perform(machine.handle(.verified(
                token, presence: presence, stillOutdated: isBelowTarget(presence?.waycarPlugin), keptVersion: nil)))
        case .failed:
            let kept = await keptVersionAfterFailure(settings: settings)
            await perform(machine.handle(.verified(token, presence: nil, stillOutdated: false, keptVersion: kept)))
        }
    }

    /// Whether a fresh detection is still below what this run is for: this
    /// build's minimum for the Host's backends, and for a Node-era Host also the native tools'
    /// (`movesToNative`), so a stale waycar.dev that served another Node
    /// version reads as still outdated, not done. Unreadable or missing
    /// detections are not below anything.
    private func isBelowTarget(_ plugin: WaycarPluginDetection?) -> Bool {
        if case .outdated = WaycarPluginRequirement.status(of: plugin, backends: backends) { return true }
        if movesToNative, case .outdated = WaycarPluginRequirement.nativeToolsStatus(of: plugin) {
            return true
        }
        return false
    }

    /// The version still installed after a failed run: a fresh detection
    /// that reads the very version the Host had before the run, so the old
    /// install is in place and the failure replaced nothing. Nil when the
    /// Host had no readable version, the detection fails (Host unreachable),
    /// or it reads anything else.
    private func keptVersionAfterFailure(settings: SSHTransportSettings) async -> String? {
        guard case .installed(let before) = detection, let version = before.version,
            let presence = try? await connector.detectBackends(settings: settings),
            case .installed(let after)? = presence.waycarPlugin, after.version == version
        else { return nil }
        return version
    }

    /// User-facing copy for a failed run.
    nonisolated static func message(for error: any Error) -> String {
        if let transport = error as? TransportError {
            return transport.presentation.message
        }
        if case HostCredentialsError.passwordNotSet = error {
            return "This Host's password is not saved. Edit the Host to add it."
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "The update could not run. (\(error))"
    }

    /// What a failed update says when a fresh detection found the Host's
    /// previous version still installed (`Phase.failed`'s `keptVersion`):
    /// the update did not take, so what worked before still does.
    nonisolated static func keptInstallMessage(version: String) -> String {
        "Waycar \(version) is still installed on this Host, as it was before the update, "
            + "so notifications and chat keep working as before."
    }
}

/// The consent and progress sheet for updating the Waycar plugin on one
/// Host. Opened in place from the Console row, an Agent card, Chat Mode and
/// Host detail.
struct WaycarPluginUpdateSheet: View {
    @Bindable var store: WaycarPluginUpdateStore
    @Environment(\.dismiss) private var dismiss
    @State private var didCopyCommand = false

    init(store: WaycarPluginUpdateStore) {
        self.store = store
    }

    var body: some View {
        NavigationStack {
            List {
                switch store.phase {
                case .confirm:
                    consentSections
                case .running(let latestLine):
                    runningSection(latestLine)
                case .succeeded(let result, let stillOutdated):
                    successSections(result, stillOutdated: stillOutdated)
                case .failed(let message, let lastLine, let keptVersion):
                    failureSections(message, lastLine: lastLine, keptVersion: keptVersion)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(store.isRunning)
        .onChange(of: store.phase) { _, phase in
            announce(phase)
        }
    }

    private var title: String {
        switch store.phase {
        case .confirm:
            "\(store.isInstall ? "Install" : "Update") Waycar on \(store.host.displayName)?"
        case .running: store.isInstall ? "Installing Waycar…" : "Updating Waycar…"
        case .succeeded(_, let stillOutdated):
            stillOutdated
                ? "Waycar Still Outdated"
                : store.isInstall ? "Waycar Installed" : "Waycar Updated"
        case .failed: store.isInstall ? "Install Failed" : "Update Failed"
        }
    }

    /// VoiceOver hears the outcome even when focus is elsewhere.
    private func announce(_ phase: WaycarPluginUpdateStore.Phase) {
        let text: String
        switch phase {
        case .succeeded(_, let stillOutdated):
            text = stillOutdated
                ? "Update finished, but Waycar is still outdated on \(store.host.displayName)."
                : store.isInstall
                    ? "Waycar installed on \(store.host.displayName)."
                    : "Waycar updated on \(store.host.displayName)."
        case .failed(let message, _, let keptVersion):
            let kept = keptVersion.map { " " + WaycarPluginUpdateStore.keptInstallMessage(version: $0) } ?? ""
            text = "\(store.isInstall ? "Install" : "Update") failed. \(message)\(kept)"
        case .confirm, .running:
            return
        }
        AccessibilityNotification.Announcement(text).post()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch store.phase {
        case .confirm:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .tint(Brand.Colors.quietAction)
            }
        case .failed:
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .tint(Brand.Colors.quietAction)
            }
        case .running:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {}
                    .disabled(true)
            }
        case .succeeded:
            ToolbarItem(placement: .confirmationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var consentSections: some View {
        Section {
            bullet("arrow.down.circle", "Downloads the latest installer from waycar.dev and runs it on the Host over SSH.")
            if store.isInstall {
                bullet(
                    "shippingbox",
                    "Installs Waycar's plugin for herdr when herdr is on the Host, otherwise its Host Tools for tmux or herdr-core.")
                bullet("link", "On Hosts with tmux 3.2 or later or herdr-core, points ~/.local/bin/waycar at it.")
                if store.refreshHooks {
                    bullet(
                        "doc.badge.gearshape",
                        "Adds Waycar's hooks to agent settings files (Claude Code, Codex, …), and "
                            + "the opencode and kilo Chat Prompt extensions, on Hosts with tmux 3.2 or later or herdr-core.")
                    bullet("checkmark.shield", "Codex may ask you to review its hooks in /hooks.")
                }
            } else if store.movesToNative {
                bullet(
                    "shippingbox",
                    "Replaces the Node version of Waycar on this Host with the new native one. "
                        + "Waycar no longer needs Node here.")
                bullet(
                    "trash",
                    "Removes the old Node files Waycar installed. Your own Node, npm and nvm stay as they are.")
                if !store.isToolsOnly {
                    bullet("link", "On Hosts with tmux 3.2 or later or herdr-core, also points ~/.local/bin/waycar at the new version.")
                }
                bullet("lock", "Keeps pairing, notification keys and settings.")
                bullet(
                    "doc.badge.gearshape",
                    "Points Waycar's hooks in agent settings files (Claude Code, Codex, …) and the "
                        + "opencode and kilo Chat Prompt extensions at the new tools. The old hooks "
                        + "would stop working without Node files.")
                bullet(
                    "checkmark.shield",
                    "If you use Codex, it will ask you to review the Waycar hooks once in /hooks.")
                if !store.isToolsOnly {
                    bullet("sidebar.left", "herdr's sidebar helper keeps the old version until herdr restarts.")
                }
            } else {
                if store.isToolsOnly {
                    bullet(
                        "shippingbox",
                        "Replaces the Waycar plugin for \(store.mode == .core ? "herdr-core" : "tmux") "
                            + "and points ~/.local/bin/waycar at the new version.")
                } else if let root = store.replacedRoot {
                    bullet("shippingbox", "Replaces the Waycar plugin linked from \(root) with the waycar.dev version.")
                } else {
                    bullet("shippingbox", "Replaces the Waycar plugin with the latest version.")
                }
                if !store.isToolsOnly {
                    bullet("link", "On Hosts with tmux 3.2 or later or herdr-core, also points ~/.local/bin/waycar at the new version.")
                }
                bullet("lock", "Keeps pairing, notification keys and settings.")
                if store.refreshHooks {
                    bullet(
                        "doc.badge.gearshape",
                        "Rewrites the opencode and kilo Chat Prompt extensions, and Waycar's hooks in agent "
                            + "settings files (Claude Code, Codex, …) on Hosts with tmux 3.2 or later or herdr-core.")
                    bullet("checkmark.shield", "Codex may ask you to review its hooks in /hooks.")
                }
                if !store.isToolsOnly {
                    bullet("sidebar.left", "herdr's sidebar helper keeps the old version until herdr restarts.")
                }
            }
        } header: {
            Text("This will")
        }

        if !store.movesToNative {
            Section {
                Toggle(
                    store.isInstall ? "Install agent status hooks" : "Refresh agent status hooks",
                    isOn: $store.refreshHooks)
            } footer: {
                Text(
                    store.isInstall
                        ? "Codex keeps new hooks inactive until you approve them in /hooks. "
                            + "Off skips the agent hooks and the opencode and kilo extensions."
                        : "Codex keeps refreshed hooks inactive until you approve them in /hooks. "
                            + "Off skips the agent hooks and the opencode and kilo extensions.")
            }
        }

        Section {
            Button {
                store.start()
            } label: {
                Text(store.isInstall ? "Install" : "Update")
                    .frame(maxWidth: .infinity)
            }
            .bold()
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Brand.Colors.accent)
        }
    }

    private func runningSection(_ latestLine: String?) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(store.isInstall ? "Installing…" : "Updating…")
            }
            .accessibilityElement(children: .combine)
            if let latestLine {
                Text(latestLine)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Installer: \(latestLine)")
            }
        } footer: {
            Text("Keep Waycar open until the installer finishes.")
        }
    }

    @ViewBuilder
    private func successSections(_ result: WaycarPluginUpdateResult, stillOutdated: Bool) -> some View {
        Section {
            let installed = result.installedVersion.map { "Waycar \($0) installed" } ?? "Waycar installed"
            if stillOutdated {
                Label(installed, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.Colors.warn)
            } else {
                Label(installed, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Brand.Colors.done)
            }
            ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                Label(WaycarPluginUpdate.displayWarning(warning), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if result.codexHooksNeedReview {
                Label(StatusHooksState.codexReviewNote, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if stillOutdated {
                Text(
                    "waycar.dev doesn't have Waycar \(store.requiredVersion) yet. "
                        + "Try again later.")
            } else {
                Text("\(store.host.displayName) reconnects with the new plugin.")
            }
        }
    }

    @ViewBuilder
    private func failureSections(_ message: String, lastLine: String?, keptVersion: String?) -> some View {
        Section {
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(Brand.Colors.danger)
            if let keptVersion {
                Label(
                    WaycarPluginUpdateStore.keptInstallMessage(version: keptVersion),
                    systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let lastLine, lastLine != message {
                Text(lastLine)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button {
                store.start()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }
        let manualCommand = WaycarPluginUpdate.manualCommand(for: store.request)
        Section {
            Text(manualCommand)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = manualCommand
                didCopyCommand = true
            } label: {
                Label(
                    didCopyCommand ? "Copied" : "Copy Command",
                    systemImage: didCopyCommand ? "checkmark" : "doc.on.doc")
            }
        } footer: {
            Text("Or run this in a terminal on the Host.")
        }
    }
}

/// Identity for `.sheet(item:)`: one presentation per store instance.
extension WaycarPluginUpdateStore: Identifiable {}
