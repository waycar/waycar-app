import Testing

@testable import Waycar

@Suite("Terminal run machine")
struct TerminalRunMachineTests {
    private typealias Machine = TerminalRunMachine

    private let startEffects: (UInt64) -> [Machine.Effect] = { token in
        [
            .publishStatus(.connecting), .telemetryBegan, .publishEndedWithMoshFailure(false),
            .publishFlavor(nil), .clearAcquired, .startRun(token),
        ]
    }

    private func live(_ flavor: TerminalSessionFlavor = .ssh) -> Machine {
        Machine().after([.start, .transportReady(flavor), .sessionOpened, .contentShown])
    }

    @Test func aStartConnectsAndTheFirstContentGoesLive() {
        var machine = Machine()
        #expect(machine.handle(.start) == startEffects(1))
        #expect(machine.isRunning)
        #expect(machine.handle(.transportReady(.mosh)) == [.publishFlavor(.mosh)])
        #expect(machine.handle(.sessionOpened) == [.sessionToken(2)])
        #expect(machine.handle(.contentShown) == [.publishStatus(.live), .publishHasBeenLive, .telemetryWentLive])
        #expect(machine.handle(.contentShown).isEmpty, "only a connecting session goes live")
    }

    @Test func theBlankFrameGraceGoesLiveOnlyForItsOwnSession() {
        var machine = Machine().after([.start, .transportReady(.mosh), .sessionOpened])
        #expect(machine.handle(.graceElapsed(session: 9)).isEmpty)
        _ = machine.handle(.sessionFinished)
        #expect(machine.handle(.graceElapsed(session: 2)).isEmpty)
        var current = Machine().after([.start, .transportReady(.mosh), .sessionOpened])
        #expect(current.handle(.graceElapsed(session: 2)) == [
            .publishStatus(.live), .publishHasBeenLive, .telemetryWentLive,
        ])
    }

    @Test func aLostLinkReattachesOncePerLiveStretch() {
        var machine = live(.mosh)
        let restart: [Machine.Effect] = [
            .telemetryRunEnded(restarting: true), .publishStatus(.connecting), .scheduleRestart(invalidating: nil),
        ]
        #expect(machine.handle(.runFailed(.moshLinkLost, message: "lost", canInvalidateMosh: true)) == restart)
        _ = machine.handle([.runFinished, .restartDue, .start])
        #expect(machine.handle(.runFailed(.moshLinkLost, message: "lost", canInvalidateMosh: true)) == [
            .telemetryRunEnded(restarting: false), .publishStatus(.ended("lost")),
        ])
        _ = machine.handle([.runFinished, .retry, .transportReady(.mosh), .sessionOpened, .contentShown])
        #expect(machine.handle(.runFailed(.moshLinkLost, message: "lost", canInvalidateMosh: true)) == restart)
    }

    @Test func aMoshFailureFallsBackOnceUntilARetryGivesItBack() {
        var machine = live(.mosh)
        #expect(machine.handle(.runFailed(.moshSessionFailed, message: "m", canInvalidateMosh: true)) == [
            .publishEndedWithMoshFailure(true), .telemetryRunEnded(restarting: true),
            .publishStatus(.connecting), .scheduleRestart(invalidating: .automaticFallback),
        ])
        _ = machine.handle([.runFinished, .restartDue, .start])
        #expect(machine.handle(.runFailed(.moshSessionFailed, message: "m", canInvalidateMosh: true)) == [
            .publishEndedWithMoshFailure(true), .telemetryRunEnded(restarting: false),
            .publishStatus(.ended("m")),
        ])
        _ = machine.handle(.runFinished)
        #expect(machine.handle(.retry) == startEffects(4))
        #expect(machine.handle(.runFailed(.moshSessionFailed, message: "m", canInvalidateMosh: true)).last
            == .scheduleRestart(invalidating: .automaticFallback))
    }

    @Test func withoutAnInvalidationAMoshFailureEnds() {
        var machine = live(.mosh)
        #expect(machine.handle(.runFailed(.moshSessionFailed, message: "m", canInvalidateMosh: false)) == [
            .publishEndedWithMoshFailure(true), .telemetryRunEnded(restarting: false),
            .publishStatus(.ended("m")),
        ])
        #expect(machine.state.endedWithMoshFailure)
    }

    @Test func aTransientDeathRetriesOncePerEndedEpisode() {
        var machine = live()
        #expect(machine.handle(.runFailed(.transient, message: "t", canInvalidateMosh: true)).last
            == .scheduleRestart(invalidating: nil))
        _ = machine.handle([.runFinished, .restartDue, .start])
        #expect(machine.handle(.runFailed(.transient, message: "t", canInvalidateMosh: true)).last
            == .publishStatus(.ended("t")))
        _ = machine.handle([.runFinished, .retry, .sessionOpened, .contentShown])
        #expect(machine.handle(.runFailed(.transient, message: "t", canInvalidateMosh: true)).last
            == .scheduleRestart(invalidating: nil))
    }

    @Test func otherFailuresAndCleanEndsEnd() {
        var machine = live()
        #expect(machine.handle(.runFailed(.other, message: "x", canInvalidateMosh: true)) == [
            .telemetryRunEnded(restarting: false), .publishStatus(.ended("x")),
        ])
        _ = machine.handle([.runFinished, .retry])
        #expect(machine.handle(.runCompleted) == [
            .telemetryRunEnded(restarting: false), .publishStatus(.ended("The session ended.")),
        ])
    }

    @Test func aStopIsTerminalForRunEndsAndRestartsButNotForAPassedRestart() {
        var machine = live(.mosh)
        #expect(machine.handle(.stop) == [.publishStopRequested, .telemetryStopped])
        #expect(machine.handle(.runFailed(.moshLinkLost, message: "l", canInvalidateMosh: true)).isEmpty)
        #expect(machine.handle(.runCompleted).isEmpty)
        #expect(machine.handle(.restartDue).isEmpty)
        #expect(machine.handle(.upgradeRestartDue).isEmpty)
        #expect(machine.handle(.stopFinished) == [.publishStatus(.stopped)])
        #expect(!machine.canUpgradeToMosh)
        // A restart that passed its check before the stop still starts.
        #expect(machine.handle(.start).last == .startRun(3))
    }

    @Test func anUpgradeOwnsTheStatusUntilItsRestartRuns() {
        var machine = live()
        #expect(machine.canUpgradeToMosh)
        #expect(machine.handle(.upgrade) == [
            .publishUpgradeScheduled(true), .publishStatus(.connecting), .scheduleUpgradeRestart,
        ])
        #expect(machine.handle(.upgrade).isEmpty)
        #expect(machine.handle(.runCompleted).isEmpty)
        #expect(machine.handle(.runFailed(.transient, message: "t", canInvalidateMosh: true)).isEmpty)
        _ = machine.handle(.runFinished)
        #expect(machine.handle(.upgradeRestartDue) == [.publishUpgradeScheduled(false), .restart])
    }

    @Test func onlyALiveOrConnectingSSHRunCanUpgrade() {
        var connecting = Machine().after([.start])
        #expect(!connecting.canUpgradeToMosh)
        _ = connecting.handle(.transportReady(.ssh))
        #expect(connecting.canUpgradeToMosh)
        let mosh = Machine().after([.start, .transportReady(.mosh)])
        #expect(!mosh.canUpgradeToMosh)
        #expect(live(.mosh).canUpgradeToMosh)
        #expect(!Machine().canUpgradeToMosh)
    }

    @Test func retriesNeedAnEndedSession() {
        var machine = live()
        #expect(machine.handle(.retry).isEmpty)
        #expect(machine.handle(.retryOverSSH).isEmpty)
        _ = machine.handle(.runCompleted)
        #expect(machine.handle(.retry).isEmpty, "the run has not finished yet")
        #expect(machine.handle(.retryOverSSH) == [.scheduleRestart(invalidating: .userChoseSSH)])
        #expect(machine.state.moshAutoFallbackUsed)
        _ = machine.handle(.runFinished)
        #expect(machine.handle(.retry).last == .startRun(3))
        #expect(!machine.state.moshAutoFallbackUsed)
    }
}
