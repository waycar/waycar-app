import Foundation
import Testing

@testable import Waycar

/// The internal-build network analytics (#105): buckets, the build-flavor
/// gate, and what the events may carry.
@MainActor
@Suite("Network analytics")
struct NetworkAnalyticsTests {
    @MainActor
    private final class RecordingSink: AnalyticsSink {
        private(set) var names: [String] = []
        private(set) var properties: [[String: String]] = []

        func enable() {}
        func disable() {}

        func capture(_ name: String, properties: [String: String], distinctID: String) {
            names.append(name)
            self.properties.append(properties)
        }
    }

    private static let connect = AnalyticsEvent.hostConnected(
        HostConnectReport(
            outcome: .success, duration: .milliseconds(180), path: .kept, trigger: .foreground))

    private static let networkEvents: [AnalyticsEvent] = [
        connect,
        .terminalAttached(
            TerminalAttachReport(
                transport: .mosh, route: .standby, outcome: .success, duration: .milliseconds(420),
                foregroundReturn: ForegroundReturn(
                    absence: .seconds(45), crossedGrace: true, at: .now))),
        .transportLost(
            TransportLossReport(transport: .ssh, reason: .unreachable, recovery: .seconds(3))),
        .appForegrounded(absence: .seconds(12)),
    ]

    /// `allowsAdmin` stands for `AppEnvironment.allowsAdmin`: true in Debug
    /// and in an admin build on a verified non-production receipt.
    private func allowedAnalytics(
        _ sink: RecordingSink, build: BuildFlavor,
        allowsAdmin: @escaping @MainActor () -> Bool = { true }
    ) throws -> GatedAnalytics {
        let defaults = try #require(UserDefaults(suiteName: "network-analytics-\(UUID().uuidString)"))
        let analytics = GatedAnalytics(
            sink: sink, identity: AnalyticsIdentity(device: VolatileSecretStore(), shared: { nil }),
            defaults: defaults, build: build, allowsAdmin: allowsAdmin)
        analytics.setEnabled(true)
        return analytics
    }

    // MARK: Buckets

    @Test(arguments: [
        (-5, "0-100"), (0, "0-100"), (99, "0-100"), (100, "100-250"), (249, "100-250"),
        (250, "250-500"), (999, "500-1000"), (1000, "1000-2000"), (4999, "2000-5000"),
        (9999, "5000-10000"), (10_000, "10000+"), (600_000, "10000+"),
    ])
    func millisecondsFallInTheirBucket(milliseconds: Int, bucket: String) {
        #expect(NetworkAnalytics.millisecondsBucket(.milliseconds(milliseconds)) == bucket)
    }

    /// Background buckets break on the lifecycle's edges: the 20 s grace
    /// period, and 70 s, past which a standby has aged out.
    @Test(arguments: [
        (0, "0-5"), (4_999, "0-5"), (5_000, "5-20"), (19_999, "5-20"), (20_000, "20-70"),
        (69_999, "20-70"), (70_000, "70-300"), (1_799_000, "300-1800"), (3_599_000, "1800-3600"),
        (3_600_000, "3600+"),
    ])
    func backgroundTimesFallInTheirBucket(milliseconds: Int, bucket: String) {
        #expect(NetworkAnalytics.backgroundBucket(.milliseconds(milliseconds)) == bucket)
    }

    @Test func missingTimesHaveTheirOwnWords() {
        #expect(NetworkAnalytics.backgroundBucket(nil) == "none")
        #expect(NetworkAnalytics.recoveryBucket(nil) == "never")
        #expect(NetworkAnalytics.recoveryBucket(.milliseconds(300)) == "250-500")
    }

    // MARK: Build gate

    /// The App Store build sends none of the network events, whatever the
    /// user allowed; its product events go out as before.
    @Test func anAppStoreBuildNeverSendsNetworkEvents() throws {
        let sink = RecordingSink()
        let analytics = try allowedAnalytics(sink, build: .appStore)

        for event in Self.networkEvents { analytics.capture(event) }
        analytics.capture(.appOpened)

        #expect(sink.names == ["app_opened"])
    }

    @Test func anInternalBuildSendsNetworkEvents() throws {
        let sink = RecordingSink()
        let analytics = try allowedAnalytics(sink, build: .internalTesting)

        for event in Self.networkEvents { analytics.capture(event) }

        #expect(sink.names == ["host_connect", "terminal_attach", "transport_lost", "app_foregrounded"])
    }

    /// The pairing funnel (WAY-210): started and abandoned carry no failure
    /// reason and go out from the App Store build; `pairing_failed`, which
    /// does, stays with internal builds.
    @Test func pairingFailureReasonsReachOnlyInternalBuilds() throws {
        let funnel: [AnalyticsEvent] = [
            .pairingStarted(method: .paste),
            .pairingFailed(method: .paste, reason: .verify),
            .pairingAbandoned(method: .paste, stage: .verify),
        ]
        let store = RecordingSink()
        let appStore = try allowedAnalytics(store, build: .appStore)
        for event in funnel { appStore.capture(event) }
        #expect(store.names == ["pairing_started", "pairing_abandoned"])
        #expect(store.properties.allSatisfy { $0["reason"] == nil })

        let internalSink = RecordingSink()
        let internalBuild = try allowedAnalytics(internalSink, build: .internalTesting)
        for event in funnel { internalBuild.capture(event) }
        #expect(internalSink.names == ["pairing_started", "pairing_failed", "pairing_abandoned"])
        #expect(internalSink.properties[1] == ["method": "paste", "reason": "verify"])
    }

