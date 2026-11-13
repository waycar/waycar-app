import Testing

@testable import Waycar

/// `TmuxControlChannelMachine`: one control client's startup, end and
/// pending lines.
@Suite("tmux control channel machine")
struct TmuxControlChannelMachineTests {
    typealias Machine = TmuxControlChannelMachine

    private static func reply(_ number: Int, flags: Int = 1, error: Bool = false) -> TmuxReply {
        TmuxReply(commandNumber: number, flags: flags, lines: ["\(number)"], isError: error)
    }

    private let attaching = Machine().after([.start(cancelled: false), .opened])
    private var open: Machine { attaching.after([.reply(Self.reply(1, flags: 0))]) }

    // MARK: Startup

    @Test func startOpensThenAttaches() {
        var machine = Machine()
        #expect(machine.handle(.start(cancelled: false)).isEmpty)
        #expect(machine.state.phase == .opening)
        #expect(machine.handle(.opened) == [.startIO])
        #expect(machine.state.phase == .attaching)
        #expect(machine.sendRefusal == Machine.notOpen)
    }

    @Test func aStartAlreadyCancelledEndsAtOnce() {
        var machine = Machine()
        #expect(machine.handle(.start(cancelled: true))
            == [.finish(.lost("cancelled"), nil, lines: []), .refuse(.cancelled)])
        #expect(machine.end == .lost("cancelled"))
    }

    @Test func aSecondStartIsRefused() {
        for machine in [Machine().after([.start(cancelled: false)]), attaching, open] {
            var started = machine
            #expect(started.handle(.start(cancelled: false)) == [.refuse(Machine.alreadyStarted)])
            #expect(started.state == machine.state)
        }
    }

    @Test func aFailedOpenEndsTheClientLost() {
        var machine = Machine().after([.start(cancelled: false)])
        #expect(machine.handle(.openFailed("refused")) == [.finish(.lost("refused"), nil, lines: [])])
        #expect(machine.end == .lost("refused"))
    }

    @Test func closeWhileOpeningRefusesWhatOpened() {
        var machine = Machine().after([.start(cancelled: false)])
        #expect(machine.handle(.close) == [.finish(.closed, nil, lines: []), .closeChannel])
        #expect(machine.handle(.opened) == [.refuse(.cancelled)])
        #expect(machine.handle(.openFailed("late")).isEmpty)
    }

    @Test func theAttachReplyOpensTheClient() {
        var machine = attaching
        #expect(machine.handle(.reply(Self.reply(5))).isEmpty)
        #expect(machine.handle(.reply(Self.reply(1, flags: 0))) == [.resumeStart])
        #expect(machine.isOpen)
        #expect(machine.sendRefusal == nil)
    }

    @Test func anAttachErrorEndsTheClient() {
        var machine = attaching
        let refused = TmuxReply(commandNumber: 1, flags: 0, lines: ["no sessions"], isError: true)
        #expect(machine.handle(.reply(refused)) == [
            .finish(.lost("tmux attach failed: no sessions"), .attachRefused("no sessions"), lines: []),
            .closeChannel,
        ])
    }

    @Test func aStartTimedOutOrCancelledWhileAttachingEnds() {
        var timedOut = attaching
        #expect(timedOut.handle(.startInterrupted(.lost("timed out"), .timedOut))
            == [.finish(.lost("timed out"), .timedOut, lines: []), .closeChannel])
        var open = self.open
        #expect(open.handle(.startInterrupted(.lost("cancelled"), .cancelled)).isEmpty)
        #expect(open.isOpen)
    }

    // MARK: Lines

    @Test func linesAreAnsweredFirstInFirstOut() {
        var machine = open
        #expect(machine.handle(.lineQueued(expectedReplies: 2)) == [.enqueue(1)])
        #expect(machine.handle(.lineQueued(expectedReplies: 1)) == [.enqueue(2)])
        #expect(machine.handle(.lineTaken(1)) == [.write(1)])
        #expect(machine.handle(.lineTaken(2)) == [.write(2)])
        #expect(machine.handle(.reply(Self.reply(10))).isEmpty)
        #expect(machine.handle(.reply(Self.reply(11)))
            == [.cancelTimer(1), .complete(1, [Self.reply(10), Self.reply(11)])])
        #expect(machine.handle(.reply(Self.reply(12)))
            == [.cancelTimer(2), .complete(2, [Self.reply(12)])])
        #expect(machine.state.pending.isEmpty)
    }

    @Test func anErrorReplyCompletesItsLineEarly() {
        var machine = open.after([.lineQueued(expectedReplies: 3), .lineTaken(1)])
        let failed = Self.reply(20, error: true)
        #expect(machine.handle(.reply(failed)) == [.cancelTimer(1), .complete(1, [failed])])
    }

    @Test func aReplyWithNothingPendingOrFlagsZeroIsDropped() {
        var machine = open
        #expect(machine.handle(.reply(Self.reply(30))).isEmpty)
        machine = machine.after([.lineQueued(expectedReplies: 1), .lineTaken(1)])
        #expect(machine.handle(.reply(Self.reply(31, flags: 0))).isEmpty)
        #expect(machine.state.pending.first?.replies.isEmpty == true)
    }

    @Test func aLineCancelledWhileQueuedIsWithdrawnAndNeverWritten() {
        var machine = open.after([.lineQueued(expectedReplies: 1)])
        #expect(machine.handle(.lineCancelled(1)) == [.cancelTimer(1), .releaseCaller(1)])
        #expect(machine.state.pending.isEmpty)
        #expect(machine.handle(.lineTaken(1)).isEmpty)
    }

    @Test func aWrittenLineCancelledKeepsItsPlaceAndDropsItsReplies() {
        var machine = open.after([
            .lineQueued(expectedReplies: 1), .lineTaken(1), .lineQueued(expectedReplies: 1),
            .lineTaken(2),
        ])
        #expect(machine.handle(.lineCancelled(1)) == [.releaseCaller(1)])
        #expect(machine.handle(.lineCancelled(1)).isEmpty)
        #expect(machine.state.pending.count == 2)
        #expect(machine.handle(.reply(Self.reply(40)))
            == [.cancelTimer(1), .complete(1, [Self.reply(40)])])
        #expect(machine.handle(.reply(Self.reply(41)))
            == [.cancelTimer(2), .complete(2, [Self.reply(41)])])
    }

    @Test func aTimedOutLineEndsTheClientAndFailsEveryLine() {
        var machine = open.after([
            .lineQueued(expectedReplies: 1), .lineTaken(1), .lineQueued(expectedReplies: 1),
        ])
        #expect(machine.handle(.lineTimedOut(9)).isEmpty)
        #expect(machine.handle(.lineTimedOut(2))
            == [.finish(.lost("timed out"), .timedOut, lines: [1, 2]), .closeChannel])
        #expect(machine.sendRefusal == .channelFailed(detail: "tmux control channel lost: timed out"))
        #expect(machine.handle(.lineQueued(expectedReplies: 1)).isEmpty)
    }

    // MARK: The end

    @Test func aReaderStoppingAfterExitIsAnOrderlyExit() {
        var machine = open.after([.exitNotified(reason: "detached")])
        #expect(machine.handle(.readerStopped(error: "boom"))
            == [.finish(.exited(reason: "detached"), nil, lines: []), .closeChannel])
        #expect(machine.sendRefusal == .channelFailed(detail: "tmux control mode exited: detached"))
    }

    @Test func aReaderStoppingWithoutExitIsLost() {
        var eof = open
        #expect(eof.handle(.readerStopped(error: nil))
            == [.finish(.lost("tmux closed the control channel"), nil, lines: []), .closeChannel])
        var failed = open
        #expect(failed.handle(.readerStopped(error: "boom"))
            == [.finish(.lost("boom"), nil, lines: []), .closeChannel])
    }

    @Test func aFailedWriteEndsTheClientLost() {
        var timedOut = open
        #expect(timedOut.handle(.writeFailed(timedOut: true, detail: "x"))
            == [.finish(.lost("timed out"), .timedOut, lines: []), .closeChannel])
        var broken = open
        #expect(broken.handle(.writeFailed(timedOut: false, detail: "broken pipe"))
            == [.finish(.lost("broken pipe"), nil, lines: []), .closeChannel])
    }

    @Test func closeEndsOnceAndClosesTheChannelEveryTime() {
        var machine = open.after([.lineQueued(expectedReplies: 1)])
        #expect(machine.handle(.close) == [.finish(.closed, nil, lines: [1]), .closeChannel])
        #expect(machine.sendRefusal == .cancelled)
        #expect(machine.handle(.close) == [.closeChannel])
    }

    @Test func anEndedClientIgnoresEverythingButClose() {
        var machine = open.after([.close])
        let ended = machine.state
        #expect(machine.handle(.reply(Self.reply(50))).isEmpty)
        #expect(machine.handle(.exitNotified(reason: nil)).isEmpty)
        #expect(machine.handle(.readerStopped(error: nil)).isEmpty)
        #expect(machine.handle(.writeFailed(timedOut: true, detail: "")).isEmpty)
        #expect(machine.handle(.lineTimedOut(1)).isEmpty)
        #expect(machine.handle(.lineCancelled(1)).isEmpty)
        #expect(machine.handle(.startInterrupted(.lost("x"), .cancelled)).isEmpty)
        #expect(machine.state == ended)
    }
}
