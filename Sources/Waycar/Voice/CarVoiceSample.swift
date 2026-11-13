import AVFoundation
import CarPlay
import Observation
import OSLog
import UIKit

/// Settings › CarPlay Voice › Play Sample: one sentence in the voice and
/// speed the car uses now, on the phone's own audio session. Never during
/// a CarPlay voice turn, which owns the session and the Natural voice's
/// engine. Without CarPlay connected, the Natural model it loads is
/// released when the sample ends (docs/design/carplay.md §5 TTS).
@MainActor
@Observable
final class CarVoiceSample {
    static let sentence = "Two tests failed in the login flow. Want me to fix them now?"
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "carplay")

    private(set) var isPlaying = false
    @ObservationIgnored private var engine: (any CarSpeechEngine)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Which play is current: a stopped play's late cleanup leaves a newer
    /// one alone.
    @ObservationIgnored private var generation = 0
    /// Whether the sample activated the audio session and still has to
    /// deactivate it.
    @ObservationIgnored private var ownsSession = false

    /// Whether a CarPlay voice turn is on: an open conversation or Blocked
    /// turn, or a line being spoken or a listen running.
    nonisolated static func isBlocked(by car: CarVoiceActivity.State) -> Bool {
        car.agent != nil || car.speaking > 0 || car.listening > 0
    }

    /// Whether Play Sample can start now.
    static var canPlay: Bool { !isBlocked(by: CarVoiceActivity.shared.state) }

    /// Plays the sample, or stops one already playing. Refused while a
    /// CarPlay voice turn is on.
    func toggle() {
        guard !isPlaying else {
            stop()
            return
        }
        guard Self.canPlay else { return }
        isPlaying = true
        generation += 1
        let current = generation
        task = Task { [weak self] in
            await self?.play(current)
        }
    }

    /// Stops at once, even while the Natural model is still loading.
    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        generation += 1
        task?.cancel()
        task = nil
        engine?.stop()
        engine = nil
        releaseModelOffCarPlay()
        releaseSession()
    }

    private func play(_ current: Int) async {
        guard generation == current else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            ownsSession = true
        } catch {
            Self.log.error("Voice sample audio session failed: \(error)")
            if generation == current {
                isPlaying = false
                task = nil
            }
            return
        }
        // An interruption (a call, an Agent Notification sound) can leave
        // the line hung: stop instead.
        let interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began else { return }
            MainActor.assumeIsolated { self?.stopIfCurrent(current) }
        }
        defer {
            NotificationCenter.default.removeObserver(interruption)
            if generation == current {
                engine = nil
                isPlaying = false
                task = nil
                releaseModelOffCarPlay()
                releaseSession()
            }
        }
        // The Natural voice when it is on: load it first, so the sample is
        // the voice the car would use rather than the fallback.
        await NaturalVoice.prepare()
        guard !Task.isCancelled, generation == current, Self.canPlay else { return }
        let engine = NaturalVoice.engine() ?? SystemSpeechEngine()
        // Left set after the line: a stale play's callback is a no-op, and
        // clearing it could drop a car line's own handler.
        engine.onExternalPause = { [weak self] in self?.stopIfCurrent(current) }
        self.engine = engine
        _ = await engine.speak(Self.sentence)
    }

    private func stopIfCurrent(_ current: Int) {
        guard generation == current else { return }
        stop()
    }

    /// The Natural model is held only while CarPlay is connected; a sample
    /// on the phone alone releases what it loaded.
    private func releaseModelOffCarPlay() {
        let carPlayConnected = UIApplication.shared.connectedScenes.contains {
            $0 is CPTemplateApplicationScene
        }
        guard !carPlayConnected else { return }
        NaturalVoice.unload()
    }

    /// Deactivates the session the sample activated, unless a CarPlay turn
    /// took it over meanwhile.
    private func releaseSession() {
        guard ownsSession else { return }
        ownsSession = false
        guard Self.canPlay else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
