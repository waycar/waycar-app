import Darwin
import Foundation
import Synchronization
import Testing

@testable import WaycarSSH

@Test("a bridge write to a closed peer reports peerClosed")
func bridgeWriteToClosedPeerReportsPeerClosed() throws {
    let transport = try DirectTCPIPByteTransport()
    var innerDescriptor = try transport.takeDescriptor()
    let pumpDescriptor = try transport.takePumpDescriptor()
    defer {
        if innerDescriptor >= 0 { Darwin.close(innerDescriptor) }
        Darwin.close(pumpDescriptor)
    }

    Darwin.close(innerDescriptor)
    innerDescriptor = -1

    let result = try SessionDriver.writeBridge(
        Data("pending outer bytes".utf8),
        descriptor: pumpDescriptor)

    #expect(result == .peerClosed)
}

// The pump reports the errno that ended a bridge write (#351). Folding it into
// `connectionFailed` inside `writeBridge` is what left a dead pump and a live
// one indistinguishable in a CI log, so the errno has to survive the throw.
@Test("a bridge write to an invalid descriptor surfaces its errno")
func bridgeWriteToInvalidDescriptorSurfacesErrno() throws {
    // -1 is never a valid descriptor. A just-closed descriptor is not safe
    // here: tests run in parallel, and another test can be handed the same
    // number before the write, which then succeeds. EPIPE would be reported
    // as `peerClosed` instead, which is the branch the test above covers.
    #expect(throws: SessionDriver.BridgeWriteFailure(code: EBADF)) {
        _ = try SessionDriver.writeBridge(
            Data("pending outer bytes".utf8),
            descriptor: -1)
    }
}

// MARK: Byte transport ownership (P3c, SSH-17)

/// How a pump or a close ended, comparable (`Result<Void, _>` is not).
private func failure(of result: Result<Void, SSHError>) -> SSHError? {
    if case .failure(let error) = result { return error }
    return nil
}

/// A pump stand-in that ends only when cancelled, as the real pump does once
/// it is cancelled and its channel cleanup ran.
private func pumpEndingOnCancellation() -> Task<Result<Void, SSHError>, Never> {
    Task {
        do {
            try await Task.sleep(for: .seconds(3_600))
            return .success(())
        } catch {
            return .failure(.cancelled)
        }
    }
}

@Test("each byte transport descriptor is handed out once")
func byteTransportHandsEachDescriptorOutOnce() throws {
    let transport = try DirectTCPIPByteTransport()
    let inner = try transport.takeDescriptor()
    let pump = try transport.takePumpDescriptor()
    defer {
        Darwin.close(inner)
        Darwin.close(pump)
    }
    #expect(throws: SSHError.connectionInvalidated) { _ = try transport.takeDescriptor() }
    #expect(throws: SSHError.connectionInvalidated) { _ = try transport.takePumpDescriptor() }
}

@Test("aborting an unstarted byte transport closes both descriptors it still owns")
func abortingAnUnstartedByteTransportClosesItsDescriptors() throws {
    let transport = try DirectTCPIPByteTransport()
    transport.abort()
    #expect(throws: SSHError.connectionInvalidated) { _ = try transport.takeDescriptor() }
    #expect(throws: SSHError.connectionInvalidated) { _ = try transport.takePumpDescriptor() }
    // A second abort has nothing left to close.
    transport.abort()
}

@Test("aborting a started byte transport cancels its pump and closes the inner descriptor")
func abortingAStartedByteTransportCancelsItsPump() async throws {
    let transport = try DirectTCPIPByteTransport()
    let pump = try transport.takePumpDescriptor()
    defer { Darwin.close(pump) }
    let task = pumpEndingOnCancellation()
    transport.start(task)
    transport.abort()
    #expect(failure(of: await task.value) == .cancelled)
    #expect(throws: SSHError.connectionInvalidated) { _ = try transport.takeDescriptor() }
}

@Test("closing a byte transport whose pump never started returns at once")
func closingAnUnstartedByteTransportReturns() async throws {
    let transport = try DirectTCPIPByteTransport()
    try await transport.close(timeout: .seconds(5))
    transport.abort()
}

@Test("closing a byte transport reports how its pump ended")
func closingAByteTransportReportsThePumpResult() async throws {
    for outcome: Result<Void, SSHError> in [.success(()), .failure(.connectionFailed)] {
        let transport = try DirectTCPIPByteTransport()
        let pump = try transport.takePumpDescriptor()
        defer { Darwin.close(pump) }
        transport.start(Task { outcome })
        let closed: Result<Void, SSHError>
        do {
            try await transport.close(timeout: .seconds(30))
            closed = .success(())
        } catch let error as SSHError {
            closed = .failure(error)
        }
        #expect(failure(of: closed) == failure(of: outcome))
        transport.abort()
    }
}

/// B-27: a pump that is still running when the close's timeout runs out is
/// cancelled then, so the close returns `timedOut` once the pump has ended,
/// instead of waiting for a pump that nothing cancels.
@Test("closing a byte transport past its timeout cancels the pump and returns")
func closingAByteTransportPastItsTimeoutCancelsThePump() async throws {
    let transport = try DirectTCPIPByteTransport()
    let pump = try transport.takePumpDescriptor()
    defer { Darwin.close(pump) }
    transport.start(pumpEndingOnCancellation())

    let closing = Task { () -> SSHError? in
        do {
            try await transport.close(timeout: .milliseconds(100))
            return nil
        } catch let error as SSHError {
            return error
        } catch {
            return .channelFailed
        }
    }
    let finished = Mutex<(done: Bool, error: SSHError?)>((false, nil))
    let watcher = Task {
        let result = await closing.value
        finished.withLock { $0 = (true, result) }
    }
    // The close should be back within its timeout and the pump's own end;
    // 10 s is far beyond both.
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !finished.withLock({ $0.done }), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
        finished.withLock { $0.done },
        "the close was still waiting for its pump 10 s after a 100 ms timeout")
    // Unblock a close stuck on the pump, so a failure ends the test.
    transport.abort()
    await watcher.value
    #expect(finished.withLock { $0.error } == .timedOut)
}
