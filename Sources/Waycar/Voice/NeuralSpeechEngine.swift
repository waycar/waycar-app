import AVFoundation
import CarPlay
import FluidAudio
import NaturalLanguage
import OSLog
import UIKit

/// A catalog model and the voice it speaks with.
struct NaturalVoiceSelection: Equatable, Sendable {
    let model: NaturalVoiceModelID
    let voice: String
}

/// The Natural voice (beta) for car lines (docs/design/carplay.md §5 TTS):
/// the active catalog model on device, when the user turned it on in
/// Settings › CarPlay Voice and that model is downloaded and loaded. A load
/// or synthesis error turns that model off until the app relaunches;
/// `CarSpeaker` then speaks with `SystemSpeechEngine`. The model is held
/// only while CarPlay is connected: a disconnect, a memory warning, the
/// toggle going off, another model or voice being picked, or a delete
/// releases it, and the next CarPlay line or `prepare()` loads the one the
/// settings ask for.
@MainActor
enum NaturalVoice {
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "carplay")
    private static var loaded: NeuralSpeechEngine?
    private static var loading: Task<Void, Never>?
    /// What `loading` loads.
    private static var pending: NaturalVoiceSelection?
    /// Models whose load or synthesis failed this launch.
    private static var failed: Set<NaturalVoiceModelID> = []
    private static var observers: [any NSObjectProtocol] = []

    /// The model and voice the settings ask for, or nil while the Natural
    /// voice is off. Reads no files.
    nonisolated static func requested(defaults: UserDefaults = .standard) -> NaturalVoiceSelection? {
        guard NaturalVoiceSettings.isEnabled(defaults: defaults) else { return nil }
        let model = NaturalVoiceSettings.activeModel(defaults: defaults)
        return NaturalVoiceSelection(
            model: model, voice: NaturalVoiceSettings.voice(for: model, defaults: defaults))
    }

    /// The neural engine when the user turned Natural voice on AND the
    /// active model is downloaded and loaded with the chosen voice; else
    /// nil. An installed model that isn't loaded yet starts loading, for a
    /// later line.
    static func engine() -> (any CarSpeechEngine)? {
        guard let wanted = requested(), !failed.contains(wanted.model) else {
            unload()
            return nil
        }
        if let loaded, loaded.selection == wanted { return loaded }
        startLoading(wanted)
        return nil
    }

    /// Warm the model (call when a CarPlay scene connects); no-op if off or
    /// not downloaded.
    static func prepare() async {
        guard let wanted = requested(), !failed.contains(wanted.model),
            loaded?.selection != wanted
        else { return }
        startLoading(wanted)
        await loading?.value
    }

    /// Whether `engine` is still the one `engine()` hands out: a failed or
    /// unloaded engine never speaks again.
    static func isCurrent(_ engine: NeuralSpeechEngine) -> Bool {
        loaded === engine
    }

    /// A load or synthesis error: `model` stays off for the rest of this
    /// launch.
    static func fail(_ error: any Error, model: NaturalVoiceModelID) {
        guard failed.insert(model).inserted else { return }
        log.error(
            "Natural voice \(model.rawValue, privacy: .public) off for this session: \(error)")
        if (loaded?.selection.model ?? pending?.model) == model { unload() }
    }

    /// Releases the model, stopping any line it speaks.
    static func unload() {
        loading?.cancel()
        loading = nil
        pending = nil
        loaded?.close()
        loaded = nil
    }

    /// Settings finished a download: every model gets a fresh chance.
    static func modelInstalled() {
        failed.removeAll()
    }

    /// Loads `wanted` offline. Never while Settings downloads a model: the
    /// offline switch is process-wide, so flipping it would fail that
    /// download. The car speaks with the system voice until it finishes.
    private static func startLoading(_ wanted: NaturalVoiceSelection) {
        guard pending != wanted else { return }
        unload()
        guard !NaturalVoiceModelStore.shared.isDownloading,
            NaturalVoiceModel.isInstalled(wanted.model)
        else { return }
        observeReleases()
        NaturalVoiceModel.allowNetwork(false)
        pending = wanted
        loading = Task {
            do {
                let synth = try await NaturalVoiceBackends.load(wanted.model, voice: wanted.voice)
                guard !Task.isCancelled else {
                    await synth.unload()
                    return
                }
                Self.loaded = NeuralSpeechEngine(synth: synth, selection: wanted)
                Self.loading = nil
                Self.pending = nil
            } catch {
                guard !Task.isCancelled else { return }
                Self.loading = nil
                Self.pending = nil
                Self.fail(error, model: wanted.model)
            }
        }
    }

    /// The toggle, the active model or its voice changed: a held model
    /// that is no longer the one asked for goes now, not on the next line.
    private static func settingsChanged() {
        guard let held = loaded?.selection ?? pending, held != requested() else { return }
        unload()
    }

    /// The model is up to several hundred MB: let it go when the car leaves
    /// or iOS asks for memory, so the phone app isn't the one jetsam ends.
    private static func observeReleases() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIScene.didDisconnectNotification, object: nil, queue: .main
            ) { notification in
                guard notification.object is CPTemplateApplicationScene else { return }
                MainActor.assumeIsolated { Self.unload() }
            },
            center.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { Self.unload() }
            },
            center.addObserver(
                forName: UserDefaults.didChangeNotification, object: UserDefaults.standard,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { Self.settingsChanged() }
            },
        ]
    }
}

