import Testing

@testable import Waycar

/// Tokens: a start mints the search (n), its settle timer (n + 1) and its
/// sweep of every address (n + 2).
@Suite("Find Computers machine")
struct FindComputersMachineTests {
    private let home = IPv4Subnet(address: 0xC0A8_012A, mask: 0xFFFF_FF00)
    private let mac = FoundComputer(
        address: "192.168.1.20", port: 22, serviceName: "Studio Mac", software: nil, source: .bonjour)
    private let linux = FoundComputer(
        address: "192.168.1.33", port: 22, serviceName: nil, software: "OpenSSH_9.6p1", source: .sweep)

    @Test func oneTapBrowsesAndChecksEveryAddress() {
        var machine = FindComputersMachine()
        #expect(machine.handle(.start(home))
            == [.cancelSearch, .milestone(.lanScanStarted), .browse(1), .armSettle(2), .sweep(3)])
        #expect(machine.sweep == .running(3))
        #expect(machine.handle(.browse(1, .ready)).isEmpty)
        #expect(!machine.hasSettled)
    }

    /// The count goes out once, after both the browse settled and the sweep
    /// ended, so it includes what only the sweep found.
    @Test func theCountWaitsForTheSweep() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        #expect(machine.handle(.browse(1, .computers([mac]))) == [.cancelSettle])
        #expect(machine.hasSettled)
        #expect(machine.handle(.sweep(3, .found(linux))).isEmpty)
        #expect(machine.handle(.sweep(3, .finished)) == [.milestone(.lanScanFound(count: 2))])
        #expect(machine.computers.count == 2)
        #expect(machine.handle(.sweep(3, .finished)).isEmpty)
    }

    /// A browser that only ever waits (Wi-Fi off) never reports `.ready`;
    /// the empty state, with Search Again, must still arrive.
    @Test func aBrowserThatNeverBecomesReadyStillSettles() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        _ = machine.handle(.sweep(3, .unavailable))
        #expect(machine.handle(.settleElapsed(2)) == [.cancelSettle, .milestone(.lanScanFound(count: 0))])
        #expect(machine.hasSettled)
        #expect(machine.sweep == .unavailable)
    }

    @Test func aSweepFindSettlesEarlyWithoutReportingYet() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        #expect(machine.handle(.sweep(3, .found(linux))) == [.cancelSettle])
        #expect(machine.hasSettled)
        #expect(machine.handle(.settleElapsed(2)).isEmpty)
    }

    @Test func oneComputerOnTwoInterfacesIsOneRow() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        let otherInterface = FoundComputer(
            address: "192.168.1.21", port: 22, serviceName: "Studio Mac", software: nil, source: .bonjour)
        _ = machine.handle(.browse(1, .computers([mac, otherInterface])))
        #expect(machine.computers == [mac])
    }

    @Test func staleSearchSweepAndTimerEventsCannotChangeTheNextSearch() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home)) // search 1, timer 2, sweep 3
        _ = machine.handle(.searchAgain(home)) // search 4, timer 5, sweep 6
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
        #expect(machine.handle(.sweep(6, .finished)).isEmpty)
    }

    @Test func denialFromBrowseOrSweepCancelsTheSearch() {
        var browseDenied = FindComputersMachine()
        _ = browseDenied.handle(.start(home))
        #expect(browseDenied.handle(.browse(1, .denied)) == [.cancelSearch, .milestone(.lanPermissionDenied)])
        #expect(browseDenied.isDenied)
        #expect(browseDenied.handle(.settleElapsed(2)).isEmpty)

        var sweepDenied = FindComputersMachine()
        _ = sweepDenied.handle(.start(home))
        #expect(sweepDenied.handle(.sweep(3, .denied)) == [.cancelSearch, .milestone(.lanPermissionDenied)])
        #expect(sweepDenied.isDenied)
    }

    /// iOS's Local Network prompt makes the app inactive. A denial seen then
    /// may only mean the prompt is unanswered: it is neither shown nor
    /// reported, and the search starts again, unannounced, once the app is
    /// active. A denial once active is real.
    @Test func aDenialBehindThePromptIsCheckedAgainOnceActive() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        _ = machine.handle(.appInactive)
        #expect(machine.handle(.sweep(3, .denied)) == [.cancelSearch])
        #expect(!machine.isDenied)
        #expect(machine.handle(.appActive(home)) == [.cancelSearch, .browse(4), .armSettle(5), .sweep(6)])
        #expect(machine.handle(.browse(4, .denied)) == [.cancelSearch, .milestone(.lanPermissionDenied)])
        #expect(machine.isDenied)
    }

    /// Nothing can be found behind the prompt, so a search with no rows yet
    /// starts again; one with rows (Control Center pulled down mid-scan) runs
    /// on, and a count that came in while inactive is reported once active.
    @Test func returningToTheAppKeepsASearchWithRows() {
        var empty = FindComputersMachine()
        _ = empty.handle(.start(home))
        _ = empty.handle(.appInactive)
        #expect(empty.handle(.appActive(home)) == [.cancelSearch, .browse(4), .armSettle(5), .sweep(6)])

        var running = FindComputersMachine()
        _ = running.handle(.start(home))
        _ = running.handle(.browse(1, .computers([mac])))
        _ = running.handle(.appInactive)
        #expect(running.handle(.appActive(home)).isEmpty)
        #expect(running.sweep == .running(3))

        var finishedWhileInactive = FindComputersMachine()
        _ = finishedWhileInactive.handle(.start(home))
        _ = finishedWhileInactive.handle(.browse(1, .computers([mac])))
        _ = finishedWhileInactive.handle(.appInactive)
        #expect(finishedWhileInactive.handle(.sweep(3, .finished)).isEmpty)
        #expect(finishedWhileInactive.handle(.appActive(home)) == [.milestone(.lanScanFound(count: 1))])
        _ = finishedWhileInactive.handle(.appInactive)
        #expect(finishedWhileInactive.handle(.appActive(home)).isEmpty)
    }

    @Test func searchAgainResetsRowsAndRecoversFromDenial() {
        var machine = FindComputersMachine()
        _ = machine.handle(.start(home))
        _ = machine.handle(.browse(1, .computers([mac])))
        _ = machine.handle(.sweep(3, .finished))
        #expect(machine.handle(.searchAgain(home))
            == [.cancelSearch, .milestone(.lanScanStarted), .browse(4), .armSettle(5), .sweep(6)])
        #expect(machine.computers.isEmpty)
        #expect(!machine.hasSettled)
        #expect(machine.sweep == .running(6))
        _ = machine.handle(.browse(4, .denied))
        #expect(machine.isDenied)
        _ = machine.handle(.searchAgain(home))
        #expect(!machine.isDenied)
    }
}
