import Foundation
import Observation
import SwiftUI

/// One anonymous product-usage event (PRIVACY.md). The cases are the whole
/// vocabulary: nothing else can be sent. The product events carry at
/// most fixed words or ranges: an Agent's kind, how a Host was added, how
/// far pairing got, how many Hosts and Agents the Console shows (as a
/// range), and which first the user reached (`Milestone`). The network
/// events (#105), sent only by internal builds (`BuildFlavor`), carry
/// fixed words and buckets (`NetworkAnalytics`). Host names, addresses,
/// usernames, paths, commands, prompts, Agent names and terminal content
/// never reach this type.
enum AnalyticsEvent: Equatable, Sendable {
    /// The app came to the foreground for the first time in this launch.
    case appOpened
    /// A new Host was saved: from a Pairing Code, the Add Host form, or
    /// (once it exists) Find computers.
    case hostAdded(method: HostAddMethod)
    /// Scan to Pair finished and saved its Host.
    case pairingSucceeded
    /// A Pairing Code parsed and the ceremony is about to run.
    case pairingStarted(method: PairingMethod)
    /// The Scan to Pair sheet closed without a Host. `method` is nil when no
    /// code was ever read.
    case pairingAbandoned(method: PairingMethod?, stage: PairingStage)
    /// A ceremony attempt failed; `reason` is the ceremony step it failed
    /// at. Internal builds only: the App Store label declares no failure
    /// reasons (WAY-208).
    case pairingFailed(method: PairingMethod, reason: PairingStage)
    /// The New Agent sheet started an Agent (not a plain shell).
    case agentLaunched(kind: SupportedAgentKind)
    /// The user tapped an Agent Notification.
    case notificationOpened
    /// The user opened the share sheet for the app's App Store link
    /// (Settings › About). A share intent only: never a confirmed recipient,
    /// an install, or a reward qualification.
    case inviteShared
    /// The Console was shown with a Host connected: at most once per local
    /// day on a device (`AnalyticsProgress`). `steered` says the user sent
    /// an Agent a message since the last one of these went out.
    case consoleActive(ConsoleSnapshot, steered: Bool)
    /// The first time on this install the user reached `milestone`
    /// (`AnalyticsProgress`), and how many days after first opening the app.
    case milestone(Milestone, daysSinceFirstOpen: Int)
    /// A Host connect attempt finished. Internal builds only.
    case hostConnected(HostConnectReport)
    /// A terminal attach went live or ended trying. Internal builds only.
    case terminalAttached(TerminalAttachReport)
    /// A live transport was lost, and came back or did not. Internal
    /// builds only.
    case transportLost(TransportLossReport)
    /// The app returned to the foreground from the background. Internal
    /// builds only.
    case appForegrounded(absence: Duration)

    var name: String {
        switch self {
        case .appOpened: "app_opened"
        case .hostAdded: "host_added"
        case .pairingSucceeded: "pairing_succeeded"
        case .pairingStarted: "pairing_started"
        case .pairingAbandoned: "pairing_abandoned"
        case .pairingFailed: "pairing_failed"
        case .agentLaunched: "agent_launched"
        case .notificationOpened: "notification_opened"
        case .inviteShared: "invite_shared"
        case .consoleActive: "console_active"
        case .milestone: "milestone"
        case .hostConnected: "host_connect"
        case .terminalAttached: "terminal_attach"
        case .transportLost: "transport_lost"
        case .appForegrounded: "app_foregrounded"
        }
    }

    /// Sent only by internal builds (`BuildFlavor`) the receipt confirms
    /// (`GatedAnalytics`).
    var isInternalOnly: Bool {
        switch self {
        case .appOpened, .hostAdded, .pairingSucceeded, .agentLaunched, .notificationOpened,
            .inviteShared, .pairingStarted, .pairingAbandoned, .consoleActive, .milestone:
            false
        case .hostConnected, .terminalAttached, .transportLost, .appForegrounded, .pairingFailed:
            true
        }
    }

