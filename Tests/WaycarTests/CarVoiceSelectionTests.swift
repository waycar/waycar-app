import Testing

@testable import Waycar

@Suite("CarPlay voice selection")
struct CarVoiceSelectionTests {
    private static func voice(
        _ name: String, _ language: String, _ quality: SpeechVoiceCandidate.Quality,
        excluded: Bool = false
    ) -> SpeechVoiceCandidate {
        SpeechVoiceCandidate(
            id: "\(name).\(language).\(quality.rawValue)", name: name, language: language,
            quality: quality, isExcluded: excluded)
    }

    private let samantha = voice("Samantha", "en-US", .standard)
    private let ava = voice("Ava", "en-US", .premium)
    private let evan = voice("Evan", "en-US", .enhanced)
    private let daniel = voice("Daniel", "en-GB", .premium)
    private let thomas = voice("Thomas", "fr-FR", .premium)
    private let zarvox = voice("Zarvox", "en-US", .premium, excluded: true)

    @Test func premiumBeatsEnhancedBeatsCompact() {
        let ranked = CarVoiceSelection.ranked([samantha, evan, ava], languageCode: "en-US")
        #expect(ranked == [ava, evan, samantha])
    }

    @Test func theExactRegionWinsAtEqualQuality() {
        #expect(CarVoiceSelection.ranked([daniel, ava], languageCode: "en-US") == [ava, daniel])
        #expect(CarVoiceSelection.ranked([ava, daniel], languageCode: "en_GB") == [daniel, ava])
    }

    @Test func qualityOutranksTheRegion() {
        // A Premium British voice over the compact American one.
        #expect(
            CarVoiceSelection.ranked([samantha, daniel], languageCode: "en-US").first == daniel)
    }

    @Test func otherLanguagesAndNoveltyVoicesAreNeverPicked() {
        let ranked = CarVoiceSelection.ranked(
            [zarvox, thomas, samantha], languageCode: "en-US")
        #expect(ranked == [samantha])
        #expect(CarVoiceSelection.ranked([zarvox, thomas], languageCode: "en-US").isEmpty)
    }

    @Test func iOSsDefaultBreaksATie() {
        let allison = Self.voice("Allison", "en-US", .standard)
        #expect(
            CarVoiceSelection.ranked(
                [allison, samantha], languageCode: "en-US", systemDefault: samantha.id)
                == [samantha, allison])
        #expect(
            CarVoiceSelection.ranked([samantha, allison], languageCode: "en-US")
                == [allison, samantha])
    }

    @Test func aStoredPickHoldsOnlyWhileOffered() {
        let ranked = CarVoiceSelection.ranked([samantha, ava], languageCode: "en-US")
        #expect(CarVoiceSelection.choice(stored: samantha.id, among: ranked) == samantha)
        #expect(CarVoiceSelection.choice(stored: zarvox.id, among: ranked) == ava)
        #expect(CarVoiceSelection.choice(stored: "", among: ranked) == ava)
        #expect(CarVoiceSelection.choice(stored: nil, among: []) == nil)
    }

    @Test func theCarSpeaksEnglish() {
        #expect(CarVoiceSelection.speechLanguage(current: "en_GB") == "en-GB")
        #expect(CarVoiceSelection.speechLanguage(current: "fr-FR") == "en-US")
    }
}
