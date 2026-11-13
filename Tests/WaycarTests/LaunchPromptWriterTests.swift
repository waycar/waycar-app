import Foundation
import Testing

@testable import Waycar

// Launch Prompt Files reach the Host through one `/bin/sh` exec whose
// arguments ride the SSH command line and whose bytes ride stdin. The real
// script runs in `WaycarSSHTransportBehaviorE2ETests`; these pin what Swift
// controls: the Codex profile's TOML, what the exec sends, and how its
// answer is trusted.
@Suite("Launch Prompt Files writer")
struct LaunchPromptWriterTests {
    // MARK: Codex profile TOML

    @Test("the Codex profile holds the prompt as one developer_instructions basic string")
    func profileIsOneDeveloperInstructionsLine() {
        #expect(
            CodexProfileTOML.render(developerInstructions: "Be brief.")
                == "developer_instructions = \"Be brief.\"\n")
    }

    @Test(
        "TOML escaping keeps every prompt character",
        arguments: [
            (#"Say "hi""#, #""Say \"hi\"""#),
            (#"C:\dir\"#, #""C:\\dir\\""#),
            ("a\nb\tc\rd", #""a\nb\tc\rd""#),
            ("\r\n", #""\r\n""#),
            ("\u{08}\u{0C}", #""\b\f""#),
            ("\u{00}\u{01}\u{1B}\u{1F}\u{7F}", #""\u0000\u0001\u001B\u001F\u007F""#),
            ("émoji 🚗 漢字 \u{200B}", "\"émoji 🚗 漢字 \u{200B}\""),
            ("'''", #""'''""#),
            ("\"\"\"", #""\"\"\"""#),
            ("$(id) `id` ${HOME}", #""$(id) `id` ${HOME}""#),
        ])
    func tomlEscaping(prompt: String, expected: String) {
        #expect(CodexProfileTOML.basicString(prompt) == expected)
    }

    @Test("no control character reaches the TOML unescaped")
    func everyControlCharacterIsEscaped() {
        let controls =
            (0..<0x20).compactMap { Unicode.Scalar(UInt32($0)) } + [Unicode.Scalar(UInt8(0x7F))]
        var prompt = ""
        prompt.unicodeScalars.append(contentsOf: controls)
        let rendered = CodexProfileTOML.render(developerInstructions: prompt)
        let body = rendered.dropLast()
        #expect(body.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
        #expect(rendered.last == "\n")
    }

    // MARK: Writer command

    private static let profileName = "waycar-1f2e3d4c-5b6a-4789-8abc-def012345678"

    @Test("one exec carries every file: counts and names as arguments, bytes on stdin")
    func planCarriesEveryFile() throws {
        let chat = LaunchPromptFile(
            destination: .stageDirectory, name: "chat-prompt.md", contents: "Ünïcode prompt")
        let first = LaunchPromptFile(
            destination: .stageDirectory, name: "first-message.md", contents: "Fix it.\n")
        let profile = LaunchPromptFile(
            destination: .codexProfile, name: Self.profileName, contents: "Say \"ok\"")
        let toml = Data(CodexProfileTOML.render(developerInstructions: profile.contents).utf8)

        let plan = try LaunchPromptWriter.plan(
            for: [chat, first, profile], codexHome: "/Users/me/Library/Application Support/codex")

        let prefix = "/bin/sh -c '\(LaunchPromptWriter.script)' waycar-launch-prompts "
            + "'/Users/me/Library/Application Support/codex' "
        #expect(plan.command.hasPrefix(prefix))
        #expect(
            plan.command.dropFirst(prefix.count).split(separator: " ")
                == ["s:16:chat-prompt.md", "s:8:first-message.md", "c:\(toml.count):\(Self.profileName)"])
        #expect(plan.input == Data(chat.contents.utf8) + Data(first.contents.utf8) + toml)
    }

    @Test("the script is one single-quoted word, so no Host shell sees its body")
    func scriptHasNoSingleQuote() {
        #expect(!LaunchPromptWriter.script.contains("'"))
        let probe = LaunchPromptWriter.capabilityProbeCommand
        let wrap = "/bin/sh -c '"
        #expect(probe.hasPrefix(wrap) && probe.hasSuffix("'"))
        #expect(!probe.dropFirst(wrap.count).dropLast().contains("'"))
    }

    @Test(
        "stage file names must be plain Waycar constants, nested only in plain directories",
        arguments: [
            "", ".", "..", "a b", "a'b", "chat;rm", "née.md", "/a", "a/", "a//b", "../a", "a/../b",
            "a/./b",
        ])
    func refusesUnplainStageNames(name: String) {
        #expect(throws: LaunchPromptStagingError.invalidFile) {
            try LaunchPromptWriter.plan(
                for: [LaunchPromptFile(destination: .stageDirectory, name: name, contents: "x")],
                codexHome: nil)
        }
    }

    /// Copilot reads its instructions only from `.github/instructions/`
    /// under the staged directory: the writer takes the nested name and the
    /// stage directory it reports is the `waycar.*` one, not a subdirectory.
    @Test func aNestedStageNameIsAcceptedAndStagedUnderTheStageDirectory() throws {
        let file = LaunchPromptFile(
            destination: .stageDirectory, name: LaunchPromptStager.copilotInstructionsFileName, contents: "x")
        let plan = try LaunchPromptWriter.plan(for: [file], codexHome: nil)
        #expect(plan.command.hasSuffix(" s:1:\(file.name)"))
        let staged = try LaunchPromptWriter.stagedFiles(
            [file],
            from: Data("\(LaunchPromptWriter.pathOutputPrefix)/tmp/waycar.Ab3dE9gH/\(file.name)\n".utf8))
        #expect(staged.map(\.path) == ["/tmp/waycar.Ab3dE9gH/\(file.name)"])
    }

    @Test(
        "Codex profile names must be the waycar-<uuid> the sweep removes",
        arguments: [
            "default", "waycar-", "waycar-review", "waycar-1f2e", "waycar-a/b", "../waycar-x",
            "waycar-1F2E3D4C-5B6A-4789-8ABC-DEF012345678",
            "waycar-1f2e3d4c5b6a47898abcdef012345678",
            "waycar-1f2e3d4c-5b6a-4789-8abc-def012345678.x",
            "1f2e3d4c-5b6a-4789-8abc-def012345678",
        ])
    func refusesUnsweepableProfileNames(name: String) {
        #expect(throws: LaunchPromptStagingError.invalidFile) {
            try LaunchPromptWriter.plan(
                for: [LaunchPromptFile(destination: .codexProfile, name: name, contents: "x")],
                codexHome: "/home/me/.codex")
        }
    }

    @Test(
        "a Codex profile needs an absolute Codex home the Host shell can take quoted",
        arguments: [nil, "", ".codex", "~/.codex", "/home/me/it's", "/home/me/a\\b", "/home/me/a\nb"]
            as [String?])
    func refusesUnusableCodexHome(codexHome: String?) {
        let profile = LaunchPromptFile(
            destination: .codexProfile, name: Self.profileName, contents: "x")
        #expect(throws: LaunchPromptStagingError.unusablePath) {
            try LaunchPromptWriter.plan(for: [profile], codexHome: codexHome)
        }
    }

    @Test("a launch without a Codex profile needs no Codex home")
    func stageFilesNeedNoCodexHome() {
        let chat = LaunchPromptFile(destination: .stageDirectory, name: "chat-prompt.md", contents: "x")
        #expect(throws: Never.self) {
            try LaunchPromptWriter.plan(for: [chat], codexHome: nil)
        }
    }

    @Test("a repeated name would overwrite its twin, so it is refused")
    func refusesRepeatedNames() {
        for destination in [LaunchPromptFile.Destination.stageDirectory, .codexProfile] {
            let file = LaunchPromptFile(destination: destination, name: Self.profileName, contents: "x")
            #expect(throws: LaunchPromptStagingError.invalidFile) {
                try LaunchPromptWriter.plan(for: [file, file], codexHome: "/home/me/.codex")
            }
        }
    }

    // MARK: Writer answer

    private static let files = [
        LaunchPromptFile(destination: .stageDirectory, name: "chat-prompt.md", contents: "a"),
        LaunchPromptFile(destination: .stageDirectory, name: "first-message.md", contents: "b"),
        LaunchPromptFile(destination: .codexProfile, name: profileName, contents: "c"),
    ]

    private static func answer(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    @Test("each file gets the path the Host printed for it, past any login-shell chatter")
    func stagedPathsFollowTheHost() throws {
        let prefix = LaunchPromptWriter.pathOutputPrefix
        let staged = try LaunchPromptWriter.stagedFiles(
            Self.files,
            from: Self.answer([
                "Welcome to the Host",
                "\(prefix)/tmp/waycar.Ab12/chat-prompt.md\r",
                "\(prefix)/tmp/waycar.Ab12/first-message.md",
                "\(prefix)/home/me/.codex/\(Self.profileName).config.toml",
                "",
            ]))
        #expect(
            staged == [
                StagedLaunchPromptFile(file: Self.files[0], path: "/tmp/waycar.Ab12/chat-prompt.md"),
                StagedLaunchPromptFile(
                    file: Self.files[1], path: "/tmp/waycar.Ab12/first-message.md"),
                StagedLaunchPromptFile(
                    file: Self.files[2], path: "/home/me/.codex/\(Self.profileName).config.toml"),
            ])
    }

    /// codex is handed the profile's name, never its path, so a Codex home
    /// under macOS's `Application Support` still takes the file route.
    @Test("a Codex profile path with spaces is accepted")
    func codexProfilePathWithSpacesIsAccepted() throws {
        let path = "/Users/me/Library/Application Support/codex/\(Self.profileName).config.toml"
        let staged = try LaunchPromptWriter.stagedFiles(
            [Self.files[2]], from: Self.answer(["\(LaunchPromptWriter.pathOutputPrefix)\(path)"]))
        #expect(staged == [StagedLaunchPromptFile(file: Self.files[2], path: path)])
    }

    @Test(
        "a stage path that cannot ride the launch line unquoted is unusable",
        arguments: [
            "/tmp/my dir/waycar.Ab12/chat-prompt.md",
            "tmp/waycar.Ab12/chat-prompt.md",
            "/tmp/wäycar/waycar.Ab12/chat-prompt.md",
            "/tmp/$x/waycar.Ab12/chat-prompt.md",
        ])
    func unplainPathIsUnusable(path: String) {
        let prefix = LaunchPromptWriter.pathOutputPrefix
        #expect(throws: LaunchPromptStagingError.unusablePath) {
            try LaunchPromptWriter.stagedFiles(
                [Self.files[0]], from: Self.answer(["\(prefix)\(path)"]))
        }
    }

    @Test(
        "an answer that does not account for every file where it belongs is a failed write",
        arguments: [
            // One path short.
            ["/tmp/waycar.Ab12/chat-prompt.md", "/tmp/waycar.Ab12/first-message.md"],
            // Stage files split across two directories.
            [
                "/tmp/waycar.Ab12/chat-prompt.md", "/tmp/waycar.Cd34/first-message.md",
                "/home/me/.codex/\(profileName).config.toml",
            ],
            // Not a Waycar stage directory.
            [
                "/tmp/other/chat-prompt.md", "/tmp/other/first-message.md",
                "/home/me/.codex/\(profileName).config.toml",
            ],
            // Another file's name.
            [
                "/tmp/waycar.Ab12/first-message.md", "/tmp/waycar.Ab12/chat-prompt.md",
                "/home/me/.codex/\(profileName).config.toml",
            ],
            // The profile without its `.config.toml`.
            [
                "/tmp/waycar.Ab12/chat-prompt.md", "/tmp/waycar.Ab12/first-message.md",
                "/home/me/.codex/\(profileName)",
            ],
            // The profile somewhere relative.
            [
                "/tmp/waycar.Ab12/chat-prompt.md", "/tmp/waycar.Ab12/first-message.md",
                ".codex/\(profileName).config.toml",
            ],
        ])
    func mismatchedAnswerIsAFailedWrite(paths: [String]) {
        let prefix = LaunchPromptWriter.pathOutputPrefix
        #expect(throws: LaunchPromptStagingError.writeFailed) {
            try LaunchPromptWriter.stagedFiles(
                Self.files, from: Self.answer(paths.map { "\(prefix)\($0)" }))
        }
    }

    // MARK: Capabilities

    private static func probeOutput(digits: String, codexHome: String?) -> Data {
        var text = "motd\n\(LaunchPromptWriter.capabilitiesOutputPrefix)\(digits)\r\n"
        if let codexHome { text += "\(LaunchPromptWriter.codexHomeOutputPrefix)\(codexHome)\n" }
        return Data(text.utf8)
    }

    @Test(
        "the probe's two digits are Claude's and Codex's routes",
        arguments: [
            ("11", LaunchPromptCapabilities(claudeAppendSystemPromptFile: true, codexProfileFile: true)),
            ("10", LaunchPromptCapabilities(claudeAppendSystemPromptFile: true, codexProfileFile: false)),
            ("01", LaunchPromptCapabilities(claudeAppendSystemPromptFile: false, codexProfileFile: true)),
            ("00", LaunchPromptCapabilities.none),
        ])
    func probeAnswer(digits: String, expected: LaunchPromptCapabilities) {
        let answer = LaunchPromptWriter.probeAnswer(
            from: Self.probeOutput(digits: digits, codexHome: "/home/me/.codex"))
        #expect(answer == LaunchPromptWriter.ProbeAnswer(capabilities: expected, codexHome: "/home/me/.codex"))
    }

    @Test(
        "the Codex home the panes resolve may hold spaces",
        arguments: ["/Users/me/Library/Application Support/codex", "/home/me/.codex/"])
    func probedCodexHomeIsKept(codexHome: String) {
        let answer = LaunchPromptWriter.probeAnswer(
            from: Self.probeOutput(digits: "11", codexHome: codexHome))
        #expect(answer?.codexHome == codexHome)
        #expect(answer?.capabilities.codexProfileFile == true)
    }

    /// Without a Codex home Waycar could write to, a profile could never be
    /// staged, so Codex takes the inline route instead.
    @Test(
        "no usable Codex home turns Codex's file route off",
        arguments: [nil, "", "relative/.codex", "/home/me/it's"] as [String?])
    func unusableCodexHomeTurnsTheRouteOff(codexHome: String?) {
        let answer = LaunchPromptWriter.probeAnswer(
            from: Self.probeOutput(digits: "11", codexHome: codexHome))
        #expect(
            answer
                == LaunchPromptWriter.ProbeAnswer(
                    capabilities: LaunchPromptCapabilities(
                        claudeAppendSystemPromptFile: true, codexProfileFile: false),
                    codexHome: nil))
    }

    @Test("a probe answer Waycar cannot read is no answer", arguments: ["", "1", "111", "1x"])
    func unreadableProbeAnswer(digits: String) {
        #expect(
            LaunchPromptWriter.probeAnswer(
                from: Self.probeOutput(digits: digits, codexHome: "/home/me/.codex")) == nil)
        #expect(LaunchPromptWriter.probeAnswer(from: Data("claude\n".utf8)) == nil)
    }
}
