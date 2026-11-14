import Testing

@testable import Waycar

/// `AgentInputGateMachine`: when a prompt to an Agent a herdr Transport
/// launched may go, and when a screen refuses it.
@Suite("herdr agent input gate machine")
struct AgentInputGateMachineTests {
    typealias Machine = AgentInputGateMachine

    private let t0 = ContinuousClock.now
    private let timeout: Duration = .seconds(60)
    private let pane = "w1:p1"

    private static let box =
        "\n  ┃\n  ┃  Ask anything...\n  ┃\n  ╹" + String(repeating: "▀", count: 40)
    private static let signIn = "\n       Cursor Agent\n       Press any key to log in..."
    private static let grokTrust = """
                    Do you trust the contents of this directory?
                     /home/waycar/work/demo
                           Yes, proceed                 y
                           No, quit                     n
        """

    private func launched(_ kind: String, at: ContinuousClock.Instant? = nil) -> Machine {
        Machine(inputReadyTimeout: timeout).after([
            .launched(pane: pane, kind: kind, at: at ?? t0)
        ])
    }

    private func check(_ machine: Machine) -> Machine.Check {
        Machine.Check(target: pane, gate: machine[pane])
    }

    private func notReady(_ kind: String, opensAt: ContinuousClock.Instant) -> Machine.Effect {
        .hold(AgentInputNotReadyError(kind: kind, target: pane, opensAt: opensAt))
    }

    // MARK: Launch

    @Test func aMarkerKindsLaunchIsHeldUntilItsTimeout() {
        let machine = launched("opencode")
        let gate = machine[pane]
        #expect(gate?.kind == "opencode")
        #expect(gate?.readyAt == t0)
        #expect(gate?.opensAt == t0 + timeout)
        #expect(machine.phase(of: pane, at: t0 + .seconds(1)) == .awaitingMarker)
        #expect(machine.phase(of: pane, at: t0 + timeout) == .expired)
    }

    @Test func aDelayKindsLaunchIsHeldForItsDelayOnly() {
        let machine = launched("copilot")
        #expect(machine[pane]?.readyAt == t0 + .milliseconds(1500))
        #expect(machine[pane]?.opensAt == t0 + .milliseconds(1500))
        #expect(machine.phase(of: pane, at: t0) == .delayHeld)
        #expect(machine.phase(of: pane, at: t0 + .seconds(2)) == .expired)
    }

    @Test func aLaunchOfAKindWithoutAGateClearsThePanesGate() {
        var machine = launched("opencode")
        #expect(machine.handle(.launched(pane: pane, kind: "codex", at: t0)).isEmpty)
        #expect(machine[pane] == nil)
        #expect(machine.phase(of: pane, at: t0) == .ready)
    }

    @Test func aRelaunchReplacesTheGateUnderANewToken() {
        var machine = launched("opencode")
        let first = machine[pane]
        _ = machine.handle(.launched(pane: pane, kind: "opencode", at: t0 + .seconds(5)))
        #expect(machine[pane]?.token != first?.token)
        #expect(machine[pane]?.opensAt == t0 + .seconds(5) + timeout)
    }

    // MARK: Prompt arrival

