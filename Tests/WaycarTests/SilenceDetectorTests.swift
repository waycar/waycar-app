import Foundation
import Testing

@testable import Waycar

/// When a watch recording ends: 3.5 s of silence after speech sends it,
/// no speech in the first 8 s cancels it, and 60 s caps it.
@Suite("Silence detector")
struct SilenceDetectorTests {
    /// A level well above the default -40 dB speech threshold.
    private static let speech: Float = -20
    /// A level well below the default threshold.
    private static let quiet: Float = -60

    /// A sample time in milliseconds.
    private static func ms(_ value: Int) -> Duration { .milliseconds(value) }

    /// A detector that heard speech at 1 s.
    private static func spokeAtOneSecond() -> SilenceDetector {
        var detector = SilenceDetector()
        #expect(detector.feed(levelDB: speech, at: ms(1000)) == .listening(silenceProgress: 0))
        return detector
    }

    /// Whether `decision` keeps listening with `expected` ring progress, to
    /// within floating-point rounding.
    private static func listens(_ decision: SilenceDetector.Decision, at expected: Double) -> Bool {
        guard case .listening(let progress) = decision else { return false }
        return abs(progress - expected) < 1e-9
    }

    // MARK: Speech threshold

    @Test func speechIsStrictlyAboveThreshold() {
        var detector = SilenceDetector()
        _ = detector.feed(levelDB: -40, at: Self.ms(100))
        #expect(!detector.hasHeardSpeech)
        _ = detector.feed(levelDB: -39.9, at: Self.ms(200))
        #expect(detector.hasHeardSpeech)
    }

    @Test func honorsConfiguredThreshold() {
        var detector = SilenceDetector(configuration: .init(speechThresholdDB: -10))
        _ = detector.feed(levelDB: Self.speech, at: Self.ms(100))
        #expect(!detector.hasHeardSpeech)
    }

    // MARK: Silence after speech

    @Test func stopsAtExactlyThreeAndAHalfSecondsOfSilence() {
        var detector = Self.spokeAtOneSecond()
        #expect(Self.listens(detector.feed(levelDB: Self.quiet, at: Self.ms(4490)), at: 3490.0 / 3500.0))
        #expect(detector.feed(levelDB: Self.quiet, at: Self.ms(4500)) == .stop(.silence))
    }

    @Test func silenceProgressFillsLinearly() {
        var detector = Self.spokeAtOneSecond()
        #expect(detector.feed(levelDB: Self.quiet, at: Self.ms(1000)) == .listening(silenceProgress: 0))
        #expect(Self.listens(detector.feed(levelDB: Self.quiet, at: Self.ms(1875)), at: 0.25))
        #expect(Self.listens(detector.feed(levelDB: Self.quiet, at: Self.ms(2750)), at: 0.5))
        #expect(Self.listens(detector.feed(levelDB: Self.quiet, at: Self.ms(3625)), at: 0.75))
    }

    @Test func speechResetsSilenceProgress() {
        var detector = Self.spokeAtOneSecond()
        #expect(Self.listens(detector.feed(levelDB: Self.quiet, at: Self.ms(4000)), at: 3000.0 / 3500.0))
        #expect(detector.feed(levelDB: Self.speech, at: Self.ms(4400)) == .listening(silenceProgress: 0))
        // 3.49 s after the old speech would have stopped; the new speech restarted the clock.
        #expect(Self.listens(detector.feed(levelDB: Self.quiet, at: Self.ms(4500)), at: 100.0 / 3500.0))
        #expect(Self.listens(detector.feed(levelDB: Self.quiet, at: Self.ms(7890)), at: 3490.0 / 3500.0))
        #expect(detector.feed(levelDB: Self.quiet, at: Self.ms(7900)) == .stop(.silence))
    }

    @Test func honorsConfiguredSilence() {
        var detector = SilenceDetector(configuration: .init(silenceToStop: .seconds(1)))
        _ = detector.feed(levelDB: Self.speech, at: Self.ms(500))
        #expect(Self.listens(detector.feed(levelDB: Self.quiet, at: Self.ms(1000)), at: 0.5))
        #expect(detector.feed(levelDB: Self.quiet, at: Self.ms(1500)) == .stop(.silence))
    }

    // MARK: No speech

    @Test func cancelsAtEightSecondsWithoutSpeech() {
        var detector = SilenceDetector()
        #expect(detector.feed(levelDB: Self.quiet, at: Self.ms(100)) == .listening(silenceProgress: 0))
        #expect(detector.feed(levelDB: Self.quiet, at: Self.ms(7999)) == .listening(silenceProgress: 0))
        #expect(detector.feed(levelDB: Self.quiet, at: Self.ms(8000)) == .stop(.noSpeech))
        #expect(!detector.hasHeardSpeech)
    }

    @Test func noSpeechTimeoutNeverAppliesOnceSpeechWasHeard() {
        var detector = SilenceDetector()
        _ = detector.feed(levelDB: Self.speech, at: Self.ms(7000))
        #expect(Self.listens(detector.feed(levelDB: Self.quiet, at: Self.ms(8000)), at: 1000.0 / 3500.0))
        #expect(Self.listens(detector.feed(levelDB: Self.quiet, at: Self.ms(9000)), at: 2000.0 / 3500.0))
    }

    @Test func speechAtEightSecondsKeepsListening() {
        var detector = SilenceDetector()
        _ = detector.feed(levelDB: Self.quiet, at: Self.ms(7900))
        #expect(detector.feed(levelDB: Self.speech, at: Self.ms(8000)) == .listening(silenceProgress: 0))
    }

    // MARK: Maximum duration

    @Test func capsAtSixtySecondsEvenWhileSpeaking() {
        var detector = SilenceDetector()
        var elapsed = 0
        while elapsed < 60_000 {
            #expect(detector.feed(levelDB: Self.speech, at: Self.ms(elapsed)) == .listening(silenceProgress: 0))
            elapsed += 100
        }
        #expect(detector.feed(levelDB: Self.speech, at: Self.ms(60_000)) == .stop(.maximumDuration))
    }

    @Test func capsAtSixtySecondsMidSilence() {
        var detector = SilenceDetector()
        _ = detector.feed(levelDB: Self.speech, at: Self.ms(58_000))
        #expect(Self.listens(detector.feed(levelDB: Self.quiet, at: Self.ms(59_999)), at: 1999.0 / 3500.0))
        #expect(detector.feed(levelDB: Self.quiet, at: Self.ms(60_000)) == .stop(.maximumDuration))
    }

    // MARK: After a stop

    @Test func repeatsStopDecisionAfterStopping() {
        var detector = Self.spokeAtOneSecond()
        #expect(detector.feed(levelDB: Self.quiet, at: Self.ms(4500)) == .stop(.silence))
        #expect(detector.feed(levelDB: Self.speech, at: Self.ms(4600)) == .stop(.silence))
    }
}
