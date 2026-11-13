import Accelerate
@preconcurrency import AVFoundation
import Foundation
import OSLog
import Speech

/// The production `DictationEngine`: on-device speech-to-text with the
/// system's own models through iOS 26's `SpeechAnalyzer`. Nothing is bundled
/// and no audio leaves the device. The Composer prefers `SpeechTranscriber`;
/// devices it does not support fall back to `DictationTranscriber`, the model
/// behind keyboard dictation. A CarPlay turn (`.car`) prefers
/// `DictationTranscriber` with the far-field hint, since the car's microphone
/// sits away from the driver. A language whose model is not on the device yet
/// is downloaded through `AssetInventory` — the system-managed copy every app
/// shares — before the microphone opens.
///
/// Cannot run in the Simulator or CI (no supported locales there); the store
/// is tested against a scripted engine and this type is verified on device.
@available(iOS 26, *)
actor SpeechDictationEngine: DictationEngine {
    static let shared = SpeechDictationEngine()

    /// Actor-confined state for one session. A cancelled session releases
    /// its claim immediately, so a startup stuck in a system await (a model
    /// download) cannot block the next attempt; its own checks stop it from
    /// ever opening the microphone.
    private final class Session {
        let id: DictationSessionID
        let microphone = MicrophoneCapture()
        var lifecycle = SpeechSessionMachine()
        var analyzer: SpeechAnalyzer?
        var input: AsyncStream<AnalyzerInput>.Continuation?

        init(id: DictationSessionID) {
            self.id = id
        }
    }

    private var session: Session?

    nonisolated func events(
        for sessionID: DictationSessionID, locale: Locale, audioProfile: DictationAudioProfile
    ) -> AsyncThrowingStream<DictationEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: DictationEvent.self, throwing: (any Error).self)
        let task = Task {
            await self.run(
                sessionID, locale: locale, audioProfile: audioProfile, continuation: continuation)
        }
        continuation.onTermination = { termination in
            guard case .cancelled = termination else { return }
            task.cancel()
            Task { await self.cancel(sessionID) }
        }
        return stream
    }

    func finish(_ sessionID: DictationSessionID) async {
        guard let session, session.id == sessionID else { return }
        await perform(session.lifecycle.handle(.finish), for: session)
    }

    private func run(
        _ sessionID: DictationSessionID,
        locale: Locale,
        audioProfile: DictationAudioProfile,
        continuation: AsyncThrowingStream<DictationEvent, any Error>.Continuation
    ) async {
        guard session == nil else {
            continuation.finish(throwing: DictationEngineError.busy)
            return
        }
        let session = Session(id: sessionID)
        self.session = session
        do {
            guard await Self.hasMicrophonePermission() else {
                throw DictationEngineError.microphonePermissionDenied
            }
            try Self.checkStarting(session, after: .permission)

            guard let transcriber = await Transcriber.make(for: locale, audioProfile: audioProfile)
            else {
                throw DictationEngineError.localeUnsupported
            }
            try Self.checkStarting(session, after: .transcriber)

            // A model other apps already installed is on the device but not
            // reserved for this one; the analyzer refuses an unreserved locale
            // (`assetLocaleNotAllocated`). Reserve before every session.
            try await SpeechModelAssets.reserve(transcriber.locales)
            try Self.checkStarting(session, after: .reservation)

            try await SpeechModelAssets.installModel(for: transcriber.module) { fraction in
                continuation.yield(.downloadingModel(fraction: fraction))
            }
            try Self.checkStarting(session, after: .installation)

            guard
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber.module])
            else {
                throw DictationEngineError.captureFailed("no audio format for the speech model")
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber.module])
            session.analyzer = analyzer
            try await analyzer.prepareToAnalyze(in: format)
            try Self.checkStarting(session, after: .analyzerPreparation)

            let (inputs, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
            session.input = input
            try await analyzer.start(inputSequence: inputs)
            // The last suspension point before the microphone opens; nothing
            // between here and `start` can let a cancel slip past.
            try Self.checkStarting(session, after: .analyzerStart)

            try session.microphone.start(
                into: format,
                audioProfile: audioProfile,
                onInterruption: { Task { await self.finish(sessionID) } },
                receive: { buffer, level in
                    input.yield(AnalyzerInput(buffer: buffer))
                    continuation.yield(.level(level))
                })
            _ = session.lifecycle.handle(.microphoneOpened(session.lifecycle.token))
            continuation.yield(.listening)

            try await transcriber.forwardResults { text, isFinal in
                continuation.yield(.transcript(text, isFinal: isFinal))
            }
            await tearDown(session)
            continuation.finish()
        } catch {
            let wasCancelled = session.lifecycle.wasCancelled
            await tearDown(session)
            if wasCancelled || error is CancellationError {
                continuation.finish()
            } else {
                SpeechModelAssets.log.error(
                    "Dictation failed: \(String(describing: error), privacy: .public)")
                continuation.finish(
                    throwing: error as? DictationEngineError
                        ?? .captureFailed(SpeechModelAssets.describe(error)))
            }
        }
    }

    private func cancel(_ sessionID: DictationSessionID) async {
        guard let session, session.id == sessionID else { return }
        await perform(session.lifecycle.handle(.cancel), for: session)
    }

    /// Idempotent: releases this session's resources and claim, never a
    /// newer session's.
    private func tearDown(_ session: Session) async {
        await perform(session.lifecycle.handle(.teardown), for: session)
        await perform(session.lifecycle.handle(.tornDown(session.lifecycle.token)), for: session)
    }

    private func perform(_ effects: [SpeechSessionMachine.Effect], for session: Session) async {
        for effect in effects {
            switch effect {
            case .continueStartup:
                break // Synchronous checkpoints consume this effect below.
            case .releaseClaim:
                if self.session === session { self.session = nil }
            case .stopCapture:
                session.microphone.stop()
                session.input?.finish()
            case .discardInput:
                session.input = nil
            case .finalize(let token):
                let succeeded: Bool
                do {
                    try await session.analyzer?.finalizeAndFinishThroughEndOfInput()
                    succeeded = true
                } catch {
                    succeeded = false
                }
                await perform(session.lifecycle.handle(.finalized(token, succeeded: succeeded)), for: session)
            case .cancelAnalyzer:
                await session.analyzer?.cancelAndFinishNow()
            case .releaseResources:
                session.analyzer = nil
                // An old startup/teardown never releases a replacement's claim.
                if self.session === session { self.session = nil }
            }
        }
    }

    private static func checkStarting(_ session: Session, after stage: SpeechSessionMachine.Stage) throws {
        let effects = session.lifecycle.handle(.checkpoint(
            session.lifecycle.token, stage, taskCancelled: Task.isCancelled))
        guard effects == [.continueStartup] else { throw CancellationError() }
    }

    private static func hasMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}

