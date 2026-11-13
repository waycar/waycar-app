import AVFoundation
import Foundation
import Observation
import WatchKit

/// Waycar's own voice recorder (design §4 W4, §6.4): no live text. It
/// records AAC 16 kHz mono to a temporary `.m4a`, meters it 10 times a
/// second into `SilenceDetector`, and ends on a tap, 3.5 s of silence after
/// speech, or the 60 s cap. No speech in the first 8 s, ✕, or an
/// interruption cancels and deletes the file. The iPhone transcribes the
/// file; the watch never sees text.
@MainActor
@Observable
final class WatchRecorder {
    /// Where the recorder stands.
    typealias Phase = WatchRecorderMachine.Phase

    // MARK: - Copy and tuning

    /// No speech in the first 8 s.
    static let noSpeechCopy = WatchRecorderMachine.noSpeechCopy
    /// Microphone permission is off.
    static let permissionCopy = WatchRecorderMachine.permissionCopy
    /// The audio session or recorder would not start.
    static let startFailedCopy = WatchRecorderMachine.startFailedCopy
    /// A call, Siri, wrist down, or leaving the app ended the recording.
    static let interruptedCopy = WatchRecorderMachine.interruptedCopy
    /// The meter tick: 10 Hz.
    static let meterInterval: Duration = .milliseconds(100)
    /// The level shown as silence (dBFS); 0 dBFS is full scale.
    static let levelFloorDB: Float = -50

    /// The temporary folder recordings live in until they settle.
    static var recordingsDirectory: URL {
        FileManager.default.temporaryDirectory.appending(
            path: "WatchRecordings", directoryHint: .isDirectory)
    }

    // MARK: - State

    /// Where the recorder stands.
    private(set) var phase: Phase = .idle
    /// The input level, 0...1, for the pulsing rings.
    private(set) var level: Double = 0

    /// The recorder while recording.
    @ObservationIgnored private var recorder: AVAudioRecorder?
    /// Decides when the recording ends.
    @ObservationIgnored private var detector = SilenceDetector()
    /// The 10 Hz meter loop.
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    /// The audio-session interruption observer while recording.
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?
    /// The machine owns permission/capture tokens; phase stays mirrored so
    /// phase-only observation notifications remain unchanged.
    @ObservationIgnored private var lifecycle = WatchRecorderMachine()

    /// An idle recorder.
    init() {}

    /// Deletes recordings a previous launch left behind; nothing is held
    /// across launches (§6.4).
    static func removeLeftoverRecordings() {
        try? FileManager.default.removeItem(at: recordingsDirectory)
    }

    // MARK: - Control

    /// Asks for microphone permission, then starts recording (`.start`
    /// haptic). A no-op while already recording.
    func start() async {
        guard !lifecycle.isRecording else { return }
        #if DEBUG
        if let demo = Self.demoPhase {
            startDemo(demo)
            return
        }
        #endif
        let effects = lifecycle.handle(.start)
        publishPhase()
        for effect in effects {
            if case .requestPermission(let token) = effect {
                observeInterruptions()
                level = 0
                let granted = await AVAudioApplication.requestRecordPermission()
                send(.permission(token, granted: granted))
            } else { perform(effect) }
        }
    }

    /// Tap or double tap: stops and keeps the audio to send (`.stop`
    /// haptic).
    func stop() {
        guard lifecycle.isRecording, let recorder else { return }
        send(.stop(recorder.url, duration: recorder.currentTime))
    }

    /// ✕: ends with nothing sent and deletes the file. Also abandons a
    /// start still waiting for permission.
    func cancel() {
        send(.cancel)
    }

    /// A call, Siri, wrist down, or the app leaving the front: cancels a
    /// recording in progress (`.failure` haptic), nothing sent.
    func interrupt() {
        send(.interrupt)
    }

    // MARK: - Recording

