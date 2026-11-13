import Foundation
import Testing

@testable import Waycar

/// The consent gate in front of the analytics service, the first-launch
/// question, and the random distinct id every event carries.
@MainActor
@Suite("Analytics")
struct AnalyticsTests {
    @MainActor
    private final class RecordingSink: AnalyticsSink {
        struct Capture: Equatable {
            let name: String
            let properties: [String: String]
            let distinctID: String
        }

        private(set) var captures: [Capture] = []
        private(set) var enableCount = 0
        private(set) var disableCount = 0

        func enable() { enableCount += 1 }
        func disable() { disableCount += 1 }

        func capture(_ name: String, properties: [String: String], distinctID: String) {
            captures.append(Capture(name: name, properties: properties, distinctID: distinctID))
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "analytics-\(UUID().uuidString)"))
    }

    private func deviceOnlyIdentity(_ device: any SecretStore = VolatileSecretStore())
        -> AnalyticsIdentity
    {
        AnalyticsIdentity(device: device, shared: { nil })
    }

    @Test func anUndecidedInstallNeverStartsTheServiceAndDropsEvents() throws {
        let device = VolatileSecretStore()
        let shared = VolatileSecretStore()
        let sink = RecordingSink()
        let analytics = GatedAnalytics(
            sink: sink, identity: AnalyticsIdentity(device: device, shared: { shared }),
            defaults: try makeDefaults())

        analytics.capture(.appOpened)
        analytics.capture(.hostAdded(method: .manual))

        #expect(analytics.needsChoice)
        #expect(!analytics.isEnabled)
        #expect(sink.enableCount == 0)
        #expect(sink.captures.isEmpty)
        // No id was made or synced for events that were never sent.
        #expect(try device.read(account: AnalyticsIdentity.account) == nil)
        #expect(try shared.read(account: AnalyticsIdentity.account) == nil)

        // Allowing later does not replay what was dropped.
        analytics.setEnabled(true)
        #expect(sink.captures.isEmpty)
    }

    @Test func allowingSendsEventsWithOnlyTheAgentKind() throws {
        let sink = RecordingSink()
        let identity = deviceOnlyIdentity()
        let analytics = GatedAnalytics(sink: sink, identity: identity, defaults: try makeDefaults())

        analytics.setEnabled(true)
        analytics.capture(.agentLaunched(kind: .codex))
        let distinctID = try identity.loadOrCreate()

        #expect(!analytics.needsChoice)
        #expect(analytics.isEnabled)
        #expect(sink.enableCount == 1)
        #expect(
            sink.captures == [
                .init(name: "agent_launched", properties: ["kind": "codex"], distinctID: distinctID)
            ])
    }

    @Test func theShareEventFollowsTheSameConsentGateAndCarriesNothing() throws {
        let device = VolatileSecretStore()
        let sink = RecordingSink()
        let identity = deviceOnlyIdentity(device)
        let analytics = GatedAnalytics(sink: sink, identity: identity, defaults: try makeDefaults())

        // Undecided: dropped, not queued, and no identity made for it.
        analytics.capture(.inviteShared)
        #expect(sink.captures.isEmpty)
        #expect(try device.read(account: AnalyticsIdentity.account) == nil)

        analytics.setEnabled(true)
        analytics.capture(.inviteShared)
        let distinctID = try identity.loadOrCreate()
        #expect(
            sink.captures == [
                .init(name: "invite_shared", properties: [:], distinctID: distinctID)
            ])
    }

    @Test func decliningDeletesAnEarlierIDAndStaysOffAcrossLaunchesUntilOptedIn() throws {
        let defaults = try makeDefaults()
        let device = VolatileSecretStore()
        // An earlier version sent by default and left its id behind.
        _ = try deviceOnlyIdentity(device).loadOrCreate()
        let sink = RecordingSink()
        let analytics = GatedAnalytics(
            sink: sink, identity: deviceOnlyIdentity(device), defaults: defaults)

        analytics.setEnabled(false)
        analytics.capture(.appOpened)
        #expect(!analytics.needsChoice)
        #expect(sink.captures.isEmpty)
        #expect(sink.disableCount == 1)
        #expect(try device.read(account: AnalyticsIdentity.account) == nil)

        // A relaunch honours the stored choice, asks nothing, and never
        // starts the service.
        let relaunchedSink = RecordingSink()
        let relaunched = GatedAnalytics(
            sink: relaunchedSink, identity: deviceOnlyIdentity(device), defaults: defaults)
        relaunched.capture(.hostAdded(method: .manual))
        #expect(!relaunched.needsChoice)
        #expect(!relaunched.isEnabled)
        #expect(relaunchedSink.enableCount == 0)
        #expect(relaunchedSink.captures.isEmpty)

        relaunched.setEnabled(true)
        relaunched.capture(.hostAdded(method: .manual))
        #expect(relaunchedSink.enableCount == 1)
        #expect(relaunchedSink.captures.map(\.name) == ["host_added"])
    }

    @Test(arguments: [true, false])
    func aChoiceStoredByAnEarlierVersionIsKeptWithoutAsking(stored: Bool) throws {
        let defaults = try makeDefaults()
        defaults.set(stored, forKey: GatedAnalytics.enabledDefaultsKey)
        let sink = RecordingSink()
        let analytics = GatedAnalytics(sink: sink, identity: deviceOnlyIdentity(), defaults: defaults)

        analytics.capture(.appOpened)

        #expect(!analytics.needsChoice)
        #expect(analytics.isEnabled == stored)
        #expect(sink.enableCount == (stored ? 1 : 0))
        #expect(sink.captures.map(\.name) == (stored ? ["app_opened"] : []))
    }

    @Test func thePromptAsksInOneWindowAndMovesOnIfThatWindowCloses() throws {
        let analytics = GatedAnalytics(
            sink: RecordingSink(), identity: deviceOnlyIdentity(), defaults: try makeDefaults())
        let prompt = AnalyticsConsentPrompt(analytics: analytics)
        let first = UUID()
        let second = UUID()

        prompt.claim(sceneID: first)
        prompt.claim(sceneID: second)
        #expect(prompt.isShown(inScene: first))
        #expect(!prompt.isShown(inScene: second))

        prompt.release(sceneID: second)
        #expect(prompt.isShown(inScene: first))
        prompt.release(sceneID: first)
        prompt.claim(sceneID: second)
        #expect(prompt.isShown(inScene: second))

        analytics.setEnabled(false)
        #expect(!prompt.isShown(inScene: second))
    }

    @Test func thePromptNeverAsksWhereAnalyticsRecordNothing() {
        // The unit-test host, the screenshot mode and previews.
        let prompt = AnalyticsConsentPrompt(analytics: NoopAnalytics())
        let scene = UUID()

        prompt.claim(sceneID: scene)

        #expect(prompt.sceneID == nil)
        #expect(!prompt.isShown(inScene: scene))
    }

    @Test func optingOutDeletesTheSyncedIDSoOptingBackInSendsUnderANewOne() throws {
        let device = VolatileSecretStore()
        let shared = VolatileSecretStore()
        let sink = RecordingSink()
        let analytics = GatedAnalytics(
            sink: sink, identity: AnalyticsIdentity(device: device, shared: { shared }),
            defaults: try makeDefaults())

        analytics.setEnabled(true)
        analytics.capture(.appOpened)
        analytics.setEnabled(false)
        #expect(try device.read(account: AnalyticsIdentity.account) == nil)
        #expect(try shared.read(account: AnalyticsIdentity.account) == nil)

        analytics.setEnabled(true)
        analytics.capture(.appOpened)
        let ids = sink.captures.map(\.distinctID)
        try #require(ids.count == 2)
        #expect(ids[0] != ids[1])
        #expect(try shared.read(account: AnalyticsIdentity.account) == Data(ids[1].utf8))
    }

    @Test func theDistinctIDIsStableAcrossReadsAndReplacedWhenMissing() throws {
        let device = VolatileSecretStore()
        let identity = deviceOnlyIdentity(device)

        let first = try identity.loadOrCreate()
        #expect(UUID(uuidString: first) != nil)
        #expect(try identity.loadOrCreate() == first)
        #expect(try deviceOnlyIdentity(device).loadOrCreate() == first)

        try device.removeSecret(account: AnalyticsIdentity.account)
        let regenerated = try identity.loadOrCreate()
        #expect(regenerated != first)
        #expect(try identity.loadOrCreate() == regenerated)

        try device.write(Data("not-a-uuid".utf8), account: AnalyticsIdentity.account)
        let replaced = try identity.loadOrCreate()
        #expect(replaced != regenerated)
        #expect(UUID(uuidString: replaced) != nil)
    }

    @Test func withSyncOnEveryDeviceSharesTheFirstPublishedID() throws {
        let shared = VolatileSecretStore()
        let iPhoneDevice = VolatileSecretStore()
        let iPadDevice = VolatileSecretStore()
        // The iPad minted its own id while sync was off.
        let iPadOwn = try deviceOnlyIdentity(iPadDevice).loadOrCreate()

        let iPhone = AnalyticsIdentity(device: iPhoneDevice, shared: { shared })
        let iPad = AnalyticsIdentity(device: iPadDevice, shared: { shared })
        let published = try iPhone.loadOrCreate()

        #expect(try iPad.loadOrCreate() == published)
        #expect(published != iPadOwn)
        // Adopted locally, so turning sync off keeps the shared id.
        #expect(try deviceOnlyIdentity(iPadDevice).loadOrCreate() == published)
    }
}