/// The on-device model bookkeeping both the live engine and the file
/// transcriber share: `AssetInventory` reservation, model install, and
/// speech-free error descriptions. Never touches the network beyond the
/// system's own model download (ADR 0003).
@available(iOS 26, *)
enum SpeechModelAssets {
    /// The Dictation log; errors only, never transcript text.
    static let log = Logger(subsystem: "com.otreva.waycar", category: "Dictation")

    /// Domain and code, enough to tell recognizer failures apart in a bug
    /// report without echoing anything the user said.
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    /// Reserves `locales` for this app, releasing another of its reservations
    /// first when the system's per-app limit is reached.
    static func reserve(_ locales: [Locale]) async throws {
        for locale in locales {
            let reserved = await AssetInventory.reservedLocales
            let id = locale.identifier(.bcp47)
            guard !reserved.contains(where: { $0.identifier(.bcp47) == id }) else { continue }
            if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
                await AssetInventory.release(reservedLocale: oldest)
            }
            do {
                try await AssetInventory.reserve(locale: locale)
            } catch {
                log.error("Reserving \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                throw DictationEngineError.modelUnavailable
            }
        }
    }

    /// Makes sure the system's model for `module`'s locale is on the device,
    /// downloading it when it is not. The system owns and shares the model;
    /// this only asks for it.
    static func installModel(
        for module: any SpeechModule,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return
        case .unsupported:
            throw DictationEngineError.localeUnsupported
        case .supported, .downloading:
            break
        @unknown default:
            break
        }
        do {
            guard
                let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [module])
            else { return }
            progress(request.progress.fractionCompleted)
            let observation = request.progress.observe(\.fractionCompleted) { value, _ in
                progress(value.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("Model install failed: \(String(describing: error), privacy: .public)")
            throw DictationEngineError.modelUnavailable
        }
    }
}

