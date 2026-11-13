import Testing

@testable import Waycar

/// Tokens: a start mints the search (n) and its settle timer (n + 1); a tap
/// on Check Every Address mints the sweep.
@Suite("Find Computers machine")
struct FindComputersMachineTests {
    private let home = IPv4Subnet(address: 0xC0A8_012A, mask: 0xFFFF_FF00)
    private let mac = FoundComputer(
        address: "192.168.1.20", port: 22, serviceName: "Studio Mac", software: nil, source: .bonjour)

    @Test func searchSettlesWithTheTimerAndReportsOnce() {
        var machine = FindComputersMachine()
        #expect(machine.handle(.start(home))
            == [.cancelSearch, .milestone(.lanScanStarted), .browse(1), .armSettle(2)])
        #expect(machine.handle(.browse(1, .ready)).isEmpty)
        #expect(!machine.hasSettled)
        #expect(machine.handle(.settleElapsed(2)) == [.cancelSettle, .milestone(.lanScanFound(count: 0))])
        #expect(machine.hasSettled)
        #expect(machine.handle(.settleElapsed(2)).isEmpty)
        #expect(machine.handle(.browse(1, .computers([mac]))).isEmpty)
        #expect(machine.computers == [mac])
    }

    /// A browser that only ever waits (Wi-Fi off) never reports `.ready`;
    /// the empty state, with Search Again, must still arrive.
    @Test func aBrowserThatNeverBecomesReadyStillSettles() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        #expect(machine.handle(.settleElapsed(2)) == [.cancelSettle, .milestone(.lanScanFound(count: 0))])
        #expect(machine.hasSettled)
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
        _ = machine.handle(.start(home)) // search 1, timer 2
        _ = machine.handle(.scanTapped) // sweep 3
        _ = machine.handle(.searchAgain(home)) // search 4, timer 5
        let before = machine.state
        #expect(machine.handle(.browse(1, .denied)).isEmpty)
        #expect(machine.handle(.browse(1, .computers([mac]))).isEmpty)
        #expect(machine.handle(.sweep(3, .found(mac))).isEmpty)
        #expect(machine.handle(.sweep(3, .denied)).isEmpty)
        #expect(machine.handle(.settleElapsed(2)).isEmpty)
        #expect(machine.state == before)
        _ = machine.handle(.stop)
        #expect(machine.handle(.browse(4, .ready)).isEmpty)
        #expect(machine.handle(.settleElapsed(5)).isEmpty)
    }

    @Test func denialFromBrowseCancelsTheSearch() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
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
        #expect(machine.handle(.scanTapped) == [.sweep(3)])
        #expect(machine.handle(.scanTapped).isEmpty)
        #expect(machine.handle(.sweep(3, .denied)) == [.cancelSearch, .milestone(.lanPermissionDenied)])
        #expect(machine.isDenied)
    }

    @Test func searchAgainResetsRowsAndSweepAndCanRecoverFromDenial() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        _ = machine.handle(.browse(1, .computers([mac])))
        #expect(machine.handle(.scanTapped) == [.sweep(3)])
        _ = machine.handle(.sweep(3, .finished))
        #expect(machine.sweep == .finished)
        #expect(machine.handle(.searchAgain(home))
            == [.cancelSearch, .milestone(.lanScanStarted), .browse(4), .armSettle(5)])
        #expect(machine.computers.isEmpty)
        #expect(!machine.hasSettled)
        #expect(machine.sweep == .idle)
        _ = machine.handle(.browse(4, .denied))
        #expect(machine.handle(.searchAgain(home))
            == [.cancelSearch, .milestone(.lanScanStarted), .browse(6), .armSettle(7)])
        #expect(!machine.isDenied)
    }

    /// An unavailable sweep (the phone was off Wi-Fi) takes another tap: the
    /// sweeper reads the subnet again.
    @Test func sweepCanEnrichSettledResultsAndRetryAfterUnavailable() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        _ = machine.handle(.browse(1, .failed))
        #expect(machine.hasSettled)
        #expect(machine.handle(.scanTapped) == [.sweep(3)])
        _ = machine.handle(.sweep(3, .found(mac)))
        #expect(machine.computers == [mac])
        _ = machine.handle(.sweep(3, .unavailable))
        #expect(machine.sweep == .unavailable)
        #expect(machine.handle(.scanTapped) == [.sweep(4)])
        #expect(machine.handle(.sweep(3, .finished)).isEmpty)
    }
}
