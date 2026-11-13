import Foundation

/// The on-device voice models Settings › CarPlay Voice › Natural Voice
/// offers (docs/design/carplay.md §5 TTS). English only, all run through
/// FluidAudio, none under the GPL. Left out: Supertonic-3 (its OpenRAIL-M
/// use restrictions would have to flow into Waycar's EULA, and upstream is
/// archived), Chatterbox Nano and NeuTTS (GPU only, so silent when the app is
/// in the background, and large), Piper and KittenTTS (GPL espeak), and
/// large LLM voices (too slow on an iPhone 15).
enum NaturalVoiceModelID: String, CaseIterable, Codable, Sendable {
    case kokoro, pocket, paradee
}

/// One of a model's speakers.
struct NaturalVoiceOption: Identifiable, Hashable, Sendable {
    /// The model's voice name, e.g. Kokoro's `af_heart` or Pocket's `alba`.
    let id: String
    let name: String
    /// Empty when upstream doesn't describe the speaker.
    let accent: String
}

struct NaturalVoiceModelInfo: Identifiable, Sendable {
    let id: NaturalVoiceModelID
    let title: String
    /// 1 is the best pick; Settings lists the models in this order.
    let rank: Int
    /// Completes "Choose it if…".
    let chooseIf: String
    let summary: String
    let license: String
    /// The model's own files. Kokoro and Paradee also need the shared English
    /// text front end (`NaturalVoiceModel.sharedTextBytes`) when it isn't on
    /// disk yet.
    let downloadBytes: Int64
    /// Every offered voice comes with the download, so switching voices never
    /// needs the network in the car.
    let voices: [NaturalVoiceOption]
    let defaultVoice: String
}

enum NaturalVoiceCatalog {
    /// Best first.
    static let models: [NaturalVoiceModelInfo] = [kokoro, pocket, paradee]

    static func info(_ id: NaturalVoiceModelID) -> NaturalVoiceModelInfo {
        switch id {
        case .kokoro: kokoro
        case .pocket: pocket
        case .paradee: paradee
        }
    }

    private static let kokoro = NaturalVoiceModelInfo(
        id: .kokoro,
        title: "Kokoro",
        rank: 1,
        chooseIf: "you want the most natural voice.",
        summary:
            "Kokoro-82M on the Neural Engine, the top-rated open voice model under one billion "
            + "parameters on public leaderboards.",
        license: "Apache-2.0",
        // FluidAudio's pinned ANE-v3 English packages and the offered voices,
        // measured 2026-10-12 (230 MB with the shared text front end).
        downloadBytes: 218_000_000,
        voices: [
            NaturalVoiceOption(id: "af_heart", name: "Heart", accent: "American"),
            NaturalVoiceOption(id: "af_bella", name: "Bella", accent: "American"),
            NaturalVoiceOption(id: "af_nicole", name: "Nicole", accent: "American"),
            NaturalVoiceOption(id: "am_michael", name: "Michael", accent: "American"),
            NaturalVoiceOption(id: "am_fenrir", name: "Fenrir", accent: "American"),
            NaturalVoiceOption(id: "bf_emma", name: "Emma", accent: "British"),
            NaturalVoiceOption(id: "bm_george", name: "George", accent: "British"),
        ],
        defaultVoice: "af_heart")

    /// Kyutai's English presets, except `cosette` and `jean`, whose
    /// recordings are licensed for non-commercial use only. The five
    /// presets recorded in other languages are left out too.
    private static let pocket = NaturalVoiceModelInfo(
        id: .pocket,
        title: "Pocket TTS (Kyutai)",
        rank: 2,
        chooseIf: "you want it to start speaking fastest, keep long replies smooth, and have the most voices.",
        summary:
            "Kyutai's streaming voice model on the Neural Engine. It speaks while it is still "
            + "generating the rest of the reply.",
        license: "Weights CC-BY-4.0 (Kyutai), code MIT",
        // The pinned v2.1 English pack for the Neural Engine, catalog voices
        // only (non-commercial and other-language presets skipped), measured 2026-10-12.
        downloadBytes: 530_000_000,
        voices: [
            "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles", "eponine", "eve",
            "fantine", "george", "jane", "javert", "marius", "mary", "michael", "paul",
            "peter_yearsley", "stuart_bell", "vera",
        ].map { NaturalVoiceOption(id: $0, name: displayName($0), accent: "") },
        defaultVoice: "alba")

    private static let paradee = NaturalVoiceModelInfo(
        id: .paradee,
        title: "Paradee Lite",
        rank: 3,
        chooseIf:
            "you want a tiny download and the least battery use. It runs on the CPU, so it's "
            + "the safest choice while the phone is locked.",
        summary: "Kokoro distilled into an 8M-parameter model with Kokoro's Heart voice.",
        license: "Apache-2.0",
        // The pinned int8 variant, measured 2026-10-12.
        downloadBytes: 13_000_000,
        voices: [NaturalVoiceOption(id: "af_heart", name: "Heart", accent: "American")],
        defaultVoice: "af_heart")

    /// `peter_yearsley` → "Peter Yearsley".
    private static func displayName(_ voice: String) -> String {
        voice.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }
}
