import Foundation
import Observation

/// The draft Dictation writes into. `AgentComposerStore` takes it directly in
/// the Composer; `DictationSender` collects it for the Direct Input
/// microphone. The store only edits its target and never sends: the Composer
/// sends when the person taps Send (while listening, Send waits for the last
/// words and delivers them with the draft), and `DictationSender` sends on
/// Direct Input's stop.
@MainActor
protocol DictationDraftTarget: AnyObject {
    var draft: String { get }
    /// UTF-16 caret/selection, matching the Composer text view.
    var draftSelection: NSRange { get }
    func applyEditorDraft(_ text: String, selection: NSRange)
}

extension AgentComposerStore: DictationDraftTarget {}

/// Owns one Composer's Dictation: tap the microphone and speak, tap again (or
/// Send) to stop. Speech is transcribed on device by the system's own models
/// (`SpeechDictationEngine`).
///
/// ```
/// idle ─start─▶ starting ─▶ (downloadingModel) ─▶ listening ─stop─▶ finishing ─▶ idle
///                  └──────── stop / cancel / error ───────┴── cancel / error ─────┘
/// ```
///
/// The draft stays untouched while listening — watching words appear in it
/// makes people speak differently. Everything heard lands at once when the
/// session ends, at the caret as it is then, so typing meanwhile is never overwritten.
/// Whatever was heard is kept whichever way a session ends.
@MainActor
@Observable
final class DictationStore {
    enum Phase: Equatable, Sendable {
        case idle
        /// Microphone permission and model lookup are in flight.
        case starting
        /// The system is downloading the language's on-device model.
        case downloadingModel(fraction: Double)
        case listening
        /// Stopped; waiting for the recognizer to flush its last words.
        case finishing
    }

    enum Failure: Equatable, Sendable {
        /// Surfaced with a Settings shortcut rather than as plain text.
        case microphonePermissionDenied
        case message(String)
    }

    var phase: Phase {
        access(keyPath: \.phase)
        return lifecycle.phase
    }
    /// Latest microphone level in `0...1`, for the waveform. Zero when idle.
    var level: Float {
        access(keyPath: \.level)
        return lifecycle.level
    }
    /// Why the last session ended early, until dismissed or the next start.
    var failure: Failure? {
        access(keyPath: \.failure)
        return lifecycle.failure
    }
    @ObservationIgnored private var lifecycle = DictationPhaseMachine()

    @ObservationIgnored private let engine: (any DictationEngine)?
    @ObservationIgnored private let locale: @MainActor () -> Locale
    @ObservationIgnored private var sessions: [UInt64: Session] = [:]

    @MainActor
    private final class Session {
        let id: DictationSessionID
        let locale: Locale
        weak var target: (any DictationDraftTarget)?
        var finalized = ""
        var volatile = ""
        var task: Task<Void, Never>?

        init(id: DictationSessionID, locale: Locale, target: any DictationDraftTarget) {
            self.id = id
            self.locale = locale
            self.target = target
        }
    }

    init(
        engine: (any DictationEngine)? = DictationEngines.live,
        // The app bundle ships only English, so `Locale.current` reports
        // English for every user; the preferred language is what they speak.
        locale: @escaping @MainActor () -> Locale = {
            Locale.preferredLanguages.first.map(Locale.init(identifier:)) ?? .current
        }
    ) {
        self.engine = engine
        self.locale = locale
    }

    /// False where the OS has no on-device speech stack; the Composer hides
    /// its microphone.
    var isAvailable: Bool { engine != nil }

    var isActive: Bool { phase != .idle }

    /// True while a different store holds the one on-device speech session
    /// (the Toolbar's 🎤 and Message Agent's mic share it). That surface's mic
    /// is disabled instead of failing with "already listening".
    var isBlockedByOtherSession: Bool {
        DictationActivity.shared.isBusy(excluding: ObjectIdentifier(self))
    }

    /// The microphone has opened, so speech may be waiting to land in the
    /// draft. Send stays available then even with an empty draft: it stops
    /// Dictation and delivers what was said.
    var holdsSpeech: Bool {
        phase == .listening || phase == .finishing
    }

    /// Begins listening for `target`. What is heard is inserted at its caret
    /// (replacing any selection) when the session ends. Ignored while a
    /// session is active.
    func start(into target: any DictationDraftTarget) {
        guard engine != nil else { return }
        send(.start, target: target)
    }

    /// Stops listening and keeps what was said; the last words land during
    /// `.finishing`. Before the microphone opens there is nothing to keep, so
    /// startup is abandoned.
    func stop() {
        send(.stop)
    }

    /// `stop()`, then waits until what was said is in the draft. Send awaits
    /// this so a message never leaves without its final phrase.
    func finish() async {
        let task = lifecycle.token.flatMap { sessions[$0]?.task }
        stop()
        await task?.value
    }

    /// Ends immediately and releases the microphone, still inserting what
    /// was heard. For teardown: the Composer went away or changed Agent.
    func cancel() {
        send(.cancel)
    }

    func dismissFailure() {
        send(.dismissFailure)
    }

    private func consume(
        _ events: AsyncThrowingStream<DictationEvent, any Error>, session: Session, token: UInt64
    ) async {
        do {
            for try await event in events {
                send(.engine(token, event))
            }
            send(.ended(token, nil))
        } catch {
            send(.ended(token, Self.failure(for: error, locale: session.locale)))
        }
    }

