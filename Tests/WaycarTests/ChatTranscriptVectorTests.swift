import Foundation
import Testing

@testable import Waycar

/// Decoder tests for the chat transcript reader's NDJSON, driven by the
/// shared vectors in `plugin/test-vectors/chat-transcript-v1.json`: the same
/// output the Node reader is held to, so the two sides cannot drift. Each
/// case's `expected` lines are decoded by `ChatTranscriptDecoding` and
/// checked against the same lines read as plain JSON.
@Suite("Chat transcript vectors")
struct ChatTranscriptVectorTests {
    private static let vectors = ChatTranscriptVectorFile.shared

    /// Guards against silently loading an empty or truncated vector file.
    @Test func sharedVectorFileHasCases() {
        #expect(Self.vectors.version == 1)
        #expect(Self.vectors.cases.count > 0)
        #expect(Set(Self.vectors.cases.map(\.name)).count == Self.vectors.cases.count)
    }

    /// Every harness that can attach tool-result images has a case that does.
    @Test func sharedVectorFileCoversMediaPerHarness() throws {
        let kindsWithMedia = try Set(
            Self.vectors.cases.filter { vector in
                try vector.expected.contains { line in
                    try !(JSONDecoder().decode(ExpectedLine.self, from: Data(line.utf8)).media ?? []).isEmpty
                }
            }.map(\.kind))
        #expect(kindsWithMedia.isSuperset(of: ["omp", "pi", "claude", "codex", "opencode"]))
    }

    @Test(arguments: vectors.cases)
    func decodesExpectedOutput(vector: ChatTranscriptVectorFile.Case) throws {
        let expectedLines = vector.expected.map(Self.substitutingPlaceholders)
        let lines = try expectedLines.map { line in
            try JSONDecoder().decode(ExpectedLine.self, from: Data(line.utf8))
        }
        let header = try #require(lines.first)
        #expect(header.type == "header")
        let expectedMessages = lines.dropFirst().filter { $0.type == "message" }

        let snapshot = try ChatTranscriptDecoding.decode(
            Data(expectedLines.joined(separator: "\n").utf8))

        #expect(snapshot.header.kind == vector.kind)
        #expect(snapshot.header.status.rawValue == header.status)
        #expect(snapshot.header.turnOpen == header.turnOpen)
        #expect(snapshot.header.activity == header.activity)
        #expect(snapshot.header.truncated == header.truncated)
        #expect(snapshot.header.transcript == header.transcript)
        #expect(snapshot.header.afterFound == header.afterFound)
        #expect(snapshot.header.error == header.error)
        #expect(snapshot.messages.count == expectedMessages.count)
        for (message, expected) in zip(snapshot.messages, expectedMessages) {
            #expect(message.id == expected.id)
            #expect(message.role.rawValue == expected.role)
            #expect(message.text == expected.text)
            let timestamp = try #require(expected.ts)
            #expect(message.timestamp == ChatModeTimestamp.date(from: timestamp))
            #expect(message.timestamp != nil)
            let expectedMedia = try (expected.media ?? []).map { try #require($0.media) }
            #expect(message.media == expectedMedia)
        }
    }

    /// Media paths in the vectors are placeholders the Node side fills with
    /// its temp dir; here they get fixed stand-ins, which need no JSON
    /// escaping.
    private static func substitutingPlaceholders(_ line: String) -> String {
        line.replacingOccurrences(of: "$TRANSCRIPT", with: "/t/session.jsonl")
            .replacingOccurrences(of: "$ROOT", with: "/root")
    }

    /// One expected media item read as plain JSON: exactly one source.
    private struct ExpectedMedia: Decodable {
        struct Inline: Decodable {
            let transcript: String?
            let offset: Int?
            let session: String?
            let pointer: String
            let kind: String?

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
            guard let kind = ChatMedia.Kind(rawValue: kind) else { return nil }
            switch (path, inline) {
            case (let path?, nil) where !path.isEmpty:
                return ChatMedia(id: id, kind: kind, mime: mime, source: .hostFile(path: path))
            case (nil, let inline?):
                guard let source = inline.source else { return nil }
                return ChatMedia(id: id, kind: kind, mime: mime, source: source)
            default:
                return nil
            }
        }
    }

    /// One expected line read as plain JSON, independent of the app decoder.
    private struct ExpectedLine: Decodable {
        let type: String
        let status: String?
        let transcript: String?
        let activity: String?
        let turnOpen: Bool?
        let truncated: Bool?
        let afterFound: Bool?
        let error: String?
        let id: String?
        let role: String?
        let text: String?
        let ts: String?
        let media: [ExpectedMedia]?

        private enum CodingKeys: String, CodingKey {
            case type, status, transcript, activity
            case turnOpen = "turn_open"
            case truncated, afterFound = "after_found", error
            case id, role, text, ts, media
        }
    }
}
