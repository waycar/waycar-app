import Foundation

/// The shared tmux pane option v1 vectors from `plugin/test-vectors/`, the
/// single source of truth for the `@waycar_*` pane options the host tools
/// write and the app reads (design §4.6). Bundled into the test target as a
/// resource so the Node plugin tests and these tests run the same cases.
struct TmuxPaneOptionsVectorFile: Decodable, Sendable {
    let paneCases: [PaneCase]

    struct PaneCase: Decodable, Sendable, CustomStringConvertible {
        let name: String
        /// Pane-level `@waycar_*` options as tmux reads them back; absent = unset.
        let options: [String: String]
        let expected: Expected
        var description: String { name }
    }

    struct Expected: Decodable, Sendable {
        let agentStatus: String
        let agentKind: String?
        let sessionID: String?
        let transcriptPath: String?
        /// Decimal string: nanoseconds exceed a double's integers.
        let stateChangeSeq: String?
    }

    static let shared: TmuxPaneOptionsVectorFile = {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "tmux-pane-options-v1", withExtension: "json")
        else {
            fatalError("tmux-pane-options-v1.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(
                TmuxPaneOptionsVectorFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("shared tmux pane option vectors failed to load: \(error)")
        }
    }()

    private final class BundleLocator {}
}
