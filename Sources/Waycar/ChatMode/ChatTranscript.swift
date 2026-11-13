import Foundation

/// The first line of the plugin's transcript reader output
/// (`plugin/src/chat-read.js`): where the reader looked and what the open
/// turn is doing.
struct ChatTranscriptHeader: Equatable, Sendable {
    enum Status: String, Sendable {
        case ok
        /// No transcript located yet: the harness may not have written one.
        case notFound = "not_found"
        case unsupported
        case error
    }

    let kind: String
    let status: Status
    /// Absolute path of the transcript read, when one was found.
    let transcript: String?
    /// A short status line for the open turn ("Running npm test").
    let activity: String?
    /// The last user prompt has no final reply yet.
    let turnOpen: Bool
    /// Older messages were cut to the reader's message cap.
    let truncated: Bool
    let error: String?
    /// False when the read asked for messages after an id the reader did not
    /// find, and so answered with every message: the list restarted. A
    /// reader that predates the field always found it.
    var afterFound: Bool = true
}

/// One chat bubble: a real user prompt or the final assistant reply of a
/// completed turn. An empty assistant `text` is a turn that ended without
/// a final message. A final reply's `media` are the images the Agent viewed
/// with its tools during that turn, in order.
struct ChatTranscriptMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    /// Stable across reads, so incremental reads merge by id.
    let id: String
    let role: Role
    let text: String
    let timestamp: Date?
    var media: [ChatMedia] = []
    var card: ChatTranscriptCard? = nil
}

struct ChatQuestionOption: Codable, Equatable, Sendable {
    let key: String
    let label: String
    let detail: String?
    let recommended: Bool
}

struct ChatQuestion: Codable, Equatable, Sendable {
    let ref: String
    let text: String
    let kind: String
    let options: [ChatQuestionOption]
}

struct ChatQuestionCard: Codable, Equatable, Sendable {
    let body: String
    let questions: [ChatQuestion]
}

struct ChatBranchPointer: Codable, Equatable, Sendable {
    let conversationId: Int
    let title: String
    let at: Date?
}

struct ChatFailureCard: Codable, Equatable, Sendable {
    let conversationId: Int?
    let title: String?
    let error: String
    let step: String?
}

struct ChatToolStepsSummary: Codable, Equatable, Sendable {
    let count: Int
    let summary: String
}

enum ChatTranscriptCard: Codable, Equatable, Sendable {
    case questions(ChatQuestionCard)
    case branch(ChatBranchPointer)
    case failure(ChatFailureCard)
    case divider(kind: String, label: String)
    case toolSteps(ChatToolStepsSummary)
}

struct ChatTranscriptSnapshot: Equatable, Sendable {
    let header: ChatTranscriptHeader
    /// Oldest first.
    let messages: [ChatTranscriptMessage]
}

enum ChatTranscriptError: Error, Equatable {
    /// The Host's plugin predates the transcript reader.
    case readerUnavailable
    /// The reader's output did not start with a header line.
    case malformedOutput
}

/// What one transcript read asks the Host for. `session*`, `cwd` and
/// `launchedAt` locate the transcript; `status` lets an idle or done Agent
/// complete its turn; `after` limits the answer to newer messages.
struct ChatTranscriptRequest: Equatable, Sendable {
    let paneID: String
    let kind: String
    let sessionKind: String?
    let sessionValue: String?
    let cwd: String?
    let launchedAt: Date?
    let status: AgentStatus?
    let after: String?
}