    var properties: [String: String] {
        switch self {
        case .agentLaunched(let kind): ["kind": kind.rawValue]
        case .pairingStarted(let method): ["method": method.rawValue]
        case .pairingAbandoned(let method, let stage):
            ["method": method?.rawValue ?? "none", "stage": stage.rawValue]
        case .pairingFailed(let method, let reason):
            ["method": method.rawValue, "reason": reason.rawValue]
        case .hostAdded(let method): ["method": method.rawValue]
        case .consoleActive(let snapshot, let steered):
            [
                "hosts": UsageBuckets.hosts(snapshot.hosts),
                "backend": snapshot.backend.rawValue,
                "agents": UsageBuckets.agents(snapshot.agents),
                "steered": steered ? "true" : "false",
                "push": snapshot.push ? "on" : "off",
            ]
        case .milestone(let milestone, let days):
            milestone.properties(daysSinceFirstOpen: days)
        case .appOpened, .pairingSucceeded, .notificationOpened, .inviteShared:
            [:]
        case .hostConnected(let report):
            [
                "outcome": report.outcome.value,
                "dial_ms": NetworkAnalytics.millisecondsBucket(report.duration),
                "path": report.path.rawValue,
                "trigger": report.trigger.rawValue,
            ]
        case .terminalAttached(let report):
            [
                "transport": report.transport?.rawValue ?? "none",
                "via": report.route?.rawValue ?? "none",
                "outcome": report.outcome.value,
                "ms": NetworkAnalytics.millisecondsBucket(report.duration),
                "after_grace": report.foregroundReturn?.crossedGrace == true ? "true" : "false",
                "bg_s": NetworkAnalytics.backgroundBucket(report.foregroundReturn?.absence),
            ]
        case .transportLost(let report):
            [
                "transport": report.transport.rawValue,
                "reason": report.reason.rawValue,
                "recovered_ms": NetworkAnalytics.recoveryBucket(report.recovery),
            ]
        case .appForegrounded(let absence):
            ["bg_s": NetworkAnalytics.backgroundBucket(absence)]
        }
    }
}

/// How a Pairing Code reached the app.
enum PairingMethod: String, Equatable, Sendable {
    case scan
    case paste
}

/// Where Scan to Pair stood: fixed words, no user content.
enum PairingStage: String, Equatable, Sendable {
    /// No Pairing Code read yet.
    case scan
    /// A code parsed; the ceremony has not reported a step.
    case start
    case parse
    case reach
    case authenticate
    case enroll
    case verify

    init(_ step: PairingStep) {
        switch step {
        case .parse: self = .parse
        case .reach: self = .reach
        case .authenticate: self = .authenticate
        case .enroll: self = .enroll
        case .verify: self = .verify
        }
    }
}

/// How a Host got into the catalog, for `host_added`.
enum HostAddMethod: String, Equatable, Sendable {
    /// A Pairing Code read by the camera.
    case scan
    /// A Pairing Code pasted from the clipboard.
    case paste
    /// A computer Find computers listed on the local network.
    case discovered
    /// The Add Host form.
    case manual

    init(_ method: PairingMethod) {
        switch method {
        case .scan: self = .scan
        case .paste: self = .paste
        }
    }
}

/// A first the user reached, reported once per install and name
/// (`AnalyticsProgress`). Fixed words only; the one count, the computers a
/// scan found, goes out as a range.
enum Milestone: Equatable, Sendable {
    /// A Host connected and delivered its first snapshot.
    case hostConnected
    /// The Console listed an Agent.
    case agentSeen
    /// The Console showed an Agent that is Blocked or Done.
    case attentionSeen
    /// A message reached an Agent from the Composer, or Allow or Cancel
    /// answered a Blocked card.
    case firstSteer
    /// The sample Host was opened.
    case sampleHostOpened
    /// Find computers started a scan of the local network.
    case lanScanStarted
    /// A scan finished; `count` is how many computers it listed.
    case lanScanFound(count: Int)
    /// iOS refused the Local Network permission Find computers asked for.
    case lanPermissionDenied

    var name: String {
        switch self {
        case .hostConnected: "host_connected"
        case .agentSeen: "agent_seen"
        case .attentionSeen: "attention_seen"
        case .firstSteer: "first_steer"
        case .sampleHostOpened: "sample_host_opened"
        case .lanScanStarted: "lan_scan_started"
        case .lanScanFound: "lan_scan_found"
        case .lanPermissionDenied: "lan_permission_denied"
        }
    }

    func properties(daysSinceFirstOpen days: Int) -> [String: String] {
        var properties = ["name": name, "days_since_first_open": UsageBuckets.days(days)]
        if case .lanScanFound(let count) = self { properties["found"] = UsageBuckets.found(count) }
        return properties
    }
}

