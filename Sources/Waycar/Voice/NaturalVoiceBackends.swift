import CoreML
import FluidAudio
import Foundation

/// A piece of a line's audio and the sentence (index into the line's
/// sentences) it speaks.
struct NaturalVoiceChunk: Sendable {
    let sentence: Int
    let samples: [Float]
}

/// One loaded Natural voice model, speaking with the voice it was loaded
/// for (docs/design/carplay.md §5 TTS).
protocol NaturalVoiceSynth: Sendable {
    var model: NaturalVoiceModelID { get }
    /// Mono Float32 samples per second; fixed for the model.
    var sampleRate: Double { get }
    /// A line's audio in order, as the model makes it: one chunk per
    /// sentence for Kokoro and Paradee, 80 ms frames for Pocket, each
    /// tagged with its sentence. Ending the iteration (or cancelling its
    /// task) stops the synthesis.
    func synthesize(_ sentences: [String]) -> AsyncThrowingStream<NaturalVoiceChunk, any Error>
    /// Frees the model.
    func unload() async
}

/// Loads each catalog model for the car, on compute units that work while
/// Waycar is in the background: CarPlay speaks with another app on the car
/// screen, where iOS denies the GPU (and may deny the Neural Engine). No
/// stage of Pocket or Paradee is GPU-only or even GPU-placed; Kokoro's
/// ANE-v3 runtime pins three small fp32 stages to `.cpuAndGPU` itself. A
/// synthesis that throws turns that model off for the session, and the car
/// speaks with the system voice.
enum NaturalVoiceBackends {
    /// Loads the installed `id` from disk and warms it with `voice` (Paradee
    /// has only `af_heart`), so the first car line doesn't pay the first-run
    /// cost. Call with FluidAudio's network switch off.
    static func load(_ id: NaturalVoiceModelID, voice: String) async throws -> any NaturalVoiceSynth {
        let synth: any NaturalVoiceSynth
        switch id {
        case .kokoro: synth = try await KokoroVoice.load(voice: voice)
        case .pocket: synth = try await PocketVoice.load(voice: voice)
        case .paradee: synth = try await ParadeeVoice.load()
        }
        do {
            for try await _ in synth.synthesize([NaturalVoiceModel.warmUpText]) {}
        } catch {
            await synth.unload()
            throw error
        }
        return synth
    }

    /// Kokoro-82M on FluidAudio's ANE-v3 runtime, English. The runtime
    /// places its own stages: ANE for the network, `.cpuAndGPU` for noise,
    /// iSTFT tail and source generator.
    static func kokoroManager(voice: String?) -> KokoroAneManager {
        KokoroAneManager(variant: .english, defaultVoice: voice, version: .v3)
    }

    /// Pocket's `.ane` placement keeps the FlowLM on the Neural Engine; the
    /// stages FluidAudio leaves on `.all` (conditioner, flow decoder) are
    /// pinned off the GPU too, and Mimi stays on the CPU.
    static let pocketComputeUnits = PocketTtsComputeUnits(
        conditioner: .cpuAndNeuralEngine, flowLM: .cpuAndNeuralEngine,
        flowDecoder: .cpuAndNeuralEngine, mimiDecoder: .cpuOnly)

    /// Kyutai Pocket TTS, English pack, rank-4 ANE models.
    static func pocketManager() -> PocketTtsManager {
        PocketTtsManager(language: .english, placement: .ane, computeUnits: pocketComputeUnits)
    }

    /// Paradee-8M int8 on the CPU only: nothing to deny when backgrounded.
    static func paradeeManager() -> ParadeeManager {
        ParadeeManager(variant: .int8, computeUnits: .cpuOnly)
    }