    @Test func abandoningBeforeAnyCodeNamesNoMethod() {
        #expect(
            AnalyticsEvent.pairingAbandoned(method: nil, stage: .scan).properties
                == ["method": "none", "stage": "scan"])
    }

    /// An admin TestFlight binary attached to an App Store version (ADR
    /// 0023): its receipt is production, or not yet verified, so it sends
    /// no network events however it was compiled. The check is made per
    /// event, so a receipt verified later lets the next ones through.
    @Test func anAdminBuildSendsNetworkEventsOnlyOnceItsReceiptAllowsAdmin() throws {
        let sink = RecordingSink()
        var receiptAllowsAdmin = false
        let analytics = try allowedAnalytics(
            sink, build: .internalTesting, allowsAdmin: { receiptAllowsAdmin })

        for event in Self.networkEvents { analytics.capture(event) }
        analytics.capture(.appOpened)
        #expect(sink.names == ["app_opened"])

        receiptAllowsAdmin = true
        analytics.capture(Self.connect)
        #expect(sink.names == ["app_opened", "host_connect"])
    }

    /// The build gate adds to the user's choice; it never replaces it.
    @Test func anInternalBuildStillWaitsForTheUsersChoice() throws {
        let sink = RecordingSink()
        let defaults = try #require(UserDefaults(suiteName: "network-analytics-\(UUID().uuidString)"))
        let analytics = GatedAnalytics(
            sink: sink, identity: AnalyticsIdentity(device: VolatileSecretStore(), shared: { nil }),
            defaults: defaults, build: .internalTesting, allowsAdmin: { true })

        analytics.capture(Self.connect)
        analytics.setEnabled(false)
        analytics.capture(Self.connect)

        #expect(sink.names.isEmpty)
    }

    // MARK: Properties

    @Test func eachEventCarriesOnlyItsWordsAndBuckets() {
        #expect(
            Self.networkEvents.map(\.properties) == [
                ["outcome": "success", "dial_ms": "100-250", "path": "kept", "trigger": "foreground"],
                [
                    "transport": "mosh", "via": "standby", "outcome": "success", "ms": "250-500",
                    "after_grace": "true", "bg_s": "20-70",
                ],
                ["transport": "ssh", "reason": "unreachable", "recovered_ms": "2000-5000"],
                ["bg_s": "5-20"],
            ])
    }

    /// Each connect trigger reports as its own snake_case word, so a
    /// mosh-recovery redial never counts as a path change.
    @Test func eachConnectTriggerReportsItsOwnWord() {
        let words = NetworkAnalytics.ConnectTrigger.allCases.map { trigger in
            AnalyticsEvent.hostConnected(
                HostConnectReport(
                    outcome: .success, duration: .milliseconds(180), path: .fresh, trigger: trigger)
            ).properties["trigger"]
        }
        #expect(words == ["launch", "foreground", "retry", "path_change", "mosh_recovery"])
    }

    /// Errors name Hosts, addresses and paths in their detail; an event
    /// built from one carries only its class.
    @Test func eventsBuiltFromErrorsCarryNoHostData() {
        let errors: [any Error] = [
            TransportError.sshUnreachable(detail: "build.example.com (192.0.2.7) refused"),
            TransportError.socketNotFound(path: "/home/alice/.config/herdr/herdr.sock"),
            TransportError.jumpHostFailed(.sshUnreachable(detail: "bastion.example.com")),
            TransportError.apiRejected(code: "pane_not_found", message: "pane w1-p7 in /srv/app"),
            TransportError.moshSessionFailed(detail: "192.0.2.7:60001 never answered"),
            TransportError.channelFailed(detail: "alice@build.example.com"),
        ]
        let leaks = ["example.com", "192.0.2.7", "alice", "/home", "/srv", "w1-p7", "60001"]
        for error in errors {
            let events: [AnalyticsEvent] = [
                .hostConnected(
                    HostConnectReport(
                        outcome: .init(error), duration: .seconds(1), path: .fresh, trigger: .retry)),
                .terminalAttached(
                    TerminalAttachReport(
                        transport: .ssh, route: .live, outcome: .init(error), duration: .seconds(1),
                        foregroundReturn: nil)),
                .transportLost(
                    TransportLossReport(
                        transport: .mosh, reason: .init(error), recovery: nil)),
            ]
            for event in events {
                let values = event.properties.values.joined(separator: " ")
                #expect(!leaks.contains { values.contains($0) }, "\(event.name): \(values)")
            }
        }
    }

    @Test func failuresAreClassifiedNotDescribed() {
        #expect(NetworkAnalytics.Failure(MoshLinkLost(timeoutMs: 15_000)) == .timeout)
        #expect(NetworkAnalytics.Failure(CancellationError()) == .cancelled)
        #expect(NetworkAnalytics.Failure(TransportError.jumpHostFailed(.authenticationFailed)) == .jumpHost)
        let key = HostKeyFingerprint(digest: Data([1]))
        #expect(NetworkAnalytics.Failure(TransportError.hostKeyMismatch(known: key, presented: key)) == .hostKey)
        #expect(NetworkAnalytics.Failure(TransportError.tmuxTooOld(found: "3.1")) == .tmux)
    }

    // MARK: Foreground return

    @Test func anAttachBelongsToAReturnOnlyWithinItsWindow() {
        let at = ContinuousClock.now
        let back = ForegroundReturn(absence: .seconds(30), crossedGrace: true, at: at)

        #expect(back.covers(at))
        #expect(back.covers(at + ForegroundReturn.attachWindow))
        #expect(!back.covers(at + ForegroundReturn.attachWindow + .milliseconds(1)))
        #expect(!back.covers(at - .milliseconds(1)))
    }
}