/// What the Console shows when `console_active` goes out. Counts only, and
/// they leave the app as ranges (`UsageBuckets`): never which Host or Agent.
struct ConsoleSnapshot: Equatable, Sendable {
    /// Which backends the connected Hosts run. `both` is herdr with tmux, as
    /// it always was; herdr-core (ADR 0031) adds `core`, `core_tmux`,
    /// `herdr_core` (Hosts on each runtime) and `all`.
    enum Backend: String, Equatable, Sendable, CaseIterable {
        case herdr
        case tmux
        case both
        case core
        case coreTmux = "core_tmux"
        case herdrCore = "herdr_core"
        case all

        /// What the connected Hosts run, as three flags. With none set the
        /// answer is `herdr`: nothing is known yet, as before tmux support.
        init(herdr: Bool, core: Bool, tmux: Bool) {
            switch (herdr, core, tmux) {
            case (false, false, false), (true, false, false): self = .herdr
            case (false, false, true): self = .tmux
            case (true, false, true): self = .both
            case (false, true, false): self = .core
            case (false, true, true): self = .coreTmux
            case (true, true, false): self = .herdrCore
            case (true, true, true): self = .all
            }
        }
    }

    /// Hosts the user has switched on.
    var hosts: Int
    var backend: Backend
    /// Agents the Console lists, shells excluded.
    var agents: Int
    /// Whether this device has a push token.
    var push: Bool
}

/// The ranges counts are reported as, so an exact number never leaves the
/// app.
enum UsageBuckets {
    static func hosts(_ count: Int) -> String {
        switch count {
        case ...1: "1"
        case 2...3: "2-3"
        default: "4+"
        }
    }

    static func agents(_ count: Int) -> String {
        switch count {
        case ...0: "0"
        case 1: "1"
        case 2...4: "2-4"
        default: "5+"
        }
    }

    static func found(_ count: Int) -> String {
        switch count {
        case ...0: "0"
        case 1: "1"
        default: "2+"
        }
    }

    static func days(_ count: Int) -> String {
        switch count {
        case ...0: "0"
        case 1...3: "1-3"
        case 4...7: "4-7"
        default: "8+"
        }
    }
}

/// What this install has already reported, so the once-only events stay
/// once: the milestones it reached, the local day `console_active` last
/// went out, and whether the user steered since. It lives in this device's
/// defaults and never leaves it. An opt-out (`reset`) keeps the milestones
/// and the active day, so opting back in, or relaunching, never repeats a
/// once-only event; it drops only the steer flag, which is not a repeat
/// guard. Nothing new is recorded while analytics are off.
@MainActor
final class AnalyticsProgress {
    static let firstOpenKey = "analytics.first-open"
    static let milestonesKey = "analytics.milestones"
    static let activeDayKey = "analytics.console-active-day"
    static let steeredKey = "analytics.steered-since-active"

    private let defaults: UserDefaults
    private let fixedCalendar: Calendar?
    private let now: () -> Date

    /// A nil `calendar` follows the device's current one, so a change of
    /// time zone moves the day boundary with it.
    init(
        defaults: UserDefaults, calendar: Calendar? = nil, now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        fixedCalendar = calendar
        self.now = now
    }

    private var calendar: Calendar { fixedCalendar ?? .current }

    /// Stores the first launch of a build that has this code. An install that
    /// updated from an older build therefore counts its days from the update.
    func recordFirstOpen() {
        guard defaults.object(forKey: Self.firstOpenKey) == nil else { return }
        defaults.set(now().timeIntervalSince1970, forKey: Self.firstOpenKey)
    }

    /// Whole local days from the first open to today.
    func daysSinceFirstOpen() -> Int {
        guard let first = defaults.object(forKey: Self.firstOpenKey) as? Double else { return 0 }
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: first))
        let today = calendar.startOfDay(for: now())
        return max(0, calendar.dateComponents([.day], from: start, to: today).day ?? 0)
    }

    /// True the first time a milestone of this name is claimed.
    func claim(_ milestone: Milestone) -> Bool {
        var claimed = defaults.stringArray(forKey: Self.milestonesKey) ?? []
        guard !claimed.contains(milestone.name) else { return false }
        claimed.append(milestone.name)
        defaults.set(claimed, forKey: Self.milestonesKey)
        return true
    }

    /// True the first time today (the device's local day) is claimed.
    func claimActiveDay() -> Bool {
        let today = now()
        if let last = defaults.object(forKey: Self.activeDayKey) as? Double,
            calendar.isDate(Date(timeIntervalSince1970: last), inSameDayAs: today)
        {
            return false
        }
        defaults.set(today.timeIntervalSince1970, forKey: Self.activeDayKey)
        return true
    }

    var steeredSinceActive: Bool { defaults.bool(forKey: Self.steeredKey) }

    func noteSteer() { defaults.set(true, forKey: Self.steeredKey) }

    func clearSteered() { defaults.removeObject(forKey: Self.steeredKey) }

    func reset() {
        defaults.removeObject(forKey: Self.steeredKey)
    }
}

