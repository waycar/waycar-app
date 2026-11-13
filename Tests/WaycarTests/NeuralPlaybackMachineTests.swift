import Testing

@testable import Waycar

@Suite("Neural playback machine")
struct NeuralPlaybackMachineTests {
    private var start: NeuralPlaybackMachine.Event {
        .start(1, sentenceStarts: [0, 10], sentences: ["First.", "Second."])
    }
    private func synthesizing() -> NeuralPlaybackMachine {
        NeuralPlaybackMachine().after([.stop, start])
    }
    private func playing() -> NeuralPlaybackMachine {
        synthesizing().after([.sentence(1, 0), .scheduled(1, frames: 100, sentence: 0)])
    }

    @Test func startsSynthesisOnlyForTheCurrentEpoch() {
        var machine = NeuralPlaybackMachine()
        #expect(machine.handle(.stop) == [.releaseResources(0)])
        #expect(machine.handle(.start(0, sentenceStarts: [], sentences: [])).isEmpty)
        #expect(machine.handle(start) == [.synthesize(1, ["First.", "Second."])])
        #expect(machine.state == .synthesizing(.init(token: 1, progress: .init(sentenceStarts: [0, 10]))))
        #expect(machine.handle(start).isEmpty)
        #expect(machine.handle(.pause).isEmpty)
        #expect(machine.handle(.resume).isEmpty)
    }

    @Test func noBuffersFinishesUnheardExactlyOnce() {
        var machine = synthesizing()
        #expect(machine.handle(.synthesized(1, sentences: 2)) == [.complete(1, spoken: false)])
        #expect(machine.handle(.synthesized(1, sentences: 2)).isEmpty)
        #expect(machine.handle(.failed(1)).isEmpty)
        #expect(machine.handle(.released(1)) == [.releaseResources(1)])
        #expect(machine.handle(.stop) == [.releaseResources(1)])
    }

    @Test func synthesisWaitsForEveryQueuedBufferToPlay() {
        var machine = synthesizing()
        #expect(machine.handle(.scheduled(1, frames: 100, sentence: 0)) == [.ensurePlaying])
        #expect(machine.handle(.sentence(1, 1)).isEmpty)
        #expect(machine.handle(.scheduled(1, frames: 200, sentence: 1)) == [.ensurePlaying])
        #expect(machine.progress.scheduledFrames == 300)
        #expect(machine.progress.spokenOffset == 0)
        #expect(machine.handle(.synthesized(1, sentences: 2)).isEmpty)
        #expect(machine.state == .draining(.init(token: 1, progress: machine.progress)))
        #expect(machine.handle(.played(1)).isEmpty)
        #expect(machine.progress.spokenOffset == 10)
        #expect(machine.handle(.played(1)) == [.complete(1, spoken: true)])
        #expect(machine.progress.spokenOffset == 0)
        #expect(machine.handle(.played(1)).isEmpty)
        #expect(machine.progress.played == 2)
        #expect(machine.handle(.released(1)) == [.releaseResources(1)])
    }

    @Test func earlyPlaybackDoesNotFinishUntilSynthesisEnds() {
        var machine = playing()
        #expect(machine.handle(.played(1)).isEmpty)
        #expect(machine.handle(.played(1)).isEmpty)
        #expect(machine.progress.played == 1)
        #expect(machine.handle(.sentence(1, 1)).isEmpty)
        #expect(machine.progress.spokenOffset == 10)
        #expect(machine.handle(.synthesized(1, sentences: 2)) == [.complete(1, spoken: true)])
    }

    @Test func pauseQueuesNewAudioWithoutStartingItAndResumePreservesTheQueue() {
        var machine = playing()
        #expect(machine.handle(.pause) == [.pauseAudio])
        #expect(machine.handle(.pause) == [.pauseAudio])
        #expect(machine.isPaused)
        #expect(machine.handle(.sentence(1, 1)).isEmpty)
        #expect(machine.handle(.scheduled(1, frames: 200, sentence: 1)).isEmpty)
        #expect(machine.progress.scheduled == 2)
        #expect(machine.handle(.configurationChanged(1)).isEmpty)
        #expect(machine.handle(.resume) == [.resumeAudio])
        #expect(!machine.isPaused)
        #expect(machine.state == .playing(.init(token: 1, progress: machine.progress)))
        #expect(machine.handle(.resume).isEmpty)
    }

