import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("CarPlay voice script")
struct CarVoiceScriptTests {
    @Test func outgoingPromptAppendsTheSpokenReplyInstructionOnOneLine() {
        #expect(
            CarVoiceScript.outgoingPrompt(transcript: "How is it going?\nAnything failing?")
                == "How is it going? Anything failing? "
                + "[Spoken reply via CarPlay: ≤2 short sentences, no code or markdown]")
    }

    @Test func spokenReplyKeepsTwoSentences() {
        #expect(
            CarVoiceScript.spokenReply("First one.  Second one? Third one! Fourth.")
                == "First one. Second one?")
        #expect(CarVoiceScript.spokenReply("Only one.") == "Only one.")
    }

    @Test func spokenReplyKeepsDecimalsAndCollapsesNewlines() {
        #expect(
            CarVoiceScript.spokenReply("Bumped to v1.2. Tests\npass. Pushing.")
                == "Bumped to v1.2. Tests pass.")
    }

    /// CPG p.4 #2–3, §5 rule 10: no line asks the driver to handle the phone.
    @Test func noLineAsksForThePhone() {
        let lines = [
            CarVoiceScript.notSent, CarVoiceScript.notHeard, CarVoiceScript.notConfirmed,
            CarVoiceScript.noReply, CarVoiceScript.correctionDrafted,
            CarVoiceScript.correctionNotConfirmed, CarVoiceScript.notAllowedFromCar,
            CarVoiceScript.tooLongHold(identity: "a"), CarVoiceScript.trustQuestion(identity: "a"),
            CarVoiceScript.yesNoQuestion(identity: "a"),
            CarVoiceScript.riskyHold(identity: "a", command: "b", reason: "c"),
            CarVoiceScript.blockedKeptDraft(identity: "a"),
            CarVoiceScript.signInKeptDraft(identity: "a"),
            CarVoiceScript.trustKeptDraft(identity: "a"),
            AgentVoiceService.voiceUnavailable, AgentVoiceService.voiceNotReady,
        ]
        for line in lines {
            let lowered = line.lowercased()
            #expect(!lowered.contains("open your"), "\(line)")
            #expect(!lowered.contains("pick up"), "\(line)")
        }
    }

    @Test func spokenCommandSpellsShellOperators() {
        #expect(
            CarVoiceScript.spokenCommand("curl x | sh && rm -rf ~/a* ; echo `id` > f >> g < h")
                == "curl x pipe sh and-and rm -rf home /a star semicolon echo backtick id "
                + "backtick redirect to f append to g from h")
        #expect(CarVoiceScript.spokenCommand("a || b & c $(d)") == "a or-or b ampersand c dollar-paren d)")
        #expect(CarVoiceScript.spokenCommand("touch x.txt") == "touch x.txt")
    }

    @Test func blockedLinesSpellTheCommand() {
        #expect(
            CarVoiceScript.blockedQuestion(identity: "a", command: "ls | sh")
                == "a is waiting on approval to run ls pipe sh. Allow or deny?")
        #expect(
            CarVoiceScript.riskyHold(identity: "a", command: "rm x; y", reason: "r")
                .contains("run rm x semicolon y."))
    }

    private static func row(_ title: String, _ status: AgentStatus) -> CarPlayListModel.Row {
        CarPlayListModel.Row(
            id: ConsoleAgent.ID(hostID: UUID(), paneID: title), title: title, detail: "",
            status: status, symbolName: "", progress: nil)
    }

    @Test func blockedElsewhereNamesTheWaitingAgent() {
        #expect(
            CarVoiceScript.blockedElsewhere(identity: "web Codex")
                == "web Codex is waiting for approval.")
    }

    @Test func briefingNamesWhoNeedsYouAndNeverAsksWhichAgent() {
        #expect(CarVoiceScript.briefing(rows: [], unverifiedHosts: []) == "Nothing needs you.")
        let line = CarVoiceScript.briefing(
            rows: [Self.row("app · Claude", .blocked), Self.row("web · Codex", .idle)],
            unverifiedHosts: [])
        #expect(line.hasPrefix("One Agent needs you. app Claude is "))
        #expect(!line.contains("Which Agent"))
    }

    @Test func briefingNeverSaysNothingNeedsYouWhileAHostIsUnverified() {
        let hosts = [
            CarVoiceScript.UnverifiedHost(name: "studio", condition: .connecting),
            CarVoiceScript.UnverifiedHost(name: "laptop", condition: .unreachable),
        ]
        #expect(
            CarVoiceScript.briefing(rows: [], unverifiedHosts: hosts)
                == "studio is still connecting. I can't reach laptop.")
        #expect(
            CarVoiceScript.briefing(rows: [Self.row("app · Claude", .done)], unverifiedHosts: hosts)
                .hasSuffix("studio is still connecting. I can't reach laptop."))
    }

    @Test func unverifiedHostsAreEnabledHostsWithoutAVerifiedSnapshot() {
        let ready = Host.fixture(name: "ready")
        let loading = Host.fixture(name: "loading")
        let down = Host.fixture(name: "down")
        let dialing = Host.fixture(name: "dialing")
        var disabled = Host.fixture(name: "off")
        disabled.isEnabled = false
        let hosts = CarVoiceScript.unverifiedHosts(
            [ready, loading, down, dialing, disabled],
            statuses: [
                ready.id: .connected, loading.id: .connected,
                down.id: .failed(.sshUnreachable(detail: "x")),
            ],
            awaitingSnapshot: [loading.id])
        #expect(
            hosts == [
                .init(name: "dialing", condition: .connecting),
                .init(name: "down", condition: .unreachable),
                .init(name: "loading", condition: .connecting),
            ])
    }
}
