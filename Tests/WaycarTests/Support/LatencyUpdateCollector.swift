/// Counts `EventsSession.latencyUpdates` emissions a test drains
/// concurrently, since the stream itself only buffers its newest value.
actor LatencyUpdateCollector {
    private(set) var count = 0
    func record() { count += 1 }
}
