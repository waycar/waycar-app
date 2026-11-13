import AVFoundation
import OSLog

/// Speaks a car voice turn's lines, half-duplex, on the turn's one audio
/// session (docs/design/carplay.md §5 Audio): `.playAndRecord`, mode
/// `.default`, no mixing, the same session the turn's listening records on
/// (`DictationAudioProfile.car`). The session stays active for the whole
/// turn the driver started — a conversation's waits for replies included,
/// so a reply never has to win the session back on its own — and `endTurn`
/// releases it with `.notifyOthersOnDeactivation` (CPG p.7 #2, p.29). The
/// microphone leaves a car session active when it stops, so the turn — not
/// whichever of speech and listening ended last — decides when the car's
/// audio comes back.
///
/// Each line goes to the Natural voice when it is on and loaded, else to
/// the system voice. An interruption (a notification, a call) pauses the
/// line where it is, and its end resumes it; one not resumed within
/// `interruptionWait` is cut. A line that fails without being stopped (a
/// cut interruption, a refused activation, an engine error) is tried once
/// more on a freshly activated session, from the start of the sentence it
/// stopped in, then with the system voice; every failure is logged with
/// the route and the reason.
@MainActor
final class CarSpeaker: AgentVoiceSpeaker {
    /// The audio session calls, as closures so tests run the speaker
    /// without one.
    struct AudioSession {
        var activate: @MainActor () throws -> Void
        var deactivate: @MainActor () throws -> Void
        /// The head unit asked for silence.
        var isSilenced: @MainActor () -> Bool
        /// Ports and sample rate, for the log.
        var route: @MainActor () -> String

        static var live: AudioSession {
            AudioSession(
                activate: { try DictationAudioProfile.car.activate() },
                deactivate: {
                    try AVAudioSession.sharedInstance().setActive(
                        false, options: .notifyOthersOnDeactivation)
                },
                isSilenced: {
                    // `promptStyle` is for voice-prompt modes; the car's
                    // `.default` session reports `.none` too, which is no
                    // request for silence (it made replies silent).
                    let session = AVAudioSession.sharedInstance()
                    return session.mode != .default && session.promptStyle == .none
                },
                route: {
                    // `CarAudio` is CarPlay's own channel; `BluetoothHFP`
                    // at 8–16 kHz would be the narrowband telephony route
                    // (docs/design/carplay.md §5 Audio).
                    let session = AVAudioSession.sharedInstance()
                    let outputs = session.currentRoute.outputs.map(\.portType.rawValue)
                        .joined(separator: ",")
                    let inputs = session.currentRoute.inputs.map(\.portType.rawValue)
                        .joined(separator: ",")
                    return "out=\(outputs) in=\(inputs) rate=\(session.sampleRate)"
                })
        }
    }

    private enum Outcome: Equatable {
        case spoken
        /// `stop()`, or the turn's task was cancelled.
        case stopped
        /// The head unit asked for silence: no retry, no fallback.
        case silenced
        /// How far this line got (UTF-16 offset into the text played):
        /// 0 when its engine never started it.
        case failed(reached: Int)
    }

    private static let log = Logger(subsystem: "com.otreva.waycar", category: "carplay")
    private static let releaseRetryCount = 8
    private static let releaseRetryDelay: Duration = .milliseconds(250)
    private static let interruptionPoll: Duration = .milliseconds(50)
    /// How often a held line tries to resume when no interruption is
    /// pending (iOS paused it without posting one).
    private static let holdPoll: Duration = .milliseconds(250)