    @Test func aPromptToAnUngatedPaneResolvesItsKindWithNoGate() {
        var machine = Machine(inputReadyTimeout: timeout)
        #expect(
            machine.handle(.promptArrived(target: pane, now: t0))
                == [.resolveKind(Machine.Check(target: pane, gate: nil))])
    }

    @Test func aPromptInsideTheMinimumDelayIsHeldUntilItsEnd() {
        var machine = launched("gemini")
        #expect(
            machine.handle(.promptArrived(target: pane, now: t0 + .seconds(1)))
                == [notReady("gemini", opensAt: t0 + .seconds(3))])
        #expect(machine[pane] != nil)
    }

    @Test func aPromptPastTheTimeoutDropsTheGateAndGoesUnread() {
        var machine = launched("opencode").after([
            .launched(pane: "w1:p2", kind: "kilo", at: t0)
        ])
        #expect(
            machine.handle(.promptArrived(target: pane, now: t0 + timeout))
                == [.resolveKind(Machine.Check(target: pane, gate: nil))])
        // Every expired gate goes, whichever pane the prompt is for.
        #expect(machine[pane] == nil)
        #expect(machine["w1:p2"] == nil)
    }

    // MARK: Kind

    @Test func aMarkerGateReadsTheScreen() {
        var machine = launched("opencode")
        let gated = check(machine)
        #expect(machine.handle(.kindResolved(gated, kind: "opencode")) == [.readScreen(gated)])
    }

    @Test func aMarkerGateReadsTheScreenWhateverKindIsNowListed() {
        // HCT-04, kept: the launch's marker decides, not the listed kind.
        var machine = launched("opencode")
        let gated = check(machine)
        #expect(machine.handle(.kindResolved(gated, kind: "codex")) == [.readScreen(gated)])
    }

    @Test func aSignInOrTrustKindReadsTheScreenWithNoGate() {
        var machine = Machine(inputReadyTimeout: timeout)
        let ungated = Machine.Check(target: pane, gate: nil)
        #expect(machine.handle(.kindResolved(ungated, kind: "cursor")) == [.readScreen(ungated)])
        #expect(machine.handle(.kindResolved(ungated, kind: "grok")) == [.readScreen(ungated)])
    }

    @Test func anyOtherKindIsAdmittedUnread() {
        var machine = Machine(inputReadyTimeout: timeout)
        let ungated = Machine.Check(target: pane, gate: nil)
        #expect(machine.handle(.kindResolved(ungated, kind: "codex")) == [.admit])
        #expect(machine.handle(.kindResolved(ungated, kind: nil)) == [.admit])
        // A delay gate past its delay holds nothing more.
        var delayed = launched("copilot")
        let copilotCheck = check(delayed)
        #expect(delayed.handle(.kindResolved(copilotCheck, kind: "copilot")) == [.admit])
    }

    // MARK: Screen

    @Test func aBlankScreenHoldsUntilTheGatesTimeout() {
        var machine = launched("opencode")
        let gated = check(machine)
        #expect(
            machine.handle(.screenRead(gated, kind: "opencode", screen: ""))
                == [notReady("opencode", opensAt: t0 + timeout)])
        #expect(machine[pane] != nil)
    }

    @Test func theMarkerOnScreenOpensTheGateForGood() {
        var machine = launched("opencode")
        let gated = check(machine)
        #expect(machine.handle(.screenRead(gated, kind: "opencode", screen: Self.box)) == [.admit])
        #expect(machine[pane] == nil)
    }

    @Test func aMarkerSeenForAReplacedGateLeavesTheReplacement() {
        var machine = launched("opencode")
        let gated = check(machine)
        _ = machine.handle(.launched(pane: pane, kind: "opencode", at: t0 + .seconds(1)))
        let replacement = machine[pane]
        // The read authorizes its own prompt, not the replacement launch.
        #expect(machine.handle(.screenRead(gated, kind: "opencode", screen: Self.box)) == [.admit])
        #expect(machine[pane] == replacement)
    }

    @Test func aSignInScreenIsRefusedBeforeTheMarkerIsLookedAt() {
        // A cursor Agent recovered as an opencode launch: the sign-in
        // screen is refused first, and the gate stays.
        var machine = launched("opencode")
        let gated = check(machine)
        #expect(
            machine.handle(.screenRead(gated, kind: "cursor", screen: Self.signIn))
                == [.refuseSignIn(AgentSignInRequiredError(kind: "cursor", target: pane))])
        #expect(machine[pane] != nil)
        let ungated = Machine.Check(target: pane, gate: nil)
        #expect(machine.handle(.screenRead(ungated, kind: "cursor", screen: "")) == [.admit])
    }

    @Test func aTrustDialogIsRefused() {
        var machine = Machine(inputReadyTimeout: timeout)
        let ungated = Machine.Check(target: pane, gate: nil)
        #expect(
            machine.handle(.screenRead(ungated, kind: "grok", screen: Self.grokTrust))
                == [
                    .refuseFolderTrust(
                        AgentFolderTrustRequiredError(kind: "grok", target: pane))
                ])
    }

    // MARK: Pane and Transport

    @Test func aGonePaneDropsOnlyTheGateTheCheckFound() {
        var machine = launched("opencode")
        let found = check(machine)
        #expect(machine.handle(.paneGone(found)).isEmpty)
        #expect(machine[pane] == nil)

        var replaced = launched("opencode")
        let old = check(replaced)
        _ = replaced.handle(.launched(pane: pane, kind: "kilo", at: t0 + .seconds(1)))
        _ = replaced.handle(.paneGone(old))
        #expect(replaced[pane]?.kind == "kilo")
    }

    @Test func closingAPaneAndTheTransportDropTheirGates() {
        var machine = launched("opencode").after([
            .launched(pane: "w1:p2", kind: "kilo", at: t0)
        ])
        #expect(machine.handle(.paneClosed(pane: pane)).isEmpty)
        #expect(machine[pane] == nil)
        #expect(machine["w1:p2"] != nil)
        #expect(machine.handle(.closed).isEmpty)
        #expect(machine.state.isEmpty)
    }
}