    /// Track each presentation key independently: transcript/level updates
    /// must not look like phase changes. End effects insert the words before
    /// notifying idle observers, as on the original store.
    private func send(_ event: DictationPhaseMachine.Event, target: (any DictationDraftTarget)? = nil) {
        let oldPhase = lifecycle.phase
        let oldLevel = lifecycle.level
        let oldFailure = lifecycle.failure
        let effects = lifecycle.handle(event)
        for effect in effects {
            switch effect {
            case .start(let token):
                guard let engine, let target else { continue }
                DictationActivity.shared.begin(ObjectIdentifier(self))
                let session = Session(id: DictationSessionID(), locale: locale(), target: target)
                sessions[token] = session
                let events = engine.events(
                    for: session.id, locale: session.locale, audioProfile: .composer)
                session.task = Task { await self.consume(events, session: session, token: token) }
            case .finish(let token):
                guard let session = sessions[token], let engine else { continue }
                Task { await engine.finish(session.id) }
            case .cancel(let token):
                sessions[token]?.task?.cancel()
            case .transcript(let token, let text, let isFinal):
                guard let session = sessions[token] else { continue }
                if isFinal {
                    session.finalized = DictationComposition.join(session.finalized, text)
                    session.volatile = ""
                } else {
                    session.volatile = text
                }
            case .end(let token):
                guard let session = sessions.removeValue(forKey: token) else { continue }
                DictationActivity.shared.end(ObjectIdentifier(self))
                insertHeardText(from: session)
            }
        }
        if oldPhase != lifecycle.phase { withMutation(keyPath: \.phase) {} }
        if oldLevel != lifecycle.level { withMutation(keyPath: \.level) {} }
        if oldFailure != lifecycle.failure { withMutation(keyPath: \.failure) {} }
    }

    /// Inserts everything heard at the target's current caret, in one edit.
    private func insertHeardText(from session: Session) {
        let heard = DictationComposition.join(session.finalized, session.volatile)
        guard let target = session.target,
            !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let composed = DictationComposition(
            draft: target.draft, selection: target.draftSelection
        ).compose(heard)
        target.applyEditorDraft(
            composed.text, selection: NSRange(location: composed.caret, length: 0))
    }

    private static func failure(for error: any Error, locale: Locale) -> Failure {
        let language = locale.language.languageCode.flatMap {
            Locale.current.localizedString(forLanguageCode: $0.identifier)
        } ?? "this language"
        switch error as? DictationEngineError {
        case .microphonePermissionDenied:
            return .microphonePermissionDenied
        case .localeUnsupported:
            return .message("This device has no on-device speech model for \(language).")
        case .modelUnavailable:
            return .message(
                "The speech model for \(language) couldn't be downloaded. "
                    + "Check your connection and try again.")
        case .busy:
            return .message("Dictation is already listening in another window.")
        case .captureFailed(let detail):
            return .message("Dictation stopped unexpectedly (\(detail)). Try again.")
        case nil:
            return .message("Dictation stopped unexpectedly. Try again.")
        }
    }
}

/// Which `DictationStore`s hold a session right now, so a second surface's
/// mic can stand down while another listens.
@MainActor
@Observable
final class DictationActivity {
    static let shared = DictationActivity()
    private var active: Set<ObjectIdentifier> = []

    func begin(_ store: ObjectIdentifier) { active.insert(store) }
    func end(_ store: ObjectIdentifier) { active.remove(store) }
    func isBusy(excluding store: ObjectIdentifier) -> Bool {
        active.contains { $0 != store }
    }
}

/// Places dictated text into the draft as it stood when Dictation started:
/// between the text before the caret and the text after it (a selection is
/// replaced), with word spacing at both seams.
struct DictationComposition: Equatable {
    let prefix: String
    let suffix: String

    init(draft: String, selection: NSRange) {
        let text = draft as NSString
        let location = min(max(selection.location, 0), text.length)
        let end = min(location + max(selection.length, 0), text.length)
        prefix = text.substring(to: location)
        suffix = text.substring(from: end)
    }

    /// The draft with `dictated` in place and the UTF-16 caret just after it.
    func compose(_ dictated: String) -> (text: String, caret: Int) {
        let spoken = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            return (prefix + suffix, (prefix as NSString).length)
        }
        let leading = Self.needsSpace(between: prefix.last, and: spoken.first) ? " " : ""
        let trailing = Self.needsSpace(between: spoken.last, and: suffix.first) ? " " : ""
        let head = prefix + leading + spoken
        return (head + trailing + suffix, (head as NSString).length)
    }

    /// Appends one recognizer segment to the text before it. Segments may or
    /// may not carry their own leading space; this adds one only where words
    /// would otherwise run together.
    static func join(_ text: String, _ segment: String) -> String {
        guard !text.isEmpty else { return segment }
        return needsSpace(between: text.last, and: segment.first)
            ? text + " " + segment : text + segment
    }

    /// Characters that attach to the word before them.
    private static let closingPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", ")", "]", "}", "…", "%", "”", "’",
    ]

    private static func needsSpace(between before: Character?, and after: Character?) -> Bool {
        guard let before, let after else { return false }
        if before.isWhitespace || after.isWhitespace { return false }
        if closingPunctuation.contains(after) { return false }
        return !writesWithoutSpaces(before) && !writesWithoutSpaces(after)
    }

    /// Scripts that do not separate words with spaces: Han, kana, Thai, Lao,
    /// Myanmar, Khmer, and CJK punctuation.
    private static func writesWithoutSpaces(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF,
            0x3000...0x30FF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}
