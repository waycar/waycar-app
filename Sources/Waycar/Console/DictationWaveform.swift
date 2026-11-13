import SwiftUI

/// The Composer's listening indicator: a dotted line that scrolls from right
/// to left, each dot stretching into a taller capsule the louder the voice
/// was at that moment. Silence reads as a flat row of dots. Sampling is
/// time-driven, so the line keeps moving evenly however bursty the
/// microphone's level updates are.
struct DictationWaveform: View {
    /// Read here rather than by the caller so each microphone level update
    /// invalidates only this view, not the Composer around it.
    let dictation: DictationStore
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history = DictationWaveformHistory()

    var body: some View {
        let level = dictation.level
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { context, size in
                let fraction = history.advance(to: timeline.date, level: level)
                draw(in: &context, size: size, scrollFraction: reduceMotion ? 0 : fraction)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, scrollFraction: Double) {
        let dot = DictationWaveformHistory.dotDiameter
        let step = dot + DictationWaveformHistory.dotSpacing
        let fadeWidth: CGFloat = 24
        let visible = Int(size.width / step) + 2
        for index in 0..<visible {
            let x = size.width - dot - (CGFloat(index) + scrollFraction) * step
            guard x > -dot else { break }
            let sample = history.sample(age: index)
            let height = dot + sample * max(size.height - dot, 0)
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: dot, height: height)
            let opacity = min(max(x / fadeWidth, 0), 1)
            context.fill(
                Path(roundedRect: rect, cornerRadius: dot / 2),
                with: .color(tint.opacity(opacity)))
        }
    }
}

/// Fixed-cadence level history behind `DictationWaveform`. A plain reference
/// type advanced from the renderer: its changes follow the timeline and must
/// not invalidate the view.
final class DictationWaveformHistory {
    static let dotDiameter: CGFloat = 3.5
    static let dotSpacing: CGFloat = 3
    private static let interval: TimeInterval = 0.06
    private static let capacity = 160

    private var samples: [CGFloat] = []
    private var lastSampleDate: Date?
    private var smoothed: CGFloat = 0

    /// Appends one sample per elapsed interval and returns how far (`0..<1`)
    /// the newest sample has travelled toward the next slot.
    func advance(to date: Date, level: Float) -> Double {
        guard let last = lastSampleDate, date.timeIntervalSince(last) < 1 else {
            // First frame, or back from a long pause: start fresh rather than
            // replaying a burst of stale samples.
            lastSampleDate = date
            return 0
        }
        var sampleDate = last
        while date.timeIntervalSince(sampleDate) >= Self.interval {
            sampleDate += Self.interval
            // Quick attack, slower release, so syllables pop and fall off.
            let target = CGFloat(min(max(level, 0), 1))
            smoothed += (target - smoothed) * (target > smoothed ? 0.7 : 0.35)
            samples.append(smoothed)
        }
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
        lastSampleDate = sampleDate
        return date.timeIntervalSince(sampleDate) / Self.interval
    }

    /// The sample `age` slots back from the newest; zero before any exist.
    func sample(age: Int) -> CGFloat {
        let index = samples.count - 1 - age
        return samples.indices.contains(index) ? samples[index] : 0
    }
}