    private let system: any CarSpeechEngine
    private let natural: @MainActor () -> (any CarSpeechEngine)?
    private let session: AudioSession
    /// How long a paused line waits for an interruption (a call, Siri, a
    /// notification) to end before it is cut and replayed.
    private let interruptionWait: Duration
    /// The engine playing the current line.
    private var speaking: (any CarSpeechEngine)?
    private var lineMachine = CarSpeakerLineMachine()
    /// Counts `stop()` calls, so a line tells being stopped from failing.
    private var stops: Int { lineMachine.stops }
    /// A turn began, so its session may be active (activated here or by
    /// the car microphone) and is ours to release, even when activating it
    /// here failed.
    private var isTurnActive = false
    private var isSessionActive = false
    /// Another app's audio took the session; its end reactivates it.
    private var isInterrupted = false
    /// When the pending interruption began.
    private var interruptedAt: ContinuousClock.Instant?
    /// Watch tasks are resources, keyed by the machine's watch tokens.
    private var watches: [UInt64: Task<Void, Never>] = [:]
    /// How long a resumed line may play without progress before it is cut
    /// and replayed (an engine whose queued audio iOS flushed never ends).
    private let resumeStallWait: Duration
    /// A release that failed and is being tried again; a new turn cancels it.
    private var releaseRetry: Task<Void, Never>?
    nonisolated(unsafe) private var interruptionObserver: (any NSObjectProtocol)?

    convenience init() {
        self.init(
            system: SystemSpeechEngine(), natural: { NaturalVoice.engine() }, session: .live)
    }

    init(
        system: any CarSpeechEngine,
        natural: @escaping @MainActor () -> (any CarSpeechEngine)?,
        session: AudioSession,
        interruptionWait: Duration = .seconds(8),
        resumeStallWait: Duration = .seconds(3)
    ) {
        self.system = system
        self.natural = natural
        self.session = session
        self.interruptionWait = interruptionWait
        self.resumeStallWait = resumeStallWait
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            // Posted on the main queue.
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.interruptionBegan()
                case .ended: self?.interruptionEnded(shouldResume: options.contains(.shouldResume))
                default: break
                }
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func beginTurn() {
        activateSession()
    }

    /// Speaks `text`, cutting off any line still speaking, and returns
    /// once it finished or was stopped: true only when the whole line was
    /// heard, false when it was stopped, the head unit asked for silence,
    /// or neither a retry nor the system voice got it out.
    @discardableResult
    func speak(_ text: String) async -> Bool {
        stop()
        guard !Task.isCancelled, !text.isEmpty else { return false }
        // Agent Notifications stay silent while the car speaks.
        CarVoiceActivity.shared.beginSpeaking()
        defer { CarVoiceActivity.shared.endSpeaking() }
        return await perform(lineMachine.handle(.start(text)))
    }

    /// Stops speaking at once; a waiting `speak` returns false now.
    func stop() {
        for effect in lineMachine.handle(.stop) { performImmediate(effect) }
        speaking = nil
    }

    /// Ends the turn's audio, handing it back to whatever was playing.
    ///
    /// A turn closed while listening releases the session before the
    /// microphone's engine has stopped (its teardown is asynchronous, on the
    /// dictation actor), and iOS refuses to deactivate a session with
    /// running I/O. Left there, the non-mixing session would keep the car's
    /// radio silent, so a refused release is tried again shortly after.
    func endTurn() {
        stop()
        guard isTurnActive else { return }
        isTurnActive = false
        isSessionActive = false
        isInterrupted = false
        interruptedAt = nil
        guard !releaseSession() else { return }
        releaseRetry = Task { [weak self] in
            for _ in 0..<Self.releaseRetryCount {
                do { try await Task.sleep(for: Self.releaseRetryDelay) } catch { return }
                guard let self, !self.isTurnActive else { return }
                if self.releaseSession() { return }
            }
        }
    }

    /// A call, Siri or a notification took the session: the line playing
    /// pauses where it is, to resume when the interruption ends. A line the
    /// engine can't hold ends now (a synthesizer may never report a line
    /// an interruption cut), and its `speak` retries once it ends.
    func interruptionBegan() {
        guard isTurnActive else { return }
        isInterrupted = true
        interruptedAt = .now
        isSessionActive = false
        let route = session.route()
        Self.log.error("CarPlay audio interrupted \(route, privacy: .public)")
        guard let engine = speaking else { return }
        if lineMachine.isHeld || engine.pause() {
            hold()
        } else {
            engine.stop()
        }
    }

