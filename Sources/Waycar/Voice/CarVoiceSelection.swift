import AVFoundation

/// A speech synthesis voice as the car's voice choice sees it.
struct SpeechVoiceCandidate: Equatable, Sendable, Identifiable {
    enum Quality: Int, Comparable, Sendable {
        /// iOS's compact voices: what made the car sound like a 1990s Mac.
        case standard = 1
        case enhanced
        case premium

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// `AVSpeechSynthesisVoice.identifier`.
    let id: String
    let name: String
    /// BCP 47, e.g. `en-US`.
    let language: String
    let quality: Quality
    /// A novelty voice (Bells, Zarvox, …) or the user's Personal Voice:
    /// never picked, never offered.
    let isExcluded: Bool
}

/// Which installed voice speaks a car voice turn (docs/design/carplay.md §5
/// TTS). Siri's voices are not available to apps; the best a third-party app
/// gets is the Enhanced and Premium voices the user downloaded in iOS
/// Settings › Accessibility › Read & Speak › Voices. Pure; `CarVoice`
/// feeds it the device's voices.
enum CarVoiceSelection {
    /// The voice the user picked in Settings › CarPlay Voice; absent means
    /// the best installed one.
    static let voiceKey = "carplay-voice"

    /// The Settings row's value: just the voice's own name, with iOS's
    /// quality suffix dropped ("Ava (Premium)" → "Ava").
    static func rowText(voice: String) -> String {
        guard voice.hasSuffix(")"), let open = voice.range(of: " (", options: .backwards) else {
            return voice
        }
        return String(voice[..<open.lowerBound])
    }

    /// Voices that can speak `languageCode`, best first: same language
    /// only, novelty and Personal voices dropped; then Premium over
    /// Enhanced over the compact default, then the exact region (`en-US`
    /// over `en-GB` for `en-US`), then iOS's own default for the language,
    /// then by name so the order is stable.
    static func ranked(
        _ voices: [SpeechVoiceCandidate], languageCode: String, systemDefault: String? = nil
    ) -> [SpeechVoiceCandidate] {
        let wanted = normalized(languageCode)
        let wantedLanguage = baseLanguage(wanted)
        return voices
            .filter { !$0.isExcluded && baseLanguage(normalized($0.language)) == wantedLanguage }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                let lhsExact = normalized(lhs.language) == wanted
                let rhsExact = normalized(rhs.language) == wanted
                if lhsExact != rhsExact { return lhsExact }
                let lhsDefault = lhs.id == systemDefault
                let rhsDefault = rhs.id == systemDefault
                if lhsDefault != rhsDefault { return lhsDefault }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id < rhs.id
            }
    }

    /// The voice to speak with: the stored pick while it is still installed
    /// and offered, otherwise the best ranked one.
    static func choice(stored: String?, among ranked: [SpeechVoiceCandidate])
        -> SpeechVoiceCandidate?
    {
        if let stored, let picked = ranked.first(where: { $0.id == stored }) { return picked }
        return ranked.first
    }

    /// The language the car speaks: every fixed line is English (the app
    /// ships English only), so an English user's own variant (`en-GB`,
    /// `en-AU`) and `en-US` for everyone else.
    static func speechLanguage(current languageCode: String) -> String {
        let code = languageCode.replacingOccurrences(of: "_", with: "-")
        return baseLanguage(normalized(code)) == "en" ? code : "en-US"
    }

    private static func normalized(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func baseLanguage(_ code: String) -> String {
        String(code.prefix { $0 != "-" })
    }
}

/// The device's voices through `CarVoiceSelection`.
@MainActor
enum CarVoice {
    /// The installed voices the car may speak with, best first.
    static func installed() -> [SpeechVoiceCandidate] {
        let language = CarVoiceSelection.speechLanguage(
            current: AVSpeechSynthesisVoice.currentLanguageCode())
        return CarVoiceSelection.ranked(
            AVSpeechSynthesisVoice.speechVoices().map(SpeechVoiceCandidate.init),
            languageCode: language,
            systemDefault: AVSpeechSynthesisVoice(language: language)?.identifier)
    }

    /// The voice a car line speaks with, as `choice` picks it.
    static func current(defaults: UserDefaults = .standard) -> SpeechVoiceCandidate? {
        CarVoiceSelection.choice(
            stored: defaults.string(forKey: CarVoiceSelection.voiceKey), among: installed())
    }

    static func synthesisVoice(defaults: UserDefaults = .standard) -> AVSpeechSynthesisVoice? {
        guard let choice = current(defaults: defaults) else {
            return AVSpeechSynthesisVoice(language: "en-US")
        }
        return AVSpeechSynthesisVoice(identifier: choice.id)
    }
}

extension SpeechVoiceCandidate {
    init(_ voice: AVSpeechSynthesisVoice) {
        let quality: Quality =
            switch voice.quality {
            case .premium: .premium
            case .enhanced: .enhanced
            default: .standard
            }
        self.init(
            id: voice.identifier, name: voice.name, language: voice.language, quality: quality,
            isExcluded: voice.voiceTraits.contains(.isNoveltyVoice)
                || voice.voiceTraits.contains(.isPersonalVoice))
    }
}
