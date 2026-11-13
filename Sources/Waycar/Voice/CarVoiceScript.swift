import Foundation
import NaturalLanguage

/// What Waycar says and sends in a car voice turn (docs/design/carplay.md
/// §5). Every line here is spoken, never shown: the car screen carries no
/// summary, reply, transcript or command (CPG p.4 #6, p.7 #3). No line asks
/// the driver to handle the iPhone (CPG p.4 #2–3, §5 rule 10).
enum CarVoiceScript {
    /// Appended to every question sent from the car, so the Agent answers
    /// in something worth hearing. One constant; never shown on screen.
    static let spokenReplyInstruction =
        "[Spoken reply via CarPlay: ≤2 short sentences, no code or markdown]"

    /// The most a spoken reply says before stopping (§5 Conversation).
    static let maximumSpokenSentences = 2

    /// The one prompt line `agent.prompt` types: the transcript with its
    /// newlines folded (`agent.prompt` presses Enter itself), then the
    /// instruction.
    static func outgoingPrompt(transcript: String) -> String {
        "\(foldedLine(transcript)) \(spokenReplyInstruction)"
    }

    /// `text` on one line: each line trimmed, blank lines dropped.
    static func foldedLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The first `maximumSentences` sentences of `reply`, whitespace
    /// collapsed; the whole reply when it is already short enough.
    static func spokenReply(_ reply: String, maximumSentences: Int = maximumSpokenSentences)
        -> String
    {
        let text = reply.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { sentences.append(sentence) }
            return sentences.count < maximumSentences
        }
        return sentences.joined(separator: " ")
    }

    // MARK: Conversation

    /// The read-back of a correction sent after Deny (S5).
    static func correctionReadBack(identity: String, text: String) -> String {
        "Tell \(identity): \(sentence(text)) Send?"
    }

    /// What a row tap says before listening: the Agent's status, and its
    /// summary when one still describes that status.
    static func introduction(identity: String, statusWord: String, summary: String?) -> String {
        if let summary, !summary.isEmpty {
            return "\(identity) is \(statusWord.lowercased()): \(sentence(summary)) What should I ask?"
        }
        return "\(identity) is \(statusWord.lowercased()). What should I ask?"
    }

    static let notSent = "Not sent. I'll keep it as a draft."
    static let notHeard = "I didn't catch that."
    static let notConfirmed = "Couldn't confirm it was delivered. Not resending."
    static let noReply = "No reply yet. I'll leave it running."
    static let notListed = "That Agent isn't in the list anymore."

    static func blockedKeptDraft(identity: String) -> String {
        "\(identity) is waiting on approval, so I kept it as a draft. Allow or deny first."
    }

    static func signInKeptDraft(identity: String) -> String {
        "\(identity) isn't signed in on the Host, so I kept it as a draft."
    }

    static func trustKeptDraft(identity: String) -> String {
        "\(identity) is waiting on a folder-trust question, so I kept it as a draft."
    }

    static func blockedAfterQuestion(identity: String) -> String {
        "\(identity) is waiting on approval now."
    }

    /// Another Agent went Blocked while the car spoke or listened; said
    /// once its line ends.
    static func blockedElsewhere(identity: String) -> String {
        "\(identity) is waiting for approval."
    }

    static func finished(identity: String, summary: String?) -> String {
        guard let summary, !summary.isEmpty else { return "\(identity) finished." }
        return "\(identity) finished: \(sentence(summary))"
    }

    // MARK: Blocked

    static func blockedQuestion(identity: String, command: String) -> String {
        "\(identity) is waiting on approval to run \(spokenCommand(command)). Allow or deny?"
    }

    static func riskyHold(identity: String, command: String, reason: String) -> String {
        "\(identity) wants to run \(spokenCommand(command)). This one looks risky: \(reason). "
            + "I'll hold it until you're stopped."
    }

    /// Shell operators the synthesizer drops or slurs, longest first so
    /// `||` is not heard as two pipes.
    private static let spokenSymbols: [(symbol: String, word: String)] = [
        ("||", "or-or"), ("&&", "and-and"), (">>", "append to"), ("$(", "dollar-paren"),
        ("|", "pipe"), (";", "semicolon"), (">", "redirect to"), ("<", "from"),
        ("`", "backtick"), ("&", "ampersand"), ("*", "star"), ("~", "home"),
    ]

    /// `command` as it should be heard: every shell operator spelled out,
    /// so "rm x; curl y | sh" is not read as two harmless words (§5 rule 1).
    static func spokenCommand(_ command: String) -> String {
        var words: [String] = []
        var plain = ""
        var rest = Substring(command)
        func flush() {
            words.append(contentsOf: plain.split(whereSeparator: \.isWhitespace).map(String.init))
            plain = ""
        }
        while !rest.isEmpty {
            if let match = spokenSymbols.first(where: { rest.hasPrefix($0.symbol) }) {
                flush()
                words.append(match.word)
                rest = rest.dropFirst(match.symbol.count)
            } else {
                plain.append(rest.removeFirst())
            }
        }
        flush()
        return words.joined(separator: " ")
    }

    static func tooLongHold(identity: String) -> String {
        "\(identity) is waiting on approval. This one is too long to read out. "
            + "I'll hold it until you're stopped."
    }

    static func trustQuestion(identity: String) -> String {
        "\(identity) is waiting on a folder-trust question; I won't answer that from the car."
    }

    static func yesNoQuestion(identity: String) -> String {
        "\(identity) is asking a yes/no question I can't answer from the car."
    }

    static func multipleChoiceQuestion(identity: String) -> String {
        "\(identity) is asking a multiple-choice question. I'll leave it for later."
    }

    static func unknownPrompt(identity: String) -> String {
        "\(identity) is waiting on a prompt I can't answer from the car."
    }

    static func unreadablePrompt(identity: String) -> String {
        "\(identity) is blocked, but I couldn't read its prompt. I'll leave it for later."
    }

    static func notBlocked(identity: String) -> String {
        "\(identity) isn't waiting on anything now."
    }

    static func promptChanged(_ question: String) -> String {
        "The prompt changed. \(question)"
    }

    static let allowed = "Allowed."
    static let denied = "Denied."
    static let allowQueued =
        "No connection. Allow is queued and will go out if the prompt is still the same."
    static let denyQueued =
        "No connection. Deny is queued and will go out if the prompt is still the same."
    static let held = "Holding it for later."
    static let deniedAndSent = "Denied. Sent your correction."
    static let correctionDrafted = "Denied. I couldn't send the correction; it's in the draft."
    static let notAllowedFromCar = "I won't allow that one from the car."
    static let stillAnswering = "Still answering the last one."
    static let correctionNotConfirmed =
        "Denied. Couldn't confirm the correction was delivered. Not resending."
    static let notAnsweredFromCar = "I won't answer that one from the car."

    /// The one re-ask after a reply that was no answer.
    static func blockedReask(canAllow: Bool) -> String {
        canAllow
            ? "I didn't catch that. Allow or deny?"
            : "I didn't catch that. Deny, or say what to do instead?"
    }

    // MARK: Briefing

    /// A Host whose Agents the briefing cannot vouch for: no verified
    /// snapshot yet.
    struct UnverifiedHost: Equatable, Sendable {
        enum Condition: Equatable, Sendable {
            case connecting
            case unreachable
        }

        let name: String
        let condition: Condition
    }

    /// The "Talk to Waycar" briefing over the car list's rows. An
    /// unverified Host is named, and "Nothing needs you" is never said
    /// while one is: its Agents are unknown, not quiet.
    static func briefing(rows: [CarPlayListModel.Row], unverifiedHosts: [UnverifiedHost])
        -> String
    {
        let needYou = rows.filter { $0.status == .blocked || $0.status == .done }
        let hostLines = unverifiedHosts.map { host in
            switch host.condition {
            case .connecting: "\(host.name) is still connecting."
            case .unreachable: "I can't reach \(host.name)."
            }
        }
        guard !needYou.isEmpty else {
            return hostLines.isEmpty ? "Nothing needs you." : hostLines.joined(separator: " ")
        }
        let count = needYou.count == 1 ? "One Agent needs you." : "\(needYou.count) Agents need you."
        let lines = needYou.map { row in
            let word = AgentActivityStatusVocabulary.word(for: row.status.rawValue).lowercased()
            return "\(spokenIdentity(row.title)) is \(word)."
        }
        return ([count] + lines + hostLines).joined(separator: " ")
    }

    /// The enabled Hosts without a verified snapshot, by name: unreachable
    /// once their connection failed or stopped, connecting otherwise.
    static func unverifiedHosts(
        _ hosts: [Host], statuses: [Host.ID: EventsSessionStatus], awaitingSnapshot: Set<Host.ID>
    ) -> [UnverifiedHost] {
        hosts.filter(\.isEnabled)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .compactMap { host in
                let status = statuses[host.id]
                if status == .connected, !awaitingSnapshot.contains(host.id) { return nil }
                switch status {
                case .failed, .suspended, .ended:
                    return UnverifiedHost(name: host.displayName, condition: .unreachable)
                case .connecting, .connected, .reconnecting, nil:
                    return UnverifiedHost(name: host.displayName, condition: .connecting)
                }
            }
    }

    /// `iOS App · Claude` reads as "iOS App Claude".
    static func spokenIdentity(_ title: String) -> String {
        title.replacingOccurrences(of: " · ", with: " ")
    }

    /// `text` folded to one line and ending in sentence punctuation, so a
    /// line that follows it is heard as a new sentence.
    static func sentence(_ text: String) -> String {
        let line = foldedLine(text)
        guard let last = line.last, !".?!".contains(last) else { return line }
        return line + "."
    }
}