    /// The interruption is over: the turn takes its session back and a
    /// paused line plays on.
    func interruptionEnded(shouldResume: Bool) {
        isInterrupted = false
        interruptedAt = nil
        guard isTurnActive else { return }
        Self.log.info("CarPlay audio interruption ended shouldResume=\(shouldResume, privacy: .public)")
        activateSession()
        resumeHeld()
    }

    /// The engine paused on its own, with no interruption posted: held the
    /// same way, resumed as soon as the session can be taken back.
    private func pausedExternally(_ engine: any CarSpeechEngine) {
        guard isTurnActive, speaking === engine, !lineMachine.isHeld else { return }
        let route = session.route()
        Self.log.error("CarPlay line paused without an interruption \(route, privacy: .public)")
        hold()
    }

    /// Keeps the current line paused until it resumes; once
    /// `interruptionWait` passes it is cut, so its `speak` replays it.
    private func hold() {
        for effect in lineMachine.handle(.hold) { performImmediate(effect) }
    }

    /// Plays the held line on, on a reactivated session; a line its engine
    /// can't resume is cut, so its `speak` replays it.
    private func resumeHeld() {
        guard lineMachine.isHeld, let engine = speaking else { return }
        isSessionActive = false
        activateSession()
        // Still refused: the hold tries again until its deadline.
        guard isSessionActive else { return }
        let resumed = engine.resume()
        if resumed {
            Self.log.info("CarPlay paused line resumed")
        } else {
            Self.log.error("CarPlay paused line could not resume; replaying it")
        }
        for effect in lineMachine.handle(.resume(progress: engine.playbackProgress, succeeded: resumed)) {
            performImmediate(effect)
        }
    }

    /// Cuts a resumed line that stays silent, so its `speak` replays it
    /// from the sentence it stopped in. Checks every `resumeStallWait`
    /// until the line ends or pauses again: a queue iOS flushed later on
    /// stalls it as surely as one flushed at once.
    private func watchResumed(_ engine: any CarSpeechEngine, token: UInt64) {
        watches[token] = Task { [weak self, resumeStallWait] in
            while true {
                do { try await Task.sleep(for: resumeStallWait) } catch { return }
                guard let self, self.speaking === engine else { return }
                let effects = self.lineMachine.handle(.progress(token, engine.playbackProgress))
                guard effects.isEmpty else {
                    Self.log.error("CarPlay resumed line made no progress; replaying it")
                    self.watches[token] = nil
                    for effect in effects { self.performImmediate(effect) }
                    return
                }
                guard case .watchingResume(_, let current, _) = self.lineMachine.state,
                      current == token else { return }
            }
        }
    }

    private func release() {
        for task in watches.values { task.cancel() }
        watches.removeAll()
    }

    /// Async effects stay in the caller's task, preserving cancellation
    /// after each await rather than detaching a line from its turn.
    private func perform(_ effects: [CarSpeakerLineMachine.Effect]) async -> Bool {
        for effect in effects {
            switch effect {
            case .play(let line):
                if line.attempt == .retry { isSessionActive = false }
                if line.attempt == .system {
                    Self.log.error("CarPlay line falling back to the system voice")
                }
                let engine = line.attempt == .system ? system : (natural() ?? system)
                let outcome = await play(line.text, on: engine, line: line.token)
                let result: CarSpeakerLineMachine.Outcome
                switch outcome {
                case .spoken: result = .spoken
                case .stopped: result = .stopped
                case .silenced: result = .silenced
                case .failed(let reached):
                    result = .failed(rest: CarLine.unfinished(line.text, from: reached), usedSystem: engine === system)
                }
                return await perform(lineMachine.handle(.completed(line.token, result)))
            case .waitForInterruption(let token):
                await waitOutInterruption(line: token)
                return await perform(lineMachine.handle(.retryReady(token, cancelled: Task.isCancelled)))
            case .finished(let spoken): return spoken
            case .release, .stopEngine, .watchHold, .watchProgress:
                performImmediate(effect)
            }
        }
        return false
    }

