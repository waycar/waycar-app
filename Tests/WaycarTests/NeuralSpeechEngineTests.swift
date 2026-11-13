import Foundation
import Testing

@testable import Waycar

/// No model files or AVAudioEngine: the streams deliberately produce no audio.
/// Audible buffering/route/pause transitions are covered by the pure machine.
private final class EmptyNeuralSynth: NaturalVoiceSynth, @unchecked Sendable {
    typealias Stream = AsyncThrowingStream<NaturalVoiceChunk, any Error>
    let model = NaturalVoiceModelID.pocket
    let sampleRate: Double = 24_000
    private let lock = NSLock()
    private var calls = 0
    private let first = Stream.makeStream()
    private let second = Stream.makeStream()

    var callCount: Int { lock.withLock { calls } }
    var firstResult: Stream.Continuation { first.continuation }
    var secondResult: Stream.Continuation { second.continuation }

    func synthesize(_ sentences: [String]) -> Stream {
        lock.withLock {
            calls += 1
            return calls == 1 ? first.stream : second.stream
        }
    }
    func unload() async {}
}

@MainActor
@Suite("Neural speech engine playback")
struct NeuralSpeechEngineTests {
    private func makeEngine(_ synth: EmptyNeuralSynth, current: Bool = true) -> NeuralSpeechEngine {
        NeuralSpeechEngine(
            synth: synth, selection: .init(model: .pocket, voice: "alba"),
            isCurrent: { _ in current })
    }

    @Test func emptySynthesisEndsUnheardWithoutStartingAudio() async throws {
        let synth = EmptyNeuralSynth()
        let engine = makeEngine(synth)
        let speaking = Task { await engine.speak("One sentence.") }
        try await waitUntil { synth.callCount == 1 }
        synth.firstResult.yield(.init(sentence: 0, samples: []))
        synth.firstResult.finish()
        #expect(await speaking.value == false)
        #expect(engine.playbackProgress == 0)
        #expect(engine.spokenOffset == 0)
        #expect(engine.pause() == false)
        #expect(engine.resume() == false)
    }

    @Test func replacementResumesOldCallerWithoutEndingTheNewOne() async throws {
        let synth = EmptyNeuralSynth()
        let engine = makeEngine(synth)
        let old = Task { await engine.speak("Old sentence.") }
        try await waitUntil { synth.callCount == 1 }
        let replacement = Task { await engine.speak("Replacement sentence.") }
        try await waitUntil { synth.callCount == 2 }
        #expect(await old.value == false)
        synth.firstResult.finish()
        engine.stop()
        #expect(await replacement.value == false)
        synth.secondResult.finish()
        #expect(engine.playbackProgress == 0)
    }

    @Test func cancellationStopsSynthesisAndCompletesItsCaller() async throws {
        let synth = EmptyNeuralSynth()
        let engine = makeEngine(synth)
        let speaking = Task { await engine.speak("One sentence.") }
        try await waitUntil { synth.callCount == 1 }
        speaking.cancel()
        #expect(await speaking.value == false)
        synth.firstResult.finish()
        #expect(engine.resume() == false)
    }

    @Test func blankOrUnloadedLinesNeverStartSynthesis() async {
        let synth = EmptyNeuralSynth()
        let active = makeEngine(synth)
        #expect(await active.speak("") == false)
        let unloaded = makeEngine(synth, current: false)
        #expect(await unloaded.speak("One sentence.") == false)
        #expect(synth.callCount == 0)
        #expect(unloaded.playbackProgress == 0)
    }
}
