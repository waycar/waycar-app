import Foundation
import Testing

@testable import Waycar

@Suite("Transcript acquisition machine")
struct TranscriptAcquisitionMachineTests {
    private let delays: [Duration] = [.seconds(1), .seconds(2)]
    private var fresh: TranscriptAcquisitionMachine { .init(retryDelays: delays) }

    @Test func startResetsTheCursorAndBudgetsOnce() {
        var machine = fresh.after([.answered(.found(transcript: nil, wholeList: true))])
        #expect(!machine.state.needsFullRead)
        #expect(machine.handle(.start) == [.cancelRetry])
        #expect(machine.state.isStarted && machine.state.needsFullRead)
        #expect(machine.handle(.start).isEmpty)
    }

    @Test(arguments: [TranscriptAcquisitionMachine.Reader.transcript, .screen])
    func aRequestDuringAPassRunsItOnceMore(reader: TranscriptAcquisitionMachine.Reader) {
        var machine = fresh
        #expect(machine.handle(.requested(reader)) == [.startPass(reader, 1)])
        _ = machine.handle(.passBegan(reader, 1))
        #expect(machine.handle(.requested(reader)).isEmpty)
        #expect(machine.handle(.requested(reader)).isEmpty)
        #expect(machine.handle(.passEnded(reader, 1)) == [.runAgain])
        _ = machine.handle(.passBegan(reader, 1))
        #expect(machine.handle(.passEnded(reader, 1)) == [.passFinished(reader)])
        #expect(machine.handle(.requested(reader)) == [.startPass(reader, 2)])
    }

    @Test func aRequestBeforeThePassBeganIsAbsorbedIntoIt() {
        var machine = fresh.after([.requested(.transcript), .requested(.transcript), .passBegan(.transcript, 1)])
        #expect(machine.handle(.passEnded(.transcript, 1)) == [.passFinished(.transcript)])
    }

    @Test func stopAndDiscardRetireThePasses() {
        var machine = fresh.after([.start, .requested(.transcript), .requested(.screen)])
        #expect(machine.handle(.screenDiscarded) == [.cancelPass(.screen)])
        #expect(machine.handle(.passEnded(.screen, 2)).isEmpty)
        #expect(machine.handle(.stop) == [.cancelPass(.screen), .cancelPass(.transcript), .cancelRetry])
        #expect(machine.handle(.passBegan(.transcript, 1)).isEmpty)
        #expect(machine.handle(.passEnded(.transcript, 1)).isEmpty)
        #expect(machine.state.transcript == .idle && !machine.state.isStarted)
    }

    @Test func failuresRetryThroughTheDelaysWhileStartedOnly() {
        var machine = fresh
        #expect(machine.handle(.readFailed(pluginGap: false)) == [.cancelRetry])
        _ = machine.handle(.start)
        #expect(machine.handle(.answered(.notFound)) == [.cancelRetry, .armRetry(1, after: .seconds(1))])
        #expect(machine.handle(.answered(.readerError)) == [.cancelRetry, .armRetry(2, after: .seconds(2))])
        #expect(machine.handle(.readFailed(pluginGap: false)) == [.cancelRetry, .armRetry(3, after: .seconds(2))])
        #expect(machine.handle(.retryElapsed(2)).isEmpty)
        #expect(machine.handle(.retryElapsed(3)) == [.scheduleRead])
        #expect(machine.state.retry == .none)
        #expect(machine.handle(.retryElapsed(3)).isEmpty)
    }

    @Test func aFoundReadResetsTheAttemptAndUnsupportedEndsRetries() {
        var machine = fresh.after([.start, .answered(.notFound)])
        #expect(machine.handle(.answered(.found(transcript: nil, wholeList: true))) == [.cancelRetry, .show])
        #expect(machine.handle(.answered(.notFound)) == [.cancelRetry, .armRetry(2, after: .seconds(1))])
        #expect(machine.handle(.answered(.unsupported)) == [.cancelRetry])
        #expect(machine.state.retry == .none)
        #expect(machine.handle(.retryElapsed(2)).isEmpty)
    }

    @Test func aPluginGapIsBelievedOutsideTheRecheckBudget() {
        var machine = fresh.after([.start])
        #expect(machine.handle(.readFailed(pluginGap: true)) == [.cancelRetry])
        #expect(machine.handle(.pluginUpdated) == [.scheduleRead])
        #expect(machine.state.pluginRechecksLeft == 2)
        #expect(machine.handle(.readFailed(pluginGap: true)) == [.cancelRetry, .armRetry(1, after: .seconds(1))])
        _ = machine.handle(.answered(.found(transcript: nil, wholeList: true)))
        #expect(machine.state.pluginRechecksLeft == 1)
        #expect(machine.handle(.readFailed(pluginGap: true)) == [.cancelRetry, .armRetry(2, after: .seconds(1))])
        #expect(machine.handle(.readFailed(pluginGap: true)) == [.cancelRetry])
        _ = machine.handle(.stop)
        #expect(machine.handle(.pluginUpdated).isEmpty)
    }

    @Test func theCursorFollowsWholeListsAndAMovedTranscript() {
        var machine = fresh.after([.requested(.transcript), .passBegan(.transcript, 1)])
        #expect(machine.handle(.answered(.found(transcript: "/one", wholeList: true))) == [.cancelRetry, .show])
        #expect(!machine.state.needsFullRead)
        #expect(machine.handle(.answered(.found(transcript: "/one", wholeList: false))) == [.cancelRetry, .merge])
        #expect(machine.handle(.answered(.found(transcript: nil, wholeList: false))) == [.cancelRetry, .merge])
        #expect(machine.state.transcriptPath == "/one")
        #expect(machine.handle(.answered(.found(transcript: "/two", wholeList: false))) == [.cancelRetry])
        #expect(machine.state.needsFullRead)
        #expect(machine.state.transcriptPath == "/two")
        #expect(machine.handle(.passEnded(.transcript, 1)) == [.runAgain])
    }

    @Test func aFirstPathIsNoMove() {
        var machine = fresh
        #expect(machine.handle(.answered(.found(transcript: "/one", wholeList: false))) == [.cancelRetry, .merge])
        #expect(machine.state.transcriptPath == "/one")
    }
}