    /// Opens the record session and starts the recorder and meter loop.
    private func begin() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        let directory = Self.recordingsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        self.recorder = recorder
        guard recorder.prepareToRecord(), recorder.record() else {
            throw RecorderError.couldNotStart
        }
        detector = SilenceDetector()
        observeInterruptions()

    }

    /// One meter sample: updates the level and the ring, and ends the
    /// recording when the detector says so.
    private func tick(_ token: UInt64) {
        guard case .recording(let current, _) = lifecycle.state, current == token,
              let recorder else { return }
        guard recorder.isRecording else {
            interrupt()
            return
        }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        level = Self.normalized(power)
        send(.sample(token, detector.feed(levelDB: power, at: .seconds(recorder.currentTime))))
    }

    private func send(_ event: WatchRecorderMachine.Event) {
        let effects = lifecycle.handle(event)
        publishPhase()
        for effect in effects { perform(effect) }
    }

    private func publishPhase() {
        if phase != lifecycle.phase { phase = lifecycle.phase }
    }

    private func perform(_ effect: WatchRecorderMachine.Effect) {
        switch effect {
        case .requestPermission: break // start() awaits this in its caller's task.
        case .begin(let token):
            do {
                try begin()
                send(.began(token))
            } catch { send(.failed(token)) }
        case .meter(let token):
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.meterInterval)
                    guard !Task.isCancelled, let self else { return }
                    self.tick(token)
                }
            }
        case .stop: stop()
        case .teardown(let delete):
            let url = recorder?.url
            teardown()
            if delete, let url { try? FileManager.default.removeItem(at: url) }
        case .stopObservingInterruptions: stopObservingInterruptions()
        case .haptic(let haptic):
            switch haptic {
            case .start: play(.start)
            case .stop: play(.stop)
            case .failure: play(.failure)
            }
        }
    }

    /// Stops the recorder, the meter loop, and the observer, and releases
    /// the audio session.
    private func teardown() {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        stopObservingInterruptions()
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Cancels the recording when the audio session is interrupted. The
    /// observer runs on the main queue.
    private func stopObservingInterruptions() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }

    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt() }
        }
    }

    /// Maps dBFS to 0...1 for the rings.
    private static func normalized(_ power: Float) -> Double {
        let clamped = min(0, max(levelFloorDB, power))
        return Double((clamped - levelFloorDB) / -levelFloorDB)
    }

    /// Plays a wrist haptic.
    private func play(_ haptic: WKHapticType) {
        WKInterfaceDevice.current().play(haptic)
    }

    /// Why recording could not begin.
    private enum RecorderError: Error {
        /// `prepareToRecord` or `record` returned false.
        case couldNotStart
    }

    #if DEBUG
    // MARK: - Demo

    /// The launch argument that freezes the recorder in one phase under
    /// `-WaycarWatchDemo YES`: `-WaycarWatchDemoRecorder listening|paused`.
    static let demoRecorderKey = "WaycarWatchDemoRecorder"

    /// The phase demo mode shows instead of recording; nil records for real.
    static var demoPhase: Phase? {
        guard WatchStore.isDemoLaunch else { return nil }
        switch UserDefaults.standard.string(forKey: demoRecorderKey) {
        case "listening": return .listening
        case "paused": return .paused(progress: 0.6)
        default: return nil
        }
    }

    /// Shows `demo` without the microphone: no permission request, no
    /// session, no file. Listening pulses a fake level.
    private func startDemo(_ demo: Phase) {
        let progress: Double
        if case .paused(let value) = demo { progress = value } else { progress = 0 }
        send(.demo(progress: progress))
        level = 0
        guard demo == .listening else { return }
        meterTask = Task { [weak self] in
            var tickCount = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.meterInterval)
                guard !Task.isCancelled, let self else { return }
                tickCount += 1
                self.level = 0.45 + 0.35 * sin(tickCount / 3)
            }
        }
    }
    #endif
}
