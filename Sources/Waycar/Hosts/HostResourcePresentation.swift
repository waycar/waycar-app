import Foundation

/// How hard a Host resource is working, from the percent the card shows:
/// color only when it warns, as AI Usage does. Computed on the rounded
/// displayed percent, so a gauge that reads "95%" is critical.
enum HostResourceLevel: Equatable {
    case normal
    case high
    case critical

    init(percent: Int) {
        self =
            switch percent {
            case 95...: .critical
            case 80...: .high
            default: .normal
            }
    }
}

/// The Hosts sheet card's CPU / MEMORY / SWAP band. Like
/// `HostTelemetryPresentation`, only an enabled, connected Host with a sample
/// renders
/// anything: nothing is preferable to a stale number, and a placeholder zero
/// would be a measurement the app never took. A Host without swap shows SWAP
/// as None — a fact about the Host, not a missing reading.
struct HostResourcePresentation: Equatable {
    struct Metric: Equatable, Identifiable {
        /// "CPU", "MEMORY" or "SWAP", shown as written.
        let label: String
        /// The whole percent shown; nil is None (swap only).
        let percent: Int?
        let level: HostResourceLevel

        var id: String { label }

        fileprivate init(label: String, percent: Int?) {
            self.label = label
            self.percent = percent
            level = percent.map(HostResourceLevel.init(percent:)) ?? .normal
        }
    }

    /// Always CPU, MEMORY, SWAP, in that order.
    let metrics: [Metric]
    let accessibilityLabel: String

    /// nil for a Disabled Host, a Host that is not connected, or one with no
    /// sample yet.
    init?(isEnabled: Bool, status: EventsSessionStatus?, usage: HostResourceUsage?) {
        guard isEnabled, status == .connected, let usage else { return nil }
        let cpu = Self.percent(usage.cpu)
        let memory = Self.percent(usage.memory)
        let swap = usage.swap.map(Self.percent)
        metrics = [
            Metric(label: "CPU", percent: cpu),
            Metric(label: "MEMORY", percent: memory),
            Metric(label: "SWAP", percent: swap),
        ]
        let spokenSwap = swap.map { "swap \($0) percent" } ?? "no swap"
        accessibilityLabel = "CPU \(cpu) percent, memory \(memory) percent, \(spokenSwap)"
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }
}