/// The two system transcribers behind one surface. `SpeechTranscriber` is the
/// newer long-form model but is not available on every device;
/// `DictationTranscriber` is the keyboard-dictation model and covers the rest.
@available(iOS 26, *)
enum Transcriber {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    /// Resolves through the Speech framework's own locale equivalence — a
    /// raw `Locale` comparison misses equivalent identifiers. Nil when the
    /// device has no on-device model for the language. `.car` tries the
    /// far-field dictation model first (docs/design/carplay.md §5 ASR): a
    /// head unit's microphone is an arm's length or more from the driver.
    static func make(for locale: Locale, audioProfile: DictationAudioProfile) async -> Transcriber? {
        if audioProfile == .car,
            let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale)
        {
            return .dictation(DictationTranscriber(locale: resolved, preset: carPreset))
        }
        if SpeechTranscriber.isAvailable,
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        {
            return .speech(SpeechTranscriber(locale: resolved, preset: .progressiveTranscription))
        }
        if let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return .dictation(
                DictationTranscriber(locale: resolved, preset: .progressiveLongDictation))
        }
        return nil
    }

    /// The model for a recorded reply (a watch voice reply, up to 60 s):
    /// the keyboard-dictation model with `recordingPreset`, final results
    /// only. Nil when the device has no on-device model.
    static func makeForRecording(locale: Locale) async -> Transcriber? {
        guard let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale)
        else { return nil }
        return .dictation(DictationTranscriber(locale: resolved, preset: recordingPreset))
    }

    /// `.longDictation`, never a short-form preset without frequent
    /// finalization: on iOS 27 `.phrase` and `.shortDictation` deliver their
    /// only result unfinalized (`resultsFinalizationTime` stays zero) even
    /// after `finalizeAndFinish(through:)`, and that result is the model's
    /// first pass, before the final pass corrects it (#202).
    static let recordingPreset = DictationTranscriber.Preset.longDictation

    /// Short utterances (a question, "send"), volatile results so the
    /// turn's endpointing sees speech as it starts, and the far-field hint.
    private static var carPreset: DictationTranscriber.Preset {
        var preset = DictationTranscriber.Preset.progressiveShortDictation
        preset.contentHints.insert(.farField)
        return preset
    }

    var locales: [Locale] {
        switch self {
        case .speech(let transcriber): transcriber.selectedLocales
        case .dictation(let transcriber): transcriber.selectedLocales
        }
    }

    var module: any SpeechModule {
        switch self {
        case .speech(let transcriber): transcriber
        case .dictation(let transcriber): transcriber
        }
    }

    /// Forwards every result until the analyzer finishes (after finalize or
    /// cancel) or fails.
    func forwardResults(_ deliver: @Sendable (String, Bool) -> Void) async throws {
        switch self {
        case .speech(let transcriber):
            for try await result in transcriber.results {
                deliver(String(result.text.characters), result.isFinal)
            }
        case .dictation(let transcriber):
            for try await result in transcriber.results {
                deliver(String(result.text.characters), result.isFinal)
            }
        }
    }

    /// A recording's whole transcript once the analyzer finishes (after
    /// finalize or cancel): every final result, plus any text the analyzer
    /// reported but never finalized (`RecordingTranscript`).
    func recordingTranscript() async throws -> String {
        var transcript = RecordingTranscript()
        switch self {
        case .speech(let transcriber):
            for try await result in transcriber.results {
                transcript.add(String(result.text.characters), isFinal: result.isFinal)
            }
        case .dictation(let transcriber):
            for try await result in transcriber.results {
                transcript.add(String(result.text.characters), isFinal: result.isFinal)
            }
        }
        return transcript.text
    }
}

