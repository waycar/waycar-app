import Foundation
import Testing

@testable import Waycar

/// `HostResourceUsage.parse`, fed real Host command output captured on
/// macOS 27, Ubuntu 24.04 and Rocky 9 (LC_ALL=C).
@Suite("Host resource usage parsing")
struct HostResourceUsageTests {
    private static let macOS = """
        __WAYCAR_IOSTAT__= 63 29  7  42.07 51.03 37.94
        __WAYCAR_MEMSIZE__=38654705664
        __WAYCAR_SWAP__=total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                                     6097.
        Pages active:                                 408776.
        Pages inactive:                               398216.
        Pages speculative:                              8983.
        Pages throttled:                                   0.
        Pages wired down:                             402626.
        Pages purgeable:                                  82.
        "Translation faults":                      970803059.
        Pages copy-on-write:                        47248587.
        Pages zero filled:                         594773350.
        Pages reactivated:                          45775914.
        Pages purged:                                7093471.
        File-backed pages:                            300647.
        Anonymous pages:                              515328.
        Pages stored in compressor:                  2492469.
        Pages occupied by compressor:                1079267.
        Decompressions:                             28626869.
        Compressions:                               38649888.
        Pageins:                                    42487640.
        Pageouts:                                      89984.
        Swapins:                                           0.
        Swapouts:                                          0.

        """

    private static let ubuntu = """
        cpu  161294055 1046 73229227 775281562 135795764 0 7841484 127868486 0 0
        cpu  161294147 1046 73229276 775281636 135795891 0 7841487 127868578 0 0
        MemTotal:        4851016 kB
        MemAvailable:    1792396 kB
        SwapTotal:       9392120 kB
        SwapFree:        3696504 kB

        """

    private static let rocky = """
        cpu  161294231 1046 73229343 775281753 135795953 0 7841489 127868689 0 0
        cpu  161294308 1046 73229376 775281969 135795988 0 7841500 127868773 0 0
        MemTotal:        4851016 kB
        MemAvailable:    1757732 kB
        SwapTotal:       9392120 kB
        SwapFree:        3700344 kB

        """

    @Test func parsesLinux() throws {
        let usage = try HostResourceUsage.parse(Self.ubuntu)
        #expect(abs(usage.cpu - 236.0 / 437.0) < 0.0001)
        #expect(abs(usage.memory - (4851016.0 - 1792396.0) / 4851016.0) < 0.0001)
        #expect(abs((usage.swap ?? -1) - (9392120.0 - 3696504.0) / 9392120.0) < 0.0001)
    }

    @Test func parsesRocky() throws {
        let usage = try HostResourceUsage.parse(Self.rocky)
        // Δbusy = 77+0+33+0+11+84 = 205, Δidle = 216+35 = 251.
        #expect(abs(usage.cpu - 205.0 / 456.0) < 0.0001)
        #expect(abs(usage.memory - (4851016.0 - 1757732.0) / 4851016.0) < 0.0001)
    }

    @Test func linuxWithoutSwapHasNoSwap() throws {
        let output = Self.ubuntu
            .replacingOccurrences(of: "SwapTotal:       9392120 kB", with: "SwapTotal:       0 kB")
            .replacingOccurrences(of: "SwapFree:        3696504 kB", with: "SwapFree:        0 kB")
        #expect(try HostResourceUsage.parse(output).swap == nil)
    }

    @Test func linuxWithNoElapsedTicksReadsIdle() throws {
        let line = "cpu  161294055 1046 73229227 775281562 135795764 0 7841484 127868486 0 0"
        let output = """
            \(line)
            \(line)
            MemTotal:        4851016 kB
            MemAvailable:    1792396 kB
            SwapTotal:       0 kB
            SwapFree:        0 kB
            """
        #expect(try HostResourceUsage.parse(output).cpu == 0)
    }

    @Test func parsesMacOS() throws {
        let usage = try HostResourceUsage.parse(Self.macOS)
        #expect(abs(usage.cpu - 0.93) < 0.0001)
        let used = (515328.0 - 82 + 402626 + 1079267) * 16384 / 38654705664
        #expect(abs(usage.memory - used) < 1e-12)
        #expect(usage.swap == nil)
    }

    @Test func parsesMacOSSwap() throws {
        let output = Self.macOS.replacingOccurrences(
            of: "total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)",
            with: "total = 2048.00M  used = 1077.25M  free = 970.75M  (encrypted)")
        let swap = try #require(try HostResourceUsage.parse(output).swap)
        #expect(abs(swap - 1077.25 / 2048) < 0.0001)
    }

