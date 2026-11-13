import Foundation

/// The shared chat transcript reader vectors from `plugin/test-vectors/`, the
/// single source of truth for the reader's NDJSON across the Node plugin and
/// this app. The JSON file is bundled into the test target as a resource so
/// the Swift decoder reads exactly the output the Node reader is held to.
/// Swift only consumes each case's `expected` lines; the transcripts and
/// reader arguments are the Node suite's input.
struct ChatTranscriptVectorFile: Decodable, Sendable {
    let version: Int
    let cases: [Case]

    struct Case: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let kind: String
        /// The reader's output, one NDJSON line each: header first.
        let expected: [String]
        var description: String { name }
    }

    static let shared: ChatTranscriptVectorFile = {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "chat-transcript-v1", withExtension: "json")
        else {
            fatalError("chat-transcript-v1.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(
                ChatTranscriptVectorFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("shared chat transcript vectors failed to load: \(error)")
        }
    }()

    private final class BundleLocator {}
}