    private func performImmediate(_ effect: CarSpeakerLineMachine.Effect) {
        switch effect {
        case .release: release()
        case .stopEngine: speaking?.stop()
        case .watchHold(let token):
            release()
            let deadline = ContinuousClock.now + interruptionWait
            watches[token] = Task { [weak self] in
                while true {
                    do { try await Task.sleep(for: Self.holdPoll) } catch { return }
                    guard let self, self.lineMachine.holds(token) else { return }
                    if !self.isInterrupted {
                        self.resumeHeld()
                        if !self.lineMachine.holds(token) { return }
                    }
                    if ContinuousClock.now >= deadline {
                        Self.log.error("CarPlay paused line not resumed in time; replaying it")
                        self.watches[token] = nil
                        for effect in self.lineMachine.handle(.holdExpired(token)) {
                            self.performImmediate(effect)
                        }
                        return
                    }
                }
            }
        case .watchProgress(let token):
            if let engine = speaking { watchResumed(engine, token: token) }
        case .play, .waitForInterruption, .finished:
            assertionFailure("Async line effect outside speak")
        }
    }

    private func play(_ text: String, on engine: any CarSpeechEngine, line: Int) async -> Outcome {
        let name = String(describing: type(of: engine))
        activateSession()
        guard isSessionActive else {
            let route = session.route()
            Self.log.error(
                "CarPlay line not spoken by \(name, privacy: .public): audio session inactive \(route, privacy: .public)"
            )
            return .failed(reached: 0)
        }
        guard !session.isSilenced() else {
            let route = session.route()
            Self.log.info(
                "CarPlay line not spoken: the head unit asked for silence \(route, privacy: .public)")
            return .silenced
        }
        speaking = engine
        engine.onExternalPause = { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.pausedExternally(engine)
        }
        let spoken = await engine.speak(text)
        // Read now, from the run that spoke `text`: the engine's offset
        // belongs to whatever line it ran last.
        let reached = engine.spokenOffset
        // A replacement may already be using this same engine. Only the
        // line that still owns it may release its callbacks and hold.
        guard stops == line else { return .stopped }
        engine.onExternalPause = nil
        if speaking === engine { speaking = nil }
        if isStopped(since: line) { return .stopped }
        if spoken { return .spoken }
        let reason = isInterrupted ? "interrupted" : "the engine stopped short"
        let route = session.route()
        Self.log.error(
            "CarPlay line not spoken by \(name, privacy: .public): \(reason, privacy: .public) \(route, privacy: .public)"
        )
        return .failed(reached: reached)
    }

    private func isStopped(since line: Int) -> Bool {
        stops != line || Task.isCancelled
    }

    /// Waits for a pending interruption to end, at most `interruptionWait`
    /// after it began.
    private func waitOutInterruption(line: Int) async {
        let deadline = (interruptedAt ?? .now) + interruptionWait
        while isInterrupted, ContinuousClock.now < deadline, !isStopped(since: line) {
            do { try await Task.sleep(for: Self.interruptionPoll) } catch { return }
        }
    }

    private func activateSession() {
        releaseRetry?.cancel()
        releaseRetry = nil
        isTurnActive = true
        guard !isSessionActive else { return }
        do {
            try session.activate()
            isSessionActive = true
            isInterrupted = false
            interruptedAt = nil
            let route = session.route()
            Self.log.info("CarPlay audio route \(route, privacy: .public)")
        } catch {
            let route = session.route()
            Self.log.error(
                "CarPlay audio session activation failed: \(error) \(route, privacy: .public)")
        }
    }

    /// True once the session is inactive.
    private func releaseSession() -> Bool {
        do {
            try session.deactivate()
            return true
        } catch {
            let route = session.route()
            Self.log.error(
                "CarPlay audio session deactivation failed: \(error) \(route, privacy: .public)")
            return false
        }
    }
}
