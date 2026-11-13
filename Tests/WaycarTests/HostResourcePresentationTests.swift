import Testing

@testable import Waycar

@Suite("Host resource presentation")
struct HostResourcePresentationTests {
    private func connected(_ usage: HostResourceUsage?) -> HostResourcePresentation? {
        HostResourcePresentation(isEnabled: true, status: .connected, usage: usage)
    }

    @Test func roundsToWholePercentsInBandOrder() throws {
        let presentation = try #require(
            connected(HostResourceUsage(cpu: 0.2349, memory: 0.6051, swap: 0.125)))
        #expect(presentation.metrics.map(\.label) == ["CPU", "MEMORY", "SWAP"])
        #expect(presentation.metrics.map(\.percent) == [23, 61, 13])
        #expect(
            presentation.accessibilityLabel
                == "CPU 23 percent, memory 61 percent, swap 13 percent")
    }

    @Test func aHostWithoutSwapShowsNone() throws {
        let presentation = try #require(
            connected(HostResourceUsage(cpu: 0.18, memory: 0.64, swap: nil)))
        let swap = try #require(presentation.metrics.last)
        #expect(swap.label == "SWAP")
        #expect(swap.percent == nil)
        #expect(swap.level == .normal)
        #expect(presentation.accessibilityLabel == "CPU 18 percent, memory 64 percent, no swap")
    }

    /// Swap configured but unused is a measured 0%, not None.
    @Test func unusedSwapIsZeroPercentNotNone() throws {
        let presentation = try #require(
            connected(HostResourceUsage(cpu: 0.18, memory: 0.64, swap: 0)))
        let swap = try #require(presentation.metrics.last)
        #expect(swap.percent == 0)
        #expect(swap.level == .normal)
        #expect(
            presentation.accessibilityLabel
                == "CPU 18 percent, memory 64 percent, swap 0 percent")
    }

    /// The level follows the percent the card shows: 79.4% reads "79%" and
    /// stays neutral, 94.6% reads "95%" and is critical.
    @Test(arguments: [
        (0.0, 0, HostResourceLevel.normal),
        (0.794, 79, .normal),
        (0.796, 80, .high),
        (0.80, 80, .high),
        (0.944, 94, .high),
        (0.946, 95, .critical),
        (0.95, 95, .critical),
        (1.0, 100, .critical),
    ])
    func levelsFollowTheDisplayedPercent(
        fraction: Double, percent: Int, level: HostResourceLevel
    ) throws {
        let presentation = try #require(
            connected(HostResourceUsage(cpu: fraction, memory: fraction, swap: fraction)))
        for metric in presentation.metrics {
            #expect(metric.percent == percent, "\(metric.label)")
            #expect(metric.level == level, "\(metric.label) at \(percent)%")
        }
    }

    /// Each gauge has its own level.
    @Test func eachMetricHasItsOwnLevel() throws {
        let presentation = try #require(
            connected(HostResourceUsage(cpu: 0.96, memory: 0.10, swap: 0.85)))
        #expect(presentation.metrics.map(\.level) == [.critical, .normal, .high])
    }

    @Test func connectedWithoutASampleRendersNothing() {
        #expect(connected(nil) == nil)
    }

    @Test func everyUnprovenStatusOrADisabledHostRendersNothingEvenWithASample() {
        let usage = HostResourceUsage(cpu: 0.5, memory: 0.5, swap: nil)
        let unproven: [EventsSessionStatus?] = [
            .connecting,
            .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
            .failed(.authenticationFailed),
            .suspended,
            .ended,
            nil,
        ]

        for status in unproven {
            #expect(
                HostResourcePresentation(isEnabled: true, status: status, usage: usage) == nil,
                "\(String(describing: status)) must not show resource use")
        }
        #expect(
            HostResourcePresentation(isEnabled: false, status: .connected, usage: usage) == nil,
            "a Disabled Host must not show resource use")
    }
}
