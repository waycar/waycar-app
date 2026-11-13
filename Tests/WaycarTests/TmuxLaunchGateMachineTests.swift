import Testing

@testable import Waycar

/// `TmuxLaunchGateMachine`: when a launched Agent takes its first prompt.
@Suite("tmux launch gate machine")
struct TmuxLaunchGateMachineTests {
    typealias Machine = TmuxLaunchGateMachine

    private let t0 = ContinuousClock.now
    private let timing = Machine.Timing(
        launchReadyDelay: .milliseconds(1500), claudeLaunchReadyTimeout: .seconds(8),
        inputReadyTimeout: .seconds(30))

    private func launched(_ kind: String, pane: String = "%7") -> Machine {
        Machine().after([.launched(pane: pane, kind: kind, at: t0)])
    }

    private func check(_ machine: Machine, pane: String = "%7") -> Machine.Check {
        Machine.Check(pane: pane, gate: machine[pane]!, timing: timing)
    }

    private static func facts(
        dead: Bool = false, detected: Bool = true, session: Bool = false, status: Bool = false,
        alternate: Bool = false
    ) -> Machine.PaneFacts {
        Machine.PaneFacts(
            dead: dead, agentDetected: detected, hookSessionSet: session, hookStatusSet: status,
            alternateScreen: alternate)
    }

    // MARK: Gates

    @Test func aPaneWithoutAGateIsAdmittedWithoutAnyRead() {
        var machine = Machine()
        #expect(machine.handle(.check(pane: "%3", now: t0, timing: timing)) == [.admit])
    }

    @Test func aLaunchSetsTheGateAndARetryReplacesIt() {
        var machine = launched("pi")
        #expect(machine["%7"] == TmuxLaunchGate(kind: "pi", launchedAt: t0))
        #expect(machine.handle(.launched(pane: "%7", kind: "codex", at: t0 + .seconds(1))).isEmpty)
        #expect(machine["%7"] == TmuxLaunchGate(kind: "codex", launchedAt: t0 + .seconds(1)))
    }

    @Test func aSnapshotPrunesOnlyTheGatesItBeganWith() {
        let began = launched("pi", pane: "%7").after([.launched(pane: "%8", kind: "pi", at: t0)])
        let gatesAtStart = began.state
        // A launch into %9 finished while the snapshot was enriched, and a
        // retry replaced %8's gate.
        var machine = began.after([
            .launched(pane: "%9", kind: "pi", at: t0 + .seconds(1)),
            .launched(pane: "%8", kind: "pi", at: t0 + .seconds(2)),
        ])
        #expect(machine.handle(.listed(panes: ["%3"], gatesAtStart: gatesAtStart)).isEmpty)
        #expect(machine["%7"] == nil)
        #expect(machine["%8"]?.launchedAt == t0 + .seconds(2))
        #expect(machine["%9"] != nil)
    }

    @Test func closeDropsEveryGate() {
        var machine = launched("pi")
        #expect(machine.handle(.closed).isEmpty)
        #expect(machine.isEmpty)
    }

    // MARK: Reads

