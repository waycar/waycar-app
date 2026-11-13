import Foundation
import Observation

/// Dictation that sends: the Toolbar's Dictate to Agent. Tap to speak, tap
/// stop, and what was heard goes to the Agent through the Composer's Send as
/// its own message; the draft is left alone. When sending is unsafe (a Blocked Agent) or the
/// session ended on its own (an interruption), what was heard goes into the
/// draft instead.
@MainActor
@Observable
final class DictationSender {
    let dictation: DictationStore
    @ObservationIgnored private var delivery = DictationSendMachine()
    @ObservationIgnored private var heard: HeardText?

    init(dictation: DictationStore = DictationStore()) {
        self.dictation = dictation
    }

    func start() {
        guard !dictation.isActive else { return }
        _ = send(.start)
    }

    /// Stops listening, waits for the last words, and sends them through
    /// `composer`'s Send. Nothing is sent when nothing was said, or when the
    /// session already ended some other way (an error or teardown).
    @discardableResult
    func stopAndSend(through composer: AgentComposerStore) async -> AgentComposerStore.SendResult {
        guard let text = await stopAndTake() else { return .ignored }
        return await composer.send(text)
    }

    /// Stops listening, waits for the last words, and puts them into
    /// `composer`'s draft at its caret instead of sending. False when nothing
    /// was kept.
    func stopAndKeep(in composer: AgentComposerStore) async -> Bool {
        guard let text = await stopAndTake() else { return false }
        Self.keep(text, in: composer)
        return true
    }

    /// After the session ended on its own (an audio interruption or route
    /// change), puts what was heard into `composer`'s draft. False while a
    /// stop is taking the words, after teardown, or when nothing was said.
    func keepInterrupted(in composer: AgentComposerStore) -> Bool {
        guard let text = send(.keepInterrupted).text else { return false }
        Self.keep(text, in: composer)
        return true
    }

    private func stopAndTake() async -> String? {
        guard let token = send(.stop).finish else { return nil }
        await dictation.finish()
        return send(.finished(token)).text
    }

    /// Inserts at the draft's caret with word spacing, as Dictation in the
    /// Composer does.
    private static func keep(_ text: String, in composer: AgentComposerStore) {
        let composed = DictationComposition(
            draft: composer.draft, selection: composer.draftSelection
        ).compose(text)
        composer.applyEditorDraft(
            composed.text, selection: NSRange(location: composed.caret, length: 0))
    }

    /// Teardown, or Cancel dictation while starting: releases the microphone
    /// and drops what was heard. The person never saw it, so nothing is sent
    /// or kept.
    func cancel() {
        _ = send(.cancel)
    }

    /// Performs synchronous effects. A finish is awaited by the calling
    /// stop, which returns its token so teardown/replacement can invalidate it.
    private func send(_ event: DictationSendMachine.Event) -> (finish: UInt64?, text: String?) {
        var result: (finish: UInt64?, text: String?) = (nil, nil)
        for effect in delivery.handle(event) {
            switch effect {
            case .start(let token):
                let target = HeardText(owner: self, token: token)
                heard = target
                dictation.start(into: target)
            case .finish(let token):
                result.finish = token
            case .take(let text):
                result.text = text
            case .cancel:
                dictation.cancel()
            }
        }
        return result
    }

    /// A session-scoped target: late insertion cannot write to a new session.
    @MainActor
    private final class HeardText: DictationDraftTarget {
        private weak var owner: DictationSender?
        private let token: UInt64

        init(owner: DictationSender, token: UInt64) {
            self.owner = owner
            self.token = token
        }

        var draft: String { owner?.delivery.text(for: token) ?? "" }

        var draftSelection: NSRange {
            NSRange(location: (draft as NSString).length, length: 0)
        }

        func applyEditorDraft(_ text: String, selection _: NSRange) {
            _ = owner?.send(.committed(token, text))
        }
    }
}
