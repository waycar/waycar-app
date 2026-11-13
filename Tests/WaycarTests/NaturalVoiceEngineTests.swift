import Foundation
import Testing

@testable import Waycar

/// Which model and voice the car loads, from Settings' stored choices. The
/// engine is replaced whenever this selection changes.
@MainActor
@Suite("CarPlay Natural voice engine selection")
struct NaturalVoiceEngineTests {
    private static func defaults() throws -> (UserDefaults, String) {
        let suite = "NaturalVoiceEngineTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func nothingLoadsWhileTheNaturalVoiceIsOff() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(NaturalVoice.requested(defaults: defaults) == nil)
        defaults.set(NaturalVoiceModelID.pocket.rawValue, forKey: NaturalVoiceSettings.activeModelKey)
        #expect(NaturalVoice.requested(defaults: defaults) == nil)
    }

    @Test func kokoroWithItsDefaultVoiceUnlessAnotherModelIsPicked() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: NaturalVoiceSettings.enabledKey)

        #expect(
            NaturalVoice.requested(defaults: defaults)
                == NaturalVoiceSelection(
                    model: .kokoro, voice: NaturalVoiceCatalog.info(.kokoro).defaultVoice))
    }

    @Test func eachModelSpeaksWithItsOwnStoredVoice() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: NaturalVoiceSettings.enabledKey)
        let pocket = NaturalVoiceCatalog.info(.pocket)
        let voice = try #require(pocket.voices.last { $0.id != pocket.defaultVoice }).id
        defaults.set("bm_george", forKey: NaturalVoiceSettings.voiceKey(for: .kokoro))
        defaults.set(voice, forKey: NaturalVoiceSettings.voiceKey(for: .pocket))
        // Not one of Paradee's voices: it speaks only its default.
        defaults.set("bm_george", forKey: NaturalVoiceSettings.voiceKey(for: .paradee))

        let kokoro = NaturalVoice.requested(defaults: defaults)
        #expect(kokoro == NaturalVoiceSelection(model: .kokoro, voice: "bm_george"))

        defaults.set(NaturalVoiceModelID.pocket.rawValue, forKey: NaturalVoiceSettings.activeModelKey)
        let picked = NaturalVoice.requested(defaults: defaults)
        #expect(picked == NaturalVoiceSelection(model: .pocket, voice: voice))

        defaults.set(NaturalVoiceModelID.paradee.rawValue, forKey: NaturalVoiceSettings.activeModelKey)
        let switched = NaturalVoice.requested(defaults: defaults)
        #expect(switched == NaturalVoiceSelection(model: .paradee, voice: "af_heart"))
        #expect(switched != picked)
    }

    /// Kokoro keeps the voice key users already have, so their pick survives
    /// the catalog.
    @Test func kokoroReadsTheVoiceStoredBeforeTheCatalog() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: NaturalVoiceSettings.enabledKey)
        defaults.set("bf_emma", forKey: "carplay-natural-voice-name")

        #expect(
            NaturalVoice.requested(defaults: defaults)
                == NaturalVoiceSelection(model: .kokoro, voice: "bf_emma"))
    }
}
