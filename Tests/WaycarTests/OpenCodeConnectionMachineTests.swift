import Testing

@testable import Waycar

@Suite("OpenCode connection machine")
struct OpenCodeConnectionMachineTests {
    private typealias Machine = OpenCodeConnectionMachine
    private static let delays: [Duration] = [.seconds(1), .seconds(2)]
    private static let dropped = TransportError.channelFailed(detail: "OpenCode ended its event stream.")
    private static let refused = TransportError.channelFailed(detail: "OpenCode: status(401)")

    private func make(_ events: [Machine.Event] = []) -> Machine {
        Machine(retryDelays: Self.delays).after(events)
    }

    private var opened: [Machine.Event] { [.relisted] }

    @Test func theFirstCompleteReListOpens() {
        var machine = make()
        #expect(machine.isLive && machine.refusal == nil)
        #expect(machine.handle(.relisted) == [.opened])
        #expect(machine.state == .open(.live(failures: 0, reread: false)))
        // Later re-lists open nothing again.
        #expect(machine.handle(.relisted).isEmpty)
    }

    @Test func anyFailureBeforeItFailsTheOpen() {
        var machine = make()
        #expect(machine.handle(.streamFailed(Self.dropped, unauthorized: false)) == [.failOpen(Self.dropped)])
        #expect(machine.state == .open(.failed))
        #expect(machine.handle(.streamFailed(Self.dropped, unauthorized: false)).isEmpty)
        #expect(machine.handle(.abandon) == [.stopPump])
        #expect(machine.state == .closed && !machine.releasesOnDeinit)
    }

    @Test func aFirst401ReReadsThePasswordAndReconnects() {
        var machine = make()
        #expect(machine.handle(.streamFailed(Self.refused, unauthorized: true)) == [.rereadPassword])
        #expect(machine.state == .open(.rereading(opening: true, failures: 0)))
        #expect(machine.handle(.passwordRead(nil)) == [.reconnect])
        #expect(machine.state == .open(.opening(reread: true)))
        // Refused again right after it: the open fails as unauthorized.
        #expect(machine.handle(.streamFailed(Self.refused, unauthorized: true)) == [.failOpen(Machine.unauthorized)])
    }

    @Test func aFailedReReadFailsTheOpenWithItsError() {
        let unreadable = TransportError.apiRejected(code: "opencode_password_unavailable", message: "no")
        var machine = make([.streamFailed(Self.refused, unauthorized: true)])
        #expect(machine.handle(.passwordRead(unreadable)) == [.failOpen(unreadable)])
    }

    @Test func aLiveStreamBacksOffThroughItsDelaysThenIsLost() {
        var machine = make(opened)
        #expect(machine.handle(.streamFailed(Self.dropped, unauthorized: false)) == [.wait(.seconds(1))])
        #expect(machine.state == .open(.backingOff(failures: 0, reread: false)))
        #expect(machine.isLive)
        #expect(machine.handle(.connecting).isEmpty)
        #expect(machine.state == .open(.live(failures: 1, reread: false)))
        #expect(machine.handle(.streamFailed(Self.dropped, unauthorized: false)) == [.wait(.seconds(2))])
        _ = machine.handle(.connecting)
        #expect(machine.handle(.streamFailed(Self.dropped, unauthorized: false)) == [.lose(Self.dropped)])
        #expect(machine.state == .lost && machine.refusal == Machine.ended && !machine.isLive)
        #expect(machine.handle(.streamFailed(Self.dropped, unauthorized: false)).isEmpty)
        #expect(machine.handle(.relisted).isEmpty)
    }

    @Test func aCompleteReListRestoresTheRetryBudget() {
        var machine = make(opened + [.streamFailed(Self.dropped, unauthorized: false), .connecting,
                                        .streamFailed(Self.dropped, unauthorized: false), .connecting])
        #expect(machine.state == .open(.live(failures: 2, reread: false)))
        #expect(machine.handle(.relisted).isEmpty)
        #expect(machine.handle(.streamFailed(Self.dropped, unauthorized: false)) == [.wait(.seconds(1))])
    }

