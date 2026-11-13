@preconcurrency import AVFoundation
import Foundation
import Speech

/// Turns a recorded audio file (a watch voice reply: AAC, 16 kHz mono .m4a)
/// into text. The seam keeps callers off Speech and AVFoundation types so
/// they are testable with a scripted transcriber.
protocol AudioFileTranscribing: Sendable {
    /// The whole file's transcript, trimmed; empty when no words were heard.
    /// Throws a `DictationEngineError`: `.captureFailed` when the file is
    /// missing or unreadable, `.localeUnsupported` when the device has no
    /// on-device model for `locale`, `.modelUnavailable` when that model
    /// cannot be installed.
    func transcribe(fileAt url: URL, locale: Locale) async throws -> String
}

extension DictationEngines {
    /// The production file transcriber, or nil where the OS has no
    /// `SpeechAnalyzer` (before iOS 26). Simulator screenshot runs get a
    /// deterministic fake.
    static var fileTranscriber: (any AudioFileTranscribing)? {
        #if DEBUG && targetEnvironment(simulator)
            if DemoScreenshotMode.isEnabled {
                return DemoAudioFileTranscriber()
            }
        #endif
        if #available(iOS 26, *) {
            return SpeechAudioFileTranscriber()
        }
        return nil
    }
}

/// On-device file transcription through iOS 26's `SpeechAnalyzer`, sharing
/// the live engine's model reservation and install (`SpeechModelAssets`).
/// Recognition never leaves the device (ADR 0003). Unlike the live engine it
/// does not claim the microphone, so it runs alongside a Composer session.
@available(iOS 26, *)
struct SpeechAudioFileTranscriber: AudioFileTranscribing {
    func transcribe(fileAt url: URL, locale: Locale) async throws -> String {
        // Open the file first: a missing or corrupt recording fails fast,
        // before any model work.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DictationEngineError.captureFailed(
                "unreadable audio file: \(SpeechModelAssets.describe(error))")
        }
        guard file.length > 0 else {
            throw DictationEngineError.captureFailed("empty audio file")
        }

        guard let transcriber = await Transcriber.makeForRecording(locale: locale) else {
            throw DictationEngineError.localeUnsupported
        }
        try await SpeechModelAssets.reserve(transcriber.locales)
        try await SpeechModelAssets.installModel(for: transcriber.module) { _ in }

        let analyzer = SpeechAnalyzer(modules: [transcriber.module])
        do {
            async let transcript = transcriber.recordingTranscript()
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await analyzer.cancelAndFinishNow()
            if error is CancellationError { throw error }
            SpeechModelAssets.log.error(
                "File transcription failed: \(String(describing: error), privacy: .public)")
            throw error as? DictationEngineError
                ?? .captureFailed(SpeechModelAssets.describe(error))
        }
    }
}

/// A recording's transcript, built from a transcriber's results in order.
/// Final results are settled text, each following the one before; an
/// unfinalized result stands in for the audio after them until a final one
/// replaces it. Text the analyzer reported but never finalized still
/// counts, so speech it heard is never sent back as "no words" (#202).
struct RecordingTranscript: Equatable, Sendable {
    /// Every final result so far, in order.
    private var settled = ""
    /// The latest unfinalized result after the last final one.
    private var pending = ""

    /// Adds the transcriber's next result.
    mutating func add(_ text: String, isFinal: Bool) {
        if isFinal {
            settled += text
            pending = ""
        } else {
            pending = text
        }
    }

    /// The transcript so far, untrimmed.
    var text: String { settled + pending }
}

#if DEBUG && targetEnvironment(simulator)
    /// Screenshot-mode stand-in: the Simulator has no speech models, so a
    /// readable file always yields the same reply.
    struct DemoAudioFileTranscriber: AudioFileTranscribing {
        /// The scripted reply every readable recording transcribes to.
        static let transcript = "Looks good, ship it."

        func transcribe(fileAt url: URL, locale: Locale) async throws -> String {
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw DictationEngineError.captureFailed("unreadable audio file")
            }
            return Self.transcript
        }
    }
#endif
