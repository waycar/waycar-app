import Foundation

/// Identifies one Dictation attempt across asynchronous startup and teardown.
/// The engine is app-wide, so a finish or cancel from an older Composer must
/// never touch a newer session.
struct DictationSessionID: Hashable, Sendable {
    private let rawValue = UUID()
}

/// One update from a live Dictation session, in order.
enum DictationEvent: Sendable, Equatable {
    /// The on-device speech model for the locale is downloading; `fraction`
    /// is in `0...1`. Only emitted before `.listening`, and only when the
    /// system does not have the model yet.
    case downloadingModel(fraction: Double)
    /// The microphone is live and audio is flowing into the recognizer.
    case listening
    /// Microphone input level, normalized to `0...1` (silence ≈ 0).
    case level(Float)
    /// A transcript segment. A volatile segment (`isFinal == false`) replaces
    /// the previous volatile one; a final segment is settled text that the
    /// next segments follow. Their concatenation is the whole dictation.
    case transcript(String, isFinal: Bool)
}

/// Why Dictation could not start or continue. A closed set, so the Composer
/// can route each cause to its own copy (and Settings, for permission)
/// without string-matching.
enum DictationEngineError: Error, Sendable, Equatable {
    /// Microphone access is denied or restricted.
    case microphonePermissionDenied
    /// The system has no on-device speech model for the language. The
    /// Simulator reports this for every language.
    case localeUnsupported
    /// The system's on-device model exists for the language but could not be
    /// downloaded.
    case modelUnavailable
    /// Another Composer already owns the microphone.
    case busy
    /// Audio capture or recognition failed; `detail` names the step or the
    /// system error (domain and code, never speech) for bug reports.
    case captureFailed(String)
}

/// How a Dictation session sets up the shared `AVAudioSession`
/// (docs/design/carplay.md §5 Audio). One engine serves both; only the
/// session differs.
enum DictationAudioProfile: Sendable, Equatable {
    /// The phone's Composer and Chat mics: `.record` / `.measurement` /
    /// `.duckOthers`, released when the session stops.
    case composer
    /// A CarPlay voice turn: `.playAndRecord`, mode `.default`, no mixing
    /// options (WWDC26), so the turn's speech and listening share one
    /// session. The turn owns that session: the microphone leaves it active
    /// when it stops, and the turn's end (`CarSpeaker.endTurn`) deactivates
    /// it with `.notifyOthersOnDeactivation`. That way a listen that ends
    /// never drops the session the turn's speech plays on.
    case car
}

/// The seam between Dictation and the iOS Speech stack. The Composer and
/// `DictationStore` depend only on this, never on Speech or AVFoundation
/// types, so the store is testable with a scripted engine — the real one
/// cannot run in the Simulator or CI.
protocol DictationEngine: Sendable {
    /// Starts a session for `locale`, with the audio session set up for
    /// `audioProfile`. Permission, model download, and microphone startup
    /// all happen inside the returned stream, so the caller renders progress
    /// without a separate call. The stream finishes normally after
    /// `finish(_:)` flushes the last final transcript, and finishes throwing
    /// a `DictationEngineError` when the session cannot start or fails.
    /// Terminating the stream (cancelling its consumer) discards the session
    /// and releases the microphone immediately.
    func events(
        for sessionID: DictationSessionID, locale: Locale, audioProfile: DictationAudioProfile
    ) -> AsyncThrowingStream<DictationEvent, any Error>

    /// Stops the microphone and finalizes the matching session: the stream
    /// yields the remaining final text, then finishes. Before `.listening`
    /// there is nothing to finalize, so this abandons the startup and the
    /// stream finishes without further text. A no-op for a stale session.
    func finish(_ sessionID: DictationSessionID) async
}

enum DictationEngines {
    /// The production engine, or nil where the OS has no `SpeechAnalyzer`
    /// (before iOS 26). The Composer hides its microphone when this is nil.
    /// Simulator screenshot runs get the scripted `DemoDictationEngine`.
    static var live: (any DictationEngine)? {
        #if DEBUG && targetEnvironment(simulator)
            if DemoScreenshotMode.isEnabled {
                return DemoDictationEngine.shared
            }
        #endif
        if #available(iOS 26, *) {
            return SpeechDictationEngine.shared
        }
        return nil
    }
}
