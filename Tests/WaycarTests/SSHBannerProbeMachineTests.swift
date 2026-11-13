import Foundation
import Testing

@testable import Waycar

@Suite("SSH banner probe machine")
struct SSHBannerProbeMachineTests {
    @Test func connectsThenReadsAFragmentedBannerAndFinishesOnce() {
        var machine = SSHBannerProbeMachine()
        #expect(machine.handle(.start) == [.armTimeout(1), .connect])
        #expect(machine.handle(.connected) == [.receive])
        #expect(machine.handle(.received(Data("Welcome\r\nS".utf8), complete: false, failed: false)) == [.receive])
        #expect(machine.handle(.received(Data("SH-2.0-OpenSSH_test\r\n".utf8), complete: false, failed: false))
            == [.finish(.ssh(banner: "SSH-2.0-OpenSSH_test"))])
        #expect(machine.handle(.timeout(1)).isEmpty)
        #expect(machine.handle(.cancel).isEmpty)
    }

    @Test func cancellationBeforeStartDoesNotConnectButCompletesTheLaterStart() {
        var machine = SSHBannerProbeMachine()
        #expect(machine.handle(.cancel).isEmpty)
        #expect(machine.handle(.start) == [.finish(.unreachable)])
        #expect(machine.state == .finished)
        #expect(machine.handle(.connected).isEmpty)
    }

    @Test func onlyTheCurrentTimeoutFinishesTheAttempt() {
        var machine = SSHBannerProbeMachine()
        _ = machine.handle(.start)
        #expect(machine.handle(.timeout(0)).isEmpty)
        _ = machine.handle(.connected)
        #expect(machine.handle(.timeout(0)).isEmpty)
        #expect(machine.handle(.timeout(1)) == [.finish(.unreachable)])
        #expect(machine.handle(.failed(.localNetworkDenied)).isEmpty)
    }
}
