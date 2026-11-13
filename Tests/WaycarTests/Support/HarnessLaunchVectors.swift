import Foundation

@testable import Waycar

/// The shared harness launch vectors (`plugin/test-vectors/harness-launch-v1.json`):
/// per kind, the launch inputs and exactly the argv, pane environment and
/// staged files the app's builders produce, plus the request the lab mock
/// logged for it (`wire`). Bundled into the test target as a resource, like
/// the chat transcript vectors; `HarnessLaunchVectorTests` holds the real
/// builders to them, and the lab suite replays them against real harnesses.
struct HarnessLaunchVectors: Decodable, Sendable {
    let version: Int
    let profileID: String
    let cases: [Case]

    /// The stand-ins `Expected.resolved` puts for the vectors' placeholders
    /// when no Host's own are given.
    static let stage = "/stage"
    static let home = "/home/you"
    static let codexHome = "/codex-home"

    struct Case: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let kind: SupportedAgentKind
        let input: Input
        let expected: Expected
        let wire: Wire?
        var description: String { name }

        /// The Chat Mode options the launch reads, nil outside Chat Mode.
        var chatOptions: ChatModeLaunchOptions? {
            input.chatPrompt.map {
                ChatModeLaunchOptions(
                    prompt: $0 == HarnessLaunchVectors.defaultChatPromptPlaceholder ? ChatModePrompt.defaultText : $0,
                    model: input.model, quickThinking: input.quickThinking)
            }
        }

        var isResume: Bool { input.resume != nil }

        /// The resume's arguments (`ClosedSession.resumeArguments`) before
        /// the user's own, as `ClosedSessionResumer` passes them.
        var userArgumentsWithResume: [String] {
            guard let resume = input.resume else { return input.userArguments }
            return ClosedSession.resumeArguments(kind: kind, session: resume.reference) + input.userArguments
        }

        var backend: HostBackend { HostBackend(rawValue: input.backend) ?? .herdr }
    }

    struct Input: Decodable, Sendable {
        let chatPrompt: String?
        let model: String?
        let quickThinking: Bool
        let firstMessage: String?
        let userArguments: [String]
        let sessionPin: UUID?
        /// nil: not a resume; `.none`: a resume with no reported session.
        let resume: Resume?
        let backend: String

        enum Resume: Decodable, Sendable {
            case none
            case session(ClosedSession.SessionReference)

            var reference: ClosedSession.SessionReference? {
                if case .session(let reference) = self { return reference }
                return nil
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let word = try? container.decode(String.self), word == "none" {
                    self = .none
                    return
                }
                struct Object: Decodable {
                    let form: ClosedSession.SessionReference.Kind
                    let value: String
                }
                let object = try container.decode(Object.self)
                self = .session(ClosedSession.SessionReference(kind: object.form, value: object.value))
            }
        }
    }

    struct Expected: Decodable, Sendable {
        struct File: Decodable, Sendable, Equatable {
            let path: String
            let contents: String
        }

        /// The executable first, then the `agent.start` arguments.
        let argv: [String]
        let env: [String: String]
        let files: [File]

        /// This case with its placeholders put back: the stage directory,
        /// the Host's `$HOME` and Codex home, and the default Chat Prompt.
        func resolved(
            stage: String = HarnessLaunchVectors.stage, home: String = HarnessLaunchVectors.home,
            codexHome: String = HarnessLaunchVectors.codexHome
        ) -> (argv: [String], environment: [String: String], files: [File]) {
            func fill(_ text: String) -> String {
                text == HarnessLaunchVectors.defaultChatPromptPlaceholder
                    ? ChatModePrompt.defaultText
                    : text.replacingOccurrences(of: "{stage}", with: stage)
                        .replacingOccurrences(of: "{codexHome}", with: codexHome)
                        .replacingOccurrences(of: "{home}", with: home)
            }
            return (
                argv.map(fill), env.mapValues(fill),
                files.map { File(path: fill($0.path), contents: fill($0.contents)) }
            )
        }
    }

    /// What the lab mock (`/_log`) logged for the launch's main request;
    /// nil fields are not asserted.
    struct Wire: Decodable, Sendable, Equatable {
        let model: String?
        let effort: String?
        /// Text of the Chat Prompt the request's system prompt carries.
        let systemContains: String?
        /// Text the first user message carries.
        let firstUserContains: String?

        init(model: String?, effort: String?, systemContains: String?, firstUserContains: String?) {
            self.model = model
            self.effort = effort
            self.systemContains = systemContains
            self.firstUserContains = firstUserContains
        }
    }

    static let defaultChatPromptPlaceholder = "{defaultChatPrompt}"

    static let shared: HarnessLaunchVectors = {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "harness-launch-v1", withExtension: "json")
        else {
            fatalError("harness-launch-v1.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(HarnessLaunchVectors.self, from: Data(contentsOf: url))
        } catch {
            fatalError("harness launch vectors failed to load: \(error)")
        }
    }()

    private final class BundleLocator {}
}
