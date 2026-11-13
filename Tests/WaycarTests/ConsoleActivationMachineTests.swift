import Testing

@testable import Waycar

@Suite("Console activation machine")
struct ConsoleActivationMachineTests {
    private typealias Machine = ConsoleActivationMachine
    private let wifi = NetworkPathKey(interface: .wifi, interfaceName: "en0", addressPrefix: "192.168.1")
    private let cellular = NetworkPathKey(
        interface: .cellular, interfaceName: "pdp_ip0", addressPrefix: "10.20.30")

    @Test func transitionsChainBehindTheLastOneEnqueued() {
        var machine = Machine()
        #expect(machine.handle(.enqueued) == [.run(1, after: nil)])
        #expect(machine.handle(.enqueued) == [.run(2, after: 1)])
        #expect(machine.handle(.enqueued) == [.run(3, after: 2)])
        #expect(machine.handle(.finished(1)) == [.release(1)])
        #expect(machine.state.tail == 3)
        #expect(machine.handle(.finished(2)) == [.release(2)])
        #expect(machine.handle(.finished(3)) == [.release(3)])
        #expect(machine.state.tail == nil)
        #expect(machine.handle(.enqueued) == [.run(4, after: nil)])
    }

    @Test func aTransitionSetsActivationAsItBeginsNotAsItIsEnqueued() {
        var machine = Machine().after([.enqueued, .began(active: true), .enqueued])
        #expect(machine.isActive)
        #expect(machine.handle(.began(active: false)).isEmpty)
        #expect(!machine.isActive)
    }

    @Test func aFollowsFirstReadingIsItsBaseline() {
        var machine = Machine()
        #expect(machine.handle(.followed) == [.follow(1)])
        #expect(machine.handle(.pathRead(follow: 1, path: wifi)) == [.setOffline(false)])
        #expect(machine.handle(.pathRead(follow: 1, path: cellular))
            == [.setOffline(false), .pathChanged(cellular, recovered: false)])
    }

    @Test func aBaselineOfNoneIsOfflineAtOnceButNoChange() {
        var machine = Machine().after([.followed])
        #expect(machine.handle(.pathRead(follow: 1, path: nil)) == [.setOffline(true), .lostPath])
        #expect(machine.handle(.pathRead(follow: 1, path: wifi))
            == [.setOffline(false), .pathChanged(wifi, recovered: true)])
    }

    @Test func aPathGoneThenBackIsARecovery() {
        var machine = Machine().after([.followed, .pathRead(follow: 1, path: wifi)])
        #expect(machine.handle(.pathRead(follow: 1, path: nil))
            == [.setOffline(true), .lostPath, .pathChanged(nil, recovered: false)])
        #expect(machine.handle(.pathRead(follow: 1, path: wifi))
            == [.setOffline(false), .pathChanged(wifi, recovered: true)])
        #expect(machine.handle(.pathRead(follow: 1, path: wifi))
            == [.setOffline(false), .pathChanged(wifi, recovered: false)])
    }

    @Test func eachFollowJudgesItsReadingsAgainstItsOwn() {
        var machine = Machine().after([.followed, .pathRead(follow: 1, path: nil)])
        #expect(machine.handle(.followed) == [.follow(2)])
        #expect(machine.handle(.pathRead(follow: 2, path: wifi)) == [.setOffline(false)])
        // A reading still buffered for the replaced follow.
        #expect(machine.handle(.pathRead(follow: 1, path: wifi))
            == [.setOffline(false), .pathChanged(wifi, recovered: true)])
        #expect(machine.handle(.followEnded(1)).isEmpty)
        #expect(machine.handle(.pathRead(follow: 1, path: nil)).isEmpty)
        #expect(machine.state.follows == [2: .known(wifi)])
    }
}
