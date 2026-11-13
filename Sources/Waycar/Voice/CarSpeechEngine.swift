import AVFoundation
import NaturalLanguage

/// What speaks one car line (docs/design/carplay.md §5 TTS). `CarSpeaker`
/// owns the audio session and picks the engine per line; an engine only
/// plays.
@MainActor
protocol CarSpeechEngine: AnyObject {
    /// Speaks `text` on the already-active audio session. Returns true only if the whole line played.
    /// A paused line keeps its `speak` waiting until it is resumed or stopped.
    func speak(_ text: String) async -> Bool
    /// Stops any speech now; a pending speak returns false.
    func stop()
    /// Holds the line playing where it is (a notification or call took the
    /// audio); true when it can be resumed, false when there is nothing to
    /// hold and the caller should stop it instead.
    func pause() -> Bool
    /// Plays a paused line on from where it stopped; false when it can't.
    func resume() -> Bool
    /// How far the line `speak` was last called with got, as a UTF-16
    /// offset into its text (0 when it never started): a cut line is
    /// spoken again from the sentence holding it.
    var spokenOffset: Int { get }
    /// Audible progress (words reached, frames rendered, buffers played;
    /// never audio merely queued): a resumed line whose value stays put
    /// is stuck.
    var playbackProgress: Int { get }
    /// Called when the line paused without `pause()` (iOS held the
    /// synthesizer and posted no interruption).
    var onExternalPause: (@MainActor () -> Void)? { get set }
}

/// Sentence handling shared by the engines and the speaker.
enum CarLine {
    /// Each sentence's range, trimmed of surrounding whitespace.
    static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var lower = range.lowerBound
            var upper = range.upperBound
            while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
            while upper > lower, text[text.index(before: upper)].isWhitespace {
                upper = text.index(before: upper)
            }
            if lower < upper { ranges.append(lower..<upper) }
            return true
        }
        return ranges
    }

    /// What is left of `text` once speech reached `offset` (UTF-16): from
    /// the start of the sentence holding it, so the driver hears that
    /// sentence whole.
    static func unfinished(_ text: String, from offset: Int) -> String {
        guard offset > 0 else { return text }
        let ranges = sentenceRanges(in: text)
        let reached = ranges.last { $0.lowerBound.utf16Offset(in: text) <= offset }
        guard let start = reached?.lowerBound ?? ranges.first?.lowerBound else { return text }
        return String(text[start...])
    }
}

/// iOS's own synthesizer, with the best installed voice
/// (`CarVoice.synthesisVoice()`): the voice every car line can fall back to.
@MainActor
final class SystemSpeechEngine: NSObject, CarSpeechEngine, AVSpeechSynthesizerDelegate {
    var onExternalPause: (@MainActor () -> Void)?
    private(set) var spokenOffset = 0
    var playbackProgress: Int { spokenOffset }
    /// The synthesizer of the line being spoken. Each line gets its own:
    /// `stopSpeaking` is asynchronous, so a stop followed at once by a
    /// new line on the same synthesizer cancels the new line too (seen
    /// on iOS 26.5: Allow's answer went silent).
    private var synthesizer: AVSpeechSynthesizer?
    /// Each waiting line's continuation; resumed `true` when the
    /// synthesizer finished it, `false` when it was cut off.
    private var pending: [ObjectIdentifier: CheckedContinuation<Bool, Never>] = [:]
    /// `pause()` held the line; its `didPause` is ours, not iOS's.
    private var isPausedHere = false

    func speak(_ text: String) async -> Bool {
        stop()
        // A line that never starts reports no progress, not the last one's.
        spokenOffset = 0
        guard !Task.isCancelled, !text.isEmpty else { return false }
        let utterance = AVSpeechUtterance(string: text)
        // `AVSpeechSynthesisVoice(language:)` is the compact voice, the
        // robotic one; the car speaks with the best installed voice instead.
        utterance.voice = CarVoice.synthesisVoice()
        utterance.rate = CarVoiceSpeed.utteranceRate(for: CarVoiceSpeed.current())
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.synthesizer = synthesizer
        let finished = await withCheckedContinuation { continuation in
            pending[ObjectIdentifier(utterance)] = continuation
            synthesizer.speak(utterance)
        }
        return finished && !Task.isCancelled
    }

    /// Stops speaking at once; every waiting `speak` returns now, not
    /// when the synthesizer gets round to reporting the cancel.
    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        isPausedHere = false
        let waiting = pending.values
        pending.removeAll()
        waiting.forEach { $0.resume(returning: false) }
    }

    func pause() -> Bool {
        guard let synthesizer, !pending.isEmpty else { return false }
        isPausedHere = true
        if synthesizer.isPaused { return true }
        // `.word` leaves the line resumable mid-sentence; `.immediate`
        // would cut a word in half.
        guard synthesizer.pauseSpeaking(at: .word) || synthesizer.isPaused else {
            isPausedHere = false
            return false
        }
        return true
    }

    func resume() -> Bool {
        guard let synthesizer, !pending.isEmpty else { return false }
        isPausedHere = false
        guard synthesizer.isPaused else { return synthesizer.isSpeaking }
        return synthesizer.continueSpeaking()
    }

    /// A line ended. Callbacks from a synthesizer `stop()` already let
    /// go are late; their `speak` has returned.
    private func finish(_ id: ObjectIdentifier, from source: ObjectIdentifier, spoken: Bool) {
        guard let synthesizer, ObjectIdentifier(synthesizer) == source else { return }
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: spoken)
    }

    private func reached(_ offset: Int, from source: ObjectIdentifier) {
        guard let synthesizer, ObjectIdentifier(synthesizer) == source else { return }
        spokenOffset = offset
    }

    /// iOS paused the line itself (no interruption reached the speaker).
    private func paused(from source: ObjectIdentifier) {
        guard let synthesizer, ObjectIdentifier(synthesizer) == source, !isPausedHere,
            !pending.isEmpty
        else { return }
        onExternalPause?()
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        let source = ObjectIdentifier(synthesizer)
        Task { @MainActor in self.finish(id, from: source, spoken: true) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        let source = ObjectIdentifier(synthesizer)
        Task { @MainActor in self.finish(id, from: source, spoken: false) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance
    ) {
        let source = ObjectIdentifier(synthesizer)
        Task { @MainActor in self.paused(from: source) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let source = ObjectIdentifier(synthesizer)
        let offset = characterRange.location
        Task { @MainActor in self.reached(offset, from: source) }
    }
}
