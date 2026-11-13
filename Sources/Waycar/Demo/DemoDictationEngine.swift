#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import Synchronization

    /// The scripted `DictationEngine` `DictationEngines.live` returns under
    /// `--demo-screenshots`. The Simulator has no on-device speech model
    /// (`SpeechDictationEngine` reports `localeUnsupported` there), so the
    /// `dictation` screenshot and the waycar.dev hero animation
    /// (`scripts/record-dictation-hero.sh`) need a scripted voice: a
    /// speech-like level that repeats every `period` seconds, and one heard
    /// sentence. No microphone is opened. The entire type is excluded from
    /// device and Release builds.
    final class DemoDictationEngine: DictationEngine {
        static let shared = DemoDictationEngine()

        /// The voice level's period, in seconds. A whole number of the
        /// waveform's 0.06 s samples (50) and of 30 fps video frames (90), so
        /// a recording of exactly one period loops without a seam.
        static let period: Double = 3.0

        /// What the demo voice says, revealed word by word as a volatile
        /// transcript and settled as final by `finish(_:)`.
        static let sentence = "Yes, run the UI test, then commit on green."

        private typealias Continuation = AsyncThrowingStream<DictationEvent, any Error>.Continuation

        /// Each live session's stream. Its producer yields only while its
        /// entry is here, under this lock, so once `finish(_:)` removes it
        /// nothing can follow the final transcript.
        private let sessions = Mutex<[DictationSessionID: Continuation]>([:])

        func events(
            for sessionID: DictationSessionID, locale: Locale, audioProfile: DictationAudioProfile
        ) -> AsyncThrowingStream<DictationEvent, any Error>
        {
            let (stream, continuation) = AsyncThrowingStream.makeStream(
                of: DictationEvent.self, throwing: (any Error).self)
            sessions.withLock { $0[sessionID] = continuation }
            let producer = Task { await self.speak(sessionID) }
            continuation.onTermination = { _ in
                producer.cancel()
                self.sessions.withLock { _ = $0.removeValue(forKey: sessionID) }
            }
            return stream
        }

        func finish(_ sessionID: DictationSessionID) async {
            guard let continuation = sessions.withLock({ $0.removeValue(forKey: sessionID) })
            else { return }
            continuation.yield(.transcript(Self.sentence, isFinal: true))
            continuation.finish()
        }

        /// Listens, then yields the level about 60 times a second, on a fixed
        /// schedule from the session's start so the level keeps real time.
        private func speak(_ sessionID: DictationSessionID) async {
            let clock = ContinuousClock()
            let start = clock.now
            let frame = Duration.seconds(1) / 60
            var wordsHeard = 0
            var tick = 0
            guard emit([.listening], to: sessionID) else { return }
            while true {
                let elapsed = start.duration(to: clock.now) / .seconds(1)
                var events: [DictationEvent] = [.level(Self.level(at: elapsed))]
                let words = Self.wordsHeard(at: elapsed)
                if words > wordsHeard {
                    wordsHeard = words
                    events.append(.transcript(Self.transcript(words: words), isFinal: false))
                }
                guard emit(events, to: sessionID) else { return }
                tick += 1
                do {
                    try await Task.sleep(until: start + frame * tick, clock: clock)
                } catch {
                    return
                }
            }
        }

        /// Yields `events` while the session is live; false once it ended,
        /// which stops its producer. `yield` never runs the termination
        /// handler (only `finish()` and the consumer's cancellation do, both
        /// outside this lock), so holding the lock here cannot deadlock.
        private func emit(_ events: [DictationEvent], to sessionID: DictationSessionID) -> Bool {
            sessions.withLock { sessions in
                guard let continuation = sessions[sessionID] else { return false }
                for event in events {
                    continuation.yield(event)
                }
                return true
            }
        }

        // MARK: Script

        /// One syllable: when it starts within the period, how long it
        /// lasts, and how loud it peaks.
        private struct Syllable: Sendable {
            let start: Double
            let duration: Double
            let peak: Double

            var end: Double { start + duration }
        }

        /// One period of speech, about 5 syllables a second: three words of
        /// four syllables, a short gap after each of the first two, and a
        /// 0.4 s pause after the third.
        private static let script: [[Syllable]] = [
            [
                Syllable(start: 0.00, duration: 0.20, peak: 0.50),
                Syllable(start: 0.17, duration: 0.22, peak: 0.88),
                Syllable(start: 0.37, duration: 0.18, peak: 0.38),
                Syllable(start: 0.53, duration: 0.27, peak: 0.72),
            ],
            [
                Syllable(start: 0.95, duration: 0.16, peak: 0.30),
                Syllable(start: 1.09, duration: 0.24, peak: 0.84),
                Syllable(start: 1.31, duration: 0.18, peak: 0.56),
                Syllable(start: 1.47, duration: 0.28, peak: 0.76),
            ],
            [
                Syllable(start: 1.90, duration: 0.20, peak: 0.66),
                Syllable(start: 2.08, duration: 0.16, peak: 0.24),
                Syllable(start: 2.22, duration: 0.24, peak: 0.80),
                Syllable(start: 2.44, duration: 0.16, peak: 0.42),
            ],
        ]

        /// The scripted voice level `elapsed` seconds into a session, in
        /// `0...1`, periodic in exactly `period`. Each syllable rises quickly
        /// and falls off more slowly; a low hum joins the syllables of a word
        /// so only the gaps between words fall to the silent floor; a tremor
        /// with a whole number of cycles per period keeps equal peaks from
        /// looking stamped. Deterministic: the same moment, the same level.
        static func level(at elapsed: Double) -> Float {
            let remainder = elapsed.truncatingRemainder(dividingBy: period)
            let phase = remainder < 0 ? remainder + period : remainder
            let silence = 0.02
            var voice = 0.0
            for word in script {
                guard let first = word.first, let last = word.last else { continue }
                voice = max(voice, 0.1 * hum(phase, from: first.start, to: last.end))
                for syllable in word {
                    let progress = (phase - syllable.start) / syllable.duration
                    guard progress > 0, progress < 1 else { continue }
                    voice = max(voice, syllable.peak * envelope(progress))
                }
            }
            let tremor = 1 + 0.06 * sin(2 * Double.pi * 19 * phase / period)
            return Float(min(max(silence + voice * tremor, 0), 1))
        }

        /// A syllable's shape over its `progress` (`0...1`): zero at both
        /// ends, peaking 30% in.
        private static func envelope(_ progress: Double) -> Double {
            let attack = 0.3
            let rise = progress < attack
                ? progress / attack
                : 1 - (progress - attack) / (1 - attack)
            let wave = sin(rise * Double.pi / 2)
            return wave * wave
        }

        /// 1 inside a word, easing to 0 over 50 ms at its edges.
        private static func hum(_ phase: Double, from start: Double, to end: Double) -> Double {
            let ramp = 0.05
            let edge = min(max(min(phase - start, end - phase) / ramp, 0), 1)
            return edge * edge * (3 - 2 * edge)
        }

        private static let sentenceWords = sentence.split(separator: " ")

        /// One more word of `sentence` every 0.3 s until all are heard.
        private static func wordsHeard(at elapsed: Double) -> Int {
            min(sentenceWords.count, Int((elapsed + 0.1) / 0.3))
        }

        private static func transcript(words: Int) -> String {
            sentenceWords.prefix(words).joined(separator: " ")
        }
    }
#endif