/// Parses the reader's NDJSON: a header, then messages oldest to newest.
/// Parsing is lenient past the header, like every herdr-facing format here:
/// unknown line types, malformed message lines, unknown roles and unknown
/// fields are skipped rather than failing the read.
enum ChatTranscriptDecoding {
    static func decode(_ data: Data) throws -> ChatTranscriptSnapshot {
        let decoder = JSONDecoder()
        var header: ChatTranscriptHeader?
        var messages: [ChatTranscriptMessage] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.contains(where: { !isJSONWhitespace($0) }) else { continue }
            let wire = try? decoder.decode(WireLine.self, from: line)
            guard header != nil else {
                guard let wire, wire.type == "header" else { throw ChatTranscriptError.malformedOutput }
                header = ChatTranscriptHeader(
                    kind: wire.kind ?? "",
                    status: wire.status.flatMap(ChatTranscriptHeader.Status.init(rawValue:)) ?? .error,
                    transcript: wire.transcript,
                    activity: wire.activity,
                    turnOpen: wire.turnOpen ?? false,
                    truncated: wire.truncated ?? false,
                    error: wire.error,
                    afterFound: wire.afterFound ?? true)
                continue
            }
            guard let wire, wire.type == "message",
                let id = wire.id, let text = wire.text,
                let role = wire.role.flatMap(ChatTranscriptMessage.Role.init(rawValue:))
            else { continue }
            messages.append(
                ChatTranscriptMessage(
                    id: id, role: role, text: text,
                    timestamp: wire.ts.flatMap(ChatModeTimestamp.date(from:)),
                    media: wire.media?.items ?? []))
        }
        guard let header else { throw ChatTranscriptError.malformedOutput }
        return ChatTranscriptSnapshot(header: header, messages: messages)
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
    }

    /// Every field either line type carries, all optional, so one retyped
    /// field costs that line rather than the read.
    private struct WireLine: Decodable {
        let type: String?
        let kind: String?
        let status: String?
        let transcript: String?
        let activity: String?
        let turnOpen: Bool?
        let truncated: Bool?
        let error: String?
        let afterFound: Bool?
        let id: String?
        let role: String?
        let text: String?
        let ts: String?
        let media: WireMediaList?

        private enum CodingKeys: String, CodingKey {
            case type, kind, status, transcript, activity
            case turnOpen = "turn_open"
            case truncated, error
            case afterFound = "after_found"
            case id, role, text, ts, media
        }
    }

    /// A message's `media` array. Never fails its line: anything but an
    /// array reads as no media, and each item that does not decode, has an
    /// unknown kind, or names no source or both is skipped.
    private struct WireMediaList: Decodable {
        let items: [ChatMedia]

        init(from decoder: any Decoder) throws {
            guard var container = try? decoder.unkeyedContainer() else {
                items = []
                return
            }
            var items: [ChatMedia] = []
            while !container.isAtEnd {
                // `Lenient` always decodes, so the container always advances.
                guard let lenient = try? container.decode(Lenient.self) else { break }
                if let media = lenient.item?.media { items.append(media) }
            }
            self.items = items
        }

        private struct Lenient: Decodable {
            let item: WireMedia?

            init(from decoder: any Decoder) throws {
                item = try? WireMedia(from: decoder)
            }
        }
    }

    /// One wire media item: exactly one of `path` (an absolute Host path),
    /// `inline` in the transcript-line form (a base64 string inside a
    /// transcript line), and `inline` in the session form (a base64 string
    /// inside a session export document: opencode's, or the one `kind`
    /// names, such as `kilo`).
    private struct WireMedia: Decodable {
        struct Inline: Decodable {
            let transcript: String?
            let offset: Int?
            let session: String?
            let pointer: String
            let kind: String?

            /// The source an inline object names, or nil when it is neither
            /// form or both.
            var source: ChatMedia.Source? {
                switch (session, transcript, offset) {
                case (let session?, nil, nil) where !session.isEmpty:
                    .sessionInline(session: session, pointer: pointer, agentKind: kind)
                case (nil, let transcript?, let offset?)
                    where !transcript.isEmpty && offset >= 0:
                    .inline(transcript: transcript, offset: offset, pointer: pointer)
                default:
                    nil
                }
            }
        }

        let id: String
        let kind: String
        let mime: String?
        let path: String?
        let inline: Inline?

        var media: ChatMedia? {
            guard !id.isEmpty, let kind = ChatMedia.Kind(rawValue: kind) else { return nil }
            let source: ChatMedia.Source
            switch (path, inline) {
            case (let path?, nil) where !path.isEmpty:
                source = .hostFile(path: path)
            case (nil, let inline?):
                guard let inlineSource = inline.source else { return nil }
                source = inlineSource
            default:
                return nil
            }
            return ChatMedia(id: id, kind: kind, mime: mime, source: source)
        }
    }
}
