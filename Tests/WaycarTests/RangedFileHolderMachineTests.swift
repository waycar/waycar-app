import Testing

@testable import Waycar

@Suite("Ranged file holder machine")
struct RangedFileHolderMachineTests {
    private typealias Machine = RangedFileHolderMachine

    /// A holder with its channel open (token 1) and no read on it.
    private var open: Machine {
        Machine().after([.readStarted, .opened(token: 1), .readEnded])
    }

    @Test func theFirstReadOpensTheChannel() {
        var machine = Machine()
        #expect(machine.handle(.readStarted) == [.cancelIdleRelease, .open(token: 1)])
        #expect(machine.state == .init(holder: .opening(token: 1), reads: 1))
    }

    @Test func aReadArrivingWhileItOpensJoinsTheOpen() {
        var machine = Machine().after([.readStarted])
        #expect(machine.handle(.readStarted) == [.cancelIdleRelease, .joinOpening])
        #expect(machine.state.reads == 2)
    }

    @Test func anOpenChannelIsReusedAndItsIdleReleaseDisarmed() {
        var machine = open
        #expect(machine.handle(.readStarted) == [.cancelIdleRelease, .use])
    }

    @Test func theLastReadEndingOnAnOpenChannelArmsTheIdleRelease() {
        var machine = Machine().after([.readStarted, .readStarted, .opened(token: 1)])
        #expect(machine.handle(.readEnded) == [.cancelIdleRelease])
        #expect(machine.handle(.readEnded) == [.cancelIdleRelease, .armIdleRelease])
        #expect(machine.state == .init(holder: .open(token: 1), reads: 0))
    }

    @Test func aFailedOpenEmptiesTheHolderAndTheNextReadOpensAgain() {
        var machine = Machine().after([.readStarted, .openFailed(token: 1)])
        #expect(machine.state.holder == .empty)
        #expect(machine.handle(.readFailed) == [.cancelIdleRelease])
        #expect(machine.handle(.readEnded) == [.cancelIdleRelease])
        #expect(machine.handle(.readStarted) == [.cancelIdleRelease, .open(token: 2)])
    }

    @Test func anOpenAnswerForAnotherTokenIsIgnored() {
        var machine = Machine().after([.readStarted])
        #expect(machine.handle(.opened(token: 9)) == [])
        #expect(machine.handle(.openFailed(token: 9)) == [])
        #expect(machine.state.holder == .opening(token: 1))
    }

    @Test func theOnlyReadFailingClosesTheChannel() {
        var machine = open.after([.readStarted])
        #expect(machine.handle(.readFailed) == [.cancelIdleRelease, .close])
        #expect(machine.state.holder == .empty)
        #expect(machine.handle(.readEnded) == [.cancelIdleRelease])
    }

    /// With another read still on the channel, that read settles it.
    @Test func aFailedReadLeavesTheChannelToAnotherReadOnIt() {
        var machine = open.after([.readStarted, .readStarted])
        #expect(machine.handle(.readFailed) == [])
        #expect(machine.state.holder == .open(token: 1))
    }

    @Test func theIdleReleaseClosesAChannelNobodyReads() {
        var machine = open
        #expect(machine.handle(.idleElapsed) == [.cancelIdleRelease, .close])
        #expect(machine.state.holder == .empty)
        #expect(machine.handle(.idleElapsed) == [.cancelIdleRelease])
    }

    @Test func theIdleReleaseWaitsWhileAReadIsOnTheChannel() {
        var machine = open.after([.readStarted])
        #expect(machine.handle(.idleElapsed) == [])
        #expect(machine.state.holder == .open(token: 1))
    }

    /// Kept race: an idle release that already ran out still closes the
    /// channel a later read used and left (the next read reopens it).
    @Test func anIdleReleaseThatRanOutBeforeALaterReadStillCloses() {
        var machine = open.after([.readStarted, .readEnded])
        #expect(machine.handle(.idleElapsed) == [.cancelIdleRelease, .close])
    }

    @Test func closingTheSessionTakesTheChannel() {
        var opened = open
        #expect(opened.handle(.sessionClosed) == [.cancelIdleRelease, .close])
        #expect(opened.state.holder == .empty)

        var opening = Machine().after([.readStarted])
        #expect(opening.handle(.sessionClosed) == [.cancelIdleRelease])
        #expect(opening.state.holder == .opening(token: 1))
    }

    @Test func noOpenTokenIsReused() {
        var machine = Machine()
        var tokens: Set<UInt64> = []
        for _ in 0..<4 {
            guard case .open(let token) = machine.handle(.readStarted).last else {
                Issue.record("no open")
                return
            }
            #expect(tokens.insert(token).inserted)
            _ = machine.handle([.opened(token: token), .readFailed, .readEnded])
        }
    }
}
