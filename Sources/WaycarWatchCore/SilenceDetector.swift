import Foundation

// MARK: - Silence detector

/// Decides when a watch voice recording ends, from metered input levels
/// (design §4 W4b). Pure: the recorder feeds it one `averagePower` sample
/// per meter tick with the time since recording started.
///
/// A sample is speech when its level is above the threshold. Before any
/// speech, the recording cancels at `noSpeechTimeout`. Once speech was
/// heard, the time since the last speech sample is silence: it fills the
/// ring (`silenceProgress`), speech empties it again, and a full ring stops
/// the recording. `maximumDuration` stops it regardless. After a stop,
/// every later sample repeats the same decision.
struct SilenceDetector: Sendable {
    /// The thresholds; the defaults are the shipped tuning.
    struct Configuration: Sendable, Equatable {
        /// `averagePower` (dBFS) above this counts as speech.
        var speechThresholdDB: Float = -40
        /// Silence after speech that stops and sends the recording.
        var silenceToStop: Duration = .milliseconds(3500)
        /// How long to wait for any speech before cancelling.
        var noSpeechTimeout: Duration = .seconds(8)
        /// The recording's hard cap.
        var maximumDuration: Duration = .seconds(60)
    }

    /// Why the recording should end.
    enum StopReason: Equatable, Sendable {
        /// Speech was followed by `silenceToStop` of silence: send it.
        case silence
        /// The recording reached `maximumDuration`: send it.
        case maximumDuration
        /// No speech within `noSpeechTimeout`: cancel, nothing is sent.
        case noSpeech
    }

    /// What the recorder should do after a sample.
    enum Decision: Equatable, Sendable {
        /// Keep recording. `silenceProgress` (0...1) drives the W4b ring;
        /// it is 0 while speaking and before any speech.
        case listening(silenceProgress: Double)
        /// End the recording.
        case stop(StopReason)
    }

    /// The thresholds in force.
    let configuration: Configuration
    /// Whether any sample so far counted as speech.
    private(set) var hasHeardSpeech = false
    /// The elapsed time of the most recent speech sample.
    private var lastSpeechAt: Duration = .zero
    /// The stop already decided, repeated for later samples.
    private var stopped: StopReason?

    /// A detector that has heard nothing yet.
    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Takes one level sample, `levelDB` in dBFS, taken `elapsed` after the
    /// recording started, and returns what to do next.
    mutating func feed(levelDB: Float, at elapsed: Duration) -> Decision {
        if let stopped { return .stop(stopped) }
        let decision = decide(levelDB: levelDB, at: elapsed)
        if case .stop(let reason) = decision { stopped = reason }
        return decision
    }

    /// The decision for one sample, updating the speech state.
    private mutating func decide(levelDB: Float, at elapsed: Duration) -> Decision {
        let isSpeech = levelDB > configuration.speechThresholdDB
        if isSpeech {
            hasHeardSpeech = true
            lastSpeechAt = elapsed
        }
        guard hasHeardSpeech else {
            if elapsed >= configuration.noSpeechTimeout { return .stop(.noSpeech) }
            if elapsed >= configuration.maximumDuration { return .stop(.maximumDuration) }
            return .listening(silenceProgress: 0)
        }
        if elapsed >= configuration.maximumDuration { return .stop(.maximumDuration) }
        if isSpeech { return .listening(silenceProgress: 0) }
        let silent = max(.zero, elapsed - lastSpeechAt)
        if silent >= configuration.silenceToStop { return .stop(.silence) }
        let progress = silent / configuration.silenceToStop
        return .listening(silenceProgress: min(1, max(0, progress)))
    }
}
