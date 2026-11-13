import Testing

extension Duration {
    /// How long a test waits for something that should happen before it
    /// fails. Only a failing test waits it out, so it is generous: CI's test
    /// host shares a busy Mac with a runner at nice 15 (and, for public CI,
    /// GitHub's slower hosted Macs), where the main thread can stall for
    /// seconds. A window that asserts something does *not* happen stays short
    /// and explicit instead, and a time window the code under test measures
    /// takes an injected clock rather than a longer real one.
    static let waitCeiling: Duration = .seconds(30)
}

/// Polls `condition` with `Task.sleep` until it holds, and records a failure
/// at the call site when it still does not after `timeout`. It returns on the
/// first success: re-checking a condition the code may move past (a status
/// the next event changes) only adds a race. Runs on the caller's actor, so
/// the condition can read its state directly.
func waitUntil(
    _ comment: Comment? = nil,
    timeout: Duration = .waitCeiling,
    sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation,
    condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await condition(), comment, sourceLocation: sourceLocation)
}
