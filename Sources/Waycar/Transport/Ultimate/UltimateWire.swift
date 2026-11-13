import Foundation

struct UltimateConversationSummary: Decodable, Sendable, Equatable {
    let id: Int
    let busy: Bool
    let title: String?
    let label: String?
    let cwd: String?
    let parentConversationId: Int?
    let ownerTaskId: Int?
    let branchOf: Branch?
    let inputAt: Double?
    let answerAt: Double?
    let concluded: Bool?

    struct Branch: Decodable, Sendable, Equatable {
        let conversationId: Int
        let at: Int
    }

    /// A malformed conversation must not hide every other conversation.
    static func decodeList(_ data: Data) throws -> [Self] {
        try JSONDecoder().decode([UltimateLossy<Self>].self, from: data).compactMap(\.value)
    }
}

struct UltimateSubmitRequest: Encodable, Sendable {
    enum WhenBusy: String, Encodable, Sendable { case steer, followUp }
    let text: String
    var whenBusy: WhenBusy = .steer
}

struct UltimateSubmitResponse: Decodable, Sendable {
    let submissionId: Int
}

struct UltimateHistoryResponse: Decodable, Sendable {
    let entries: [UltimateEntry]
    let before: Int?

    private enum CodingKeys: String, CodingKey { case entries, before }
    init(entries: [UltimateEntry], before: Int?) {
        self.entries = entries
        self.before = before
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        entries = try fields.decode([UltimateLossy<UltimateEntry>].self, forKey: .entries).compactMap(\.value)
        before = try fields.decodeIfPresent(Int.self, forKey: .before)
    }
}

/// Stored history is newest-first. Keep its ids for pagination/deduplication;
/// unknown kinds remain decodable but contribute no transcript text.
struct UltimateEntry: Decodable, Sendable {
    let id: Int
    let kind: String
    let model: [JSONValue]?
    let data: JSONValue?

    enum Role: Sendable { case user, assistant, tool }
    struct Text: Sendable {
        let role: Role
        let text: String
    }

    var timestamp: Date? {
        guard case .number(let milliseconds) = model?.first?["timestamp"], milliseconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    var toolCalls: [JSONValue] {
        guard kind == "pi.assistant", model?.first?["role"]?.stringValue == "assistant",
              case .array(let blocks) = model?.first?["content"] else { return [] }
        return blocks.filter { $0["type"]?.stringValue == "toolCall" }
    }

    /// Tool arguments are schema-free on the wire; project only known fields.
    var questionCards: [ChatQuestionCard] {
        toolCalls.compactMap { call in
            guard call["name"]?.stringValue == "message",
                  let args = call["arguments"], args["to"]?.stringValue == "user",
                  case .array(let values) = args["questions"] else { return nil }
            let questions = values.enumerated().compactMap { index, value -> ChatQuestion? in
                guard let text = value["text"]?.stringValue else { return nil }
                var options: [ChatQuestionOption] = []
                if case .array(let items) = value["options"] {
                    options = items.enumerated().compactMap { offset, item in
                        guard let label = item["label"]?.stringValue else { return nil }
                        return ChatQuestionOption(
                            key: item["key"]?.stringValue ?? String(offset + 1), label: label,
                            detail: item["detail"]?.stringValue,
                            recommended: item["recommended"] == .bool(true))
                    }
                }
                return ChatQuestion(ref: value["ref"]?.stringValue ?? String(index + 1),
                                    text: text, kind: value["kind"]?.stringValue ?? "text", options: options)
            }
            guard !questions.isEmpty else { return nil }
            return ChatQuestionCard(body: args["text"]?.stringValue ?? "", questions: questions)
        }
    }

    var storedCard: ChatTranscriptCard? {
        switch kind {
        case "lineage.branched":
            guard let id = Self.positiveID(data?["branch"]) else { return nil }
            return .branch(ChatBranchPointer(conversationId: id,
                title: data?["intent"]?.stringValue ?? "Branch", at: timestamp))
        case "board.asked":
            guard let id = Self.positiveID(data?["from"]) else { return nil }
            return .branch(ChatBranchPointer(conversationId: id,
                title: data?["summary"]?.stringValue ?? "Question", at: timestamp))
        case "watchdog.failure":
            guard let error = data?["error"]?.stringValue else { return nil }
            return .failure(ChatFailureCard(conversationId: Self.positiveID(data?["conversation"]),
                title: data?["title"]?.stringValue, error: error, step: data?["step"]?.stringValue))
        case "pi.reset": return .divider(kind: "reset", label: "Conversation reset")
        case "pi.compaction": return .divider(kind: "compaction", label: "Conversation compacted")
        default: return nil
        }
    }

    private static func positiveID(_ value: JSONValue?) -> Int? {
        guard case .number(let number) = value, number > 0,
              number < Double(Int.max), number.rounded() == number else { return nil }
        return Int(number)
    }

    var extractedText: Text? {
        guard let message = model?.first else { return nil }
        let role: Role
        switch (kind, message["role"]?.stringValue) {
        case ("pi.user", "user"): role = .user
        case ("pi.assistant", "assistant"): role = .assistant
        case ("pi.tool-result", "toolResult"):
            return Text(role: .tool, text: message["toolName"]?.stringValue ?? "Tool")
        default: return nil
        }
        let text: String
        if let content = message["content"]?.stringValue { text = content }
        else if case .array(let blocks) = message["content"] {
            text = blocks.compactMap { block -> String? in
                switch block["type"]?.stringValue {
                case "text": return block["text"]?.stringValue
                case "toolCall": return block["name"]?.stringValue.map { "Tool: \($0)" }
                default: return nil
                }
            }.joined(separator: "\n\n")
        } else { return nil }
        guard !text.isEmpty else { return nil }
        return Text(role: role, text: text)
    }
}

private struct UltimateLossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}
