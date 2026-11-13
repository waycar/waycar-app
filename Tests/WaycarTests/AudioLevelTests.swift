import Testing

@testable import Waycar

/// The Composer waveform's level mapping: silence stays flat, normal speech
/// fills most of the height, loud speech saturates.
struct AudioLevelTests {
    @Test func silenceReadsAsZero() {
        #expect(AudioLevel.normalized(decibels: -80) == 0)
        #expect(AudioLevel.normalized(decibels: -50) == 0)
    }

    @Test func quietRoomNoiseStaysLow() {
        #expect(AudioLevel.normalized(decibels: -48) < 0.25)
    }

    @Test func typicalSpeechFillsMostOfTheBar() {
        let level = AudioLevel.normalized(decibels: -30)
        #expect(level > 0.5)
        #expect(level < 0.85)
    }

    @Test func loudSpeechSaturates() {
        #expect(AudioLevel.normalized(decibels: -10) == 1)
        #expect(AudioLevel.normalized(decibels: 0) == 1)
    }
}
