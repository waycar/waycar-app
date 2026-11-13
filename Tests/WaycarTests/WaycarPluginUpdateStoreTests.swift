import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Waycar plugin update store")
struct WaycarPluginUpdateStoreTests {
    /// Every presence `onUpdated` received, in order.
    @MainActor
    private final class UpdatedLog {
        var presences: [HostBackendPresence?] = []
    }

    /// The store never dials a Transport; any dial would fail.
    private static let noDial = FakeTransportConnector.Outcome.unreachable(.timedOut)

    private static let installed = WaycarPluginUpdateResult(
        installedVersion: "1.4.0", warnings: [], codexHooksNeedReview: false,
        output: ["waycar: installed Waycar 1.4.0 for tmux in /x"])

    private static let outdatedTmux = WaycarPluginDetection.installed(
        WaycarPluginInstall(version: "1.3.0", mode: .tmux))

    private static func tmuxPresence(pluginVersion: String) -> HostBackendPresence {
        HostBackendPresence(
            herdr: false, tmuxVersion: "3.4",
            waycarPlugin: .installed(WaycarPluginInstall(version: pluginVersion, mode: .tmux)))
    }

    private func makeStore(
        host: Host = .fixture(),
        detection: WaycarPluginDetection? = outdatedTmux,
        connector: FakeTransportConnector,
        activity: WaycarPluginUpdateActivity
    ) -> (WaycarPluginUpdateStore, UpdatedLog) {
        let log = UpdatedLog()
        let store = WaycarPluginUpdateStore(
            host: host,
            detection: detection,
            connector: connector,
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            onUpdated: { log.presences.append($0) },
            activity: activity)
        return (store, log)
    }

    @Test func onlyAHostWithoutThePluginIsAnInstall() {
        let connector = FakeTransportConnector(outcome: Self.noDial, update: .success(Self.installed))
        let activity = WaycarPluginUpdateActivity()
        let cases: [(WaycarPluginDetection?, Bool)] = [
            (.notInstalled, true),
            (Self.outdatedTmux, false),
            (nil, false),
        ]
        for (detection, isInstall) in cases {
            let (store, _) = makeStore(detection: detection, connector: connector, activity: activity)
            #expect(store.isInstall == isInstall)
        }
    }

