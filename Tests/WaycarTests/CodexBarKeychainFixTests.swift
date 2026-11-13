import Foundation
import Testing

@testable import Waycar

/// The Keychain Fix's Agent prompt stays one plain line with no tab, quote,
/// `$`, `!` or backtick, though it now reaches the Agent as a Launch Prompt
/// File. Host and provider names come from the user and CodexBar, so none
/// of them may break that.
@Suite("CodexBar Keychain Fix prompt")
struct CodexBarKeychainFixTests {
    private static let unsafeCharacters: [Character] = ["\n", "\t", "\"", "'", "`", "$", "!"]

    private static func blockedProvider(displayName: String, providerID: String) -> AIUsageProvider {
        AIUsageProvider(
            id: providerID, providerID: providerID, displayName: displayName, account: nil,
            windows: [], errorMessage: "No Claude session key found in browser cookies.")
    }

    @Test(arguments: [CodexBarKeychainFix.Problem.keychainBlocked, .serverTimedOut])
    func agentPromptIsOneSafeLineWhateverTheNames(problem: CodexBarKeychainFix.Problem) {
        let unsafePath = "/Users/me/My Apps/codexbar"
        let prompt = CodexBarKeychainFix.agentPrompt(
            hostName: "Mike's \"Studio\"\t$HOME!`whoami`",
            problem: problem,
            providers: [Self.blockedProvider(displayName: "Clau\nde", providerID: "cla\"ude")],
            codexBarPath: unsafePath)

        for character in Self.unsafeCharacters {
            #expect(!prompt.contains(character), "prompt contains \(character.debugDescription)")
        }
        // A path that would not read the same on the Host is left for the
        // Agent to look up, never handed over mangled.
        #expect(!prompt.contains(unsafePath))
        // The Agent can only set up what the app then reads.
        #expect(prompt.contains(CodexBarServe.launchAgentLabel))
        #expect(prompt.contains("127.0.0.1:\(CodexBarServe.port)"))
    }

    @Test(arguments: [CodexBarKeychainFix.Problem.keychainBlocked, .serverTimedOut])
    func agentPromptNamesAPlainCodexBarPathVerbatim(problem: CodexBarKeychainFix.Problem) {
        let path = "/opt/homebrew/bin/codexbar"
        let prompt = CodexBarKeychainFix.agentPrompt(
            hostName: "Studio",
            problem: problem,
            providers: [Self.blockedProvider(displayName: "Claude", providerID: "claude")],
            codexBarPath: path)

        #expect(prompt.contains(path))
        // CodexBar's default 30-second request timeout leaves Claude's CLI
        // fetch (31 s on one Mac) too little time.
        #expect(prompt.contains(
            "serve, --port, \(CodexBarServe.port), --request-timeout, \(CodexBarServe.requestTimeoutSeconds)"))
        for character in Self.unsafeCharacters {
            #expect(!prompt.contains(character), "prompt contains \(character.debugDescription)")
        }
    }

    /// An existing helper that timed out is updated, not set up again: the
    /// Agent rewrites only Waycar's own LaunchAgent, and leaves one that
    /// already has the timeout alone.
    @Test func aTimedOutHelperIsUpdatedOnlyWhenItIsWaycarsAndStillShort() {
        let prompt = CodexBarKeychainFix.agentPrompt(
            hostName: "Studio", problem: .serverTimedOut,
            providers: [Self.blockedProvider(displayName: "Claude", providerID: "claude")],
            codexBarPath: "/opt/homebrew/bin/codexbar")
        let keychain = CodexBarKeychainFix.agentPrompt(
            hostName: "Studio", problem: .keychainBlocked,
            providers: [Self.blockedProvider(displayName: "Claude", providerID: "claude")],
            codexBarPath: "/opt/homebrew/bin/codexbar")
        let timeout = CodexBarServe.requestTimeoutSeconds

        #expect(prompt.contains("for Claude that helper answers usage timed out"))
        // Another codexbar serve on the port, even beside a stale plist, is
        // left alone: reloading Waycar's would start a second server.
        #expect(prompt.contains(
            "If that plist does not exist, or the process listening on the port is not the pid "
                + "launchctl print reports, the helper was not set up by Waycar: change nothing"))
        #expect(prompt.contains("already pass --request-timeout \(timeout) or more, change nothing"))
        #expect(!prompt.contains("cannot open the login keychain"))
        #expect(keychain.contains("cannot open the login keychain"))
        #expect(!keychain.contains("the helper was not set up by Waycar"))
    }

    /// The confirmed fix opens New Agent locked to the blocked Host with the
    /// prompt attached; the preset carries no quick chat, so it can't
    /// auto-start.
    @Test func presetLocksTheGivenHostAndCarriesTheAgentPrompt() {
        let hostID = UUID()
        let providers = [Self.blockedProvider(displayName: "Claude", providerID: "claude")]
        let path = "/opt/homebrew/bin/codexbar"
        let preset = CodexBarKeychainFix.preset(
            hostID: hostID, hostName: "Studio", problem: .serverTimedOut, providers: providers,
            codexBarPath: path)

        #expect(preset.hostID == hostID)
        #expect(preset.locksHost)
        #expect(preset.firstMessage == CodexBarKeychainFix.agentPrompt(
            hostName: "Studio", problem: .serverTimedOut, providers: providers, codexBarPath: path))
        #expect(preset.suggestedName == "fix-ai-usage")
        #expect(preset.title == "Fix AI Usage")
    }
}
