import Foundation

/// An Agent this transport launched that may not take a prompt yet (design
/// §4.3 Launch): claude once its `SessionStart` hook set `@waycar_session`
/// or `claudeLaunchReadyTimeout` after launch, whichever comes first (a Host
/// without Status Hooks never sets it); a kind with an input marker
/// (`AgentScreen.InputMarker`: opencode, kilo, cline) once the marker is on
/// its alternate screen or its pane has an `@waycar_status`, or
/// `inputReadyTimeout` after launch (their TUIs drop input until then:
/// opencode 6–24 s after launch on Linux test Hosts); other kinds
/// `launchReadyDelay` after their kind is first detected, or their
/// `AgentScreen.InputReadiness.minimumDelay` if longer, and, for a kind
/// with screen rules (`TmuxScreenDetector`), not while its screen shows a
/// dialog. Detection, not launch, anchors the kind's delay: the lab
/// measured it from the agent's own start, and `new-window` returns before
/// the login-shell wrapper's rc files have run, often for seconds.
struct TmuxLaunchGate: Sendable, Equatable {
    let kind: String
    var launchedAt: ContinuousClock.Instant
    var detectedAt: ContinuousClock.Instant?
}

/// The launch gates of the Agents a tmux transport started, per raw pane
/// id (``TmuxLaunchGate``), and the checks a prompt runs against them
/// (``TmuxTransport/checkLaunchReadiness(_:)``). Panes this transport did
/// not launch are always ready.
///
/// A check holds the gate it found (``Check``) across its reads and decides
/// on that gate; what it writes when it ends (the gate opened, or the time
/// its kind was first detected) lands whatever replaced or removed the gate
/// meanwhile. A snapshot prunes only the gates it began with.
struct TmuxLaunchGateMachine: StateMachine {
    /// The transport's gate timings (`TmuxTransport.Configuration`).
    struct Timing: Equatable, Sendable {
        var launchReadyDelay: Duration
        var claudeLaunchReadyTimeout: Duration
        var inputReadyTimeout: Duration
    }

    /// One check in flight: the pane, the gate as the check found it, and
    /// the timings it runs on.
    struct Check: Equatable, Sendable {
        let pane: String
        let gate: TmuxLaunchGate
        let timing: Timing

        var isClaude: Bool { gate.kind == SupportedAgentKind.claude.rawValue }
        var readiness: AgentScreen.InputReadiness { AgentScreen.readiness(kind: gate.kind) }
    }

    /// What one readiness read of the pane showed
    /// (``TmuxTransport/readinessFormat``).
    struct PaneFacts: Equatable, Sendable {
        let dead: Bool
        /// An Agent kind is detected there (hook, command or `ps`).
        let agentDetected: Bool
        /// `@waycar_session` is set: claude's `SessionStart` hook ran.
        let hookSessionSet: Bool
        /// `@waycar_status` holds a status: the Agent took input already.
        let hookStatusSet: Bool
        let alternateScreen: Bool
    }

    enum Event: Equatable, Sendable {
        /// The transport launched a `kind` Agent into `pane` (a fresh start,
        /// or a tagged retry that found its earlier pane).
        case launched(pane: String, kind: String, at: ContinuousClock.Instant)
        /// A snapshot that began with `gatesAtStart` listed `panes`.
        case listed(panes: Set<String>, gatesAtStart: [String: TmuxLaunchGate])
        /// A prompt asks whether `pane` takes input.
        case check(pane: String, now: ContinuousClock.Instant, timing: Timing)
        case paneRead(Check, PaneFacts, now: ContinuousClock.Instant)
        case markerRead(Check, onScreen: Bool)
        /// The kind's screen rules read Blocked, or not.
        case dialogRead(Check, blocked: Bool)
        /// The transport closed.
        case closed
    }

    enum Effect: Equatable, Sendable {
        /// The prompt may go.
        case admit
        /// Fail the prompt `agent_not_ready` for this gate.
        case hold(TmuxLaunchGate)
        /// Read the pane's readiness fields.
        case readPane(Check)
        /// Read the visible screen for the kind's input marker.
        case readMarker(Check, AgentScreen.InputMarker)
        /// Read the screen with the kind's screen rules, for a dialog.
        case readDialog(Check)
    }

    /// Per raw pane id.
    private(set) var state: [String: TmuxLaunchGate] = [:]

    init() {}

    subscript(_ pane: String) -> TmuxLaunchGate? { state[pane] }

    var isEmpty: Bool { state.isEmpty }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .launched(let pane, let kind, let at):
            state[pane] = TmuxLaunchGate(kind: kind, launchedAt: at)
            return []

        case .listed(let panes, let gatesAtStart):
            // A launch may have finished after these panes were listed:
            // prune only the launch the snapshot began with.
            state = state.filter { id, gate in
                panes.contains(id) || gatesAtStart[id]?.launchedAt != gate.launchedAt
            }
            return []

        case .check(let pane, let now, let timing):
            guard let gate = state[pane] else { return [.admit] }
            let check = Check(pane: pane, gate: gate, timing: timing)
            let elapsed = gate.launchedAt.duration(to: now)
            if check.isClaude, elapsed >= timing.claudeLaunchReadyTimeout {
                // Past the timeout claude holds only while a dialog (folder
                // trust) shows: Enter would accept it.
                return [.readDialog(check)]
            }
            if check.readiness.marker != nil, elapsed >= timing.inputReadyTimeout {
                return open(pane)
            }
            return [.readPane(check)]

        case .paneRead(let check, let facts, let now):
            // Nothing will start in a dead pane; the prompt fails on its own.
            if facts.dead { return open(check.pane) }
            if check.isClaude {
                guard facts.agentDetected, facts.hookSessionSet else { return [.hold(check.gate)] }
                return open(check.pane)
            }
            if let marker = check.readiness.marker, facts.agentDetected {
                // A status means the Agent has taken input already (typed in
                // the terminal); else its marker must be on the alternate
                // screen.
                if facts.hookStatusSet { return open(check.pane) }
                guard facts.alternateScreen else { return [.hold(check.gate)] }
                return [.readMarker(check, marker)]
            }
            guard facts.agentDetected else { return [.hold(check.gate)] }
            let detectedAt = check.gate.detectedAt ?? now
            let delay = max(check.timing.launchReadyDelay, check.readiness.minimumDelay)
            guard detectedAt.duration(to: now) >= delay else {
                var gate = check.gate
                gate.detectedAt = detectedAt
                state[check.pane] = gate
                return [.hold(gate)]
            }
            // A kind with screen rules may open on a dialog (copilot's
            // "Session in use" on resume, codex's hooks review) before any
            // hook could report it: Enter would answer it.
            guard TmuxScreenDetector.supports(kind: check.gate.kind) else { return open(check.pane) }
            return [.readDialog(check)]

        case .markerRead(let check, let onScreen):
            guard onScreen else { return [.hold(check.gate)] }
            return open(check.pane)

        case .dialogRead(let check, let blocked):
            guard !blocked else { return [.hold(check.gate)] }
            return open(check.pane)

        case .closed:
            state = [:]
            return []
        }
    }

    private mutating func open(_ pane: String) -> [Effect] {
        state[pane] = nil
        return [.admit]
    }
}
