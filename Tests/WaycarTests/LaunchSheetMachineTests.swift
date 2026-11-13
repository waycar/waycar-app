import Testing

@testable import Waycar

@Suite("Launch sheet machine")
struct LaunchSheetMachineTests {
    @Test func noNotesAreReadyAndPendingNotesBlockConsent() {
        var machine = LaunchSheetMachine()
        #expect(machine.isReadyForConsent)
        #expect(machine.handle(.notesChanged(pending: true)) == [])
        #expect(machine.state == .notesPending)
        #expect(!machine.isReadyForConsent)
        #expect(machine.handle(.notesChanged(pending: false)) == [])
        #expect(machine.isReadyForConsent)
    }

    @Test func acknowledgementDoesNotMeanDismissalHasFinished() {
        var machine = LaunchSheetMachine().after([.notesChanged(pending: true)])
        #expect(machine.handle(.appeared(notesPending: true)) == [])
        #expect(machine.state == .notesShowing)
        #expect(machine.handle(.notesChanged(pending: false)) == [])
        #expect(machine.state == .notesDismissing)
        #expect(!machine.isReadyForConsent)
        #expect(machine.handle(.dismissed(notesPending: false)) == [])
        #expect(machine.isReadyForConsent)
    }

    @Test func lateAppearanceAfterAnotherWindowAcknowledgedStillWaitsForDismissal() {
        var machine = LaunchSheetMachine()
        #expect(machine.handle(.appeared(notesPending: false)) == [])
        #expect(machine.state == .notesDismissing)
        #expect(machine.handle(.notesChanged(pending: false)) == [])
        #expect(!machine.isReadyForConsent)
        _ = machine.handle(.dismissed(notesPending: false))
        #expect(machine.isReadyForConsent)
    }

    @Test func aDismissCallbackUsesTheCurrentNotesRatherThanAssumingTheyWereAcknowledged() {
        var machine = LaunchSheetMachine().after([.appeared(notesPending: true)])
        _ = machine.handle(.dismissed(notesPending: true))
        #expect(machine.state == .notesPending)
        _ = machine.handle(.notesChanged(pending: false))
        #expect(machine.isReadyForConsent)
    }

    @Test(arguments: [false, true])
    func callbacksReconcileCurrentNotesFromEveryPresentationState(pending: Bool) {
        let setups: [[LaunchSheetMachine.Event]] = [
            [], [.notesChanged(pending: true)], [.appeared(notesPending: true)],
            [.appeared(notesPending: false)],
        ]
        for setup in setups {
            var appearing = LaunchSheetMachine().after(setup)
            #expect(appearing.handle(.appeared(notesPending: pending)) == [])
            #expect(appearing.state == (pending ? .notesShowing : .notesDismissing))
            var dismissing = LaunchSheetMachine().after(setup)
            #expect(dismissing.handle(.dismissed(notesPending: pending)) == [])
            #expect(dismissing.state == (pending ? .notesPending : .readyForConsent))
        }
    }

    @Test func callbackOrderingAndRepeatedEventsDoNotOpenTheGateEarly() {
        var machine = LaunchSheetMachine().after([.appeared(notesPending: true)])
        _ = machine.handle(.notesChanged(pending: true))
        #expect(machine.state == .notesShowing)
        _ = machine.handle(.appeared(notesPending: true))
        #expect(machine.state == .notesShowing)
        _ = machine.handle(.notesChanged(pending: false))
        _ = machine.handle(.notesChanged(pending: true))
        _ = machine.handle(.appeared(notesPending: false))
        #expect(machine.state == .notesDismissing)
        _ = machine.handle(.dismissed(notesPending: false))
        _ = machine.handle(.notesChanged(pending: false))
        _ = machine.handle(.dismissed(notesPending: false))
        #expect(machine.isReadyForConsent)
    }
}
