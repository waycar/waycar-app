import Foundation
import Testing

@testable import Waycar

@Suite("tmux error mapping")
struct TmuxErrorsTests {
    @Test func missingObjectsMapToHerdrCodes() {
        #expect(TmuxErrors.apiError("can't find pane: %999")
            == HerdrAPIError(code: "pane_not_found", message: "can't find pane: %999"))
        #expect(TmuxErrors.apiError("can't find window: @999").code == "tab_not_found")
        #expect(TmuxErrors.apiError("can't find window: 9").code == "tab_not_found")
        #expect(TmuxErrors.apiError("can't find session: $999").code == "workspace_not_found")
        #expect(TmuxErrors.apiError("can't find session: nosuch\n").message == "can't find session: nosuch")
    }

    @Test func everythingElseIsATmuxErrorWithTmuxsText() {
        #expect(TmuxErrors.apiError("duplicate session: a")
            == HerdrAPIError(code: "tmux_error", message: "duplicate session: a"))
        #expect(TmuxErrors.apiError("parse error: unknown command: bogus-command").code == "tmux_error")
        #expect(TmuxErrors.apiError("can't find buffer: b").code == "tmux_error")
    }

    @Test func recordedErrorRepliesMap() {
        var parser = TmuxControlParser()
        let messages = parser.feed(TmuxTranscripts.data(TmuxTranscripts.errors))
        let codes = messages.compactMap { message -> String? in
            guard case .reply(let reply) = message, reply.isError else { return nil }
            return TmuxErrors.apiError(reply: reply).code
        }
        #expect(codes == ["pane_not_found", "tab_not_found"])
    }

    @Test func serverLossIsATransportError() {
        #expect(TmuxErrors.transportError("no server running on /tmp/tmux-501/default")
            == .channelFailed(detail: "tmux: no server running on /tmp/tmux-501/default"))
        #expect(TmuxErrors.transportError(
            "error connecting to /tmp/tmux-501/default (No such file or directory)") != nil)
        #expect(TmuxErrors.transportError("server exited unexpectedly") != nil)
        #expect(TmuxErrors.transportError("lost server") != nil)
        #expect(TmuxErrors.transportError("can't find pane: %1") == nil)
    }

    @Test func aMissingBinaryIsTmuxNotInstalled() {
        for text in [
            "bash: tmux: command not found",
            "sh: 1: tmux: not found",
            "zsh:1: command not found: tmux",
            "fish: Unknown command: tmux",
        ] {
            #expect(TmuxErrors.transportError(text) == .tmuxNotInstalled, "\(text)")
        }
    }

    @Test func errorPrefersTheTransportMeaning() {
        #expect(TmuxErrors.error("lost server") as? TransportError == .channelFailed(detail: "tmux: lost server"))
        #expect(TmuxErrors.error("can't find pane: %2") as? HerdrAPIError
            == HerdrAPIError(code: "pane_not_found", message: "can't find pane: %2"))
    }
}
