import Foundation
import os

/// The network lifecycle's permanent phase log (#105): one `network`
/// category in the app's subsystem, and signpost intervals Instruments
/// draws on a timeline — the dial and its phases, the kept connection's
/// probe and hedge, the first channel, ping, subscribe, snapshot, terminal
/// attach, mosh stalls — plus single lines for transport losses and path
/// changes. Durations, outcomes and failure classes are public; Host
/// names, addresses, usernames, pane ids and paths are never logged. One
/// line per phase edge, nothing per byte.
enum NetworkLog {
    static let logger = Logger(subsystem: "com.otreva.waycar", category: "network")
    static let signposter = OSSignposter(logger: logger)
}

/// One timed phase: a signpost interval with its own clock, so the line
/// that ends it carries the duration.
struct NetworkInterval: Sendable {
    let name: StaticString
    let started: ContinuousClock.Instant
    private let state: OSSignpostIntervalState

    init(_ name: StaticString) {
        self.name = name
        started = .now
        let signposter = NetworkLog.signposter
        state = signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    var elapsed: Duration { .now - started }

    /// Ends the interval, logging `outcome` (a fixed word, never Host data)
    /// with the time it took, and returns that time.
    @discardableResult
    func end(_ outcome: String) -> Duration {
        let elapsed = elapsed
        NetworkLog.signposter.endInterval(name, state, "\(outcome, privacy: .public)")
        NetworkLog.logger.info(
            "\(name.description, privacy: .public): \(outcome, privacy: .public) in \(elapsed.wholeMilliseconds, privacy: .public) ms"
        )
        return elapsed
    }
}

/// How an attach reached its terminal (#105). mosh: a standby started at
/// Background Grace expiry, a speculative standby kept for the last-viewed
/// Agent, or a bootstrap of its own over SSH. SSH: the connection kept
/// across the last suspension, or the Host's live one.
enum TerminalAttachRoute: String, Sendable, CaseIterable {
    case standby
    case speculative
    case bootstrap
    case kept
    case live

    init(_ origin: StandbyMosh.Origin) {
        switch origin {
        case .graceExpiry: self = .standby
        case .speculative: self = .speculative
        }
    }
}

/// A return to the foreground, as the attaches right after it see it.
struct ForegroundReturn: Equatable, Sendable {
    /// How long an attach counts as the return's: the shown Agent's
    /// reattach and a standby's client start within it.
    static let attachWindow: Duration = .seconds(10)

    let absence: Duration
    /// Whether the absence crossed the Background Grace Period, so the
    /// connections were quiesced (`AppActivityCoordinator`).
    let crossedGrace: Bool
    let at: ContinuousClock.Instant

    /// Whether an attach started at `instant` belongs to this return.
    func covers(_ instant: ContinuousClock.Instant) -> Bool {
        instant >= at && instant - at <= Self.attachWindow
    }
}

/// Where the network edges report what internal builds count (#105). The
/// composition root installs the app's analytics; until then, and in every
/// test, nothing is recorded. `GatedAnalytics` keeps the user's choice and
/// the build-flavor gate, so App Store builds never send these events.
@MainActor
enum NetworkTelemetry {
    static var analytics: (any Analytics)?
    private(set) static var lastReturn: ForegroundReturn?

    static func record(_ event: AnalyticsEvent) {
        analytics?.capture(event)
    }

    /// `record` from off the main actor. Skipped outright where the build
    /// would drop the event anyway.
    nonisolated static func recordDetached(_ event: AnalyticsEvent) {
        guard BuildFlavor.current.sends(event) else { return }
        Task { @MainActor in record(event) }
    }

    /// The app returned to the foreground after `absence` (nil on launch).
    static func didReturn(
        after absence: Duration?, crossedGrace: Bool, at now: ContinuousClock.Instant = .now
    ) {
        guard let absence else { return }
        NetworkLog.logger.notice(
            "foreground after \(absence.wholeMilliseconds, privacy: .public) ms, grace crossed: \(crossedGrace, privacy: .public)"
        )
        lastReturn = ForegroundReturn(absence: absence, crossedGrace: crossedGrace, at: now)
        record(.appForegrounded(absence: absence))
    }

    /// The return an attach started at `now` belongs to, if any.
    static func foregroundReturn(at now: ContinuousClock.Instant = .now) -> ForegroundReturn? {
        lastReturn.flatMap { $0.covers(now) ? $0 : nil }
    }
}

extension Duration {
    /// Whole milliseconds, rounded down; what logs and buckets read.
    var wholeMilliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