/// What the UI records usage through. Views and stores depend on this, never
/// on the analytics SDK (the same rule as the transport abstraction).
@MainActor
protocol Analytics: AnyObject, Sendable {
    /// The user's "Share usage analytics" choice; false until they make one.
    var isEnabled: Bool { get }
    /// True until the user has answered the first-launch question or set
    /// the Settings toggle. Nothing is sent meanwhile.
    var needsChoice: Bool { get }
    func setEnabled(_ enabled: Bool)
    func capture(_ event: AnalyticsEvent)
    /// The Console is on screen with a Host connected. Sent at most once per
    /// local day on this device, however often the app returns to the
    /// foreground; dropped, and not counted as that day's, while analytics
    /// are off.
    func consoleActive(_ snapshot: ConsoleSnapshot)
    /// The user reached `milestone`. Sent the first time on this install
    /// only; dropped, and not counted as reached, while analytics are off.
    func milestone(_ milestone: Milestone)
    /// The user sent an Agent a message (`Milestone.firstSteer`). Remembered
    /// for the next `console_active`.
    func noteSteer()
}

/// Where permitted events go. `enable` runs at launch when the user has
/// allowed analytics, and again whenever they opt back in; nothing may reach the
/// network before it. `disable` stops sending and discards the sink's own
/// identity state, so events after the next `enable` start a new session
/// that is not linked to the ones before.
@MainActor
protocol AnalyticsSink: AnyObject {
    func enable()
    func disable()
    func capture(_ name: String, properties: [String: String], distinctID: String)
}

/// Analytics behind the user's explicit choice (App Review 5.1.1(ii)). No
/// stored choice means undecided: the sink is never enabled, no distinct id
/// is read or made, and events are dropped, not queued, until the user
/// allows it. A choice stored by an earlier version stays the user's. The
/// choice lives in this device's defaults and is not synced. While off,
/// nothing is captured and the sink is told to stop; the distinct id is read
/// from the Keychain only once the first event is actually sent. Opting out
/// (or declining the first-launch question) deletes the distinct id, so
/// opting back in sends under a new one. Events the build may not send
/// (`BuildFlavor`) are dropped whatever the choice, and so are the
/// internal-only ones unless the runtime admin check passes too
/// (`AppEnvironment.allowsAdmin`, ADR 0032): an admin binary that reached
/// the App Store, or whose receipt is not yet verified, sends none of them.
/// `console_active` and the milestones also pass `AnalyticsProgress`, which
/// keeps them to one per day and one per install.
@MainActor
@Observable
final class GatedAnalytics: Analytics {
    static let enabledDefaultsKey = "analytics.enabled"

    private(set) var isEnabled: Bool
    private(set) var needsChoice: Bool

    @ObservationIgnored private let sink: any AnalyticsSink
    @ObservationIgnored private let identity: AnalyticsIdentity
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults
    @ObservationIgnored private var distinctID: String?
    @ObservationIgnored private let build: BuildFlavor
    @ObservationIgnored private let allowsAdmin: @MainActor () -> Bool
    @ObservationIgnored private let progress: AnalyticsProgress

    init(
        sink: any AnalyticsSink, identity: AnalyticsIdentity, defaults: UserDefaults = .standard,
        build: BuildFlavor = .current,
        allowsAdmin: @escaping @MainActor () -> Bool = { AppEnvironment.allowsAdmin },
        progress: AnalyticsProgress? = nil
    ) {
        self.sink = sink
        self.identity = identity
        self.defaults = defaults
        self.build = build
        self.allowsAdmin = allowsAdmin
        let progress = progress ?? AnalyticsProgress(defaults: defaults)
        self.progress = progress
        progress.recordFirstOpen()
        let stored = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool
        needsChoice = stored == nil
        isEnabled = stored ?? false
        if isEnabled { sink.enable() }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        let wasUndecided = needsChoice
        needsChoice = false
        // Declining while undecided still cleans up: an earlier version that
        // sent by default may have left a distinct id behind.
        guard enabled != isEnabled || wasUndecided else { return }
        isEnabled = enabled
        if enabled {
            sink.enable()
        } else {
            sink.disable()
            // Best effort, as `resolve()` is: a Keychain failure must not
            // keep the toggle from turning analytics off.
            try? identity.forget()
            distinctID = nil
            progress.reset()
        }
    }

