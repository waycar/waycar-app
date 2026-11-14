import Foundation

/// The input gates of the Agents a herdr Transport launched, per pane id,
/// and the check every prompt runs against them
/// (`WaycarSSHTransport.awaitAgentInput`), per the kind's
/// `AgentScreen.InputReadiness`: a launch is held, unread, until its
/// minimum delay has passed (copilot, qwen, gemini); a kind with an input
/// marker (opencode, kilo, cline) is then held until one screen read shows
/// the marker, which opens the gate for good, or until `inputReadyTimeout`
/// after the launch, when it opens unread. A prompt to a kind with a
/// sign-in screen or folder-trust dialog reads the screen whoever launched
/// it and is refused while either shows. Every refusal comes before
/// anything is written to the Agent.
///
/// A check carries the gate it found (``Check``) across its awaits and
/// decides on that gate: a marker it saw opens only that gate, never one a
/// later launch put in its place (each launch's gate has its own token).
struct AgentInputGateMachine: StateMachine {
    /// One launch's hold.
    struct Gate: Equatable, Sendable {
        let token: UInt64
        let kind: String
        let readiness: AgentScreen.InputReadiness
        /// Until then nothing goes out (`InputReadiness.minimumDelay`).
        let readyAt: ContinuousClock.Instant
        /// The hold ends here: with a marker, `inputReadyTimeout` after the
        /// launch; without, at ``readyAt``.
        let opensAt: ContinuousClock.Instant
    }

    /// Where a pane's gate stands at a moment.
    enum Phase: Equatable, Sendable {
        /// Inside the kind's minimum delay: held unread.
        case delayHeld
        /// Past the delay, before `opensAt`: held until a read shows the
        /// marker.
        case awaitingMarker
        /// Past `opensAt`: opens unread at the next check.
        case expired
        /// No gate: prompts go once any sign-in or trust read passes.
        case ready
    }

    /// One prompt's check in flight: its target and the gate it found.
    struct Check: Equatable, Sendable {
        let target: String
        let gate: Gate?
    }

    enum Event: Equatable, Sendable {
        /// A `kind` Agent was launched in `pane` at `at` (a start's ack, or
        /// a recovery that found it): any earlier gate there is replaced.
        case launched(pane: String, kind: String, at: ContinuousClock.Instant)
        /// A prompt to `target` arrives.
        case promptArrived(target: String, now: ContinuousClock.Instant)
        /// The target's kind, remembered or asked; nil when herdr names none.
        case kindResolved(Check, kind: String?)
        /// The visible screen the check read.
        case screenRead(Check, kind: String?, screen: String)
        /// The check's screen read found the pane gone.
        case paneGone(Check)
        /// The Transport is closing `pane`.
        case paneClosed(pane: String)
        /// The Transport closed.
        case closed
    }

    enum Effect: Equatable, Sendable {
        /// Fail the prompt with this error; nothing was written.
        case hold(AgentInputNotReadyError)
        case refuseSignIn(AgentSignInRequiredError)
        case refuseFolderTrust(AgentFolderTrustRequiredError)
        /// Resolve the target's kind, then send `kindResolved`.
        case resolveKind(Check)
        /// Read the visible screen, then send `screenRead` or `paneGone`.
        case readScreen(Check)
        /// The prompt may go.
        case admit
    }

    let inputReadyTimeout: Duration
    /// Per pane id.
    private(set) var state: [String: Gate] = [:]
    private var lastToken: UInt64 = 0

    init(inputReadyTimeout: Duration) {
        self.inputReadyTimeout = inputReadyTimeout
    }

    subscript(_ pane: String) -> Gate? { state[pane] }

    /// `pane`'s gate phase at `now`.
    func phase(of pane: String, at now: ContinuousClock.Instant) -> Phase {
        guard let gate = state[pane] else { return .ready }
        if now >= gate.opensAt { return .expired }
        if now < gate.readyAt { return .delayHeld }
        return .awaitingMarker
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .launched(let pane, let kind, let at):
            let readiness = AgentScreen.readiness(kind: kind)
            guard readiness.gatesLaunch else {
                state[pane] = nil
                return []
            }
            lastToken += 1
            let readyAt = at + readiness.minimumDelay
            state[pane] = Gate(
                token: lastToken, kind: kind, readiness: readiness, readyAt: readyAt,
                opensAt: readiness.marker == nil ? readyAt : at + inputReadyTimeout)
            return []

        case .promptArrived(let target, let now):
            // A gate past its `opensAt` opens unread, whichever pane it is.
            state = state.filter { now < $0.value.opensAt }
            let gate = state[target]
            if let gate, now < gate.readyAt {
                return [
                    .hold(
                        AgentInputNotReadyError(
                            kind: gate.kind, target: target, opensAt: gate.readyAt))
                ]
            }
            return [.resolveKind(Check(target: target, gate: gate))]

        case .kindResolved(let check, let kind):
            // A gate past its `readyAt` that is still open waits for a marker.
            let readiness = kind.map(AgentScreen.readiness(kind:))
            let readsScreen = readiness.map { $0.hasSignInScreen || $0.hasTrustDialog } ?? false
            guard check.gate?.readiness.marker != nil || readsScreen else { return [.admit] }
            return [.readScreen(check)]

        case .screenRead(let check, let kind, let screen):
            if let kind,
                let refusal = Self.screenRefusal(kind: kind, target: check.target, screen: screen)
            {
                return [refusal]
            }
            if let gate = check.gate, let marker = gate.readiness.marker {
                guard AgentScreen.inputIsOnScreen(marker, screen: screen) else {
                    return [
                        .hold(
                            AgentInputNotReadyError(
                                kind: gate.kind, target: check.target, opensAt: gate.opensAt))
                    ]
                }
                forget(gate, pane: check.target)
            }
            return [.admit]

        case .paneGone(let check):
            // Nothing will take input there any more.
            if let gate = check.gate { forget(gate, pane: check.target) }
            return []

        case .paneClosed(let pane):
            state[pane] = nil
            return []

        case .closed:
            state = [:]
            return []
        }
    }

    /// The refusal for a prompt to a `kind` Agent showing `screen`: its
    /// sign-in screen, else its folder-trust dialog; nil for neither.
    static func screenRefusal(kind: String, target: String, screen: String) -> Effect? {
        let readiness = AgentScreen.readiness(kind: kind)
        if readiness.hasSignInScreen, AgentScreen.signInRequired(kind: kind, screen: screen) {
            return .refuseSignIn(AgentSignInRequiredError(kind: kind, target: target))
        }
        if readiness.hasTrustDialog, AgentScreen.trustDialogShown(kind: kind, screen: screen) {
            return .refuseFolderTrust(AgentFolderTrustRequiredError(kind: kind, target: target))
        }
        return nil
    }

    /// Drops `gate`, unless a later launch in `pane` replaced it while the
    /// check read the screen.
    private mutating func forget(_ gate: Gate, pane: String) {
        if state[pane]?.token == gate.token { state[pane] = nil }
    }
}
