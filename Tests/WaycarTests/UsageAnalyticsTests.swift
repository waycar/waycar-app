import Foundation
import Testing

@testable import Waycar

/// `console_active` and the milestones (WAY-280): consent in front of them,
/// once per local day and once per install, and only fixed words and ranges
/// in their properties.
@MainActor
@Suite("Usage analytics")
struct UsageAnalyticsTests {
    @MainActor
    private final class RecordingSink: AnalyticsSink {
        struct Capture: Equatable {
            let name: String
            let properties: [String: String]
            let distinctID: String
        }

        private(set) var captures: [Capture] = []
        private(set) var enableCount = 0

        func enable() { enableCount += 1 }
        func disable() {}

        func capture(_ name: String, properties: [String: String], distinctID: String) {
            captures.append(Capture(name: name, properties: properties, distinctID: distinctID))
        }

        var names: [String] { captures.map(\.name) }
    }

    @MainActor
    private final class TestClock {
        var date: Date
        init(_ iso: String) { date = ISO8601DateFormatter().date(from: iso)! }
        func advance(days: Int = 0, hours: Int = 0) {
            date = date.addingTimeInterval(TimeInterval(days * 86_400 + hours * 3_600))
        }
    }

    private static let snapshot = ConsoleSnapshot(hosts: 2, backend: .both, agents: 3, push: true)

    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private struct Rig {
        let analytics: GatedAnalytics
        let sink: RecordingSink
        let clock: TestClock
        let device: VolatileSecretStore
    }

    /// An allowed analytics whose days are the UTC days of `clock`.
    private func makeRig(
        allowed: Bool = true, start: String = "2026-11-02T09:00:00Z"
    ) throws -> Rig {
        let defaults = try #require(UserDefaults(suiteName: "usage-\(UUID().uuidString)"))
        let clock = TestClock(start)
        let sink = RecordingSink()
        let device = VolatileSecretStore()
        let progress = AnalyticsProgress(
            defaults: defaults, calendar: utc, now: { clock.date })
        let analytics = GatedAnalytics(
            sink: sink, identity: AnalyticsIdentity(device: device, shared: { nil }),
            defaults: defaults, progress: progress)
        if allowed { analytics.setEnabled(true) }
        return Rig(analytics: analytics, sink: sink, clock: clock, device: device)
    }

    @Test func fiveForegroundsInADayGiveOneConsoleActive() throws {
        let rig = try makeRig()
        for hour in [0, 3, 6, 8, 14] {
            rig.clock.date = ISO8601DateFormatter().date(from: "2026-11-02T09:00:00Z")!
            rig.clock.advance(hours: hour)
            rig.analytics.consoleActive(Self.snapshot)
        }
        #expect(rig.sink.names == ["console_active"])
        #expect(
            rig.sink.captures[0].properties == [
                "hosts": "2-3", "backend": "both", "agents": "2-4", "steered": "false",
                "push": "on",
            ])