    func capture(_ event: AnalyticsEvent) {
        guard permits(event) else { return }
        send(event)
    }

    func consoleActive(_ snapshot: ConsoleSnapshot) {
        let event = AnalyticsEvent.consoleActive(snapshot, steered: progress.steeredSinceActive)
        guard permits(event), progress.claimActiveDay() else { return }
        progress.clearSteered()
        send(event)
    }

    func milestone(_ milestone: Milestone) {
        let event = AnalyticsEvent.milestone(
            milestone, daysSinceFirstOpen: progress.daysSinceFirstOpen())
        guard permits(event), progress.claim(milestone) else { return }
        send(event)
    }

    func noteSteer() {
        // Nothing is remembered while analytics are off.
        guard isEnabled else { return }
        progress.noteSteer()
        milestone(.firstSteer)
    }

    private func permits(_ event: AnalyticsEvent) -> Bool {
        isEnabled && build.sends(event) && (!event.isInternalOnly || allowsAdmin())
    }

    private func send(_ event: AnalyticsEvent) {
        sink.capture(event.name, properties: event.properties, distinctID: resolvedDistinctID())
    }

    private func resolvedDistinctID() -> String {
        if let distinctID { return distinctID }
        let resolved = identity.resolve()
        distinctID = resolved
        return resolved
    }
}

/// Records nothing. The process hosting the unit tests, the Debug
/// screenshot mode, and previews use it, so none of them ever reach the
/// analytics service; the toggle still works for the session.
@MainActor
@Observable
final class NoopAnalytics: Analytics {
    private(set) var isEnabled: Bool
    /// Never asks: these compositions must not show the first-launch prompt.
    let needsChoice = false

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) { isEnabled = enabled }

    func capture(_ event: AnalyticsEvent) {}

    func consoleActive(_ snapshot: ConsoleSnapshot) {}

    func milestone(_ milestone: Milestone) {}

    func noteSteer() {}
}

/// The one-time first-launch analytics question. App-wide, so an iPad with
/// several windows asks it in one of them only: the first window to claim it
/// shows it, and hands it on if that window closes before an answer. It
/// never shows where the analytics need no choice (`NoopAnalytics`: the
/// unit-test host, the screenshot mode, previews) or once one exists.
@MainActor
@Observable
final class AnalyticsConsentPrompt {
    static let title = "Help make Waycar better?"
    static let message =
        "Waycar is new, and knowing which features people use and where they get stuck tells us "
        + "what to fix and build next. If you allow it, Waycar sends simple counts, like "
        + "\u{201C}Host added\u{201D} or \u{201C}agent launched\u{201D}, tied to a random ID. Never "
        + "Host names, commands, prompts or terminal content. You can change this anytime in Settings."
    static let allowTitle = "Allow"
    static let declineTitle = "Don't Allow"

    /// The window asking; nil until one claims the question.
    private(set) var sceneID: UUID?
    @ObservationIgnored private let analytics: any Analytics

    init(analytics: any Analytics) {
        self.analytics = analytics
    }

    func isShown(inScene sceneID: UUID) -> Bool {
        analytics.needsChoice && self.sceneID == sceneID
    }

    func claim(sceneID: UUID) {
        guard self.sceneID == nil, analytics.needsChoice else { return }
        self.sceneID = sceneID
    }

    func release(sceneID: UUID) {
        guard self.sceneID == sceneID else { return }
        self.sceneID = nil
    }
}

enum AppAnalytics {
    /// The Settings toggle's label and its one-line explanation.
    static let toggleTitle = "Share usage analytics"
    static let toggleFooter =
        "Helps us see which features people use and where they get stuck, so we know what to "
        + "improve. Simple counts tied to a random ID, never your name or Apple Account. Never "
        + "Host names, paths, commands, prompts or terminal content."

    /// The composition root's analytics: the real service in a normal launch,
    /// a no-op in the unit-test host process and the screenshot mode.
    @MainActor
    static func make() -> any Analytics {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return NoopAnalytics()
        }
        #if DEBUG && targetEnvironment(simulator)
            if DemoScreenshotMode.isEnabled { return NoopAnalytics() }
        #endif
        return GatedAnalytics(sink: PostHogAnalyticsSink(), identity: .production)
    }
}

extension EnvironmentValues {
    /// The app's analytics; nil where no composition root provided one
    /// (previews, the screenshot mode), which records nothing.
    @Entry var analytics: (any Analytics)? = nil
}
