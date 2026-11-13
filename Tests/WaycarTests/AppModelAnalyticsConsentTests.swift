import Foundation
import Testing

@testable import Waycar

/// `app_opened` waits for the first-launch analytics answer, goes out once
/// when the user allows, and never goes out when the user declines.
@MainActor
@Suite("App model analytics consent")
struct AppModelAnalyticsConsentTests {
    @MainActor
    private final class RecordingSink: AnalyticsSink {
        private(set) var names: [String] = []

        func enable() {}
        func disable() {}

        func capture(_ name: String, properties: [String: String], distinctID: String) {
            names.append(name)
        }
    }

    private func makeApp() throws -> (WaycarAppModel, GatedAnalytics, RecordingSink) {
        let defaults = try #require(UserDefaults(suiteName: "app-consent-\(UUID().uuidString)"))
        let sink = RecordingSink()
        let analytics = GatedAnalytics(
            sink: sink,
            identity: AnalyticsIdentity(device: VolatileSecretStore(), shared: { nil }),
            defaults: defaults)
        let app = WaycarAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(),
            hostStore: HostStore(volatileHosts: []),
            analytics: analytics)
        return (app, analytics, sink)
    }

    @Test func appOpenedWaitsForAllowThenSendsOncePerLaunch() throws {
        let (app, analytics, sink) = try makeApp()

        app.scenePhaseDidChange(.active)
        #expect(analytics.needsChoice)
        #expect(sink.names.isEmpty)

        app.answerAnalyticsConsent(allow: true)
        #expect(sink.names == ["app_opened"])

        app.scenePhaseDidChange(.active)
        #expect(sink.names == ["app_opened"])
    }

    @Test func decliningSendsNothingNowOrOnActivation() throws {
        let (app, _, sink) = try makeApp()

        app.answerAnalyticsConsent(allow: false)
        #expect(sink.names.isEmpty)

        app.scenePhaseDidChange(.active)
        #expect(sink.names.isEmpty)
    }
}
