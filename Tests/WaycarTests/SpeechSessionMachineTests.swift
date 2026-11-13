import Testing

@testable import Waycar

@Suite("Speech session machine")
struct SpeechSessionMachineTests {
    typealias Machine = SpeechSessionMachine

    private var startup: [Machine.Event] {
        Machine.Stage.allCases.filter { $0 != .microphone }.map {
            .checkpoint(1, $0, taskCancelled: false)
        }
    }

    private var capturing: Machine { Machine().after(startup + [.microphoneOpened(1)]) }

    @Test func eachStartupAwaitMustPassItsOwnCheckpoint() {
        var machine = Machine()
        for stage in Machine.Stage.allCases where stage != .microphone {
            #expect(machine.state == .preparing(1, stage))
            #expect(machine.handle(.checkpoint(99, stage, taskCancelled: false)) == [])
            #expect(machine.handle(.checkpoint(1, stage, taskCancelled: true)) == [])
            #expect(machine.state == .preparing(1, stage))
            #expect(machine.handle(.checkpoint(1, stage, taskCancelled: false)) == [.continueStartup])
            #expect(machine.handle(.checkpoint(1, stage, taskCancelled: false)) == [])
        }
        #expect(machine.state == .preparing(1, .microphone))
        #expect(machine.handle(.microphoneOpened(99)) == [])
        #expect(machine.handle(.microphoneOpened(1)) == [])
        #expect(machine.state == .capturing(1))
    }

    @Test func cancellationAtAnyStartupStageNeverOpensTheMicrophone() {
        for stage in Machine.Stage.allCases {
            var machine = Machine()
            for previous in Machine.Stage.allCases {
                if previous == stage { break }
                _ = machine.handle(.checkpoint(1, previous, taskCancelled: false))
            }
            #expect(machine.handle(.cancel) == [.releaseClaim, .stopCapture, .cancelAnalyzer])
            #expect(machine.wasCancelled)
            #expect(machine.handle(.checkpoint(1, stage, taskCancelled: false)) == [])
            #expect(machine.handle(.microphoneOpened(1)) == [])
            #expect(machine.handle(.finish) == [])
            #expect(machine.handle(.cancel) == [])
        }
    }

    @Test func finishingStartupAbandonsInsteadOfFinalizing() {
        var machine = Machine()
        #expect(machine.handle(.finish) == [.releaseClaim, .stopCapture, .cancelAnalyzer])
        #expect(machine.state == .cancelling(1, .cancelled))
    }

    @Test func capturedAudioStopsBeforeOneFinalizationAndTeardownDoesNotCancelIt() {
        var machine = capturing
        #expect(machine.handle(.finish) == [.stopCapture, .finalize(1)])
        #expect(machine.state == .finalizing(1))
        #expect(machine.handle(.finish) == [])
        #expect(machine.handle(.finalized(1, succeeded: true)) == [])
        #expect(machine.handle(.teardown) == [.stopCapture, .discardInput])
        #expect(machine.handle(.tornDown(99)) == [])
        #expect(machine.handle(.tornDown(1)) == [.releaseResources])
        #expect(machine.state == .released(1, .finalizing))
        #expect(!machine.wasCancelled)
    }

    @Test func failedFinalizationCancelsOnlyItsOwnAnalyzerEvenAfterTeardown() {
        var machine = capturing.after([.finish])
        #expect(machine.handle(.finalized(99, succeeded: false)) == [])
        #expect(machine.handle(.finalized(1, succeeded: false)) == [.cancelAnalyzer])
        _ = machine.handle([.teardown, .tornDown(1)])
        #expect(machine.handle(.finalized(1, succeeded: false)) == [.cancelAnalyzer])
    }

    @Test func cancellationWhileFinalizingKeepsTheTeardownDisposition() {
        var machine = capturing.after([.finish])
        #expect(machine.handle(.cancel) == [.releaseClaim, .stopCapture, .cancelAnalyzer])
        #expect(machine.state == .cancelling(1, .cancelledFinalization))
        #expect(machine.handle(.teardown) == [.stopCapture, .discardInput])
        #expect(machine.handle(.tornDown(1)) == [.releaseResources])
        #expect(machine.wasCancelled)
    }

    @Test func cancellationOfCaptureAndNonfinalizingTeardownCancelTheAnalyzer() {
        var machine = capturing
        #expect(machine.handle(.cancel) == [.releaseClaim, .stopCapture, .cancelAnalyzer])
        #expect(machine.handle(.teardown) == [.stopCapture, .discardInput, .cancelAnalyzer])
        #expect(machine.handle(.tornDown(1)) == [.releaseResources])
        #expect(machine.wasCancelled)
        #expect(machine.handle(.cancel) == [])
        #expect(machine.handle(.teardown) == [.stopCapture, .discardInput, .cancelAnalyzer])
        #expect(machine.handle(.tornDown(1)) == [.releaseResources])
    }

    @Test func cancellationDuringTeardownStillReleasesOnlyTheCapturedSession() {
        for var machine in [Machine(), capturing, capturing.after([.finish])] {
            _ = machine.handle(.teardown)
            #expect(machine.handle(.cancel) == [.releaseClaim, .stopCapture, .cancelAnalyzer])
            #expect(machine.handle(.cancel) == [])
            #expect(machine.handle(.tornDown(1)) == [.releaseResources])
            #expect(machine.wasCancelled)
            #expect(machine.handle(.finish) == [])
        }
    }

    @Test func outOfOrderStartupAndUnissuedFinalizationsAreIgnored() {
        var machine = Machine()
        #expect(machine.handle([
            .checkpoint(1, .reservation, taskCancelled: false), .microphoneOpened(1),
            .finalized(1, succeeded: false), .tornDown(1),
        ]) == [])
        #expect(machine.state == .preparing(1, .permission))
    }
}