    /// A stream fed by `produce` on its own task; ends when `produce`
    /// returns or throws, and cancels it when the consumer stops.
    fileprivate static func stream(
        _ produce: @escaping @Sendable (AsyncThrowingStream<NaturalVoiceChunk, any Error>.Continuation)
            async throws -> Void
    ) -> AsyncThrowingStream<NaturalVoiceChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await produce(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Kokoro with Waycar's pronunciations; one sentence per chunk.
private struct KokoroVoice: NaturalVoiceSynth {
    let manager: KokoroAneManager
    let voice: String

    var model: NaturalVoiceModelID { .kokoro }
    var sampleRate: Double { Double(KokoroAneConstants.sampleRate) }

    static func load(voice: String) async throws -> KokoroVoice {
        let manager = NaturalVoiceBackends.kokoroManager(voice: voice)
        await manager.setEnglishCustomLexicon(NaturalVoiceModel.pronunciations)
        do {
            try await manager.initialize(preloadVoices: [voice])
        } catch {
            await manager.cleanup()
            throw error
        }
        return KokoroVoice(manager: manager, voice: voice)
    }

    func synthesize(_ sentences: [String]) -> AsyncThrowingStream<NaturalVoiceChunk, any Error> {
        NaturalVoiceBackends.stream { [manager, voice] continuation in
            for (index, sentence) in sentences.enumerated() {
                let result = try await manager.synthesizeDetailed(text: sentence, voice: voice)
                continuation.yield(NaturalVoiceChunk(sentence: index, samples: result.samples))
            }
        }
    }

    func unload() async {
        await manager.cleanup()
    }
}

/// Pocket streams: one session per line keeps the voice prefilled and the
/// Mimi decoder's state continuous across its sentences, and yields each
/// 80 ms frame as it is generated.
private struct PocketVoice: NaturalVoiceSynth {
    let manager: PocketTtsManager
    let voice: String

    var model: NaturalVoiceModelID { .pocket }
    var sampleRate: Double { Double(PocketTtsConstants.audioSampleRate) }

    static func load(voice: String) async throws -> PocketVoice {
        let manager = NaturalVoiceBackends.pocketManager()
        do {
            try await manager.initialize()
        } catch {
            await manager.cleanup()
            throw error
        }
        return PocketVoice(manager: manager, voice: voice)
    }

    func synthesize(_ sentences: [String]) -> AsyncThrowingStream<NaturalVoiceChunk, any Error> {
        NaturalVoiceBackends.stream { [manager, voice] continuation in
            let session = try await manager.makeSession(voice: voice)
            for sentence in sentences { session.enqueue(sentence) }
            session.finish()
            // A consumer that stops (or a cancelled task) ends `frames`,
            // which cancels the session's generation. Each enqueued
            // sentence is one utterance.
            for try await frame in session.frames {
                continuation.yield(
                    NaturalVoiceChunk(sentence: frame.utteranceIndex ?? 0, samples: frame.samples))
            }
        }
    }

    func unload() async {
        await manager.cleanup()
    }
}

/// Paradee speaks only `af_heart`; one sentence per chunk.
private struct ParadeeVoice: NaturalVoiceSynth {
    let manager: ParadeeManager

    var model: NaturalVoiceModelID { .paradee }
    var sampleRate: Double { Double(ParadeeConstants.sampleRate) }

    static func load() async throws -> ParadeeVoice {
        let manager = NaturalVoiceBackends.paradeeManager()
        do {
            try await manager.initialize()
        } catch {
            await manager.cleanup()
            throw error
        }
        return ParadeeVoice(manager: manager)
    }

    func synthesize(_ sentences: [String]) -> AsyncThrowingStream<NaturalVoiceChunk, any Error> {
        NaturalVoiceBackends.stream { [manager] continuation in
            for (index, sentence) in sentences.enumerated() {
                let samples: [Float]
                do {
                    samples = try await manager.synthesize(text: sentence)
                } catch ParadeeError.inputProcessingFailed {
                    // Nothing speakable in it (an emoji, a lone symbol):
                    // skip the sentence, not the model.
                    continue
                }
                continuation.yield(NaturalVoiceChunk(sentence: index, samples: samples))
            }
        }
    }

    func unload() async {
        await manager.cleanup()
    }
}
