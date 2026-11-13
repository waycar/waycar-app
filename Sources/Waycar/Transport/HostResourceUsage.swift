import Foundation

/// A Host's CPU, memory and swap use, each a fraction in 0…1, sampled by one
/// Host command (``command``). `swap` is nil when the Host has no swap
/// configured. CPU is measured over a one-second window on the Host itself,
/// so the parser needs no baseline from an earlier sample.
///
/// Inside a container `/proc` reports the container host's numbers, the same
/// figures `free` and `top` show there.
struct HostResourceUsage: Sendable, Equatable {
    let cpu: Double
    let memory: Double
    let swap: Double?

    init(cpu: Double, memory: Double, swap: Double?) {
        self.cpu = Self.clamped(cpu)
        self.memory = Self.clamped(memory)
        self.swap = swap.map(Self.clamped)
    }

    /// The Host's output matched neither the Linux nor the macOS shape, or
    /// carried a value no real Host prints (non-numeric, non-finite).
    struct Unsupported: Error, Equatable {}

    /// The Host answered in a known shape with a reading that cannot be
    /// right (macOS swap in use over the configured total). Transient, unlike
    /// ``Unsupported``: this tick has no sample and the next asks again.
    struct ImplausibleReading: Error, Equatable {}

    /// The sample could not get a channel within ``admissionBudget`` or its
    /// exec outlived ``execBudget``. Deliberately not
    /// `TransportError.timedOut`: a slow sample says nothing about the link,
    /// and a link failure would make the Console distrust and redial a
    /// healthy connection. Liveness stays the ping's job.
    struct TimedOut: Error, Equatable {}

    /// How long a sample waits for an ordinary session channel. A saturated
    /// connection skips the tick rather than queueing samples behind work.
    /// Only this wait is bounded from outside: cancelling an exec mid
    /// channel-open would make the SSH layer invalidate the whole connection.
    static let admissionBudget: Duration = .seconds(2)

    /// The exec's own SSH deadline, covering the command's one-second
    /// window plus a slow non-interactive shell start.
    static let execBudget: Duration = .seconds(5)

    /// More output than this is not the command's: a few hundred bytes on
    /// Linux, about 1.5 KB on macOS, plus any login-shell chatter.
    static let outputLimit = 64 * 1024

    /// POSIX `sh` regardless of the account's login shell (which may be
    /// fish). Linux reads `/proc` twice a second apart; macOS asks `iostat`
    /// for a one-second CPU window and reads memory from `vm_stat`/`sysctl`,
    /// by absolute path so the Host's PATH does not matter.
    static let command =
        "/bin/sh -c '"
        + "if [ -r /proc/stat ] && [ -r /proc/meminfo ]; then "
        + "head -n 1 /proc/stat; sleep 1; head -n 1 /proc/stat; "
        + "grep -E \"^(MemTotal|MemAvailable|SwapTotal|SwapFree):\" /proc/meminfo; "
        + "else "
        + "printf \"\(iostatMarker)%s\\n\" "
        + "\"$(/usr/sbin/iostat -c 2 -w 1 -n 0 | /usr/bin/tail -n 1)\"; "
        + "printf \"\(memsizeMarker)%s\\n\" \"$(/usr/sbin/sysctl -n hw.memsize)\"; "
        + "printf \"\(swapMarker)%s\\n\" \"$(/usr/sbin/sysctl -n vm.swapusage)\"; "
        + "/usr/bin/vm_stat; "
        + "fi'"

    static let iostatMarker = "__WAYCAR_IOSTAT__="
    static let memsizeMarker = "__WAYCAR_MEMSIZE__="
    static let swapMarker = "__WAYCAR_SWAP__="

    /// Maps the sample running out of time — the admission wait or the
    /// exec's own deadline, both `TransportError.timedOut` by then — to
    /// ``TimedOut``; cancellation to `TransportError.cancelled`. Everything
    /// else passes through.
    static func replacingTimeout(_ error: any Error) -> any Error {
        if error is CancellationError { return TransportError.cancelled }
        if error as? TransportError == .timedOut {
            return TimedOut()
        }
        return error
    }

    static func parse(_ output: Data) throws -> HostResourceUsage {
        guard output.count <= outputLimit else { throw Unsupported() }
        return try parse(String(decoding: output, as: UTF8.self))
    }

    static func parse(_ output: String) throws -> HostResourceUsage {
        guard output.utf8.count <= outputLimit else { throw Unsupported() }
        let lines = output.split(whereSeparator: \.isNewline)
        if let usage = try linux(lines) ?? macOS(lines) {
            return usage
        }
        throw Unsupported()
    }

    // MARK: Linux