enum NeuralSpeechError: Error {
    case audioFormat(sampleRate: Double)
}

/// Speaks a line with a loaded catalog model, on its own `AVAudioEngine`
/// over the turn's already-active session. Audio is queued as the model
/// makes it (a sentence at a time, or Pocket's 80 ms frames), so the next
/// sentence synthesizes while the current one plays. The engine is torn
/// down after every line, so the microphone is free when the turn listens.
@MainActor
final class NeuralSpeechEngine: CarSpeechEngine {
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "carplay")

    let selection: NaturalVoiceSelection
    private let synth: any NaturalVoiceSynth
    private let isCurrent: @MainActor (NeuralSpeechEngine) -> Bool
    private var playback = NeuralPlaybackMachine()
    /// Bumped by every `speak` and `stop`; work for an older line is stale.
    private var line: Int { playback.token }
    private var audioLine: Int?
    private var audio: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    /// Watches the line's engine: iOS stops it on a route or format change
    /// without an interruption, and its buffers then never finish.
    private var configurationObserver: (any NSObjectProtocol)?
    /// The line's synthesis, queuing audio on the player as it arrives.
    private var synthesis: [Int: Task<Void, Never>] = [:]
    /// Waiting callers and synthesis Tasks are resources keyed by line epoch.
    private var finishes: [Int: CheckedContinuation<Bool, Never>] = [:]
    var onExternalPause: (@MainActor () -> Void)?

    /// The start of the sentence of the first buffer not yet heard.
    var spokenOffset: Int { playback.progress.spokenOffset }

    /// Audible progress: buffers played plus frames the player rendered,
    /// capped at the frames queued. Queuing alone doesn't count, nor does
    /// a running player's clock past its queue, so a line whose queued
    /// buffers iOS flushed stays still.
    var playbackProgress: Int {
        let rendered = player.flatMap { player in
            player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }
        }.map { Int($0.sampleTime) } ?? 0
        return min(max(rendered, 0), playback.progress.scheduledFrames) &+ playback.progress.played
    }

    init(
        synth: any NaturalVoiceSynth, selection: NaturalVoiceSelection,
        isCurrent: @escaping @MainActor (NeuralSpeechEngine) -> Bool = { NaturalVoice.isCurrent($0) }
    ) {
        self.synth = synth
        self.selection = selection
        self.isCurrent = isCurrent
    }

    func speak(_ text: String) async -> Bool {
        stop()
        // A line that never starts reports no progress, not the last one's.
        perform(playback.handle(.resetProgress))
        // Unloaded or failed: return at once, so the caller's fallback
        // doesn't wait on a model that is gone.
        guard isCurrent(self) else { return false }
        let ranges = CarLine.sentenceRanges(in: text)
        guard !Task.isCancelled, !ranges.isEmpty else { return false }
        let sentenceStarts = ranges.map { $0.lowerBound.utf16Offset(in: text) }
        let sentences = ranges.map { String(text[$0]) }
        let current = line
        return await withTaskCancellationHandler {
            await play(sentences, sentenceStarts: sentenceStarts, line: current)
        } onCancel: {
            Task { @MainActor in self.stop(line: current) }
        }
    }

    func stop() { perform(playback.handle(.stop)) }

    /// Stops speaking and frees the model.
    func close() {
        stop()
        Task { [synth] in await synth.unload() }
    }

    private func stop(line stale: Int) { perform(playback.handle(.stopLine(stale))) }

    func pause() -> Bool {
        guard finishes[line] != nil, player != nil, audio != nil else { return false }
        let effects = playback.handle(.pause)
        guard effects.contains(.pauseAudio) else { return false }
        return perform(effects)
    }

    /// Restarts the engine (an interruption stops it) and plays the
    /// buffers still queued on the player.
    func resume() -> Bool {
        guard playback.isPaused, finishes[line] != nil, player != nil, audio != nil else { return false }
        return perform(playback.handle(.resume))
    }

    /// True once every queued buffer played.
    private func play(_ sentences: [String], sentenceStarts: [Int], line current: Int) async -> Bool {
        defer { perform(playback.handle(.released(current))) }
        let effects = playback.handle(.start(current, sentenceStarts: sentenceStarts, sentences: sentences))
        guard !effects.isEmpty else { return false }
        return await withCheckedContinuation { continuation in
            finishes[current] = continuation
            perform(effects)
        }
    }

    /// Queues the line's audio as the model makes it. A stopped line's
    /// synthesis ends however it ends; only the current line's error counts
    /// against the model.
    private func synthesize(_ sentences: [String], line current: Int) async {
        do {
            // One stream per line (Pocket keeps one session, its voice
            // prefill and decoder state, across the line); each chunk says
            // which sentence it speaks.
            for try await chunk in synth.synthesize(sentences) {
                guard line == current else { return }
                perform(playback.handle(.sentence(current, chunk.sentence)))
                try schedule(chunk.samples, sentence: chunk.sentence, line: current)
            }
        } catch {
            guard line == current, !Task.isCancelled else { return }
            NaturalVoice.fail(error, model: synth.model)
            perform(playback.handle(.failed(current)))
            return
        }
        perform(playback.handle(.synthesized(current, sentences: sentences.count)))
    }

    /// Queues one chunk of audio behind the ones still playing.
    private func schedule(_ samples: [Float], sentence: Int, line current: Int) throws {
        guard !samples.isEmpty else { return }
        let (player, format) = try startedPlayer(line: current)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { throw NeuralSpeechError.audioFormat(sampleRate: synth.sampleRate) }
        samples.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let effects = playback.handle(.scheduled(current, frames: samples.count, sentence: sentence))
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
            Task { @MainActor in self.bufferPlayed(line: current) }
        }
        perform(effects)
    }

    /// The line's player, started on first use. Every catalog model speaks
    /// mono at its own fixed rate (24 kHz today); the mixer converts to the
    /// route's format.
    private func startedPlayer(line current: Int) throws -> (AVAudioPlayerNode, AVAudioFormat) {
        if let player, let format { return (player, format) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: synth.sampleRate, channels: 1)
        else { throw NeuralSpeechError.audioFormat(sampleRate: synth.sampleRate) }
        let audio = AVAudioEngine()
        let player = AVAudioPlayerNode()
        audio.attach(player)
        // Speaking Speed: the models have no common speed control, so the
        // audio is time-stretched (pitch kept). Buffers still complete one
        // by one, so `spokenOffset` and resume are unaffected.
        let speed = CarVoiceSpeed.current()
        if speed != CarVoiceSpeed.standard {
            let stretch = AVAudioUnitTimePitch()
            stretch.rate = Float(speed)
            audio.attach(stretch)
            audio.connect(player, to: stretch, format: format)
            audio.connect(stretch, to: audio.mainMixerNode, format: format)
        } else {
            audio.connect(player, to: audio.mainMixerNode, format: format)
        }
        audio.prepare()
        try audio.start()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.configurationChanged(line: current) }
        }
        self.audio = audio
        self.player = player
        self.format = format
        audioLine = current
        return (player, format)
    }

    private func bufferPlayed(line current: Int) { perform(playback.handle(.played(current))) }

    /// All AVFoundation and Task effects remain on the main actor. Completion
    /// removes the continuation before resuming, including reentrant model unload.
    @discardableResult
    private func perform(_ effects: [NeuralPlaybackMachine.Effect]) -> Bool {
        var succeeded = true
        for effect in effects {
            switch effect {
            case .synthesize(let token, let sentences):
                synthesis[token] = Task { await self.synthesize(sentences, line: token) }
            case .complete(let token, let spoken):
                finishes.removeValue(forKey: token)?.resume(returning: spoken)
            case .releaseResources(let token):
                releaseResources(line: token)
            case .ensurePlaying:
                if let player, !player.isPlaying { player.play() }
            case .pauseAudio:
                player?.pause()
                audio?.pause()
            case .resumeAudio:
                guard let player, let audio else { succeeded = false; continue }
                do {
                    if !audio.isRunning { try audio.start() }
                    player.play()
                } catch {
                    Self.log.error("Natural voice line not resumed: \(error)")
                    succeeded = false
                }
            case .configurationStopped:
                Self.log.error("Natural voice line stopped: audio engine configuration changed")
            }
        }
        return succeeded
    }

    /// iOS stopped the line's engine: the line ends unheard, without
    /// counting against the model, so the caller can speak it another way.
    private func configurationChanged(line current: Int) {
        perform(playback.handle(.configurationChanged(current)))
    }

    /// Stops playback and synthesis and tears the audio engine down; a
    /// waiting `speak` returns false.
    private func releaseResources(line current: Int) {
        synthesis.removeValue(forKey: current)?.cancel()
        guard audioLine == current else { return }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        player?.stop()
        audio?.stop()
        player = nil
        audio = nil
        format = nil
        audioLine = nil
    }

    /// The line's sentences, so the first plays while the rest synthesize.
    static func sentences(in text: String) -> [String] {
        CarLine.sentenceRanges(in: text).map { String(text[$0]) }
    }
}
