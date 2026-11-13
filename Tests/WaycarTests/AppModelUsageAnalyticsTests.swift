import Foundation
import Testing

@testable import Waycar

/// The wiring WAY-280 adds to `WaycarAppModel`: what the Console shows
/// becomes the milestones and one `console_active` a day, through the same
/// consent gate as every other event.
@MainActor
@Suite("App model usage analytics", .timeLimit(.minutes(1)))
struct AppModelUsageAnalyticsTests {
    @MainActor
    private final class RecordingSink: AnalyticsSink {
        struct Capture {
            let name: String
            let properties: [String: String]
        }

        private(set) var captures: [Capture] = []

        func enable() {}
        func disable() {}

        func capture(_ name: String, properties: [String: String], distinctID: String) {
            captures.append(Capture(name: name, properties: properties))
        }

        func count(_ name: String) -> Int { captures.filter { $0.name == name }.count }

        var milestones: [String] { captures.compactMap { $0.properties["name"] } }
    }

    private func makeApp(
        allowed: Bool, sink: RecordingSink, console: ConsoleStore, host: Host
    ) throws -> WaycarAppModel {
        let defaults = try #require(UserDefaults(suiteName: "app-usage-\(UUID().uuidString)"))
        let analytics = GatedAnalytics(
            sink: sink,
            identity: AnalyticsIdentity(device: VolatileSecretStore(), shared: { nil }),
            defaults: defaults)
        if allowed { analytics.setEnabled(true) }
        return WaycarAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(),
            hostStore: HostStore(volatileHosts: [host]),
            console: console,
            analytics: analytics)
    }

    private func makeConsole(status: AgentStatus) -> ConsoleStore {
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: status)]))
        return ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
                keepalive: .default)
        }
    }

    /// One connected Host with a Blocked Agent, foregrounded five times: one
    /// `console_active`, and each milestone the Console earned, once.
    @Test func aConnectedHostForegroundedFiveTimesGivesOneConsoleActive() async throws {
        let host = Host.fixture()
        let console = makeConsole(status: .blocked)
        let sink = RecordingSink()
        let app = try makeApp(allowed: true, sink: sink, console: console, host: host)

        app.scenePhaseDidChange(.active)
        app.start()
        try await waitUntil("the Console should report its first active day") {
            sink.count("console_active") == 1
        }
        // Four more returns to the foreground: the Console is up with its
        // Host connected each time.
        for _ in 0..<4 { app.scenePhaseDidChange(.active) }
        try await Task.sleep(for: .milliseconds(50))

        #expect(sink.count("console_active") == 1)
        #expect(
            sink.captures.first { $0.name == "console_active" }?.properties == [
                "hosts": "1", "backend": "herdr", "agents": "1", "steered": "false",
                "push": "off",
            ])
        #expect(Set(sink.milestones) == ["host_connected", "agent_seen", "attention_seen"])
        #expect(sink.milestones.count == 3)
        console.setHosts([])
    }

    @Test func aSteerFromTheConsoleIsTheFirstSteerMilestoneOnce() async throws {
        let host = Host.fixture()
        let console = makeConsole(status: .idle)
        let sink = RecordingSink()
        let app = try makeApp(allowed: true, sink: sink, console: console, host: host)
        _ = app

        console.onSteer?()
        console.onSteer?()

        #expect(sink.milestones == ["first_steer"])
    }

    /// Consent off: the Host connects and the app is foregrounded, and not a
    /// single event is handed to the service.
    @Test func withAnalyticsOffTheConsoleSendsNothing() async throws {
        let host = Host.fixture()
        let console = makeConsole(status: .blocked)
        let sink = RecordingSink()
        let app = try makeApp(allowed: false, sink: sink, console: console, host: host)

        app.scenePhaseDidChange(.active)
        app.start()
        try await waitUntil("the Host should come up connected") {
            console.hostStatuses[host.id] == .connected
        }
        try await Task.sleep(for: .milliseconds(100))
        console.onSteer?()

        #expect(sink.captures.isEmpty)
        console.setHosts([])
    }
}