    @Test func successRunsInTheHostsModeAndReportsTheFreshDetection() async throws {
        let host = Host.fixture()
        let fresh = Self.tmuxPresence(pluginVersion: WaycarPluginRequirement.nativeToolsMinimumVersion)
        let connector = FakeTransportConnector(
            outcome: Self.noDial, presence: fresh,
            update: .success(Self.installed))
        let activity = WaycarPluginUpdateActivity()
        let (store, log) = makeStore(host: host, connector: connector, activity: activity)
        store.refreshHooks = false

        store.start()
        try await waitUntil("the run finishes") { !store.isRunning }

        #expect(
            await connector.updateRequests
                == [WaycarPluginUpdateRequest(mode: .tmux, refreshHooks: false)])
        #expect(store.phase == .succeeded(Self.installed, stillOutdated: false))
        #expect(log.presences == [fresh])
        try await waitUntil("the Host's update is released") { activity.runningHosts.isEmpty }
    }

    @Test func freshDetectionBelowTheMinimumIsStillOutdated() async throws {
        let fresh = Self.tmuxPresence(pluginVersion: "1.3.1")
        let connector = FakeTransportConnector(
            outcome: Self.noDial, presence: fresh,
            update: .success(Self.installed))
        let (store, log) = makeStore(connector: connector, activity: WaycarPluginUpdateActivity())

        store.start()
        try await waitUntil("the run finishes") { !store.isRunning }

        #expect(store.phase == .succeeded(Self.installed, stillOutdated: true))
        #expect(log.presences == [fresh])
    }

    @Test func installerFailureShowsItsMessageOnceAndReleasesTheHost() async throws {
        let host = Host.fixture()
        let errorLine = "waycar: error: could not download x"
        let connector = FakeTransportConnector(
            outcome: Self.noDial,
            update: .failure(
                WaycarPluginUpdate.Failure(line: errorLine, exitStatus: 1, output: [errorLine])),
            updateProgress: [errorLine])
        let activity = WaycarPluginUpdateActivity()
        let (store, log) = makeStore(host: host, connector: connector, activity: activity)

        store.start()
        try await waitUntil("the run finishes") { !store.isRunning }

        #expect(
            store.phase == .failed(message: "Could not download x", lastLine: nil, keptVersion: nil))
        #expect(log.presences.isEmpty)
        #expect(await connector.detectionCount == 1)
        try await waitUntil("the Host's update is released") { activity.runningHosts.isEmpty }

        // Retry runs the installer again.
        store.start()
        #expect(store.isRunning)
        try await waitUntil("the retry finishes") { !store.isRunning }
        #expect(await connector.updateRequests.count == 2)
        #expect(await connector.detectionCount == 2, "each failure re-reads the plugin once")
        #expect(
            store.phase == .failed(message: "Could not download x", lastLine: nil, keptVersion: nil))
        try await waitUntil("the retry is released") { activity.runningHosts.isEmpty }
    }

    @Test func secondRunOnTheSameHostIsRefused() async throws {
        let host = Host.fixture()
        let connector = FakeTransportConnector(
            outcome: Self.noDial, update: .success(Self.installed))
        let activity = WaycarPluginUpdateActivity()
        #expect(activity.begin(host.id))
        let (store, log) = makeStore(host: host, connector: connector, activity: activity)

        store.start()
        await Task.yield()

        let refusal = "An update is already running on this Host."
        #expect(store.phase == .failed(message: refusal, lastLine: nil, keptVersion: nil))
        #expect(await connector.updateRequests.isEmpty)
        #expect(await connector.detectionCount == 0)
        #expect(log.presences.isEmpty)
        // The other run keeps its hold on the Host.
        #expect(activity.runningHosts == [host.id])
    }

    @Test func failedRedetectionAfterInstallReportsNilPresence() async throws {
        let connector = FakeTransportConnector(
            outcome: Self.noDial, detectionError: .timedOut,
            update: .success(Self.installed))
        let (store, log) = makeStore(connector: connector, activity: WaycarPluginUpdateActivity())

        store.start()
        try await waitUntil("the run finishes") { !store.isRunning }

        #expect(store.phase == .succeeded(Self.installed, stillOutdated: false))
        #expect(log.presences == [nil])
        #expect(await connector.detectionCount == 1)
    }

    // MARK: Move off Node (WAY-451)

    private static func herdrDetection(_ version: String?) -> WaycarPluginDetection {
        .installed(WaycarPluginInstall(version: version, mode: .herdr))
    }

    private static func herdrPresence(_ version: String) -> HostBackendPresence {
        HostBackendPresence(herdr: true, tmuxVersion: nil, waycarPlugin: herdrDetection(version))
    }

    /// Only a Host known to run a Node-era plugin is a move; the sheet and the
    /// check of its result then use the native minimum.
    @Test func aNodeEraPluginIsAMoveToTheNativeTools() {
        let connector = FakeTransportConnector(outcome: Self.noDial, update: .success(Self.installed))
        let activity = WaycarPluginUpdateActivity()
        let native = WaycarPluginRequirement.nativeToolsMinimumVersion
        let cases: [(WaycarPluginDetection?, Bool)] = [
            (Self.herdrDetection("1.7.0"), true),
            (Self.herdrDetection("1.99.0"), true),
            (Self.outdatedTmux, true),
            (Self.herdrDetection(native), false),
            (Self.herdrDetection("2.0.0-beta"), false),
            (Self.herdrDetection(nil), false),
            (Self.herdrDetection("garbage"), false),
            (.notInstalled, false),
            (nil, false),
        ]
        for (detection, moves) in cases {
            let (store, _) = makeStore(detection: detection, connector: connector, activity: activity)
            #expect(store.movesToNative == moves, "\(String(describing: detection))")
            #expect(
                store.requiredVersion
                    == (moves ? native : WaycarPluginRequirement.minimumVersion))
        }
    }

    /// waycar.dev served another Node version: the Host is above this build's
    /// minimum but still Node-era, so the prompt would come straight back.
    @Test func aMoveThatEndsOnAnotherNodeVersionIsStillOutdated() async throws {
        let stale = Self.herdrPresence("1.8.0")
        let connector = FakeTransportConnector(
            outcome: Self.noDial, presence: stale, update: .success(Self.installed))
        let (store, log) = makeStore(
            detection: Self.herdrDetection("1.7.0"), connector: connector,
            activity: WaycarPluginUpdateActivity())

        store.start()
        try await waitUntil("the run finishes") { !store.isRunning }

        #expect(store.phase == .succeeded(Self.installed, stillOutdated: true))
        #expect(log.presences == [stale])
    }

    @Test func aMoveThatReachesTheNativeMinimumIsDone() async throws {
        let native = Self.herdrPresence(WaycarPluginRequirement.nativeToolsMinimumVersion)
        let connector = FakeTransportConnector(
            outcome: Self.noDial, presence: native, update: .success(Self.installed))
        let (store, log) = makeStore(
            detection: Self.herdrDetection("1.7.0"), connector: connector,
            activity: WaycarPluginUpdateActivity())

        store.start()
        try await waitUntil("the run finishes") { !store.isRunning }

        #expect(store.phase == .succeeded(Self.installed, stillOutdated: false))
        #expect(log.presences == [native])
    }

    /// A Host with no Node-era plugin (an install) never reads as still
    /// outdated against the native minimum, so an installer that served a
    /// newer-than-minimum 1.x does not claim the Host is outdated.
    @Test func aFreshInstallIsNotMeasuredAgainstTheNativeMinimum() async throws {
        let fresh = Self.herdrPresence(WaycarPluginRequirement.minimumVersion)
        let connector = FakeTransportConnector(
            outcome: Self.noDial, presence: fresh, update: .success(Self.installed))
        let (store, _) = makeStore(
            detection: .notInstalled, connector: connector, activity: WaycarPluginUpdateActivity())

        store.start()
        try await waitUntil("the run finishes") { !store.isRunning }

        #expect(store.phase == .succeeded(Self.installed, stillOutdated: false))
    }

    // MARK: Failed update that left the old install working

    private func failedRun(
        before: WaycarPluginDetection, after: HostBackendPresence?, detectionError: TransportError? = nil
    ) async throws -> (WaycarPluginUpdateStore.Phase, UpdatedLog) {
        let errorLine = "waycar: error: the new tools would not start on this Host"
        let connector = FakeTransportConnector(
            outcome: Self.noDial, presence: after ?? .herdrOnly, detectionError: detectionError,
            update: .failure(
                WaycarPluginUpdate.Failure(line: errorLine, exitStatus: 1, output: [errorLine])))
        let (store, log) = makeStore(
            detection: before, connector: connector, activity: WaycarPluginUpdateActivity())
        store.start()
        try await waitUntil("the run finishes") { !store.isRunning }
        return (store.phase, log)
    }

    @Test func aFailedUpdateThatLeftTheOldVersionInPlaceSaysSo() async throws {
        let (phase, log) = try await failedRun(
            before: Self.herdrDetection("1.7.0"), after: Self.herdrPresence("1.7.0"))

        #expect(
            phase
                == .failed(
                    message: "The new tools would not start on this Host", lastLine: nil,
                    keptVersion: "1.7.0"))
        #expect(log.presences.isEmpty, "a failure does not report a presence")
        let message = WaycarPluginUpdateStore.keptInstallMessage(version: "1.7.0")
        #expect(message.contains("Waycar 1.7.0 is still installed"))
        #expect(message.contains("keep working as before"))
    }

    /// The claim needs evidence: the fresh read must be the version the Host
    /// had. A different version, an unreadable one, a failed read, no version
    /// before the run and no plugin before it all say nothing.
    @Test func aFailedUpdateOnlyClaimsTheOldInstallWhenAFreshReadShowsIt() async throws {
        let unchanged = Self.herdrPresence("1.7.0")
        let cases: [(WaycarPluginDetection, HostBackendPresence?, TransportError?)] = [
            (Self.herdrDetection("1.7.0"), Self.herdrPresence("2.0.0"), nil),
            (Self.herdrDetection("1.7.0"), Self.herdrPresence("1.6.0"), nil),
            (Self.herdrDetection("1.7.0"), HostBackendPresence(herdr: true, tmuxVersion: nil, waycarPlugin: .notInstalled), nil),
            (Self.herdrDetection("1.7.0"), .herdrOnly, nil),
            (Self.herdrDetection("1.7.0"), unchanged, .timedOut),
            (Self.herdrDetection(nil), Self.herdrPresence("1.7.0"), nil),
            (.notInstalled, unchanged, nil),
        ]
        for (before, after, error) in cases {
            let (phase, _) = try await failedRun(before: before, after: after, detectionError: error)
            guard case .failed(_, _, let kept) = phase else {
                Issue.record("not failed: \(phase)")
                continue
            }
            #expect(kept == nil, "before \(before), after \(String(describing: after))")
        }
    }
}
