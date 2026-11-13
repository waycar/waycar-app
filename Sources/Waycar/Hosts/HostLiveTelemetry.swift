import Foundation
import Observation

/// What `HostLiveTelemetry` samples: the Console, or a fake in tests.
@MainActor
protocol HostLiveTelemetrySource: AnyObject {
    /// Hosts whose Console connection is `.connected` right now.
    var connectedHostIDs: Set<Host.ID> { get }
    /// Re-measures and republishes the Host's latency badge; true only when
    /// the ping proved the Host's live connection.
    func sampleLatency(on hostID: Host.ID) async -> Bool
    /// One CPU / memory / swap sample over the Host's live connection.
    func hostResourceUsage(on hostID: Host.ID) async throws -> HostResourceUsage
}

/// The Hosts sheet's live numbers: while `run()` is running, every
/// `interval` each connected Host re-measures its latency and then samples
/// its CPU / memory / swap use. Lives with the sheet; nothing is sampled, and
/// nothing is kept, once the sheet stops running it.
@MainActor
@Observable
final class HostLiveTelemetry {
    /// The latest sample per connected Host, only from the current `run()`.
    private(set) var usage: [Host.ID: HostResourceUsage] = [:]

    @ObservationIgnored private let source: any HostLiveTelemetrySource
    @ObservationIgnored private let interval: Duration
    /// Hosts with a sample still in flight: at most one per Host.
    @ObservationIgnored private var inFlight: Set<Host.ID> = []
    /// Hosts whose OS the command does not understand; not asked again
    /// during this run.
    @ObservationIgnored private var unsupported: Set<Host.ID> = []
    /// The running `run()`, so a sample finishing after it ended is dropped.
    @ObservationIgnored private var runGeneration: Int?
    @ObservationIgnored private var lastGeneration = 0

    init(source: any HostLiveTelemetrySource, interval: Duration = .seconds(2)) {
        self.source = source
        self.interval = interval
    }

    /// Samples until cancelled, then drops every sample. Each Host's work
    /// runs in its own unstructured Task — ping first, then the resource
    /// command, so the ping stays off the exec's channel open — so
    /// cancelling this loop never cuts an RPC off mid-flight; it only stops
    /// scheduling new ones. A later `run()` supersedes this one: the old loop
    /// stops scheduling, and neither its exit nor its late answers touch the
    /// new run's samples.
    func run() async {
        lastGeneration += 1
        let generation = lastGeneration
        runGeneration = generation
        defer {
            if runGeneration == generation {
                runGeneration = nil
                usage = [:]
                unsupported = []
            }
        }
        while !Task.isCancelled, runGeneration == generation {
            schedule(generation: generation)
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    private func schedule(generation: Int) {
        let connected = source.connectedHostIDs
        usage = usage.filter { connected.contains($0.key) }
        for hostID in connected where !inFlight.contains(hostID) {
            inFlight.insert(hostID)
            Task { await self.sample(hostID, generation: generation) }
        }
    }

    private func sample(_ hostID: Host.ID, generation: Int) async {
        defer { inFlight.remove(hostID) }
        let proved = await source.sampleLatency(on: hostID)
        guard runGeneration == generation else { return }
        // An unproved ping skips the exec: it would only queue behind a link
        // the Console may be replacing. The current sample stays — a healthy
        // `.connected` Host's ping is unproved during every pane-subscription
        // reinstall, and real trouble already hides the line through its
        // status and `schedule()`'s filter.
        guard proved else { return }
        guard !unsupported.contains(hostID) else { return }
        do {
            let sample = try await source.hostResourceUsage(on: hostID)
            guard runGeneration == generation, source.connectedHostIDs.contains(hostID) else {
                return
            }
            usage[hostID] = sample
        } catch {
            // No stale number: a failed sample clears the line until the
            // next one lands. An unsupported Host is not asked again.
            guard runGeneration == generation else { return }
            usage[hostID] = nil
            if error is HostResourceUsage.Unsupported {
                unsupported.insert(hostID)
            }
        }
    }
}
