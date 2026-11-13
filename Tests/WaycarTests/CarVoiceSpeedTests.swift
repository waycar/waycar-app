import AVFoundation
import Foundation
import Testing

@testable import Waycar

@Suite("CarPlay speaking speed")
struct CarVoiceSpeedTests {
    @Test func unsetOrInvalidIsNormalSpeed() throws {
        let defaults = try #require(UserDefaults(suiteName: "CarVoiceSpeedTests.\(UUID())"))
        #expect(CarVoiceSpeed.current(defaults: defaults) == 1.0)
        defaults.set(-2.0, forKey: CarVoiceSpeed.key)
        #expect(CarVoiceSpeed.current(defaults: defaults) == 1.0)
        defaults.set(1.25, forKey: CarVoiceSpeed.key)
        #expect(CarVoiceSpeed.current(defaults: defaults) == 1.25)
        // A value between steps snaps to the nearest one.
        defaults.set(1.4, forKey: CarVoiceSpeed.key)
        #expect(CarVoiceSpeed.current(defaults: defaults) == 1.5)
    }

    @Test func utteranceRateScalesTheDefaultWithinRange() {
        #expect(CarVoiceSpeed.utteranceRate(for: 1.0) == AVSpeechUtteranceDefaultSpeechRate)
        #expect(
            CarVoiceSpeed.utteranceRate(for: 1.25) == AVSpeechUtteranceDefaultSpeechRate * 1.25)
        #expect(CarVoiceSpeed.utteranceRate(for: 10) == AVSpeechUtteranceMaximumSpeechRate)
        #expect(CarVoiceSpeed.utteranceRate(for: 0) == AVSpeechUtteranceMinimumSpeechRate)
        for step in CarVoiceSpeed.steps {
            let rate = CarVoiceSpeed.utteranceRate(for: step)
            #expect(rate >= AVSpeechUtteranceMinimumSpeechRate && rate <= AVSpeechUtteranceMaximumSpeechRate)
        }
    }

    @Test func rowShowsOnlyTheVoiceName() {
        #expect(CarVoiceSelection.rowText(voice: "Heart") == "Heart")
        #expect(CarVoiceSelection.rowText(voice: "Ava (Premium)") == "Ava")
        #expect(CarVoiceSelection.rowText(voice: "Evan (Enhanced)") == "Evan")
        #expect(CarVoiceSpeed.label(1.0) == "1.0×")
        #expect(CarVoiceSpeed.label(0.75) == "0.75×")
    }

    @Test func playSampleIsBlockedWhileACarTurnIsOn() {
        #expect(!CarVoiceSample.isBlocked(by: CarVoiceActivity.State()))
        var turn = CarVoiceActivity.State()
        turn.agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:pA")
        var speaking = CarVoiceActivity.State()
        speaking.speaking = 1
        var listening = CarVoiceActivity.State()
        listening.listening = 1
        for state in [turn, speaking, listening] {
            #expect(CarVoiceSample.isBlocked(by: state))
        }
    }
}