    @Test func aCheckReadsThePaneFirst() {
        var machine = launched("pi")
        #expect(machine.handle(.check(pane: "%7", now: t0, timing: timing))
            == [.readPane(check(machine))])
    }

    @Test func aDeadPaneOpensTheGate() {
        var machine = launched("pi")
        #expect(machine.handle(.paneRead(check(machine), Self.facts(dead: true), now: t0))
            == [.admit])
        #expect(machine["%7"] == nil)
    }

    @Test func aShellStillInFrontHolds() {
        var machine = launched("pi")
        let gate = machine["%7"]!
        #expect(machine.handle(.paneRead(check(machine), Self.facts(detected: false), now: t0))
            == [.hold(gate)])
        #expect(machine["%7"] == gate)
    }

    // MARK: claude

    @Test func claudeOpensOnceItsSessionHookRan() {
        var machine = launched("claude")
        let gate = machine["%7"]!
        #expect(machine.handle(.paneRead(check(machine), Self.facts(), now: t0)) == [.hold(gate)])
        #expect(machine.handle(.paneRead(check(machine), Self.facts(session: true), now: t0))
            == [.admit])
        #expect(machine["%7"] == nil)
    }

    @Test func claudePastItsTimeoutReadsOnlyForADialog() {
        var machine = launched("claude")
        let gate = machine["%7"]!
        let late = t0 + .seconds(8)
        #expect(machine.handle(.check(pane: "%7", now: late, timing: timing))
            == [.readDialog(check(machine))])
        #expect(machine.handle(.dialogRead(check(machine), blocked: true)) == [.hold(gate)])
        #expect(machine["%7"] == gate)
        #expect(machine.handle(.dialogRead(check(machine), blocked: false)) == [.admit])
        #expect(machine["%7"] == nil)
    }

    // MARK: Input markers

    @Test func aMarkerKindOpensOnAHookStatusOrItsMarker() {
        var hooked = launched("opencode")
        #expect(hooked.handle(.paneRead(check(hooked), Self.facts(status: true), now: t0))
            == [.admit])

        var machine = launched("opencode")
        let gate = machine["%7"]!
        #expect(machine.handle(.paneRead(check(machine), Self.facts(), now: t0)) == [.hold(gate)])
        #expect(machine.handle(.paneRead(check(machine), Self.facts(alternate: true), now: t0))
            == [.readMarker(check(machine), .barBorderedBox)])
        #expect(machine.handle(.markerRead(check(machine), onScreen: false)) == [.hold(gate)])
        #expect(machine.handle(.markerRead(check(machine), onScreen: true)) == [.admit])
        #expect(machine["%7"] == nil)
    }

    @Test func aMarkerKindPastItsCapOpensUnread() {
        var machine = launched("cline")
        #expect(machine.handle(.check(pane: "%7", now: t0 + .seconds(30), timing: timing))
            == [.admit])
        #expect(machine["%7"] == nil)
    }

    // MARK: Delays from detection

    @Test func otherKindsWaitTheirDelayFromFirstDetection() {
        var machine = launched("pi")
        let detected = t0 + .seconds(5)
        let held = TmuxLaunchGate(kind: "pi", launchedAt: t0, detectedAt: detected)
        #expect(machine.handle(.paneRead(check(machine), Self.facts(), now: detected))
            == [.hold(held)])
        #expect(machine["%7"] == held)
        // Detection keeps its first time.
        #expect(machine.handle(.paneRead(check(machine), Self.facts(), now: detected + .seconds(1)))
            == [.hold(held)])
        #expect(machine.handle(
            .paneRead(check(machine), Self.facts(), now: detected + .milliseconds(1500)))
            == [.admit])
        #expect(machine["%7"] == nil)
    }

    @Test func aKindsMinimumDelayOutlastsTheGenericOne() {
        // qwen: 2 s from detection, past the generic 1.5 s.
        var machine = launched("qwen")
        let detected = t0
        _ = machine.handle(.paneRead(check(machine), Self.facts(), now: detected))
        let gate = machine["%7"]!
        #expect(machine.handle(
            .paneRead(check(machine), Self.facts(), now: detected + .milliseconds(1500)))
            == [.hold(gate)])
        #expect(machine.handle(.paneRead(check(machine), Self.facts(), now: detected + .seconds(2)))
            == [.readDialog(check(machine))])
    }

    @Test func aKindWithScreenRulesHoldsWhileADialogShows() {
        var machine = launched("codex")
        let detected = t0
        _ = machine.handle(.paneRead(check(machine), Self.facts(), now: detected))
        let gate = machine["%7"]!
        let due = detected + .milliseconds(1500)
        #expect(machine.handle(.paneRead(check(machine), Self.facts(), now: due))
            == [.readDialog(check(machine))])
        #expect(machine.handle(.dialogRead(check(machine), blocked: true)) == [.hold(gate)])
        #expect(machine.handle(.dialogRead(check(machine), blocked: false)) == [.admit])
    }

    // MARK: Checks across a replaced gate

    @Test func aCheckEndsOnTheGateItFoundEvenIfItWasReplaced() {
        var machine = launched("pi")
        let found = check(machine)
        _ = machine.handle(.launched(pane: "%7", kind: "pi", at: t0 + .seconds(9)))
        // The check that began before the retry writes its own gate back
        // (kept as it was before the machine).
        let written = TmuxLaunchGate(kind: "pi", launchedAt: t0, detectedAt: t0 + .seconds(10))
        #expect(machine.handle(.paneRead(found, Self.facts(), now: t0 + .seconds(10)))
            == [.hold(written)])
        #expect(machine["%7"] == written)
    }
}
