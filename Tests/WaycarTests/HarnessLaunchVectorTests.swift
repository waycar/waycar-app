import Foundation
import Testing

@testable import Waycar

/// The real launch builders against `plugin/test-vectors/harness-launch-v1.json`,
/// the launches the lab suite replays against real harnesses: every case's
/// argv, pane environment and staged files must come out exactly.
@Suite("Harness launch vectors")
struct HarnessLaunchVectorTests {
    private static let vectors = HarnessLaunchVectors.shared

    /// Guards against silently loading an empty or truncated vector file:
    /// every Chat Mode kind has a launch, and every kind a resume.
    @Test func everyKindIsCovered() {
        let kinds = Set(Self.vectors.cases.map(\.kind))
        #expect(Set(SupportedAgentKind.allCases.filter(\.supportsChatMode)).isSubset(of: kinds))
        #expect(kinds.isSuperset(of: [.cursor, .devin, .kiro]))
        #expect(Self.vectors.cases.count >= 50)
    }

    @Test(arguments: vectors.cases)
    func theBuildersProduceTheVector(_ vector: HarnessLaunchVectors.Case) throws {
        let profileID = try #require(UUID(uuidString: Self.vectors.profileID))
        let user = vector.userArgumentsWithResume
        // Every fresh launch pins where its kind can, Chat Mode or not.
        let pin =
            vector.isResume
            ? nil : ChatModeLaunch.sessionPin(kind: vector.kind, userArguments: user, makeID: { vector.input.sessionPin ?? UUID() })
        #expect(pin == vector.input.sessionPin)
        let plan = LaunchPromptStager.plan(
            kind: vector.kind, chatOptions: vector.chatOptions, sessionPin: pin, userArguments: user,
            initialPrompt: vector.input.firstMessage,
            capabilities: LaunchPromptCapabilities(claudeAppendSystemPromptFile: true, codexProfileFile: true),
            backend: vector.backend,
            home: LaunchPromptStager.needsHome(kind: vector.kind, userArguments: user) ? HarnessLaunchVectors.home : nil,
            isResume: vector.isResume, makeID: { profileID })
        let staged = plan.files.map { file in
            StagedLaunchPromptFile(
                file: file,
                path: file.destination == .stageDirectory
                    ? "\(HarnessLaunchVectors.stage)/\(file.name)"
                    : "\(HarnessLaunchVectors.codexHome)/\(file.name).config.toml")
        }
        let command = try plan.command(staged: staged)
        let expected = vector.expected.resolved()

        #expect([vector.kind.executable] + command.arguments == expected.argv)
        #expect(command.environment == expected.environment)
        #expect(
            staged.map { staged in
                HarnessLaunchVectors.Expected.File(
                    path: staged.path,
                    contents: staged.file.destination == .codexProfile
                        ? CodexProfileTOML.render(developerInstructions: staged.file.contents)
                        : staged.file.contents)
            } == expected.files)
    }

    /// The Swift kind catalog and the plugin's agree on every kind id and
    /// its order (`plugin/test-vectors/agent-kinds-v1.json`; the plugin
    /// suite holds `AGENT_IDS` and the Status Hook kinds to the same file).
    @Test func theKindCatalogMatchesTheSharedVector() throws {
        struct Catalog: Decodable {
            let version: Int
            let kinds: [String]
        }
        final class BundleLocator {}
        let url = try #require(
            Bundle(for: BundleLocator.self).url(forResource: "agent-kinds-v1", withExtension: "json"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        #expect(catalog.version == 1)
        #expect(SupportedAgentKind.allCases.map(\.rawValue) == catalog.kinds)
    }
}