    @Test func aLive401ReReadsOncePerReListAndASecondInARowIsLost() {
        var machine = make(opened)
        #expect(machine.handle(.streamFailed(Self.refused, unauthorized: true)) == [.rereadPassword])
        #expect(machine.handle(.passwordRead(nil)) == [.reconnect])
        #expect(machine.state == .open(.live(failures: 0, reread: true)))
        #expect(machine.handle(.relisted).isEmpty)
        #expect(machine.handle(.streamFailed(Self.refused, unauthorized: true)) == [.rereadPassword])
        _ = machine.handle(.passwordRead(nil))
        #expect(machine.handle(.streamFailed(Self.refused, unauthorized: true)) == [.lose(Machine.unauthorized)])
        #expect(machine.state == .lost)
    }

    @Test func anotherFailureClearsTheReReadAndAFailedReReadBacksOff() {
        var machine = make(opened + [.streamFailed(Self.refused, unauthorized: true), .passwordRead(nil)])
        #expect(machine.handle(.streamFailed(Self.dropped, unauthorized: false)) == [.wait(.seconds(1))])
        #expect(machine.state == .open(.backingOff(failures: 0, reread: false)))
        _ = machine.handle(.connecting)
        #expect(machine.handle(.streamFailed(Self.refused, unauthorized: true)) == [.rereadPassword])
        let unreadable = TransportError.timedOut
        #expect(machine.handle(.passwordRead(unreadable)) == [.wait(.seconds(2))])
        #expect(machine.state == .open(.backingOff(failures: 1, reread: true)))
    }

    @Test func anUnauthorizedReListIsLostAtOnce() {
        var machine = make(opened)
        #expect(machine.handle(.streamFailed(Machine.unauthorized, unauthorized: false)) == [.lose(Machine.unauthorized)])
    }

    @Test(arguments: [[], [OpenCodeConnectionMachine.Event.relisted],
                      [.relisted, .streamFailed(.timedOut, unauthorized: false)]])
    func closeReleasesOnceAndForgetsThePassword(before: [OpenCodeConnectionMachine.Event]) {
        var machine = make(before)
        #expect(machine.handle(.close) == [.stopPump, .endEvents, .forgetPassword, .release])
        #expect(machine.state == .closed && machine.refusal == .cancelled && !machine.releasesOnDeinit)
        #expect(machine.handle(.close).isEmpty)
        #expect(machine.handle(.distrust) == [.stopPump, .endEvents, .forgetPassword])
        #expect(machine.state == .closed)
    }

    @Test func distrustKeepsTheHoldUntilClose() {
        var machine = make(opened)
        #expect(machine.handle(.distrust) == [.stopPump, .endEvents, .forgetPassword])
        #expect(machine.state == .distrusted && machine.refusal == .cancelled && machine.releasesOnDeinit)
        #expect(machine.handle(.streamFailed(Self.dropped, unauthorized: false)).isEmpty)
        #expect(machine.handle(.close) == [.stopPump, .endEvents, .forgetPassword, .release])
    }

    /// B-41: a re-read that finishes after Close or distrust is dropped.
    @Test func onlyAnOpenOrLostTransportKeepsAPasswordItReads() {
        #expect(make().keepsPassword)
        #expect(make(opened + [.streamFailed(Machine.unauthorized, unauthorized: false)]).keepsPassword)
        #expect(!make([.distrust]).keepsPassword)
        #expect(!make([.close]).keepsPassword)
        #expect(!make([.abandon]).keepsPassword)
    }

    @Test func aLostTransportStillClosesOnce() {
        var machine = make(opened + [.streamFailed(Machine.unauthorized, unauthorized: false)])
        #expect(machine.releasesOnDeinit)
        #expect(machine.handle(.close) == [.stopPump, .endEvents, .forgetPassword, .release])
    }
}
