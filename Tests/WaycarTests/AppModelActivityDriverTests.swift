import Testing
import UIKit

@testable import Waycar

/// The wiring #167 pins: `WaycarAppModel.start()` running
/// `ConsoleActivityDriver` is the only path that turns an app suspension
/// into a Console teardown (spec #20) and a foreground return into a
/// re-probe (#142). Deleting those lines used to leave the whole suite
/// green, because no test could reach the stores the composition root builds
/// inside itself. The injection seam on `WaycarAppModel.init` exists so this
/// test can hand the real model a volatile Host catalog, a scripted Console,
/// and a fast coordinator, start it the way every window does, and watch the
/// injected stores for the driver's effects.
@MainActor
@Suite("App model activity driver", .timeLimit(.minutes(1)))
struct AppModelActivityDriverTests {
    /// Backgrounding past the grace period must suspend the Host's
    /// connection: the coordinator emits `.suspended`, and only the driver
    /// consuming it calls `console.suspend()`. Both halves of that
    /// consumption are asserted on the injected stores — the connection's
    /// published status, and the background assertion the driver hands back
    /// via `didFinishSuspending()` once the teardown has returned.
    @Test func backgroundingPastTheGracePeriodSuspendsTheConsoleConnection() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let console = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: .default)
        }
        let granter = RecordingBackgroundExecutionGranter()
        let activity = AppActivityCoordinator(
            gracePeriod: .milliseconds(100), granter: granter)

        let app = WaycarAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(),
            hostStore: HostStore(volatileHosts: [host]),
            console: console,
            activity: activity)
        // A second window starting the app again must not start a second
        // driver: the activity stream has exactly one consumer.
        app.start()
        app.start()

        // Start aligns the injected Console with the injected catalog and
        // resumes it.
        try await waitUntil("the injected Host should come up connected") {
            console.hostStatuses[host.id] == .connected
        }

        app.scenePhaseDidChange(.background)

        // The grace period elapses and the coordinator emits `.suspended`.
        // Only the driver turns that into a Console teardown — deleting it
        // leaves the Host `.connected` and this wait red.
        try await waitUntil("the driver should suspend the Host's connection") {
            console.hostStatuses[host.id] == .suspended
        }
        // `console.suspend()` publishes `.suspended` *before* the driver
        // calls `didFinishSuspending()` and ends the assertion. Sampling
        // the granter on the same turn as the status flip is a flake —
        // wait for the second half the same way as the first.
        try await waitUntil("the driver should release the background assertion") {
            granter.endedTokens == granter.beginTokens && granter.endedTokens.count == 1
        }
        console.setHosts([])
    }

    /// The Host catalog feeds the Console through the model's own
    /// observation, not through any window: a Host added after start, with
    /// no view rendering, still reaches the Console.
    @Test func hostsAddedAfterStartReachTheConsoleWithoutAWindow() async throws {
        let first = Host.fixture()
        let second = Host.fixture()
        let console = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, _, subscriptions in
            let transport = ScriptedTransport(snapshot: .fixture())
            return EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: .default)
        }
        let hostStore = HostStore(volatileHosts: [first])
        let app = WaycarAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(),
            hostStore: hostStore,
            console: console,
            activity: AppActivityCoordinator(
                gracePeriod: .seconds(60), granter: RecordingBackgroundExecutionGranter()))
        app.start()
        try await waitUntil("the initial Host should connect") {
            console.hostStatuses[first.id] == .connected
        }

        try hostStore.add(second)

        try await waitUntil("the added Host should connect") {
            console.hostStatuses[second.id] == .connected
        }
        console.setHosts([])
    }

    /// The expiration path (#105): the system took its background time
    /// back, so the Hosts' suspension must not wait on the network. It is
    /// reported while a Transport's close is still parked.
    @Test func theExpirationPathSuspendsWithoutWaitingOnTheNetwork() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let console = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: nil)
        }
        let granter = RecordingBackgroundExecutionGranter()
        let app = WaycarAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(),
            hostStore: HostStore(volatileHosts: [host]),
            console: console,
            activity: AppActivityCoordinator(gracePeriod: .seconds(60), granter: granter))
        app.start()
        try await waitUntil("the Host should come up connected") {
            console.hostStatuses[host.id] == .connected
        }
        let closing = ScriptedTransportCallGate()
        await transport.gateNextClose(using: closing)

        app.scenePhaseDidChange(.background)
        granter.expire()
        try await waitUntil("the Host should suspend with its close still parked") {
            console.hostStatuses[host.id] == .suspended
        }
        try await waitUntil("the close runs on its own") { await closing.entryCount == 1 }
        #expect(await !transport.isClosed)
        await closing.open()
        console.setHosts([])
    }

    /// Turning a Host off through the Host store ends its connection while
    /// the Console keeps its saved state, and turning it back on reconnects
    /// it with no window resuming the Console. Handing the Console only the
    /// enabled Hosts would drop that state; not observing enablement would
    /// leave the Host connected.
    @Test func disablingAHostKeepsItsClosedSessionsAndReenablingReconnectsIt() async throws {
        let host = Host.fixture()
        let closed = ClosedSessionsStore()
        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10), closedSessions: closed
        ) { _, _, subscriptions in
            let transport = ScriptedTransport(snapshot: .fixture())
            return EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: .default)
        }
        let hostStore = HostStore(volatileHosts: [host])
        let app = WaycarAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(),
            hostStore: hostStore,
            console: console,
            activity: AppActivityCoordinator(
                gracePeriod: .seconds(60), granter: RecordingBackgroundExecutionGranter()))
        app.start()
        try await waitUntil("the Host should connect") {
            console.hostStatuses[host.id] == .connected
        }
        closed.record([
            ClosedAgentCapture(
                row: ConsoleAgent(
                    hostID: host.id, hostName: host.name,
                    agent: Agent(
                        terminalID: "t9", kind: "claude", title: "Gone", status: .idle,
                        workspaceID: "w9", tabID: "w9:t1", paneID: "w9:p1", cwd: "/work",
                        revision: 1,
                        agentSession: AgentSessionInfo(
                            agent: "claude", kind: .id, source: "herdr:claude", value: "s-gone")),
                    workspaceLabel: "Gone", repositoryCheckout: nil),
                session: nil, lastSeenRunningAt: closed.now())
        ])
        #expect(closed.sessions.map(\.hostID) == [host.id])

        try hostStore.setEnabled(false, for: host.id)

        try await waitUntil("disabling should end the Host's connection") {
            console.hostStatuses[host.id] == nil
        }
        #expect(closed.sessions.map(\.hostID) == [host.id])

        try hostStore.setEnabled(true, for: host.id)

        try await waitUntil("re-enabling should reconnect the Host") {
            console.hostStatuses[host.id] == .connected
        }
        #expect(closed.sessions.map(\.hostID) == [host.id])
        console.setHosts([])
    }

    /// At launch only `start()` hands the Console its Hosts; the catalog
    /// observer does not fire for the initial value. A Disabled Host must be
    /// among them, or every relaunch would drop its saved state.
    @Test func launchKeepsADisabledHostsClosedSessionsWithoutContactingIt() async throws {
        let on = Host.fixture(name: "On")
        var off = Host.fixture(name: "Off")
        off.isEnabled = false
        let closed = ClosedSessionsStore()
        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10), closedSessions: closed
        ) { _, _, subscriptions in
            let transport = ScriptedTransport(snapshot: .fixture())
            return EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: .default)
        }
        closed.record([
            ClosedAgentCapture(
                row: ConsoleAgent(
                    hostID: off.id, hostName: off.name,
                    agent: Agent(
                        terminalID: "t9", kind: "claude", title: "Gone", status: .idle,
                        workspaceID: "w9", tabID: "w9:t1", paneID: "w9:p1", cwd: "/work",
                        revision: 1,
                        agentSession: AgentSessionInfo(
                            agent: "claude", kind: .id, source: "herdr:claude", value: "s-gone")),
                    workspaceLabel: "Gone", repositoryCheckout: nil),
                session: nil, lastSeenRunningAt: closed.now())
        ])
        let app = WaycarAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(),
            hostStore: HostStore(volatileHosts: [on, off]),
            console: console,
            activity: AppActivityCoordinator(
                gracePeriod: .seconds(60), granter: RecordingBackgroundExecutionGranter()))
        app.start()

        // The enabled Host connecting proves start handed the Console its Hosts.
        try await waitUntil("the enabled Host should connect") {
            console.hostStatuses[on.id] == .connected
        }
        #expect(closed.sessions.map(\.hostID) == [off.id])
        #expect(console.hostStatuses[off.id] == nil)
        console.setHosts([])
    }

    // MARK: Early activation (#105)

    /// A Console whose one Host counts its dials, and the model around it.
    private func makeLaunchingApp(
        hosts: [Host] = [Host.fixture()]
    ) -> (WaycarAppModel, ConsoleStore, Host, DialCounter) {
        let host = hosts[0]
        let transport = ScriptedTransport(snapshot: .fixture())
        let dials = DialCounter()
        let console = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    await dials.count()
                    return transport
                },
                keepalive: nil)
        }
        let app = WaycarAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(),
            hostStore: HostStore(volatileHosts: hosts),
            console: console,
            activity: AppActivityCoordinator(
                gracePeriod: .seconds(60), granter: RecordingBackgroundExecutionGranter()))
        return (app, console, host, dials)
    }

    /// A watch request while the reachable watch app already holds the app
    /// is no return: the connections aren't re-proved. The watch leaving
    /// while CarPlay shows Waycar keeps the app active.
    @Test func aRepeatedWatchActivationIsNoReturn() {
        let (app, _, _, _) = makeLaunchingApp()
        app.watchDidBecomeActive()
        let activations = app.activity.activationCount
        app.watchDidBecomeActive()
        #expect(app.activity.activationCount == activations)

        app.carPlayDidBecomeActive()
        app.watchDidEnterBackground()
        #expect(app.activity.phase == .active)
    }

    @Test func aConnectingSceneDialsBeforeItsWindowStartsTheApp() async throws {
        let (app, console, host, dials) = makeLaunchingApp()
        app.connectAtLaunch()
        try await waitUntil("the Host should connect with no window up") {
            console.hostStatuses[host.id] == .connected
        }
        // The first window finds the dial done and dials nothing again.
        app.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await dials.value == 1)
        #expect(console.hostStatuses[host.id] == .connected)
        console.setHosts([])
    }

    /// The early launch dial (#105) goes by the same catalog as `start()`:
    /// a Disabled Host is never dialed, by it or by the window after it
    /// (#110).
    @Test func theLaunchDialNeverContactsADisabledHost() async throws {
        var off = Host.fixture(name: "Off")
        off.isEnabled = false
        let (app, console, _, dials) = makeLaunchingApp(hosts: [off])
        app.connectAtLaunch()
        app.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await dials.value == 0)
        #expect(console.hostStatuses[off.id] == nil)
        console.setHosts([])
    }

    /// The real launch: a scene-based app launches in the background state
    /// and only then connects its window scene, new or restored from a
    /// saved session; each posts `UIScene.willConnectNotification`, so the
    /// dial hangs off that. This test host connected one; the app window's
    /// notification qualifies, one naming no scene does not.
    @Test func theLaunchWindowSceneStartsTheDials() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first {
                $0.session.role == .windowApplication
            })
        let connecting = Notification(name: UIScene.willConnectNotification, object: scene)
        #expect(
            PushRegistrationDelegate.startsDials(
                forConnecting: connecting, keychainReadable: true))
        #expect(
            !PushRegistrationDelegate.startsDials(
                forConnecting: connecting, keychainReadable: false))
        #expect(
            !PushRegistrationDelegate.startsDials(
                forConnecting: Notification(name: UIScene.willConnectNotification),
                keychainReadable: true))
        #expect(
            !PushRegistrationDelegate.startsDials(
                connecting: .windowExternalDisplayNonInteractive, keychainReadable: true))
    }

    /// A CarPlay launch with the phone locked in a pocket dials too: the
    /// car's list is the only screen (docs/design/carplay.md §6).
    @Test func theCarPlaySceneStartsTheDials() {
        #expect(
            PushRegistrationDelegate.startsDials(
                connecting: .carTemplateApplication, keychainReadable: true,
                carPlaySupported: true))
        // Below iOS 26.4 the scene shows a static screen and dials nothing
        // (and an iPad, never in CarPlay, reads unsupported too).
        #expect(
            !PushRegistrationDelegate.startsDials(
                connecting: .carTemplateApplication, keychainReadable: true,
                carPlaySupported: false))
        #expect(
            PushRegistrationDelegate.startsDials(
                connecting: .windowApplication, keychainReadable: true,
                carPlaySupported: false))
    }

    /// The Host credentials are unreadable (before the first unlock after
    /// a restart): the scene leaves the dial to `start()`.
    @Test func anUnreadableKeychainLeavesTheDialToStart() {
        #expect(
            !PushRegistrationDelegate.startsDials(
                connecting: .windowApplication, keychainReadable: false))
        #expect(
            !PushRegistrationDelegate.startsDials(
                connecting: .carTemplateApplication, keychainReadable: false))
    }

    /// A locked phone's `AfterFirstUnlock` Keychain answers; only the
    /// before-first-unlock refusal reads as "not yet".
    @Test func onlyInteractionNotAllowedMakesTheKeychainUnreadable() {
        #expect(!KeychainReadability.isReadable(status: errSecInteractionNotAllowed))
        #expect(KeychainReadability.isReadable(status: errSecSuccess))
        #expect(KeychainReadability.isReadable(status: errSecItemNotFound))
    }
}

/// Grants background time and records its lifecycle, so the test can see the
/// driver hand the assertion back (`didFinishSuspending`) once the Console's
/// teardown has returned.
@MainActor
private final class RecordingBackgroundExecutionGranter: BackgroundExecutionGranting {
    private(set) var beginTokens: [BackgroundExecutionToken] = []
    private(set) var endedTokens: [BackgroundExecutionToken] = []
    private var nextRawValue = 1

    private var expirations: [@MainActor @Sendable () -> Void] = []

    func begin(
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken? {
        let token = BackgroundExecutionToken(rawValue: nextRawValue)
        nextRawValue += 1
        beginTokens.append(token)
        expirations.append(onExpiration)
        return token
    }

    func end(_ token: BackgroundExecutionToken) {
        endedTokens.append(token)
    }

    /// Stands in for the system reclaiming its background time.
    func expire() {
        let handlers = expirations
        expirations.removeAll()
        for handler in handlers { handler() }
    }

    var backgroundTimeRemaining: Duration { .seconds(10) }
}

private actor DialCounter {
    private(set) var value = 0

    func count() {
        value += 1
    }
}