        // 00:30 the next local day is a new day.
        rig.clock.date = ISO8601DateFormatter().date(from: "2026-11-03T00:30:00Z")!
        rig.analytics.consoleActive(Self.snapshot)
        #expect(rig.sink.names == ["console_active", "console_active"])
    }

    @Test func theDayFollowsTheDevicesTimeZoneNotUTC() throws {
        let defaults = try #require(UserDefaults(suiteName: "usage-\(UUID().uuidString)"))
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let clock = TestClock("2026-11-03T01:00:00Z")  // 20:00 on Nov 2 in New York
        let sink = RecordingSink()
        let analytics = GatedAnalytics(
            sink: sink, identity: AnalyticsIdentity(device: VolatileSecretStore(), shared: { nil }),
            defaults: defaults,
            progress: AnalyticsProgress(defaults: defaults, calendar: newYork, now: { clock.date }))
        analytics.setEnabled(true)

        analytics.consoleActive(Self.snapshot)
        clock.date = ISO8601DateFormatter().date(from: "2026-11-03T04:30:00Z")!  // 23:30, same day
        analytics.consoleActive(Self.snapshot)
        #expect(sink.names == ["console_active"])

        clock.date = ISO8601DateFormatter().date(from: "2026-11-03T05:30:00Z")!  // 00:30 Nov 3
        analytics.consoleActive(Self.snapshot)
        #expect(sink.names == ["console_active", "console_active"])
    }

    @Test func nothingReachesTheServiceWhileUndecidedOrOff() throws {
        let rig = try makeRig(allowed: false)
        rig.analytics.consoleActive(Self.snapshot)
        rig.analytics.milestone(.hostConnected)
        rig.analytics.noteSteer()
        #expect(rig.sink.captures.isEmpty)
        #expect(rig.sink.enableCount == 0)
        #expect(try rig.device.read(account: AnalyticsIdentity.account) == nil)

        // What was dropped was not spent: the first allowed call still goes out.
        rig.analytics.setEnabled(true)
        rig.analytics.consoleActive(Self.snapshot)
        rig.analytics.milestone(.hostConnected)
        #expect(rig.sink.names == ["console_active", "milestone"])
        // And a steer made while off was not remembered.
        #expect(rig.sink.captures[0].properties["steered"] == "false")
    }

    @Test func eachMilestoneGoesOutOncePerInstall() throws {
        let rig = try makeRig()
        let all: [Milestone] = [
            .hostConnected, .agentSeen, .attentionSeen, .firstSteer, .sampleHostOpened,
            .lanScanStarted, .lanScanFound(count: 0), .lanPermissionDenied,
        ]
        for _ in 0..<3 { for milestone in all { rig.analytics.milestone(milestone) } }

        #expect(rig.sink.names == Array(repeating: "milestone", count: all.count))
        #expect(
            rig.sink.captures.map { $0.properties["name"] } == [
                "host_connected", "agent_seen", "attention_seen", "first_steer",
                "sample_host_opened", "lan_scan_started", "lan_scan_found",
                "lan_permission_denied",
            ])
        // A later scan with a better result does not report a second time.
        rig.analytics.milestone(.lanScanFound(count: 4))
        #expect(rig.sink.captures.count == all.count)
    }

    @Test func milestonesNameTheDaysSinceFirstOpenAsARange() throws {
        let rig = try makeRig()
        let names: [Milestone] = [.hostConnected, .agentSeen, .attentionSeen, .firstSteer]
        // Days after first open: 0, 2, 5, 20.
        for (milestone, days) in zip(names, [0, 2, 3, 15]) {
            rig.clock.advance(days: days)
            rig.analytics.milestone(milestone)
        }
        #expect(
            rig.sink.captures.map { $0.properties["days_since_first_open"] } == [
                "0", "1-3", "4-7", "8+",
            ])
    }

    @Test func aScanReportsHowManyComputersAsARangeOnly() {
        let counts = [0, 1, 2, 9].map {
            AnalyticsEvent.milestone(.lanScanFound(count: $0), daysSinceFirstOpen: 0)
                .properties["found"]
        }
        #expect(counts == ["0", "1", "2+", "2+"])
        #expect(
            AnalyticsEvent.milestone(.hostConnected, daysSinceFirstOpen: 0).properties["found"]
                == nil)
    }

    @Test func steeringIsReportedOnTheNextActiveDayThenClears() throws {
        let rig = try makeRig()
        rig.analytics.consoleActive(Self.snapshot)
        rig.analytics.noteSteer()
        rig.analytics.noteSteer()

        rig.clock.advance(days: 1)
        rig.analytics.consoleActive(Self.snapshot)
        rig.clock.advance(days: 1)
        rig.analytics.consoleActive(Self.snapshot)

        let steered = rig.sink.captures.filter { $0.name == "console_active" }
            .map { $0.properties["steered"] }
        #expect(steered == ["false", "true", "false"])
        // first_steer went out once, for two steers.
        #expect(rig.sink.captures.filter { $0.properties["name"] == "first_steer" }.count == 1)
    }

    @Test func optingOutAndBackInStartsANewIDButDoesNotRepeatOnceOnlyEvents() throws {
        let rig = try makeRig()
        rig.analytics.milestone(.hostConnected)
        rig.analytics.consoleActive(Self.snapshot)
        rig.analytics.setEnabled(false)
        rig.analytics.milestone(.agentSeen)
        rig.analytics.consoleActive(Self.snapshot)
        rig.analytics.setEnabled(true)
        rig.analytics.milestone(.hostConnected)
        rig.analytics.consoleActive(Self.snapshot)
        #expect(rig.sink.names == ["milestone", "console_active"])

        // Off recorded nothing, so a firsts it missed is still new.
        rig.analytics.milestone(.agentSeen)
        #expect(rig.sink.names == ["milestone", "console_active", "milestone"])

        // A later local day still sends, under a new ID.
        rig.clock.advance(days: 1)
        rig.analytics.consoleActive(Self.snapshot)
        #expect(rig.sink.names.last == "console_active")
        #expect(rig.sink.captures[0].distinctID != rig.sink.captures[3].distinctID)
    }

    @Test func recordsSurviveARelaunchAfterAnOptOut() throws {
        let defaults = try #require(UserDefaults(suiteName: "usage-\(UUID().uuidString)"))
        let clock = TestClock("2026-11-02T09:00:00Z")
        let sink = RecordingSink()
        let device = VolatileSecretStore()
        func launch() -> GatedAnalytics {
            GatedAnalytics(
                sink: sink, identity: AnalyticsIdentity(device: device, shared: { nil }),
                defaults: defaults,
                progress: AnalyticsProgress(defaults: defaults, calendar: utc, now: { clock.date }))
        }

        let first = launch()
        first.setEnabled(true)
        first.milestone(.hostConnected)
        first.consoleActive(Self.snapshot)
        first.setEnabled(false)
        first.setEnabled(true)

        let relaunched = launch()
        relaunched.milestone(.hostConnected)
        relaunched.consoleActive(Self.snapshot)
        #expect(sink.names == ["milestone", "console_active"])

        clock.advance(days: 1)
        relaunched.consoleActive(Self.snapshot)
        #expect(sink.names == ["milestone", "console_active", "console_active"])
    }

    @Test func countsLeaveTheAppAsRangesAtEveryBoundary() {
        #expect([0, 1, 2, 3, 4, 40].map(UsageBuckets.hosts) == ["1", "1", "2-3", "2-3", "4+", "4+"])
        #expect(
            [0, 1, 2, 4, 5, 90].map(UsageBuckets.agents) == ["0", "1", "2-4", "2-4", "5+", "5+"])
        #expect([-1, 0, 1, 2].map(UsageBuckets.found) == ["0", "0", "1", "2+"])
        #expect(
            [-1, 0, 1, 3, 4, 7, 8, 400].map(UsageBuckets.days) == [
                "0", "0", "1-3", "1-3", "4-7", "4-7", "8+", "8+",
            ])
    }

    @Test func firstOpenIsStoredOnceAndSurvivesAnOptOut() throws {
        let rig = try makeRig()
        rig.clock.advance(days: 5)
        rig.analytics.setEnabled(false)
        rig.analytics.setEnabled(true)
        rig.analytics.milestone(.agentSeen)
        #expect(rig.sink.captures[0].properties["days_since_first_open"] == "4-7")
    }

    /// Every property a usage event can carry is a fixed word or a range.
    @Test func usageEventPropertiesAreEnumsAndRangesOnly() {
        let allowed: [String: Set<String>] = [
            "hosts": ["1", "2-3", "4+"],
            "backend": ["herdr", "tmux", "both", "core", "core_tmux", "herdr_core", "all"],
            "agents": ["0", "1", "2-4", "5+"],
            "steered": ["true", "false"],
            "push": ["on", "off"],
            "days_since_first_open": ["0", "1-3", "4-7", "8+"],
            "found": ["0", "1", "2+"],
            "method": ["scan", "paste", "discovered", "manual"],
            "name": [
                "host_connected", "agent_seen", "attention_seen", "first_steer",
                "sample_host_opened", "lan_scan_started", "lan_scan_found",
                "lan_permission_denied",
            ],
        ]
        let milestones: [Milestone] = [
            .hostConnected, .agentSeen, .attentionSeen, .firstSteer,
            .sampleHostOpened, .lanScanStarted, .lanScanFound(count: 3), .lanPermissionDenied,
        ]
        var events: [AnalyticsEvent] = [
            .consoleActive(Self.snapshot, steered: true),
            .consoleActive(
                ConsoleSnapshot(hosts: 9, backend: .tmux, agents: 99, push: false),
                steered: false),
            .hostAdded(method: .scan), .hostAdded(method: .paste),
            .hostAdded(method: .discovered), .hostAdded(method: .manual),
        ]
        events += milestones.map { AnalyticsEvent.milestone($0, daysSinceFirstOpen: 12) }
        for event in events {
            for (key, value) in event.properties {
                #expect(allowed[key]?.contains(value) == true, "\(event.name).\(key)=\(value)")
            }
            #expect(!event.isInternalOnly)
        }
    }

    @Test func theAppStoreBuildSendsTheUsageEvents() throws {
        let defaults = try #require(UserDefaults(suiteName: "usage-\(UUID().uuidString)"))
        let sink = RecordingSink()
        let analytics = GatedAnalytics(
            sink: sink, identity: AnalyticsIdentity(device: VolatileSecretStore(), shared: { nil }),
            defaults: defaults, build: .appStore, allowsAdmin: { false })
        analytics.setEnabled(true)
        analytics.consoleActive(Self.snapshot)
        analytics.milestone(.hostConnected)
        analytics.capture(.hostAdded(method: .manual))
        #expect(sink.names == ["console_active", "milestone", "host_added"])
    }
}