    @Test func garbageIsUnsupported() {
        #expect(throws: HostResourceUsage.Unsupported.self) {
            try HostResourceUsage.parse("sh: iostat: not found\nFreeBSD\n")
        }
    }

    @Test func linuxWithoutMemAvailableIsUnsupported() {
        let output = Self.ubuntu.replacingOccurrences(
            of: "MemAvailable:    1792396 kB\n", with: "")
        #expect(throws: HostResourceUsage.Unsupported.self) {
            try HostResourceUsage.parse(output)
        }
    }

    @Test func linuxSwapWithoutSwapFreeIsUnsupported() {
        let output = Self.ubuntu.replacingOccurrences(
            of: "SwapFree:        3696504 kB\n", with: "")
        #expect(throws: HostResourceUsage.Unsupported.self) {
            try HostResourceUsage.parse(output)
        }
    }

    /// Each field moves by a distinct power of two, scattered so that a
    /// one-position field shift changes the ratio: busy is user nice system
    /// irq softirq steal (8+1+64+16+512+4 = 605), idle is idle iowait
    /// (2+256 = 258), and guest/guest_nice (128, 32) count as neither.
    @Test func linuxCountsExactlyTheRightFields() throws {
        let output = """
            cpu  0 0 0 0 0 0 0 0 0 0
            cpu  8 1 64 2 256 16 512 4 128 32
            MemTotal:        100 kB
            MemAvailable:    50 kB
            SwapTotal:       0 kB
            SwapFree:        0 kB
            """
        #expect(try HostResourceUsage.parse(output).cpu == 605.0 / 863.0)
    }

    @Test func macOSWithSmallPagesAndLargePurgeable() throws {
        let output = """
            __WAYCAR_IOSTAT__= 10 5 85 1.00 1.00 1.00
            __WAYCAR_MEMSIZE__=8589934592
            __WAYCAR_SWAP__=total = 0.00M  used = 0.00M  free = 0.00M
            Mach Virtual Memory Statistics: (page size of 4096 bytes)
            Pages wired down:                             100000.
            Pages purgeable:                              400000.
            Anonymous pages:                              500000.
            Pages occupied by compressor:                  50000.
            """
        let usage = try HostResourceUsage.parse(output)
        let used = (500000.0 - 400000.0 + 100000.0 + 50000.0) * 4096.0 / 8589934592.0
        #expect(abs(usage.memory - used) < 1e-12)
        #expect(abs(usage.cpu - 0.15) < 1e-12)
    }

    /// Login-shell chatter prints before the command; the command's own
    /// marker is the last one.
    @Test func theLastMarkerWins() throws {
        let output = "__WAYCAR_IOSTAT__= 0 0 50 0 0 0\n" + Self.macOS
        #expect(abs(try HostResourceUsage.parse(output).cpu - 0.93) < 1e-12)
    }

    @Test(arguments: ["nan", "-nan", "inf", "infinity", "1e308", "-1"])
    func nonNumericLinuxValuesAreUnsupported(value: String) {
        let cpu = Self.ubuntu.replacingOccurrences(
            of: "cpu  161294147 1046", with: "cpu  \(value) 1046")
        let memory = Self.ubuntu.replacingOccurrences(
            of: "MemAvailable:    1792396 kB", with: "MemAvailable:    \(value) kB")
        let total = Self.ubuntu.replacingOccurrences(
            of: "MemTotal:        4851016 kB", with: "MemTotal:        \(value) kB")
        for output in [cpu, memory, total] {
            #expect(throws: HostResourceUsage.Unsupported.self) {
                try HostResourceUsage.parse(output)
            }
        }
    }

    @Test(arguments: ["nan", "-nan", "inf", "infinity", "1e308", "-1"])
    func nonFiniteOrOutOfRangeMacOSValuesAreUnsupported(value: String) {
        let idle = Self.macOS.replacingOccurrences(
            of: "__WAYCAR_IOSTAT__= 63 29  7 ", with: "__WAYCAR_IOSTAT__= 63 29  \(value) ")
        let swap = Self.macOS.replacingOccurrences(
            of: "total = 0.00M  used = 0.00M", with: "total = 2048.00M  used = \(value)M")
        let memsize = Self.macOS.replacingOccurrences(
            of: "__WAYCAR_MEMSIZE__=38654705664", with: "__WAYCAR_MEMSIZE__=\(value)")
        // A huge but finite swap figure is a number, just more than the
        // total: that is an implausible reading, not an unsupported Host
        // (`macOSSwapUsedOverTotalIsNoReading`).
        let outputs = value == "1e308" ? [idle, memsize] : [idle, swap, memsize]
        for output in outputs {
            #expect(throws: HostResourceUsage.Unsupported.self) {
                try HostResourceUsage.parse(output)
            }
        }
    }

    /// More swap in use than configured is no reading: not None (that means
    /// no swap configured) and not Unsupported (the Host stays asked), so
    /// this tick clears and the next one tries again.
    @Test(arguments: ["4096.00", "1e308"])
    func macOSSwapUsedOverTotalIsNoReading(used: String) {
        let output = Self.macOS.replacingOccurrences(
            of: "total = 0.00M  used = 0.00M", with: "total = 2048.00M  used = \(used)M")
        #expect(throws: HostResourceUsage.ImplausibleReading.self) {
            try HostResourceUsage.parse(output)
        }
    }

    @Test func macOSIdleOverAHundredIsUnsupported() {
        let output = Self.macOS.replacingOccurrences(
            of: "__WAYCAR_IOSTAT__= 63 29  7 ", with: "__WAYCAR_IOSTAT__= 63 29  101 ")
        #expect(throws: HostResourceUsage.Unsupported.self) {
            try HostResourceUsage.parse(output)
        }
    }

    @Test func outputOverTheCapIsUnsupported() {
        let padded = Data(Self.ubuntu.utf8) + Data(count: HostResourceUsage.outputLimit)
        #expect(throws: HostResourceUsage.Unsupported.self) {
            try HostResourceUsage.parse(padded)
        }
    }

    @Test func directValuesAreAlwaysFiniteFractions() {
        let usage = HostResourceUsage(cpu: .nan, memory: 1.7, swap: -0.2)
        #expect(usage.cpu == 0)
        #expect(usage.memory == 1)
        #expect(usage.swap == 0)
    }

    /// Running out of time is never a link failure: the Console must not
    /// distrust and redial a healthy connection because a sample waited for
    /// a channel or ran long.
    @Test func runningOutOfBudgetIsNotALinkFailure() {
        #expect(
            HostResourceUsage.replacingTimeout(TransportError.timedOut)
                is HostResourceUsage.TimedOut)
        #expect(
            HostResourceUsage.replacingTimeout(CancellationError()) as? TransportError
                == .cancelled)
        let other = TransportError.sshUnreachable(detail: "gone")
        #expect(HostResourceUsage.replacingTimeout(other) as? TransportError == other)
    }
}
