import Foundation
import Testing

@testable import Waycar

@Suite("tmux control-mode parser")
struct TmuxControlParserTests {
    private func parse(_ transcript: String) -> [TmuxControlMessage] {
        var parser = TmuxControlParser()
        return parser.feed(TmuxTranscripts.data(transcript))
    }

    /// Feeds `data` in `size`-byte chunks.
    private func parse(_ data: Data, chunkSize size: Int) -> [TmuxControlMessage] {
        var parser = TmuxControlParser()
        var messages: [TmuxControlMessage] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + size, data.endIndex)
            messages += parser.feed(data[offset..<end])
            offset = end
        }
        return messages
    }

    private func notifications(_ messages: [TmuxControlMessage]) -> [TmuxNotification] {
        messages.compactMap { message -> TmuxNotification? in
            guard case .notification(let notification) = message else { return nil }
            return notification
        }
    }

    private func replies(_ messages: [TmuxControlMessage]) -> [TmuxReply] {
        messages.compactMap { message -> TmuxReply? in
            guard case .reply(let reply) = message else { return nil }
            return reply
        }
    }

    // MARK: Framing

    @Test func attachReplyCarriesFlagsZeroBeforeItsNotifications() {
        let messages = parse(TmuxTranscripts.attach)
        #expect(messages.first == .reply(TmuxReply(
            commandNumber: 289, flags: 0, lines: [], isError: false)))
        #expect(notifications(messages) == [
            .sessionChanged(sessionID: "$0", name: "alpha"),
            .unlinkedWindowAdd(windowID: "@2"),
            .sessionsChanged,
            .unlinkedWindowRenamed(windowID: "@2", name: "tmux"),
            .unlinkedWindowClose(windowID: "@2"),
            .sessionsChanged,
            .unlinkedWindowRenamed(windowID: "@1", name: "zsh"),
        ])
    }

    @Test func startupRepliesArriveInSendOrderWithRawSeparators() {
        let replies = replies(parse(TmuxTranscripts.startup))
        #expect(replies.map(\.commandNumber) == [310, 311, 312, 313])
        #expect(replies.allSatisfy { $0.flags == 1 && !$0.isError })
        #expect(replies[0].lines == [
            "3.7c attached,focused,control-mode,no-detach-on-destroy,no-output,UTF-8",
        ])
        #expect(replies[1].lines == ["\u{241E}$0\u{241F}\u{241F}alpha", "\u{241E}$1\u{241F}\u{241F}beta"])
        #expect(replies[3].lines == [
            "\u{241E}%0\u{241F}@0\u{241F}$0\u{241F}zsh", "\u{241E}%1\u{241F}@1\u{241F}$1\u{241F}zsh",
        ])
    }

    @Test func everyChunkSizeYieldsTheSameMessages() {
        let transcript = TmuxTranscripts.attach + TmuxTranscripts.startup
            + TmuxTranscripts.subscription + TmuxTranscripts.output
            + TmuxTranscripts.errors + TmuxTranscripts.killServer
        let data = TmuxTranscripts.data(transcript)
        let whole = parse(transcript)
        #expect(whole.count == 58)
        for size in [1, 2, 3, 7, 64, 4096] {
            #expect(parse(data, chunkSize: size) == whole, "chunk size \(size)")
        }
    }

    @Test func aPartialLineWaitsForItsLineFeed() {
        var parser = TmuxControlParser()
        #expect(parser.feed(Data("%begin 1 5 1\nhal".utf8)).isEmpty)
        #expect(parser.feed(Data("f a line\n%end 1 5".utf8)).isEmpty)
        #expect(parser.feed(Data(" 1\n%window-add @".utf8)) == [
            .reply(TmuxReply(commandNumber: 5, flags: 1, lines: ["half a line"], isError: false)),
        ])
        #expect(parser.feed(Data("7\n".utf8)) == [.notification(.windowAdd(windowID: "@7"))])
    }

    @Test func aMultiMegabyteLineSurvivesSmallChunks() {
        let long = String(repeating: "x", count: 2 * 1024 * 1024)
        let data = Data("%begin 1 9 1\n\(long)\n%end 1 9 1\n".utf8)
        let messages = parse(data, chunkSize: 16 * 1024)
        #expect(messages == [
            .reply(TmuxReply(commandNumber: 9, flags: 1, lines: [long], isError: false)),
        ])
    }

    @Test func trailingCarriageReturnsAreIgnored() {
        let messages = parse("%begin 1 3 1\r\nok\r\n%end 1 3 1\r\n%sessions-changed\r\n")
        #expect(messages == [
            .reply(TmuxReply(commandNumber: 3, flags: 1, lines: ["ok"], isError: false)),
            .notification(.sessionsChanged),
        ])
    }

    @Test func blockContentIsVerbatimUntilItsOwnGuard() {
        // A reply line that looks like a notification or another block's
        // guard is content; only `%end` with the same time, number and
        // flags closes the block.
        let messages = parse(
            "%begin 100 7 1\n%window-add @1\n%end 100 8 1\n%begin 1 2 3\n\n%end 100 7 1\n")
        #expect(messages == [
            .reply(TmuxReply(
                commandNumber: 7, flags: 1,
                lines: ["%window-add @1", "%end 100 8 1", "%begin 1 2 3", ""],
                isError: false)),
        ])
    }

    @Test func invalidUTF8DecodesLossily() {
        var parser = TmuxControlParser()
        var bytes = Data("%begin 1 4 1\nab".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append(Data("cd\n%end 1 4 1\n".utf8))
        #expect(parser.feed(bytes) == [
            .reply(TmuxReply(commandNumber: 4, flags: 1, lines: ["ab\u{FFFD}\u{FFFD}cd"], isError: false)),
        ])
    }

    // MARK: Errors

    @Test func errorBlocksAreRepliesMarkedAsErrors() {
        let replies = replies(parse(TmuxTranscripts.errors))
        #expect(replies == [
            TmuxReply(commandNumber: 324, flags: 1, lines: ["can't find pane: %999"], isError: true),
            TmuxReply(commandNumber: 325, flags: 1, lines: ["ok"], isError: false),
            // The line's second command never ran, so it has no block.
            TmuxReply(commandNumber: 326, flags: 1, lines: ["can't find window: @999"], isError: true),
        ])
    }

    @Test func aParseErrorAnswersTheWholeLineOnce() {
        #expect(parse(TmuxTranscripts.parseError) == [
            .reply(TmuxReply(
                commandNumber: 327, flags: 1,
                lines: ["parse error: unknown command: bogus-command"], isError: true)),
        ])
    }

    @Test func noSessionsFailsTheAttachReplyThenExits() {
        #expect(parse(TmuxTranscripts.noSessions) == [
            .reply(TmuxReply(commandNumber: 280, flags: 0, lines: ["no sessions"], isError: true)),
            .notification(.exit(reason: nil)),
        ])
    }

    // MARK: Notifications

    @Test func subscriptionValuesKeepTheirSeparatorBytes() {
        let notifications = notifications(parse(TmuxTranscripts.subscription))
        #expect(notifications == [
            .subscriptionChanged(TmuxSubscriptionChange(
                name: "wc-status", sessionID: "$0", windowID: nil, windowIndex: nil,
                paneID: nil, value: "%0\u{241F}\u{241F}\u{241E}%1\u{241F}\u{241F}\u{241E}")),
            .subscriptionChanged(TmuxSubscriptionChange(
                name: "wc-status", sessionID: "$0", windowID: nil, windowIndex: nil,
                paneID: nil, value: "%0\u{241F}working\u{241F}claude\u{241E}%1\u{241F}\u{241F}\u{241E}")),
        ])
    }

    @Test func subscriptionValueStartsAfterTheFirstSeparator() {
        let messages = parse(
            "%subscription-changed wc-pane $1 @2 3 %4 : a : b\n%subscription-changed s $1 - - - : \n")
        #expect(notifications(messages) == [
            .subscriptionChanged(TmuxSubscriptionChange(
                name: "wc-pane", sessionID: "$1", windowID: "@2", windowIndex: 3,
                paneID: "%4", value: "a : b")),
            .subscriptionChanged(TmuxSubscriptionChange(
                name: "s", sessionID: "$1", windowID: nil, windowIndex: nil,
                paneID: nil, value: "")),
        ])
    }

    @Test func windowsInTheAttachedSession() {
        #expect(notifications(parse(TmuxTranscripts.attachedSessionWindows)).prefix(5) == [
            .windowAdd(windowID: "@3"),
            .windowRenamed(windowID: "@3", name: "build two"),
            .layoutChange(windowID: "@0", layout: "4197,80x24,0,0[80x12,0,0,0,80x11,0,13,4]"),
            .unlinkedWindowClose(windowID: "@3"),
            .unlinkedWindowAdd(windowID: "@4"),
        ])
    }

    @Test func windowsInAnotherSession() {
        #expect(notifications(parse(TmuxTranscripts.otherSessionWindows)) == [
            .unlinkedWindowAdd(windowID: "@5"),
            .unlinkedWindowRenamed(windowID: "@5", name: "logs two"),
            .unlinkedWindowClose(windowID: "@5"),
        ])
    }

    @Test func sessionsCreatedRenamedAndKilled() {
        #expect(notifications(parse(TmuxTranscripts.sessions)) == [
            .unlinkedWindowAdd(windowID: "@6"),
            .sessionsChanged,
            .unlinkedWindowRenamed(windowID: "@6", name: "tmux"),
            .sessionRenamed(sessionID: "$4", name: "gamma two"),
            .sessionsChanged,
            .unlinkedWindowClose(windowID: "@6"),
        ])
    }

    @Test func focusChanges() {
        #expect(notifications(parse(TmuxTranscripts.focus)).prefix(3) == [
            .sessionWindowChanged(sessionID: "$0", windowID: "@2"),
            .layoutChange(windowID: "@2", layout: "c19f,80x24,0,0[80x12,0,0,2,80x11,0,13,5]"),
            .windowPaneChanged(windowID: "@2", paneID: "%5"),
        ])
    }

    @Test func switchingTheControlClientsSession() {
        #expect(parse(TmuxTranscripts.switchClient) == [
            .reply(TmuxReply(commandNumber: 352, flags: 1, lines: [], isError: false)),
            .notification(.sessionChanged(sessionID: "$1", name: "beta")),
        ])
    }

    @Test func pasteBuffersAndOtherClients() {
        #expect(notifications(parse(TmuxTranscripts.pasteBuffers + TmuxTranscripts.otherClient)) == [
            .pasteBufferChanged(name: "wcbuf"),
            .pasteBufferDeleted(name: "wcbuf"),
            .clientSessionChanged(client: "client-88691", sessionID: "$0", name: "alpha"),
            .clientDetached(client: "client-88691"),
        ])
    }

    @Test func killServerEndsWithExit() {
        #expect(notifications(parse(TmuxTranscripts.killServer)) == [
            .sessionsChanged, .sessionsChanged, .exit(reason: nil),
        ])
        #expect(notifications(parse("%exit detached\n")) == [.exit(reason: "detached")])
    }

    @Test func configErrorsInsideTheAttachReplyAreNotifications() {
        let messages = parse(TmuxTranscripts.configError)
        #expect(Array(messages.prefix(3)) == [
            .notification(.configError(
                "/tmp/wc-tmuxcore-5d94e5/bad.conf:2: unknown command: bogus-command")),
            .reply(TmuxReply(commandNumber: 283, flags: 0, lines: [], isError: false)),
            .notification(.sessionChanged(sessionID: "$0", name: "cfg")),
        ])
    }

    @Test func aClientCommandsConfigErrorLookalikeIsContent() {
        #expect(parse("%begin 1 6 1\n%config-error x\n%end 1 6 1\n") == [
            .reply(TmuxReply(commandNumber: 6, flags: 1, lines: ["%config-error x"], isError: false)),
        ])
    }

    @Test func pauseAndContinue() {
        #expect(notifications(parse("%pause %3\n%continue %3\n")) == [
            .pause(paneID: "%3"), .continue(paneID: "%3"),
        ])
    }

    @Test func windowCloseInTheAttachedSession() {
        #expect(notifications(parse("%window-close @9\n")) == [.windowClose(windowID: "@9")])
    }

    @Test func unknownAndMalformedLinesStayWhole() {
        #expect(notifications(parse(
            "%message hello there\n%window-add\n%window-add 3\n%output nope data\nunframed error\n")) == [
            .unknown("%message hello there"),
            .unknown("%window-add"),
            .unknown("%window-add 3"),
            .unknown("%output nope data"),
            .unknown("unframed error"),
        ])
        // A blank line between blocks says nothing.
        #expect(parse("\n\n").isEmpty)
    }

    // MARK: Output

    @Test func outputDecodesOctalEscapesIntoBytes() throws {
        let outputs = notifications(parse(TmuxTranscripts.output))
        #expect(outputs.count == 36)
        guard case .output(let pane, let data) = try #require(outputs.last) else {
            Issue.record("expected %output")
            return
        }
        #expect(pane == "%1")
        #expect(data == Data("tab\there \u{1B}[1mbold\u{1B}[0m café back\\slash\r\n".utf8))
    }

    @Test func outputJoinedAcrossLinesRebuildsTheEcho() {
        var echoed = Data()
        for case .output(_, let data) in notifications(parse(TmuxTranscripts.output)).dropLast(2) {
            echoed.append(data)
        }
        // The shell's own echo of the typed command, with its redraws.
        #expect(String(decoding: echoed, as: UTF8.self).hasPrefix("p\u{8}printf 'tab\\"))
    }

    @Test func extendedOutputCarriesAgeAndData() {
        let outputs = notifications(parse(TmuxTranscripts.extendedOutput))
        #expect(outputs.count == 15)
        #expect(outputs.first == .extendedOutput(
            paneID: "%0", age: 0, data: Data("s\u{8}sleep 1.5; ye".utf8)))
        #expect(outputs[4] == .extendedOutput(paneID: "%0", age: 0, data: Data(" ".utf8)))
        #expect(outputs.last == .extendedOutput(
            paneID: "%0", age: 0, data: Data("\u{1B}[?2004l\r\r\n".utf8)))
        #expect(notifications(parse("%extended-output %2 15 x y : z\n%extended-output %2 1 :\n")) == [
            .extendedOutput(paneID: "%2", age: 15, data: Data("z".utf8)),
            .extendedOutput(paneID: "%2", age: 1, data: Data()),
        ])
    }

    @Test func octalDecodingEdges() {
        func decode(_ text: String) -> Data {
            TmuxControlParser.decodeOctalEscapes(ArraySlice(Array(text.utf8)))
        }
        #expect(decode("\\000\\177\\377") == Data([0x00, 0x7F, 0xFF]))
        #expect(decode("\\134\\134") == Data("\\\\".utf8))
        // Not an escape: kept as typed.
        #expect(decode("\\8\\12\\400x\\") == Data("\\8\\12\\400x\\".utf8))
        #expect(decode("\\0123") == Data([0x0A, 0x33]))
        #expect(decode("") == Data())
    }
}
