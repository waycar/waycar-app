import Foundation

/// The shared Agent Summary store v1 vectors from `plugin/test-vectors/`:
/// raw records as the plugin writes them and what the app must read from
/// each, `progress` included (#189). Bundled into the test target as a
/// resource so the Node plugin tests and these tests run the same cases.
struct AgentSummaryStoreVectorFile: Decodable, Sendable {
    let cases: [Case]

    struct Case: Decodable, Sendable, CustomStringConvertible {
        let name: String
        /// One store file's contents, possibly malformed.
        let line: String
        /// Nil when the reader must drop the line.
        let expected: Expected?
        var description: String { name }
    }

    struct Expected: Decodable, Sendable {
        let pane: String
        let status: String
        let summary: String
        let ts: Int64
        let progress: Progress?
        /// When the progress was last refreshed; nil when the line has none
        /// or no progress survives.
        let progressTS: Int64?
        /// Whether the line carried the `progress` key at all.
        let declaresProgress: Bool

        private enum CodingKeys: String, CodingKey {
            case pane, status, summary, ts, progress
            case progressTS = "progress_ts"
            case declaresProgress = "declares_progress"
        }
    }

    /// The reader's normalized estimate: only the halves that survive.
    struct Progress: Decodable, Sendable {
        let done: Int?
        let total: Int?
        let phase: String?
    }

    static let shared: AgentSummaryStoreVectorFile = {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "agent-summary-store-v1", withExtension: "json")
        else {
            fatalError("agent-summary-store-v1.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(
                AgentSummaryStoreVectorFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("shared Agent Summary store vectors failed to load: \(error)")
        }
    }()

    private final class BundleLocator {}
}