    private static func linux(_ lines: [Substring]) -> HostResourceUsage? {
        let cpuLines = lines.filter { $0.hasPrefix("cpu ") }.suffix(2)
        guard cpuLines.count == 2,
            let first = cpuTimes(cpuLines[cpuLines.startIndex]),
            let second = cpuTimes(cpuLines[cpuLines.startIndex + 1])
        else { return nil }
        let busy = second.busy - first.busy
        let total = busy + (second.idle - first.idle)
        let cpu = total > 0 ? busy / total : 0

        // Later lines win, like the macOS markers: chatter comes first.
        var meminfo: [Substring: Double] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                let token = parts[1].split(separator: " ", maxSplits: 1).first,
                let value = UInt64(token)
            else { continue }
            meminfo[parts[0]] = Double(value)
        }
        guard let memTotal = meminfo["MemTotal"], memTotal > 0,
            let memAvailable = meminfo["MemAvailable"],
            let swapTotal = meminfo["SwapTotal"]
        else { return nil }
        let swap: Double?
        if swapTotal > 0 {
            guard let swapFree = meminfo["SwapFree"] else { return nil }
            swap = (swapTotal - swapFree) / swapTotal
        } else {
            swap = nil
        }
        return finite(cpu: cpu, memory: (memTotal - memAvailable) / memTotal, swap: swap)
    }

    /// `user nice system idle iowait irq softirq steal`; guest time is
    /// already counted in user/nice, so the fields after steal are ignored.
    private static func cpuTimes(_ line: Substring) -> (busy: Double, idle: Double)? {
        let tokens = line.split(separator: " ", maxSplits: 9).dropFirst().prefix(8)
        let fields = tokens.compactMap { UInt64($0) }.map(Double.init)
        guard fields.count == 8 else { return nil }
        let idle = fields[3] + fields[4]
        let busy = fields[0] + fields[1] + fields[2] + fields[5] + fields[6] + fields[7]
        return (busy, idle)
    }

    // MARK: macOS

    private static func macOS(_ lines: [Substring]) throws -> HostResourceUsage? {
        func marked(_ marker: String) -> Substring? {
            lines.last { $0.hasPrefix(marker) }.map { $0.dropFirst(marker.count) }
        }
        // iostat: `us sy id 1m 5m 15m`.
        guard let iostat = marked(iostatMarker)?.split(separator: " ", maxSplits: 3),
            iostat.count >= 3, let idle = Double(iostat[2]), idle.isFinite,
            (0...100).contains(idle),
            let memsizeText = marked(memsizeMarker),
            let memsize = UInt64(memsizeText.trimmingCharacters(in: .whitespaces)), memsize > 0,
            let pageSize = vmStatPageSize(lines),
            let swapText = marked(swapMarker),
            let swap = swapFraction(swapText)
        else { return nil }

        var pages: [Substring: UInt64] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(".") { value.removeLast() }
            if let number = UInt64(value) { pages[parts[0]] = number }
        }
        // Activity Monitor's "Memory Used": App + Wired + Compressed.
        guard let anonymous = pages["Anonymous pages"],
            let purgeable = pages["Pages purgeable"],
            let wired = pages["Pages wired down"],
            let compressed = pages["Pages occupied by compressor"]
        else { return nil }
        let app = Double(anonymous) - Double(purgeable)
        let used = (app + Double(wired) + Double(compressed)) * Double(pageSize)
        return finite(
            cpu: (100 - idle) / 100, memory: used / Double(memsize), swap: try swap.fraction())
    }

    /// `Mach Virtual Memory Statistics: (page size of 16384 bytes)`.
    private static func vmStatPageSize(_ lines: [Substring]) -> UInt64? {
        guard let header = lines.last(where: { $0.contains("page size of ") }),
            let range = header.range(of: "page size of "),
            let token = header[range.upperBound...].split(separator: " ", maxSplits: 1).first,
            let size = UInt64(token), size > 0
        else { return nil }
        return size
    }

    /// `total = 2048.00M  used = 1077.25M  free = 970.75M  (encrypted)`.
    /// nil when malformed.
    private static func swapFraction(_ line: Substring) -> SwapReading? {
        func megabytes(_ key: String) -> Double? {
            guard let range = line.range(of: "\(key) = ") else { return nil }
            let token = line[range.upperBound...].prefix { !$0.isWhitespace }
            guard token.hasSuffix("M"), let value = Double(token.dropLast()),
                value.isFinite, value >= 0
            else { return nil }
            return value
        }
        guard let total = megabytes("total"), let used = megabytes("used") else { return nil }
        return SwapReading(total: total, used: used)
    }

    private struct SwapReading {
        let total: Double
        let used: Double

        /// The share in use; nil for a Host without swap (zero total), which
        /// the card shows as None. More in use than configured cannot be
        /// right, and must not read as None either: it throws
        /// ``ImplausibleReading`` so this tick has no sample and the next
        /// one asks again.
        func fraction() throws -> Double? {
            guard total > 0 else { return nil }
            guard used <= total else { throw ImplausibleReading() }
            return used / total
        }
    }

    /// Rejects a sample whose arithmetic left the finite numbers: never a
    /// made-up zero.
    private static func finite(cpu: Double, memory: Double, swap: Double?) -> HostResourceUsage? {
        guard cpu.isFinite, memory.isFinite, swap?.isFinite ?? true else { return nil }
        return HostResourceUsage(cpu: cpu, memory: memory, swap: swap)
    }

    /// Defence in depth for direct inits (demo, tests); mirrors
    /// `AIUsageReport.clampedPercent`.
    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