/// Owns the audio session, the input tap, and format conversion for one
/// session. Called only from `SpeechDictationEngine`'s actor; the tap block
/// runs on the realtime audio thread and touches only its own converter.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var isSessionActive = false
    private var isTapInstalled = false
    private var observers: [any NSObjectProtocol] = []
    private var audioProfile = DictationAudioProfile.composer

    /// Starts capture as one transaction: any failure after the audio session
    /// activates undoes everything before the error escapes.
    /// `onInterruption` fires when the system takes the microphone away (a
    /// call, Siri) or the route changes under the engine; the engine then
    /// finishes gracefully instead of hanging on silent input.
    func start(
        into format: AVAudioFormat,
        audioProfile: DictationAudioProfile,
        onInterruption: @escaping @Sendable () -> Void,
        receive: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void
    ) throws {
        self.audioProfile = audioProfile
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioProfile.activate(audioSession)
            isSessionActive = true

            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw DictationEngineError.captureFailed("no microphone input")
            }
            let converter = BufferConverter(outputFormat: format)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
                buffer, _ in
                let level = AudioLevel.normalized(buffer)
                guard let converted = try? converter.convert(buffer) else { return }
                receive(converted, level)
            }
            isTapInstalled = true

            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: audioSession, queue: nil
                ) { note in
                    let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    if raw == AVAudioSession.InterruptionType.began.rawValue {
                        onInterruption()
                    }
                },
                center.addObserver(
                    forName: .AVAudioEngineConfigurationChange,
                    object: engine, queue: nil
                ) { _ in
                    onInterruption()
                },
            ]

            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    /// Idempotent.
    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        engine.stop()
        // A car turn owns its session and deactivates it at the turn's end
        // (`DictationAudioProfile.car`); only the Composer's is ours to drop.
        if isSessionActive, audioProfile.deactivatesWithMicrophone {
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
        }
        isSessionActive = false
    }
}

extension DictationAudioProfile {
    /// Sets the category for this profile and activates the shared session.
    /// `CarSpeaker` activates `.car` the same way, so the turn's speech and
    /// listening never reconfigure the session under each other.
    func activate(_ audioSession: AVAudioSession = .sharedInstance()) throws {
        switch self {
        case .composer:
            // `.spokenAudio` is a playback mode; paired with `.record` iOS
            // rejects it with paramErr (-50). `.measurement` is the mode
            // Apple's speech-recognition sample records with.
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        case .car:
            // One `.playAndRecord` session for the whole turn, mode
            // `.default`, mixing off (docs/design/carplay.md §5 Audio).
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [])
        }
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Whether stopping the microphone releases the session. The car turn
    /// keeps it for the reply and deactivates it itself.
    var deactivatesWithMicrophone: Bool { self == .composer }
}

/// Microphone loudness for the Composer's waveform.
enum AudioLevel {
    /// Speech sits roughly between these; quieter reads as silence, louder
    /// saturates.
    private static let floorDecibels: Float = -50
    private static let ceilingDecibels: Float = -10

    /// First-channel RMS mapped from decibels onto `0...1`.
    static func normalized(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        let rms = vDSP.rootMeanSquare(samples)
        return normalized(decibels: 20 * log10(max(rms, 1e-7)))
    }

    /// `0...1` for a dBFS value: linear across the speech range, then lifted
    /// with a square root so normal speech fills most of the waveform's
    /// height while silence stays at zero.
    static func normalized(decibels: Float) -> Float {
        let fraction = (decibels - floorDecibels) / (ceilingDecibels - floorDecibels)
        return sqrt(min(max(fraction, 0), 1))
    }
}

/// Converts captured microphone buffers to the analyzer's format. Adapted from
/// Apple's “Bringing advanced speech-to-text capabilities to your app” sample
/// (WWDC25 session 277, BufferConversion.swift; Notices/Apple-SpeechAnalyzer-MIT.txt).
/// Used only from the tap thread.
private final class BufferConverter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != outputFormat else { return buffer }
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            // Sacrifice the first samples' quality to avoid timestamp drift.
            converter?.primeMethod = .none
        }
        guard let converter else { throw DictationEngineError.captureFailed("no converter") }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { throw DictationEngineError.captureFailed("no conversion buffer") }

        // Hand the buffer over once, then report no more data so the
        // converter emits exactly this buffer's worth of output.
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw DictationEngineError.captureFailed("conversion failed") }
        return output
    }
}
