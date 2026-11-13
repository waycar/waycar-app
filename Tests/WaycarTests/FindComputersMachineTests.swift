import Testing

@testable import Waycar

@Suite("Find Computers machine")
struct FindComputersMachineTests {
    private let home = IPv4Subnet(address: 0xC0A8_012A, mask: 0xFFFF_FF00)
    private let mac = FoundComputer(
        address: "192.168.1.20", port: 22, serviceName: "Studio Mac", software: nil, source: .bonjour)

    @Test func searchSettlesWithTheTimerAndReportsOnce() {
        var machine = FindComputersMachine()
        #expect(machine.handle(.start(home)) == [.cancelSearch, .milestone(.lanScanStarted), .browse(1)])
        #expect(machine.handle(.browse(1, .ready)) == [.armSettle(2)])
        #expect(!machine.hasSettled)
        #expect(machine.handle(.settleElapsed(2)) == [.cancelSettle, .milestone(.lanScanFound(count: 0))])
        #expect(machine.hasSettled)
        #expect(machine.handle(.settleElapsed(2)).isEmpty)
        #expect(machine.handle(.browse(1, .computers([mac]))).isEmpty)
        #expect(machine.computers == [mac])
    }

    @Test func findingAComputerSettlesEarlyWithTheRowCount() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        _ = machine.handle(.browse(1, .ready))
        let otherInterface = FoundComputer(
            address: "192.168.1.21", port: 22, serviceName: "Studio Mac", software: nil, source: .bonjour)
        #expect(machine.handle(.browse(1, .computers([mac, otherInterface])))
            == [.cancelSettle, .milestone(.lanScanFound(count: 1))])
        #expect(machine.hasSettled)
        #expect(machine.computers == [mac])
    }

    @Test func staleSearchSweepAndTimerEventsCannotChangeTheNextSearch() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        _ = machine.handle(.browse(1, .ready))
        _ = machine.handle(.scanTapped) // sweep 3
        _ = machine.handle(.searchAgain(home)) // search 4
        let before = machine.state
        #expect(machine.handle(.browse(1, .denied)).isEmpty)
        #expect(machine.handle(.browse(1, .computers([mac]))).isEmpty)
        #expect(machine.handle(.sweep(3, .found(mac))).isEmpty)
        #expect(machine.handle(.sweep(3, .denied)).isEmpty)
        #expect(machine.handle(.settleElapsed(2)).isEmpty)
        #expect(machine.state == before)
        _ = machine.handle(.stop)
        #expect(machine.handle(.browse(4, .ready)).isEmpty)
    }

    @Test func denialFromBrowseCancelsTheSearch() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        _ = machine.handle(.browse(1, .ready))
        #expect(machine.handle(.browse(1, .denied)) == [.cancelSearch, .milestone(.lanPermissionDenied)])
        #expect(machine.isDenied)
        #expect(machine.handle(.settleElapsed(2)).isEmpty)
        #expect(machine.handle(.scanTapped).isEmpty)
    }

    @Test func sweepStartsOnlyOnATapAndItsDenialCancelsEverything() {
        var machine = FindComputersMachine()
        #expect(machine.handle(.scanTapped).isEmpty)
        _ = machine.handle(.start(home))
        #expect(machine.sweep == .idle)
        #expect(machine.handle(.start(home)).isEmpty)
        #expect(machine.handle(.scanTapped) == [.sweep(2)])
        #expect(machine.handle(.scanTapped).isEmpty)
        #expect(machine.handle(.sweep(2, .denied)) == [.cancelSearch, .milestone(.lanPermissionDenied)])
        #expect(machine.isDenied)
    }

    @Test func searchAgainResetsRowsAndSweepAndCanRecoverFromDenial() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        _ = machine.handle(.browse(1, .computers([mac])))
        #expect(machine.handle(.scanTapped) == [.sweep(2)])
        _ = machine.handle(.sweep(2, .finished))
        #expect(machine.sweep == .finished)
        #expect(machine.handle(.searchAgain(home))
            == [.cancelSearch, .milestone(.lanScanStarted), .browse(3)])
        #expect(machine.computers.isEmpty)
        #expect(!machine.hasSettled)
        #expect(machine.sweep == .idle)
        _ = machine.handle(.browse(3, .denied))
        _ = machine.handle(.searchAgain(home))
        #expect(!machine.isDenied)
        #expect(machine.handle(.browse(4, .ready)) == [.armSettle(5)])
    }

    @Test func sweepCanEnrichSettledResultsAndBecomeUnavailable() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        _ = machine.handle(.browse(1, .failed))
        #expect(machine.hasSettled)
        _ = machine.handle(.scanTapped)
        _ = machine.handle(.sweep(2, .found(mac)))
        #expect(machine.computers == [mac])
        _ = machine.handle(.sweep(2, .unavailable))
        #expect(machine.sweep == .unavailable)
        #expect(machine.handle(.scanTapped).isEmpty)
        #expect(machine.handle(.sweep(2, .finished)).isEmpty)
    }
}
