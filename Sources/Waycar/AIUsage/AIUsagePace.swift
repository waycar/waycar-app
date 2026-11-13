import Foundation

/// CodexBar's pace estimate for one rate-limit window: how its usage
/// compares with the time elapsed in the window. Decoded from the
/// `pace.<slot>` object of `codexbar usage --format json`, and rendered the
/// way CodexBar's own popover draws it — a gray footnote line under the
/// gauge, "12% in reserve · Lasts until reset".
struct AIUsagePace: Sendable, Equatable {
    /// CodexBar's stage for the delta; nil when it names an unknown stage
    /// (a later CodexBar may add cases this build does not know).
    let stage: Stage?
    /// Used minus expected, in points of the window: positive burns faster
    /// than the window lasts (a deficit), negative leaves room (a reserve).
    let deltaPercent: Double?
    /// How much longer the quota lasts at the current pace; nil when
    /// CodexBar cannot project one (it omits `etaSeconds` when it expects
    /// the quota to outlast the window).
    let etaSeconds: Int?
    /// Whether CodexBar projects the quota to outlast the window
    /// (`willLastToReset`).
    let lastsUntilReset: Bool?

    /// CodexBar 0.70's `UsagePace.Stage`. CodexBar derives the stage from
    /// the delta (|δ| ≤ 2 on track, ≤ 6 slight, ≤ 12, else far); Waycar
    /// reads the stage it emits rather than recomputing the thresholds.
    enum Stage: String, Sendable, Equatable {
        case onTrack
        case slightlyAhead, ahead, farAhead
        case slightlyBehind, behind, farBehind
    }

    /// Nothing legit projects a quota lasting past a year; beyond that the
    /// field is hostile or broken.
    private static let maximumProjectionSeconds = 365 * 86_400

    /// CodexBar's left pace label: "On pace", "12% in deficit", or "12% in
    /// reserve". nil when CodexBar sent neither a delta nor an on-track
    /// stage.
    var summary: String? {
        // The delta is used−expected of two 0–100 percents, so anything
        // outside ±100 is a corrupt field; clamping keeps a corrupt field
        // from trapping Int(Double) — and by the leniency rule a corrupt
        // field costs only itself.
        guard let delta = deltaPercent, delta.isFinite else {
            return stage == .onTrack ? "On pace" : nil
        }
        let points = Int(min(max(delta, -100.0), 100.0).rounded())
        if points == 0 || stage == .onTrack { return "On pace" }
        return delta < 0
            ? "\(abs(points))% in reserve"
            : "\(abs(points))% in deficit"
    }

    /// CodexBar's right pace label: "Lasts until reset", "Runs out in
    /// 2d 4h", "Projected empty in 3h". The primary slot reads "projected
    /// empty" and every other window "runs out", like the desktop popover;
    /// a deficit without a projection says plainly that it runs out first.
    func outlook(usesSessionWording: Bool, now: Date) -> String? {
        if lastsUntilReset == true { return "Lasts until reset" }
        guard let eta = etaSeconds else {
            return lastsUntilReset == false ? "Runs out before reset" : nil
        }
        if eta <= 0 {
            return usesSessionWording ? "Projected empty now" : "Runs out now"
        }
        // CodexBar omits eta when the quota outlasts the window, so nothing
        // legit projects past a year; a projection past it is a hostile or
        // broken field, and by the leniency rule such a field costs only
        // itself (and would trap compactDuration's Int conversion).
        guard eta <= Self.maximumProjectionSeconds else { return nil }
        let duration = AIUsageFormat.compactDuration(
            until: now.addingTimeInterval(TimeInterval(eta)), now: now)
        return usesSessionWording
            ? "Projected empty in \(duration)"
            : "Runs out in \(duration)"
    }

    /// The line the sheet shows under the gauge, "12% in reserve · Lasts
    /// until reset"; nil when there is nothing to say.
    func paceText(usesSessionWording: Bool, now: Date) -> String? {
        let parts = [
            summary,
            outlook(usesSessionWording: usesSessionWording, now: now),
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// CodexBar's popover speaks the session wording ("Projected empty in")
/// only for a primary window that is not itself weekly; its weekly, 30-day
/// and extra windows read "Runs out in". Its provider-specific exceptions
/// (Kimi's secondary is a 5-hour window) are not visible in the CLI JSON.
extension AIUsageWindow {
    var usesSessionPaceWording: Bool {
        id == "primary" && !isWeeklyWindow
    }
}
