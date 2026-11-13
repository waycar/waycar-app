import AVFoundation

/// How fast the car speaks, for the Apple voice and the Natural voice alike
/// (Settings › CarPlay Voice › Speaking Speed): a multiplier on each voice's
/// normal pace.
enum CarVoiceSpeed {
    static let key = "carplay-voice-speed"
    static let steps: [Double] = [0.75, 0.9, 1.0, 1.1, 1.25, 1.5]
    static let standard = 1.0

    /// The stored speed, snapped to a step; unset or invalid is 1.0×.
    static func current(defaults: UserDefaults = .standard) -> Double {
        snapped(defaults.double(forKey: key))
    }

    static func snapped(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return standard }
        return steps.min { abs($0 - value) < abs($1 - value) } ?? standard
    }

    /// `AVSpeechUtterance.rate` for `multiplier`: the default rate scaled,
    /// kept within the synthesizer's range.
    static func utteranceRate(for multiplier: Double) -> Float {
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(multiplier)
        return min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    /// "1.25×", "0.9×", "1.0×".
    static func label(_ multiplier: Double) -> String {
        let text = multiplier.formatted(.number.precision(.fractionLength(1...2)).locale(Locale(identifier: "en_US")))
        return "\(text)×"
    }
}