    @Test func pausedSynthesisCanFinishAndThenResumeDraining() {
        var machine = playing().after([.pause])
        #expect(machine.handle(.synthesized(1, sentences: 2)).isEmpty)
        #expect(machine.state == .paused(.init(token: 1, progress: machine.progress), .finished))
        #expect(machine.handle(.resume) == [.resumeAudio])
        #expect(machine.state == .draining(.init(token: 1, progress: machine.progress)))
        #expect(machine.handle(.pause) == [.pauseAudio])
        #expect(machine.handle(.played(1)) == [.complete(1, spoken: true)])
    }

    @Test func playedCallbacksWhilePausedStillWaitForSynthesis() {
        var machine = playing().after([.pause])
        #expect(machine.handle(.played(1)).isEmpty)
        #expect(machine.handle(.played(1)).isEmpty)
        #expect(machine.handle(.synthesized(1, sentences: 2)) == [.complete(1, spoken: true)])
    }

    @Test func stopCompletesEachActiveStageOnceAndKeepsLastAudibleProgress() {
        let setups: [[NeuralPlaybackMachine.Event]] = [
            [], [.scheduled(1, frames: 100, sentence: 0)],
            [.scheduled(1, frames: 100, sentence: 0), .pause],
            [.scheduled(1, frames: 100, sentence: 0), .synthesized(1, sentences: 2)],
        ]
        for setup in setups {
            var machine = synthesizing().after(setup)
            let progress = machine.progress
            #expect(machine.handle(.stop) == [.releaseResources(1), .complete(1, spoken: false)])
            #expect(machine.token == 2)
            #expect(machine.progress == progress)
            #expect(machine.handle(.stop) == [.releaseResources(2)])
            #expect(machine.handle(.resetProgress).isEmpty)
            #expect(machine.progress.sentenceStarts.isEmpty)
            #expect(machine.progress.bufferSentences.isEmpty)
            #expect(machine.progress.played == progress.played)
            #expect(machine.progress.scheduledFrames == progress.scheduledFrames)
        }
    }

    @Test func failureAndRouteChangeEndCurrentWorkButNotAHeldLine() {
        let setups: [[NeuralPlaybackMachine.Event]] = [
            [], [.scheduled(1, frames: 100, sentence: 0)],
            [.scheduled(1, frames: 100, sentence: 0), .synthesized(1, sentences: 2)],
        ]
        for setup in setups {
            var failed = synthesizing().after(setup)
            #expect(failed.handle(.failed(1)) == [.complete(1, spoken: false)])
            #expect(failed.handle(.failed(1)).isEmpty)
            var changed = synthesizing().after(setup)
            #expect(changed.handle(.configurationChanged(1)) == [
                .configurationStopped, .releaseResources(1), .complete(1, spoken: false),
            ])
        }
        var paused = playing().after([.pause])
        #expect(paused.handle(.failed(1)) == [.complete(1, spoken: false)])
    }

    @Test func staleCallbacksCannotChangeOrCompleteAReplacementLine() {
        var machine = playing().after([.stop, .start(2, sentenceStarts: [0], sentences: ["New."])])
        let state = machine.state
        #expect(machine.handle([
            .sentence(1, 99), .scheduled(1, frames: 100, sentence: 0), .played(1),
            .synthesized(1, sentences: 99), .failed(1), .configurationChanged(1),
            .released(1), .stopLine(1),
        ]).isEmpty)
        #expect(machine.state == state)
        #expect(machine.handle(.stopLine(2)) == [.releaseResources(2), .complete(2, spoken: false)])
    }

    @Test func idleAndEndedStatesIgnoreLateLifecycleEvents() {
        let events: [NeuralPlaybackMachine.Event] = [
            .sentence(0, 1), .scheduled(0, frames: 100, sentence: 0), .played(0),
            .synthesized(0, sentences: 1), .failed(0), .pause, .resume,
            .configurationChanged(0), .released(0),
        ]
        var idle = NeuralPlaybackMachine()
        #expect(idle.handle(events).isEmpty)
        var ended = synthesizing().after([.synthesized(1, sentences: 2)])
        #expect(ended.handle(events).isEmpty)
        var active = playing()
        #expect(active.handle(.resetProgress).isEmpty)
        #expect(active.handle(.scheduled(1, frames: 0, sentence: 0)).isEmpty)
    }
}
