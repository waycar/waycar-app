import Foundation

/// One direct-input dictation's words, from capture to a single consumption.
/// Teardown discards both buffered and future words. Stop owns consumption
/// until its matching finish returns; an interruption check cannot steal it.
struct DictationSendMachine: StateMachine {
    enum State: Equatable, Sendable {
        case idle
        case recording(token: UInt64)
        case interrupted(token: UInt64, text: String)
        case stopping(token: UInt64, text: String)
        case discarded
    }

    enum Event: Equatable, Sendable {
        case start
        case committed(UInt64, String)
        case stop
        case finished(UInt64)
        case keepInterrupted
        case cancel
    }

    enum Effect: Equatable, Sendable {
        case start(UInt64)
        case finish(UInt64)
        case take(String)
        case cancel
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    /// The target reads only its own session's buffered words.
    func text(for token: UInt64) -> String {
        switch state {
        case .interrupted(let current, let text), .stopping(let current, let text):
            return current == token ? text : ""
        case .idle, .recording, .discarded:
            return ""
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .start):
            lastToken += 1
            state = .recording(token: lastToken)
            return [.start(lastToken)]
        case (_, .cancel):
            state = .discarded
            return [.cancel]
        case (.recording(let token), .committed(let current, let text)),
            (.interrupted(let token, _), .committed(let current, let text)):
            guard current == token else { return [] }
            state = .interrupted(token: token, text: text)
            return []
        case (.stopping(let token, _), .committed(let current, let text)):
            guard current == token else { return [] }
            state = .stopping(token: token, text: text)
            return []
        case (.recording(let token), .stop):
            state = .stopping(token: token, text: "")
            return [.finish(token)]
        case (.interrupted(let token, let text), .stop):
            state = .stopping(token: token, text: text)
            return [.finish(token)]
        case (.stopping(let token, _), .stop):
            return [.finish(token)]
        case (.stopping(let token, let text), .finished(let current)):
            guard current == token else { return [] }
            state = .idle
            return take(text)
        case (.interrupted(_, let text), .keepInterrupted):
            state = .idle
            return take(text)
        case (.idle, _), (.recording, _), (.interrupted, _), (.stopping, _), (.discarded, _):
            return []
        }
    }

    private func take(_ text: String) -> [Effect] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [.take(trimmed)]
    }
}
